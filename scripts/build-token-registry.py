#!/usr/bin/env python3
"""Build BitTool Signer's offline token registry and bundled token icons.

This is a build-time tool. It may use the network; the iOS app never downloads
token metadata or icons at runtime.

Usage
-----
    python3 scripts/build-token-registry.py [--cache-dir DIR] [--offline]
                                            [--network KEY ...] [--dry-run]

    --cache-dir DIR  Where HTTP responses are cached (default:
                     $TMPDIR/bittool-signer-token-registry-cache). Re-runs reuse it.
    --offline        Never touch the network; every response must be cached.
    --network KEY    Only verify/print the given network(s) (ethereum,
                     smartchain, arbitrum, base, tron, solana). Implies
                     --dry-run because a partial registry must not be written.
    --dry-run        Verify everything but write nothing.

Requirements: Python 3.9+ and Pillow (pip install pillow). A first run makes
about 100 rate-limited CoinGecko requests (paced ~6.5 s apart, backing off on
HTTP 429) and can take 15-30 minutes; later runs are served from the cache.
Setting COINGECKO_DEMO_API_KEY (optional, free CoinGecko demo key) raises the
rate limit.

Inputs
------
engine/data/token-source-selection.json is the frozen selection. It pins, per
network and in popularity order, every exact contract / mint address together
with the curated display name/symbol, the expected decimals, the CoinGecko coin
id and the icon source. Re-running this script therefore reproduces the
registry without re-ranking anything.

What is verified for every pinned token (the build aborts on any failure)
-----------------------------------------------------------------------
* CoinGecko: the coin id maps to exactly this address on the network
  (api/v3/coins/list?include_platform=true), and decimals agree with the
  CoinGecko token list for the platform when it lists the token.
* Trust Wallet assets (pinned commit): info.json, when present, must be
  status "active" with the same decimals. Tokens without a Trust Wallet record
  use the CoinGecko coin record (api/v3/coins/<id>) as metadata source and its
  per-platform decimals must agree.
* Independent token lists (Uniswap default list, 1inch lists, CoinMarketCap
  list, MyEtherWallet lists, PancakeSwap extended list, Arbitrum token lists,
  Superchain token list, Jupiter verified list, TronScan), or the issuer's own
  documentation pinned as `officialSource` (its raw page must contain the exact
  address): presence is recorded;
  any decimals disagreement aborts, except for the CoinMarketCap list whose
  decimals are known to be unreliable (recorded as decimalsDisagreement).
  At least one source independent of CoinGecko must list the token.
* On-chain via public RPC: EVM decimals()/symbol(); TRON decimals()/symbol()
  through TronGrid triggerconstantcontract; Solana getMultipleAccounts
  (jsonParsed) for mint decimals and owner token program, plus the Metaplex
  metadata account or Token-2022 metadata extension for the on-chain symbol.
  On-chain decimals are the source of truth and must equal the pinned value.
* Symbols: a display symbol or Trust Wallet symbol that differs from the
  on-chain symbol requires an explanatory "note" in the selection.

Icons: the pinned icon URL (normally Trust Wallet logo.png at the pinned
commit, otherwise CoinGecko's large image) is decoded with Pillow, rejected if
tiny, fully transparent or a flat placeholder, converted to RGBA, fitted into a
transparent 128x128 canvas and saved as an optimized PNG in
engine/data/curated-icons/token_<network>_<first 16 hex of sha256(address)>.png.
On a successful non-dry run every existing curated icon file is deleted
and regenerated; no other asset is touched.

Output: engine/data/token-registry.json, the curated layer with full
provenance. It is an input, not something the app reads: what the app and the
engine ship is produced by scripts/build-expanded-registry.py, which merges
this file with the CoinMarketCap snapshot. Run that afterwards.
"""
from __future__ import annotations

import argparse
import base64
import concurrent.futures
import hashlib
import io
import json
import os
import pathlib
import shutil
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

try:
    from PIL import Image, ImageStat
except ImportError:  # pragma: no cover
    sys.exit('Pillow is required: python3 -m pip install pillow')

ROOT = pathlib.Path(__file__).resolve().parents[1]
SELECTION = ROOT / 'engine/data/token-source-selection.json'
# The curated layer only. build-expanded-registry.py merges it with the
# CoinMarketCap snapshot and writes everything the app and the engine ship.
OUTPUTS = [ROOT / 'engine/data/token-registry.json']
ASSETS = ROOT / 'BitToolSigner/Assets.xcassets'
CURATED_ICONS = ROOT / 'engine/data/curated-icons'
ICON_SIZE = 128
CONTENTS_JSON = {'images': [{'filename': 'icon.png', 'idiom': 'universal'}], 'info': {'author': 'xcode', 'version': 1}}
TOKENKEG = 'TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA'
TOKEN_2022 = 'TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb'
METAPLEX = 'metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s'
UA = 'BitTool Signer-token-registry-build/2 (+https://github.com; build-time only)'

EVM_RPC = {
    '1': ['https://ethereum-rpc.publicnode.com', 'https://eth.llamarpc.com'],
    '56': ['https://bsc-rpc.publicnode.com', 'https://bsc-dataseed.bnbchain.org'],
    '42161': ['https://arbitrum-one-rpc.publicnode.com', 'https://arb1.arbitrum.io/rpc'],
    '8453': ['https://base-rpc.publicnode.com', 'https://mainnet.base.org'],
}
SOLANA_RPC = ['https://api.mainnet-beta.solana.com', 'https://solana-rpc.publicnode.com']
TRONGRID = 'https://api.trongrid.io/wallet/triggerconstantcontract'
TRON_ZERO_OWNER = 'T9yD14Nj9j7xAB4dbGeiX9h8unkKHxuWwb'
COINGECKO = 'https://api.coingecko.com/api/v3'

# Independent token lists used for cross-checking (network key -> [(name, url, chainId filter)]).
MEW = 'https://raw.githubusercontent.com/MyEtherWallet/ethereum-lists/master/dist/tokens/{0}/tokens-{0}.json'
TOKEN_LISTS = {
    'ethereum': [('uniswap', 'https://tokens.uniswap.org', 1), ('1inch', 'https://tokens.1inch.io/v1.2/1', 1),
                 ('coinmarketcap', 'https://api.coinmarketcap.com/data-api/v3/uniswap/all.json', 1),
                 ('myetherwallet', MEW.format('eth'), 1)],
    'smartchain': [('uniswap', 'https://tokens.uniswap.org', 56), ('1inch', 'https://tokens.1inch.io/v1.2/56', 56),
                   ('pancakeswap', 'https://tokens.pancakeswap.finance/pancakeswap-extended.json', 56),
                   ('myetherwallet', MEW.format('bsc'), 56)],
    'arbitrum': [('uniswap', 'https://tokens.uniswap.org', 42161), ('1inch', 'https://tokens.1inch.io/v1.2/42161', 42161),
                 ('arbitrum-whitelist', 'https://tokenlist.arbitrum.io/ArbTokenLists/arbed_arb_whitelist_era.json', 42161),
                 ('arbitrum-uniswap', 'https://tokenlist.arbitrum.io/ArbTokenLists/arbed_uniswap_labs.json', 42161),
                 ('myetherwallet', MEW.format('arb'), 42161)],
    'base': [('uniswap', 'https://tokens.uniswap.org', 8453), ('1inch', 'https://tokens.1inch.io/v1.2/8453', 8453),
             ('superchain', 'https://static.optimism.io/optimism.tokenlist.json', 8453),
             ('myetherwallet', MEW.format('base'), 8453)],
    'tron': [],
    'solana': [],
}
# The CoinMarketCap list confirms addresses but its decimals are unreliable (it lists USDT, USDC and WBTC
# on Ethereum with 18 decimals). It is used for address presence only; on-chain decimals are the truth and
# any disagreement is recorded in verification.decimalsDisagreement instead of failing the build.
PRESENCE_ONLY_LISTS = {'coinmarketcap'}
JUPITER_VERIFIED = 'https://lite-api.jup.ag/tokens/v2/tag?query=verified'
TRONSCAN_TOKEN = 'https://apilist.tronscanapi.com/api/token_trc20?contract={}&showAll=1&start=0&limit=20'


class BuildError(Exception):
    pass


# --------------------------------------------------------------------------- HTTP

class Http:
    """Tiny cached HTTP client. Responses are cached by URL+body; 429/5xx are retried."""

    def __init__(self, cache_dir: pathlib.Path, offline: bool):
        self.cache = cache_dir
        self.cache.mkdir(parents=True, exist_ok=True)
        self.offline = offline
        self.lock = threading.Lock()
        self.last_call: dict[str, float] = {}

    def _pace(self, url: str):
        host = url.split('/')[2]
        gap = 6.5 if host == 'api.coingecko.com' else (1.2 if 'tronscan' in host or 'trongrid' in host else 0.0)
        if not gap:
            return
        with self.lock:
            wait = self.last_call.get(host, 0) + gap - time.monotonic()
            if wait > 0:
                time.sleep(wait)
            self.last_call[host] = time.monotonic()

    def get(self, url: str, body: bytes | None = None, allow_404: bool = False, max_bytes: int = 40_000_000,
            headers: dict | None = None) -> bytes | None:
        key = hashlib.sha256(url.encode() + b'\n' + (body or b'')).hexdigest()
        path = self.cache / key
        if path.exists():
            data = path.read_bytes()
            return None if data == b'\x00404' else data
        if self.offline:
            raise BuildError(f'--offline and not cached: {url}')
        hdrs = {'User-Agent': UA, 'Accept': '*/*'}
        if body is not None:
            hdrs['Content-Type'] = 'application/json'
        hdrs.update(headers or {})
        if url.startswith(COINGECKO) and os.environ.get('COINGECKO_DEMO_API_KEY'):
            hdrs['x-cg-demo-api-key'] = os.environ['COINGECKO_DEMO_API_KEY']  # optional; not part of the cache key
        delay = 5.0
        for attempt in range(9):
            self._pace(url)
            try:
                req = urllib.request.Request(url, data=body, headers=hdrs)
                with urllib.request.urlopen(req, timeout=60) as resp:
                    data = resp.read(max_bytes + 1)
                if len(data) > max_bytes:
                    raise BuildError(f'response too large: {url}')
                tmp = path.with_suffix('.tmp')
                tmp.write_bytes(data)
                tmp.replace(path)
                return data
            except urllib.error.HTTPError as e:
                if e.code == 404 and allow_404:
                    path.write_bytes(b'\x00404')
                    return None
                if e.code in (429, 500, 502, 503, 504) and attempt < 8:
                    retry_after = e.headers.get('Retry-After')
                    time.sleep(min(float(retry_after) if retry_after and retry_after.isdigit() else delay, 90))
                    delay = min(delay * 2, 90)
                    continue
                raise BuildError(f'HTTP {e.code} for {url}') from e
            except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
                if attempt < 8:
                    time.sleep(delay)
                    delay = min(delay * 2, 60)
                    continue
                raise BuildError(f'network error for {url}: {e}') from e
        raise BuildError(f'giving up on {url}')

    def json(self, url: str, body=None, **kw):
        raw = self.get(url, None if body is None else json.dumps(body, sort_keys=True).encode(), **kw)
        return None if raw is None else json.loads(raw)


# --------------------------------------------------------------------------- encodings

B58 = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'


def b58decode(s: str) -> bytes:
    n = 0
    for ch in s:
        n = n * 58 + B58.index(ch)
    body = n.to_bytes((n.bit_length() + 7) // 8, 'big') if n else b''
    return b'\x00' * (len(s) - len(s.lstrip('1'))) + body


def b58encode(b: bytes) -> str:
    n = int.from_bytes(b, 'big')
    out = ''
    while n:
        n, r = divmod(n, 58)
        out = B58[r] + out
    return '1' * (len(b) - len(b.lstrip(b'\x00'))) + out


def tron_address_ok(addr: str) -> bool:
    try:
        raw = b58decode(addr)
    except ValueError:
        return False
    payload, chk = raw[:-4], raw[-4:]
    return (len(payload) == 21 and payload[0] == 0x41 and
            hashlib.sha256(hashlib.sha256(payload).digest()).digest()[:4] == chk)


def solana_address_ok(addr: str) -> bool:
    try:
        return len(b58decode(addr)) == 32 and b58encode(b58decode(addr)) == addr
    except ValueError:
        return False


_RC = [0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000, 0x000000000000808B,
       0x0000000080000001, 0x8000000080008081, 0x8000000000008009, 0x000000000000008A, 0x0000000000000088,
       0x0000000080008009, 0x000000008000000A, 0x000000008000808B, 0x800000000000008B, 0x8000000000008089,
       0x8000000000008003, 0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
       0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008]
_ROT = [[0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61], [28, 55, 25, 21, 56], [27, 20, 39, 8, 14]]
_M64 = (1 << 64) - 1


def keccak256(data: bytes) -> bytes:
    """Original Keccak-256 (as used by Ethereum), pure Python; only used for EIP-55 checksums."""
    rate = 136
    msg = bytearray(data) + b'\x01'
    while len(msg) % rate:
        msg += b'\x00'
    msg[-1] |= 0x80
    a = [[0] * 5 for _ in range(5)]
    rol = lambda x, n: ((x << n) | (x >> (64 - n))) & _M64 if n else x
    for off in range(0, len(msg), rate):
        for i in range(rate // 8):
            a[i % 5][i // 5] ^= int.from_bytes(msg[off + 8 * i:off + 8 * i + 8], 'little')
        for rc in _RC:
            c = [a[x][0] ^ a[x][1] ^ a[x][2] ^ a[x][3] ^ a[x][4] for x in range(5)]
            d = [c[(x - 1) % 5] ^ rol(c[(x + 1) % 5], 1) for x in range(5)]
            a = [[a[x][y] ^ d[x] for y in range(5)] for x in range(5)]
            b = [[0] * 5 for _ in range(5)]
            for x in range(5):
                for y in range(5):
                    b[y][(2 * x + 3 * y) % 5] = rol(a[x][y], _ROT[x][y])
            a = [[b[x][y] ^ ((~b[(x + 1) % 5][y]) & b[(x + 2) % 5][y]) for y in range(5)] for x in range(5)]
            a[0][0] ^= rc
    return b''.join(a[i % 5][i // 5].to_bytes(8, 'little') for i in range(4))


def eip55(addr: str) -> str:
    a = addr.lower().removeprefix('0x')
    h = keccak256(a.encode()).hex()
    return '0x' + ''.join(ch.upper() if int(h[i], 16) >= 8 else ch for i, ch in enumerate(a))


_P = 2 ** 255 - 19
_D = (-121665 * pow(121666, _P - 2, _P)) % _P


def _on_ed25519_curve(b: bytes) -> bool:
    y = (int.from_bytes(b, 'little') & ((1 << 255) - 1)) % _P
    u, v = (y * y - 1) % _P, (_D * y * y + 1) % _P
    w = u * pow(v, _P - 2, _P) % _P
    return w == 0 or pow(w, (_P - 1) // 2, _P) == 1


def find_program_address(seeds: list[bytes], program: str) -> str:
    pid = b58decode(program)
    for bump in range(255, -1, -1):
        h = hashlib.sha256(b''.join(seeds) + bytes([bump]) + pid + b'ProgramDerivedAddress').digest()
        if not _on_ed25519_curve(h):
            return b58encode(h)
    raise BuildError('no program address')


def norm_symbol(symbol: str | None) -> str:
    """Case/decoration-insensitive symbol comparison key (e.g. '$WIF' == 'WIF', 'USD₮0' == 'USDT0')."""
    return (symbol or '').upper().replace('$', '').replace('₮', 'T').strip()


def abi_string(hexdata: str | None) -> str | None:
    if not hexdata or hexdata == '0x':
        return None
    b = bytes.fromhex(hexdata[2:])
    if len(b) == 32:  # bytes32 symbol (e.g. MKR)
        return b.rstrip(b'\x00').decode('utf-8', 'replace') or None
    if len(b) >= 64:
        off = int.from_bytes(b[:32], 'big')
        if off + 32 <= len(b):
            n = int.from_bytes(b[off:off + 32], 'big')
            if off + 32 + n <= len(b):
                return b[off + 32:off + 32 + n].decode('utf-8', 'replace')
    return None


def abi_uint(hexdata: str | None) -> int | None:
    if not hexdata or hexdata == '0x' or len(hexdata) < 66:
        return None
    return int(hexdata[2:66], 16)


# --------------------------------------------------------------------------- on-chain

def evm_onchain(http: Http, chain_id: str, addresses: list[str]) -> dict:
    out: dict[str, dict] = {}
    for url in EVM_RPC[chain_id]:
        todo = [a for a in addresses if a not in out]
        if not todo:
            break
        try:
            for i in range(0, len(todo), 20):
                chunk = todo[i:i + 20]
                reqs = []
                for j, a in enumerate(chunk):
                    reqs.append({'jsonrpc': '2.0', 'id': 2 * j, 'method': 'eth_call', 'params': [{'to': a, 'data': '0x313ce567'}, 'latest']})
                    reqs.append({'jsonrpc': '2.0', 'id': 2 * j + 1, 'method': 'eth_call', 'params': [{'to': a, 'data': '0x95d89b41'}, 'latest']})
                res = http.json(url, reqs)
                if not isinstance(res, list):
                    raise BuildError(f'unexpected RPC reply from {url}: {str(res)[:200]}')
                by_id = {r.get('id'): r for r in res}
                for j, a in enumerate(chunk):
                    dec = abi_uint(by_id.get(2 * j, {}).get('result'))
                    if dec is None:
                        continue  # try the next endpoint
                    out[a] = {'decimals': dec, 'symbol': abi_string(by_id.get(2 * j + 1, {}).get('result'))}
        except BuildError as e:
            print(f'  ! {url}: {e}', file=sys.stderr)
    return out


def tron_call(http: Http, contract: str, signature: str) -> str | None:
    body = {'owner_address': TRON_ZERO_OWNER, 'contract_address': contract, 'function_selector': signature,
            'parameter': '', 'visible': True}
    res = http.json(TRONGRID, body)
    if res and res.get('result', {}).get('result') and res.get('constant_result'):
        return '0x' + res['constant_result'][0]
    return None


def tron_onchain(http: Http, addresses: list[str]) -> dict:
    out = {}
    for a in addresses:
        dec = abi_uint(tron_call(http, a, 'decimals()'))
        if dec is not None:
            out[a] = {'decimals': dec, 'symbol': abi_string(tron_call(http, a, 'symbol()'))}
    return out


def solana_rpc(http: Http, method: str, params: list):
    last = None
    for url in SOLANA_RPC:
        try:
            res = http.json(url, {'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params})
            if 'error' in res:
                raise BuildError(str(res['error']))
            return res['result']
        except BuildError as e:
            last = e
            print(f'  ! {url}: {e}', file=sys.stderr)
    raise BuildError(f'Solana RPC failed: {last}')


def _borsh_string(b: bytes, off: int) -> tuple[str, int]:
    n = int.from_bytes(b[off:off + 4], 'little')
    return b[off + 4:off + 4 + n].split(b'\x00')[0].decode('utf-8', 'replace').strip(), off + 4 + n


def solana_onchain(http: Http, mints: list[str]) -> dict:
    out: dict[str, dict] = {}
    for i in range(0, len(mints), 100):
        chunk = mints[i:i + 100]
        res = solana_rpc(http, 'getMultipleAccounts', [chunk, {'encoding': 'jsonParsed', 'commitment': 'finalized'}])
        for mint, acc in zip(chunk, res['value']):
            if not acc:
                continue
            parsed = acc.get('data', {}).get('parsed', {}) if isinstance(acc.get('data'), dict) else {}
            if parsed.get('type') != 'mint':
                continue
            info = parsed['info']
            entry = {'decimals': info.get('decimals'), 'tokenProgram': acc.get('owner'), 'symbol': None}
            for ext in info.get('extensions') or []:
                if ext.get('extension') == 'tokenMetadata':
                    entry['symbol'] = (ext.get('state') or {}).get('symbol')
            out[mint] = entry
    need = [m for m in mints if m in out and not out[m]['symbol']]
    pdas = {find_program_address([b'metadata', b58decode(METAPLEX), b58decode(m)], METAPLEX): m for m in need}
    keys = list(pdas)
    for i in range(0, len(keys), 100):
        chunk = keys[i:i + 100]
        res = solana_rpc(http, 'getMultipleAccounts', [chunk, {'encoding': 'base64', 'commitment': 'finalized'}])
        for key, acc in zip(chunk, res['value']):
            if not acc or acc.get('owner') != METAPLEX:
                continue
            raw = base64.b64decode(acc['data'][0])
            if b58encode(raw[33:65]) != pdas[key]:
                continue
            _, off = _borsh_string(raw, 65)
            symbol, _ = _borsh_string(raw, off)
            out[pdas[key]]['symbol'] = symbol or None
    return out


# --------------------------------------------------------------------------- icons

# Source images known to be placeholders rather than logos (SHA-256 of the
# downloaded bytes). CoinGecko served a "broken image" glyph as a coin image.
PLACEHOLDER_ICONS = {
    'a2a629267a06feff6bce212a77329e17a7a8af1bc33b2d97a3419a5a00e641ab',
}


def normalize_icon(raw: bytes) -> bytes:
    if hashlib.sha256(raw).hexdigest() in PLACEHOLDER_ICONS:
        raise BuildError('icon is a known placeholder image')
    with Image.open(io.BytesIO(raw)) as im:
        im.load()
        w, h = im.size
        if min(w, h) < 64:
            raise BuildError(f'icon too small ({w}x{h})')
        rgba = im.convert('RGBA')
    alpha = rgba.getchannel('A')
    if not alpha.getbbox():
        raise BuildError('icon is fully transparent')
    visible = alpha.point(lambda v: 255 if v > 32 else 0)
    coverage = visible.histogram()[255] / (w * h)
    # A single-colour glyph on transparency is a normal logo; a uniformly coloured, fully opaque
    # rectangle is not (typical of blank/placeholder images).
    if coverage > 0.95 and max(ImageStat.Stat(rgba.convert('RGB'), mask=visible).stddev) < 3:
        raise BuildError('icon is a flat colour rectangle (placeholder?)')
    scale = min(ICON_SIZE / w, ICON_SIZE / h)
    size = (max(1, round(w * scale)), max(1, round(h * scale)))
    if size != (w, h):
        rgba = rgba.resize(size, Image.LANCZOS)
    canvas = Image.new('RGBA', (ICON_SIZE, ICON_SIZE), (0, 0, 0, 0))
    canvas.paste(rgba, ((ICON_SIZE - size[0]) // 2, (ICON_SIZE - size[1]) // 2))
    # Fully transparent pixels carry no colour: zero them for smaller, deterministic output.
    canvas.paste((0, 0, 0, 0), mask=canvas.getchannel('A').point(lambda v: 255 if v == 0 else 0))
    out = io.BytesIO()
    canvas.save(out, format='PNG', optimize=True)
    return out.getvalue()


def icon_asset_name(network: str, address: str) -> str:
    return f'token_{network}_{hashlib.sha256(address.encode()).hexdigest()[:16]}'


# --------------------------------------------------------------------------- sources

def load_lists(http: Http, network: str, platform: str) -> dict[str, dict[str, int | None]]:
    """name -> {normalized address -> decimals}"""
    lists: dict[str, dict] = {}
    evm = network not in ('tron', 'solana')
    norm = (lambda a: a.lower()) if evm else (lambda a: a)
    for name, url, chain in TOKEN_LISTS[network]:
        data = http.json(url)
        tokens = data.get('tokens', data) if isinstance(data, dict) else data
        if isinstance(tokens, dict):  # 1inch: address -> token
            tokens = list(tokens.values())
        lists[name] = {norm(t['address']): t.get('decimals') for t in tokens
                       if t.get('chainId', chain) == chain and t.get('address')}
        if not lists[name]:
            raise BuildError(f'token list {name} is empty: {url}')
    cg = http.json(f'https://tokens.coingecko.com/{platform}/all.json')
    lists['coingecko-tokenlist'] = {norm(t['address']): t.get('decimals') for t in cg['tokens']}
    if network == 'solana':
        lists['jupiter-verified'] = {t['id']: t.get('decimals') for t in http.json(JUPITER_VERIFIED)}
    return lists


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--cache-dir', default=os.path.join(tempfile.gettempdir(), 'bittool-signer-token-registry-cache'))
    ap.add_argument('--offline', action='store_true')
    ap.add_argument('--network', action='append')
    ap.add_argument('--dry-run', action='store_true')
    args = ap.parse_args()
    http = Http(pathlib.Path(args.cache_dir), args.offline)
    sel = json.loads(SELECTION.read_text())
    tw_commit = sel['trustWalletCommit']
    tw_base = f'https://raw.githubusercontent.com/trustwallet/assets/{tw_commit}/blockchains'
    dry = args.dry_run or bool(args.network)

    platforms = {c['id']: c.get('platforms') or {} for c in http.json(f'{COINGECKO}/coins/list?include_platform=true')}
    assets, counts, errors, icons = [], {}, [], {}

    for net in sel['networks']:
        key, family, platform = net['key'], net['chainFamily'], net['coingeckoPlatform']
        if args.network and key not in args.network:
            continue
        print(f'== {key}: {len(net["tokens"])} pinned tokens', flush=True)
        lists = load_lists(http, key, platform)
        evm = family == 'evm'
        addresses = [t['address'] for t in net['tokens']]
        if evm:
            onchain = evm_onchain(http, net['chainId'], addresses)
        elif family == 'tron':
            onchain = tron_onchain(http, addresses)
        else:
            onchain = solana_onchain(http, addresses)
        seen_symbols: dict[str, str] = {}

        def verify(rank_token):
            rank, tok = rank_token
            addr = tok['address']
            problems = []
            if evm:
                if addr != addr.lower() or len(addr) != 42 or not all(c in '0123456789abcdef' for c in addr[2:]):
                    problems.append('EVM address must be lowercase 0x hex')
                tw_dir = eip55(addr)
            elif family == 'tron':
                if not tron_address_ok(addr):
                    problems.append('invalid TRON address')
                tw_dir = addr
            else:
                if not solana_address_ok(addr):
                    problems.append('invalid Solana mint')
                tw_dir = addr
            dec = tok['decimals']
            ver: dict = {'coingeckoId': tok['coingeckoId']}
            # CoinGecko platform mapping
            mapped = platforms.get(tok['coingeckoId'], {}).get(platform)
            ver['coingecko'] = bool(mapped) and (mapped.lower() == addr.lower() if evm else mapped == addr)
            if not ver['coingecko']:
                problems.append(f'CoinGecko {tok["coingeckoId"]} maps {platform} to {mapped}')
            # Trust Wallet
            tw_info_url = f'{tw_base}/{net["trustWalletChain"]}/assets/{tw_dir}/info.json'
            tw = http.json(tw_info_url, allow_404=True)
            ver['trustwallet'] = False
            tw_symbol = None
            if tw is not None:
                if tw.get('status') != 'active':
                    problems.append(f'Trust Wallet status {tw.get("status")}')
                elif tw.get('decimals') != dec:
                    problems.append(f'Trust Wallet decimals {tw.get("decimals")} != {dec}')
                else:
                    ver['trustwallet'] = True
                    tw_symbol = tw.get('symbol')
            # independent lists
            found, ignored = [], []
            norm = addr.lower() if evm else addr
            for name, table in lists.items():
                if norm in table:
                    ld = table[norm]
                    if ld is not None and int(ld) != dec:
                        if name in PRESENCE_ONLY_LISTS:
                            ignored.append(f'{name}:{ld}')  # known-unreliable decimals; on-chain value wins
                            found.append(name)
                        else:
                            problems.append(f'{name} decimals {ld} != {dec}')
                    else:
                        found.append(name)
            if ignored:
                ver['decimalsDisagreement'] = ignored
            if family == 'tron':
                ts = http.json(TRONSCAN_TOKEN.format(addr))
                rec = (ts or {}).get('trc20_tokens') or []
                if rec:
                    if int(rec[0].get('decimals', -1)) != dec:
                        problems.append(f'TronScan decimals {rec[0].get("decimals")} != {dec}')
                    else:
                        found.append('tronscan')
            # Issuer documentation: the pinned page (raw response, no rendering) must contain
            # the exact address. It counts as an independent source like a token list.
            official = tok.get('officialSource')
            if official:
                if not official.startswith('https://'):
                    problems.append('officialSource must be an https URL')
                else:
                    page = http.get(official, allow_404=True)
                    text = (page or b'').decode('utf-8', 'replace')
                    if (addr.lower() in text.lower()) if evm else (addr in text):
                        found.append('official:' + official.split('/')[2])
                        ver['officialSource'] = official
                    else:
                        problems.append(f'official source does not contain the address: {official}')
            ver['tokenLists'] = sorted(found)
            if not ver['trustwallet'] and not any(n != 'coingecko-tokenlist' for n in found):
                problems.append('no source independent of CoinGecko lists this token')
            # metadata source
            if ver['trustwallet']:
                meta_url = tw_info_url
            else:
                meta_url = f'{COINGECKO}/coins/{tok["coingeckoId"]}'
                coin = http.json(meta_url + '?localization=false&tickers=false&market_data=false'
                                 '&community_data=false&developer_data=false&sparkline=false')
                detail = (coin.get('detail_platforms') or {}).get(platform) or {}
                cg_addr = detail.get('contract_address') or ''
                if (cg_addr.lower() if evm else cg_addr) != (addr.lower() if evm else addr):
                    problems.append(f'CoinGecko coin record address {cg_addr}')
                if detail.get('decimal_place') is not None and detail['decimal_place'] != dec:
                    problems.append(f'CoinGecko coin decimals {detail["decimal_place"]} != {dec}')
            # on-chain
            oc = onchain.get(addr)
            if oc is None:
                problems.append('on-chain metadata unavailable')
            else:
                ver['onchainDecimals'] = oc['decimals'] == dec
                if not ver['onchainDecimals']:
                    problems.append(f'on-chain decimals {oc["decimals"]} != {dec}')
                if oc.get('symbol'):
                    ver['onchainSymbol'] = oc['symbol']
                # Symbols may legitimately differ (bridged variants, renamed tickers), but only with a
                # recorded explanation in the selection; anything else is treated as a metadata conflict.
                shown, onchain_sym = norm_symbol(tok['symbol']), norm_symbol(oc.get('symbol'))
                conflicts = []
                if onchain_sym and shown != onchain_sym:
                    conflicts.append(f'display symbol {tok["symbol"]} != on-chain {oc.get("symbol")}')
                if tw_symbol and onchain_sym and norm_symbol(tw_symbol) != onchain_sym:
                    conflicts.append(f'Trust Wallet symbol {tw_symbol} != on-chain {oc.get("symbol")}')
                if conflicts and not tok.get('note'):
                    problems.extend(conflicts)
                if family == 'solana':
                    if oc.get('tokenProgram') not in (TOKENKEG, TOKEN_2022):
                        problems.append(f'unexpected mint owner {oc.get("tokenProgram")}')
                    if tok.get('tokenProgram') and tok['tokenProgram'] != oc.get('tokenProgram'):
                        problems.append(f'token program {oc.get("tokenProgram")} != pinned {tok["tokenProgram"]}')
            # icon
            icon_url = tok['icon']
            if icon_url == 'trustwallet':
                icon_url = f'{tw_base}/{net["trustWalletChain"]}/assets/{tw_dir}/logo.png'
            png = None
            try:
                if 'missing' in icon_url.rsplit('/', 1)[-1]:
                    raise BuildError('placeholder image URL')
                png = normalize_icon(http.get(icon_url))
            except BuildError as e:
                problems.append(f'icon {icon_url}: {e}')
            entry = {'chainFamily': family}
            if evm:
                entry['chainId'] = net['chainId']
            entry.update({'assetAddress': addr, 'name': tok['name'], 'symbol': tok['symbol'], 'decimals': dec})
            if family == 'solana' and oc:
                entry['tokenProgram'] = oc.get('tokenProgram')
            if tok.get('note'):
                ver['note'] = tok['note']
            entry.update({'iconAsset': icon_asset_name(key, addr), 'rank': rank, 'metadataSource': meta_url,
                          'verifiedAt': sel['collectedAt'], 'iconSource': icon_url,
                          'iconSha256': hashlib.sha256(png).hexdigest() if png else None,
                          'verification': ver})
            return entry, png, problems

        with concurrent.futures.ThreadPoolExecutor(6) as pool:
            results = list(pool.map(verify, enumerate(net['tokens'], 1)))
        for entry, png, problems in results:
            label = f'{key} #{entry["rank"]} {entry["symbol"]} {entry["assetAddress"]}'
            for p in problems:
                errors.append(f'{label}: {p}')
            if entry['symbol'] in seen_symbols:
                errors.append(f'{label}: duplicate symbol within network (also {seen_symbols[entry["symbol"]]})')
            seen_symbols[entry['symbol']] = entry['assetAddress']
            if not any(ch.isalnum() for ch in entry['symbol']) or not entry['symbol'].isprintable():
                errors.append(f'{label}: symbol is not clean text')
            if not 0 <= entry['decimals'] <= 30:
                errors.append(f'{label}: decimals out of range')
            assets.append(entry)
            if png:
                icons[entry['iconAsset']] = png
        counts[key] = {'target': net['target'], 'included': len(net['tokens'])}
        print(f'   verified {len(results)} tokens, {sum(1 for r in results if r[2])} with problems', flush=True)

    if errors:
        print('\nBUILD FAILED:', file=sys.stderr)
        for e in errors:
            print('  - ' + e, file=sys.stderr)
        return 1
    if dry:
        print('dry run: nothing written')
        return 0

    registry = {
        'schemaVersion': 1,
        'registryVersion': sel['registryVersion'],
        'collectedAt': sel['collectedAt'],
        'sources': sel['sources'],
        'selection': sel['selection'],
        'counts': counts,
        'networks': sel['registryNetworks'],
        'assets': assets,
    }
    # Curated artwork is an input to build-expanded-registry.py, which writes the
    # icons the app actually ships (content-addressed, deduplicated). Nothing here
    # goes into the asset catalogue.
    for stale in CURATED_ICONS.glob('token_*.png'):
        stale.unlink()
    CURATED_ICONS.mkdir(parents=True, exist_ok=True)
    for name, png in icons.items():
        (CURATED_ICONS / f'{name}.png').write_bytes(png)
    text = json.dumps(registry, ensure_ascii=False, indent=2) + '\n'
    for out in OUTPUTS:
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(text)
    total = sum(len(p) for p in icons.values())
    print(f'wrote {len(assets)} assets, {len(icons)} icons ({total / 1024:.0f} KiB)')
    print('now run scripts/build-expanded-registry.py to rebuild what the app ships')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except BuildError as e:
        sys.exit(f'error: {e}')
