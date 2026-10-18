#!/usr/bin/env python3
"""Discover candidate tokens for BitTool Signer's offline token registry.

Build-time research tool; the app never runs it. It does NOT modify the frozen
selection (engine/data/token-source-selection.json), the generated registry, the
app resources or any asset catalog. It only writes candidate reports that a human
review turns into additions to the selection.

It imports scripts/build-token-registry.py as a module and reuses its cached HTTP
client, token lists and on-chain helpers, applying the method described in
docs/TokenRegistrySources.md with relaxed thresholds:

  1. candidates   CoinGecko coins whose platform map has an exact address on the
                  network, minus addresses already pinned in the selection.
                  Addresses in the selection's `exclusions` are evaluated too but
                  reported separately (`previouslyExcluded`).
  2. market data  /coins/markets in batches of 250 ids (price, market cap, FDV,
                  24h volume, market-cap rank, image).
  3. pre-filter   market cap (FDV when the market cap is 0) >= $1M and 24h volume
                  >= $20k; or a zero-market-cap bridged copy of a coin with a
                  market cap >= $100M; or a zero-market-cap token with >= $20k
                  volume. Zero-market-cap tokens are valued from on-chain supply.
  4. on-chain     decimals, symbol and total supply (EVM JSON-RPC, TronGrid,
                  Solana getMultipleAccounts); valueUsd = min(market cap,
                  supply x price), or supply x price when there is no market cap.
  5. holders      Blockscout (Ethereum/Arbitrum/Base), GeckoTerminal (BNB Smart
                  Chain), TronScan (TRON), Jupiter (Solana). Fetched only for
                  tokens that pass the network's value/volume rule (TronScan and
                  Jupiter data come with the listing lookups for every
                  pre-filtered token). Top-10 holder share where the source has it.
  6. listings     Trust Wallet info.json at the selection's pinned commit, the
                  independent token lists of the build script, Jupiter verified
                  (Solana), TronScan (TRON).
  7. flags        review heuristics (tokenized stocks/funds, receipt/vault tokens,
                  leveraged, LP, deprecated, decimals or symbol disagreements,
                  symbol collisions, holder concentration, ...). Flags never drop
                  a token; `needsReview` is true when a review-level flag is set.
  8. eligibility  relaxed per-network rules (RULES below). Every rule's outcome is
                  recorded. Near-misses are kept: exactly one rule short (a number
                  within 50% of its threshold, or the listing rule) with the rest
                  known, only data missing, or a value/volume shortfall within 50%
                  for which holders were not fetched.

Usage
-----
    python3 scripts/discover-token-candidates.py [--cache-dir DIR] [--out-dir DIR]
        [--network KEY ...] [--offline] [--refresh GROUP ...]

    --cache-dir DIR   HTTP cache shared with build-token-registry.py (default:
                      $TMPDIR/bittool-signer-token-registry-cache). Re-runs are served
                      from it, so a second run is fast and reproducible.
    --out-dir DIR     Where candidates-<network>.json and summary.md are written
                      (default: $TMPDIR/bittool-signer-token-candidates).
    --network KEY     Only these networks (ethereum, smartchain, arbitrum, base,
                      tron, solana). Repeatable.
    --offline         Never touch the network; everything must be cached.
    --refresh GROUP   Ignore cached responses of a group once per run: markets
                      (CoinGecko), holders (Blockscout/GeckoTerminal/TronScan/
                      Jupiter search), trustwallet, lists, rpc, or all.

Stdlib only. Pillow is not needed: if it is missing, a stub is installed before
the build module is imported (icons are never processed here). A cold run makes
~70 CoinGecko requests (paced 6.5 s) and a few hundred GeckoTerminal requests
(paced 5 s; the gap grows on HTTP 429 and shrinks back after successes); expect 20-60 minutes. A warm run takes about a minute.

Output items carry: address (EVM lowercase; TRON/Solana exact), coingeckoId,
name, symbol (CoinGecko, upper-cased), onchainSymbol, decimals (on-chain),
tokenProgram (Solana), priceUsd, marketCapUsd, fdvUsd, volume24hUsd, supply
(token units), valueUsd, holders, trustWallet, lists, jupiter / tronscan,
flags, needsReview, iconCandidate, rules, eligibleReason / failReason, errors.
Each file also has a compact `rejected` list (every other pre-filtered token and why).
"""
from __future__ import annotations

import argparse
import collections
import concurrent.futures
import datetime
import hashlib
import http.client
import importlib.util
import json
import os
import pathlib
import re
import sys
import tempfile
import threading
import time
import traceback
import types
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
BUILD_SCRIPT = ROOT / 'scripts' / 'build-token-registry.py'


def _import_build():
    sys.dont_write_bytecode = True  # keep scripts/ free of __pycache__
    try:
        import PIL  # noqa: F401
    except ImportError:  # only the build's icon code needs Pillow; discovery never touches icons
        stub = types.ModuleType('PIL')
        stub.Image = stub.ImageStat = None
        sys.modules['PIL'] = stub
    spec = importlib.util.spec_from_file_location('build_token_registry', BUILD_SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


build = _import_build()
BuildError = build.BuildError

# --------------------------------------------------------------------------- configuration

NETWORK_ORDER = ['ethereum', 'smartchain', 'arbitrum', 'base', 'tron', 'solana']
DESIRED_TOTAL = {'ethereum': 200, 'smartchain': 150, 'arbitrum': 100, 'base': 100, 'tron': 30, 'solana': 200}

PREFILTER = {'marketCapUsd': 1e6, 'volume24hUsd': 2e4, 'bridgedCanonicalMarketCapUsd': 1e8}
NEAR = 0.5  # a failed numeric rule within this factor of its threshold counts as a near miss

RULES = {
    'ethereum': {'value': 5e6, 'volume': 1e5, 'altValue': 2e8, 'altVolume': 2e4, 'holders': 3000,
                 'listing': 'trustwallet-or-1-list'},
    'smartchain': {'value': 3e6, 'volume': 1e5, 'altValue': 1.5e8, 'altVolume': 2e4, 'holders': 5000,
                   'listing': 'trustwallet-or-2-lists-and-20k-holders'},
    'arbitrum': {'value': 1e6, 'volume': 5e4, 'altValue': 5e7, 'altVolume': 2e4, 'holders': 1000,
                 'listing': 'trustwallet-or-1-list'},
    'base': {'value': 2e6, 'volume': 1e5, 'altValue': 5e7, 'altVolume': 2e4, 'holders': 5000,
             'listing': 'trustwallet-or-1-list'},
    'tron': {'value': 1e6, 'volume': 2e4, 'holders': 5000, 'listing': 'tronscan', 'notDeprecated': True},
    'solana': {'value': 3e6, 'volume': 1e5, 'liquidity': 5e5, 'holders': 5000, 'listing': 'jupiter-verified'},
}
RULE_TEXT = {
    'ethereum': 'value >= $5M; 24h volume >= $100k (or value >= $200M and volume >= $20k); holders >= 3,000 '
                '(Blockscout); active Trust Wallet record or >= 1 independent list',
    'smartchain': 'value >= $3M; 24h volume >= $100k (or value >= $150M and volume >= $20k); holders >= 5,000 '
                  '(GeckoTerminal); active Trust Wallet record, or >= 2 independent lists and >= 20,000 holders',
    'arbitrum': 'value >= $1M; 24h volume >= $50k (or value >= $50M and volume >= $20k); holders >= 1,000 '
                '(Blockscout); >= 1 independent list or active Trust Wallet record',
    'base': 'value >= $2M; 24h volume >= $100k (or value >= $50M and volume >= $20k); holders >= 5,000 '
            '(Blockscout); >= 1 independent list or active Trust Wallet record',
    'tron': 'TronScan record; holders >= 5,000 (TronScan); value >= $1M; 24h volume >= $20k; not deprecated',
    'solana': 'Jupiter verified; holders >= 5,000 (Jupiter); 24h volume >= $100k or DEX liquidity >= $500k; '
              'value >= $3M',
}

BLOCKSCOUT = {'ethereum': 'https://eth.blockscout.com', 'arbitrum': 'https://arbitrum.blockscout.com',
              'base': 'https://base.blockscout.com'}
GECKOTERMINAL = 'https://api.geckoterminal.com/api/v2/networks/bsc/tokens/{}/info'
TRONSCAN_HOLDERS = 'https://apilist.tronscanapi.com/api/token_trc20/holders?contract_address={}&start=0&limit=10'
JUPITER_SEARCH = 'https://lite-api.jup.ag/tokens/v2/search?query='

HOST_GAPS = {  # minimum seconds between requests per host
    'api.coingecko.com': 6.5, 'api.geckoterminal.com': 5.0, 'apilist.tronscanapi.com': 1.2,
    'api.trongrid.io': 1.2, 'lite-api.jup.ag': 1.0, 'eth.blockscout.com': 0.2,
    'arbitrum.blockscout.com': 0.2, 'base.blockscout.com': 0.2,
}
# Hosts fetched by Http._get_polite: GeckoTerminal answers 429 with "Retry-After: 0", which makes the build's
# client retry instantly and burn its attempts inside the same rate-limit window.
POLITE_HOSTS = {'api.geckoterminal.com', 'lite-api.jup.ag', 'apilist.tronscanapi.com', 'eth.blockscout.com',
                'arbitrum.blockscout.com', 'base.blockscout.com'}
LIST_URLS = {u for lists in build.TOKEN_LISTS.values() for _, u, _ in lists} | {build.JUPITER_VERIFIED}
RPC_URLS = {u for urls in build.EVM_RPC.values() for u in urls} | set(build.SOLANA_RPC) | {build.TRONGRID}
REFRESH_GROUPS = {
    'markets': lambda u: u.startswith(build.COINGECKO),
    'holders': lambda u: any(h in u for h in ('blockscout.com/', 'geckoterminal.com/', 'tronscanapi.com/',
                                              JUPITER_SEARCH)),
    'trustwallet': lambda u: 'raw.githubusercontent.com/trustwallet/' in u,
    'lists': lambda u: u in LIST_URLS or u.startswith('https://tokens.coingecko.com/'),
    'rpc': lambda u: u in RPC_URLS,
}

# Heuristic flags. Review-level flags set needsReview; the others are informational.
REVIEW_FLAGS = {
    'tokenizedStockOrFund', 'receiptOrVault', 'leveraged', 'lpToken', 'deprecated', 'decimalsDisagreement',
    'symbolMismatch', 'symbolCollidesWithPinned', 'symbolCollidesWithCandidate', 'highHolderConcentration',
    'trustWalletInactive', 'blockscoutReputation', 'tronscanTag', 'lowOrganicScore', 'noIcon', 'weirdDecimals',
    'onchainUnavailable', 'nonAsciiSymbol', 'lowTransfers24h', 'multipleCoingeckoIds', 'noMarketCap',
}
TOKENIZED_RE = re.compile(
    r'xstock|tokeni[sz]ed|\bb?stocks?\b|\brstocks?\b|\betfs?\b|\bbacked (finance|assets)\b|'
    r'\b(buidl|usyc|usdy|ousg|ustb|jaaa|jtrsy|eutbl|ustbl|benji|acred|stbt|tbill|mtbill|vbill|wtgxx|ylds|wylds)\b|'
    r'spiko|treasur(y|ies)\b|t-bills?|money market|\bfunds?\b|securitize|superstate|dinari|franklin|'
    r'wisdomtree|hamilton lane|hashnote|anemoy|libeara|reinsurance|\bhastra\b|'
    r'\bequit(y|ies)\b|\bshares\b|\bprivate credit\b|prestocks?|pre-ipo|\bsecurities\b|'
    r'\bdtf\b|\bindex (fund|dtf|token)\b|\.ssi\b', re.I)
JUPITER_STOCK_TAGS = {'stocks', 'xstocks', 'prestocks', 'pre-ipo'}
RECEIPT_NAME_RE = re.compile(
    r'^aave (v\d|ethereum|arbitrum|base|bnb|bsc|polygon|optimism|avalanche|horizon)\b|static ?aave|\bstata|'
    r'^morpho \w|morpho vault|^syrup|^euler \w|\byearn (v\d|vault)|\byvault\b|\bbeefy \w|'
    r'^(pt|yt)[- ]|\bpendle (pt|yt|lp|market)\b|\bvaults?\b|^compound \w|^venus \w|staked ena\b|stkaave|'
    r'staked aave|jupiter lend|lido earn|ether\.?fi liquid|\bliquid (eth|btc|usd)\b|\bgauntlet\b|'
    r'\bsteakhouse\b|\bre7\b|mev capital|\bkpk\b|\breceipt\b|\binterest[- ]bearing\b|\byield[- ]bearing\b|'
    r'\bearn (eth|usd|btc)|\bdeposit token\b', re.I)
RECEIPT_SYMBOL_RE = re.compile(r'^(stata[a-z0-9]+|pt-.+|yt-.+|syrup[a-z]+|sena|stkaave|stkgho|stkbpt)$', re.I)
# Receipt tickers whose meaning depends on capitalisation (cUSDC, vUSDT, yvDAI, mooX, jlUSDC, earnETH,
# liquidETH); matched case-sensitively against the on-chain symbol so MOODENG or Moonwell do not match.
RECEIPT_CASED_RE = re.compile(r'^(c(USDC|USDT|ETH|DAI|WBTC|COMP|WETH|USDS)(v3)?|v(USDT|USDC|BNB|BTC|ETH|XVS|DAI|BUSD|'
                              r'FDUSD|WBNB|SOL|TRX)|yv[A-Z]|moo[A-Z]|jl[A-Z]|earn[A-Z]|liquid[A-Z])')
# Aave aTokens / static wrappers keep Aave's capitalisation on-chain (aEthUSDC, stataArbUSDCn, waBasWETH);
# matched case-sensitively so ordinary tickers such as AETHIR do not match.
ATOKEN_RE = re.compile(r'^(a|stata|wa)(Eth|Arb|Bas|Bnb|Opt|Pol|Ava|Lin|Hor|Sol|Gno|Sca|Zk|Plasma|Mnt)[A-Z0-9]')
LIQUID_STAKING_RE = re.compile(r'\bstaked\b|liquid stak|restak|\blst\b', re.I)
LEVERAGED_RE = re.compile(r'leverag|\b\d+(\.\d+)?x (long|short)\b|\b[2-9]x\b|\b(3l|3s|5l|5s)\b', re.I)
LP_RE = re.compile(r'\blp\b|lp token|liquidity provider|uni-v2|cake-lp|curve\.fi|balancer pool|'
                   r'\bpool token\b|\bgm: |\b(jlp|glp|hlp)\b', re.I)
DEPRECATED_RE = re.compile(r'\[old\]|\(old\)|\bold\b|legacy|deprecated|discontinued|\bsollet\b|\bmigrat', re.I)
BRIDGE_RE = re.compile(r'binance-peg|bridged|wormhole|\bpeg(ged)?\b|portal|layerzero|stargate|axelar|\baxl|'
                       r'celer|multichain|allbridge|hyperlane|\((bsc|eth|arbitrum|base|solana|tron|trc-?20|'
                       r'bep-?20|erc-?20)\)', re.I)
BRIDGE_PREFIXES = ('axl', 'wh', 'so', 'multi', 'any', 'ce', 'w', 'b')
BRIDGE_SUFFIXES = ('.e', '.b', '.w', '_e', 'e', 'b')
RPC_TRANSIENT_RE = re.compile(r'rate|limit|too many|capacity|timeout|timed out|busy|exceeded|unavailable', re.I)


# --------------------------------------------------------------------------- HTTP

class Http(build.Http):
    """build.Http plus per-host pacing locks, rate-limit back-off that adapts the per-host gap,
    cache refresh groups, extra retries on transport errors, and no caching of invalid JSON or
    transient JSON-RPC errors."""

    def __init__(self, cache_dir: pathlib.Path, offline: bool, refresh=()):
        super().__init__(cache_dir, offline)
        self._host_locks: dict[str, threading.Lock] = {}
        self._refresh = set(refresh)
        self._refreshed: set[str] = set()
        self.gaps = dict(HOST_GAPS)
        self.blocked_until: dict[str, float] = {}
        self.rate_limited = collections.Counter()

    def _pace(self, url: str):
        host = url.split('/')[2]
        gap = self.gaps.get(host, 0.0)
        if not gap and host not in self.blocked_until:
            return
        with self.lock:
            host_lock = self._host_locks.setdefault(host, threading.Lock())
        with host_lock:  # waiting for one host never blocks requests to another
            ready = max(self.last_call.get(host, 0) + gap, self.blocked_until.get(host, 0))
            wait = ready - time.monotonic()
            if wait > 0:
                time.sleep(wait)
            self.last_call[host] = time.monotonic()

    def _eased(self, host: str):
        """After a success, shrink a grown gap back towards the configured one (AIMD)."""
        with self.lock:
            base = HOST_GAPS.get(host, 0.0)
            if self.gaps.get(host, 0.0) > base:
                self.gaps[host] = max(base, self.gaps[host] * 0.95)

    def _get_polite(self, url: str, path: pathlib.Path, allow_404: bool, max_bytes: int, headers) -> bytes | None:
        if self.offline:
            raise BuildError(f'--offline and not cached: {url}')
        host = url.split('/')[2]
        hdrs = {'User-Agent': build.UA, 'Accept': 'application/json'}
        hdrs.update(headers or {})
        backoff, last = 20.0, None
        for attempt in range(10):
            self._pace(url)
            try:
                with urllib.request.urlopen(urllib.request.Request(url, headers=hdrs), timeout=60) as resp:
                    data = resp.read(max_bytes + 1)
                if len(data) > max_bytes:
                    raise BuildError(f'response too large: {url}')
                tmp = path.with_suffix('.tmp')
                tmp.write_bytes(data)
                tmp.replace(path)
                self._eased(host)
                return data
            except urllib.error.HTTPError as e:
                if e.code == 404 and allow_404:
                    path.write_bytes(b'\x00404')
                    self._eased(host)
                    return None
                if e.code not in (429, 500, 502, 503, 504):
                    raise BuildError(f'HTTP {e.code} for {url}') from e
                last = f'HTTP {e.code}'
                ra = to_float(e.headers.get('Retry-After')) or 0.0
                wait = max(ra, backoff)
                with self.lock:
                    if e.code == 429:
                        self.rate_limited[host] += 1
                        self.gaps[host] = min(max(self.gaps.get(host, 0.0), 0.5) * 1.4, 15.0)
                    self.blocked_until[host] = max(self.blocked_until.get(host, 0), time.monotonic() + wait)
                print(f'  ~ {host}: {last}, waiting {wait:.0f}s (gap now {self.gaps.get(host, 0):.1f}s)',
                      file=sys.stderr, flush=True)
                backoff = min(backoff * 2, 120.0)
            except (urllib.error.URLError, http.client.HTTPException, OSError) as e:
                last = e
                time.sleep(min(backoff, 30.0))
        raise BuildError(f'giving up on {url}: {last}')

    def _path(self, url: str, body: bytes | None) -> pathlib.Path:
        return self.cache / hashlib.sha256(url.encode() + b'\n' + (body or b'')).hexdigest()

    def _wants_refresh(self, url: str, path: pathlib.Path) -> bool:
        if not self._refresh or self.offline:
            return False
        with self.lock:
            if path.name in self._refreshed:
                return False
            if 'all' in self._refresh or any(REFRESH_GROUPS[g](url) for g in self._refresh if g in REFRESH_GROUPS):
                self._refreshed.add(path.name)
                return True
        return False

    def get(self, url, body=None, allow_404=False, max_bytes=40_000_000, headers=None):
        path = self._path(url, body)
        if path.exists():
            if self._wants_refresh(url, path):
                path.unlink(missing_ok=True)
            elif path.read_bytes() == b'__404__':  # 404 marker of earlier ad-hoc tooling sharing this cache
                return None
        if body is None and not path.exists() and url.split('/')[2] in POLITE_HOSTS:
            return self._get_polite(url, path, allow_404, max_bytes, headers)
        last = None
        for attempt in range(3):
            try:
                return super().get(url, body, allow_404=allow_404, max_bytes=max_bytes, headers=headers)
            except BuildError:
                raise
            except (http.client.HTTPException, OSError) as e:  # truncated reads, TLS resets, ...
                last = e
                time.sleep(5 * (attempt + 1))
        raise BuildError(f'network error for {url}: {last}')

    def json(self, url, body=None, **kw):
        raw_body = None if body is None else json.dumps(body, sort_keys=True).encode()
        raw = self.get(url, raw_body, **kw)
        if raw is None:
            return None
        try:
            data = json.loads(raw)
        except ValueError as e:
            self._path(url, raw_body).unlink(missing_ok=True)
            raise BuildError(f'invalid JSON from {url[:120]}: {raw[:80]!r}') from e
        if body is not None and _rpc_transient(data):
            self._path(url, raw_body).unlink(missing_ok=True)
            raise BuildError(f'transient RPC error from {url}: {str(data)[:200]}')
        return data


def _rpc_transient(data) -> bool:
    """Top-level JSON-RPC errors and rate-limit errors inside batches must not be cached."""
    if isinstance(data, dict):
        return 'error' in data and 'result' not in data
    if isinstance(data, list):
        return any(isinstance(r, dict) and r.get('error') and RPC_TRANSIENT_RE.search(str(r['error']))
                   for r in data)
    return False


# --------------------------------------------------------------------------- helpers

def now_iso() -> str:
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z')


def fmt_usd(x) -> str:
    if x is None:
        return 'n/a'
    for unit, div in (('B', 1e9), ('M', 1e6), ('k', 1e3)):
        if abs(x) >= div:
            return f'${x / div:.3g}{unit}'
    return f'${x:.0f}'


def fmt_int(x) -> str:
    return 'n/a' if x is None else f'{int(x):,}'


def to_int(x):
    try:
        return None if x is None or x == '' else int(x)
    except (TypeError, ValueError):
        try:
            return int(float(x))
        except (TypeError, ValueError):
            return None


def to_float(x):
    try:
        return None if x is None or x == '' else float(x)
    except (TypeError, ValueError):
        return None


def addr_ok(a: str, family: str) -> bool:
    if family == 'evm':
        return re.fullmatch(r'0x[0-9a-f]{40}', a) is not None
    if family == 'tron':
        return build.tron_address_ok(a)
    return build.solana_address_ok(a)


def canonical_for(m: dict, big: dict) -> dict | None:
    """A coin with market cap >= $100M whose symbol matches this coin's (after stripping common
    bridge prefixes/suffixes such as axl-, wh-, w-, .e) and whose price is within 5%."""
    sym, price = (m.get('symbol') or '').lower(), m.get('current_price')
    if not sym or not price:
        return None
    variants = {sym}
    for p in BRIDGE_PREFIXES:
        if sym.startswith(p) and len(sym) > len(p) + 1:
            variants.add(sym[len(p):])
    for s in BRIDGE_SUFFIXES:
        for v in list(variants):
            if v.endswith(s) and len(v) > len(s) + 1:
                variants.add(v[:-len(s)])
    best = None
    for v in variants:
        for c in big.get(v, ()):
            if c['id'] != m['id'] and abs(c['current_price'] - price) <= 0.05 * c['current_price']:
                if best is None or c['market_cap'] > best['market_cap']:
                    best = c
    return best


# --------------------------------------------------------------------------- on-chain

def evm_total_supply(http: Http, chain_id: str, addresses: list[str], err) -> dict[str, int]:
    out: dict[str, int] = {}
    for url in build.EVM_RPC[chain_id]:
        todo = [a for a in addresses if a not in out]
        for i in range(0, len(todo), 40):
            chunk = todo[i:i + 40]
            reqs = [{'jsonrpc': '2.0', 'id': j, 'method': 'eth_call', 'params': [{'to': a, 'data': '0x18160ddd'}, 'latest']}
                    for j, a in enumerate(chunk)]
            try:
                res = http.json(url, reqs)
                if not isinstance(res, list):
                    raise BuildError(f'unexpected RPC reply: {str(res)[:120]}')
            except BuildError as e:
                err('rpc', f'totalSupply {url}', e)
                continue
            by_id = {r.get('id'): r for r in res if isinstance(r, dict)}
            for j, a in enumerate(chunk):
                v = build.abi_uint(by_id.get(j, {}).get('result'))
                if v is not None:
                    out[a] = v
    return out


# --------------------------------------------------------------------------- per-network discovery

class Discovery:
    def __init__(self, ctx, net: dict):
        self.ctx, self.net, self.http = ctx, net, ctx.http
        self.key, self.family, self.platform = net['key'], net['chainFamily'], net['coingeckoPlatform']
        self.evm = self.family == 'evm'
        self.rule = RULES[self.key]
        self.stats = collections.Counter()
        self.errors = collections.Counter()
        self.error_samples: list[str] = []
        self.lock = threading.Lock()
        self.pinned = {self.norm(t['address']) for t in net['tokens']}
        self.pinned_symbols = {build.norm_symbol(t['symbol']): t['symbol'] for t in net['tokens']}
        self.excluded = {self.norm(e['address']): e for e in ctx.sel['exclusions'] if e['network'] == self.key}
        self.tw_base = ctx.tw_base
        self.lists: dict[str, dict] = {}
        self.jup_verified: dict[str, dict] = {}

    # ---- utilities
    def norm(self, a: str) -> str:
        a = a.strip()
        return a.lower() if self.evm else a

    def log(self, msg: str):
        print(f'[{time.strftime("%H:%M:%S")}] [{self.key}] {msg}', flush=True)

    def err(self, source: str, what: str, e):
        with self.lock:
            self.errors[source] += 1
            if len(self.error_samples) < 60:
                self.error_samples.append(f'{source}: {what}: {str(e)[:200]}')

    def tw_dir(self, a: str) -> str:
        return build.eip55(a) if self.evm else a

    # ---- sources
    def load_lists(self):
        try:
            self.lists = build.load_lists(self.http, self.key, self.platform)
        except Exception as e:  # fall back to list-by-list loading so one broken list does not hide the rest
            self.err('lists', 'load_lists', e)
            norm = self.norm
            for name, url, chain in build.TOKEN_LISTS[self.key]:
                try:
                    data = self.http.json(url)
                    tokens = data.get('tokens', data) if isinstance(data, dict) else data
                    if isinstance(tokens, dict):
                        tokens = list(tokens.values())
                    self.lists[name] = {norm(t['address']): t.get('decimals') for t in tokens
                                        if t.get('chainId', chain) == chain and t.get('address')}
                except Exception as e2:
                    self.err('lists', name, e2)
            for name, url in [('coingecko-tokenlist', f'https://tokens.coingecko.com/{self.platform}/all.json')] + (
                    [('jupiter-verified', build.JUPITER_VERIFIED)] if self.key == 'solana' else []):
                try:
                    data = self.http.json(url)
                    tokens = data['tokens'] if isinstance(data, dict) else data
                    self.lists[name] = {norm(t.get('address') or t.get('id')): t.get('decimals') for t in tokens}
                except Exception as e2:
                    self.err('lists', name, e2)
        if self.key == 'solana':
            try:
                self.jup_verified = {t['id']: t for t in self.http.json(build.JUPITER_VERIFIED)}
            except Exception as e:
                self.err('lists', 'jupiter-verified', e)

    def onchain(self, addrs: list[str]) -> dict[str, dict]:
        http, meta = self.http, {}
        if self.evm:
            cid = self.net['chainId']
            for i in range(0, len(addrs), 200):
                chunk = addrs[i:i + 200]
                try:
                    meta.update(build.evm_onchain(http, cid, chunk))
                except Exception as e:
                    self.err('rpc', f'decimals/symbol chunk {i}', e)
            supply = evm_total_supply(http, cid, addrs, self.err)
            for a, m in meta.items():
                m['totalSupply'] = supply.get(a)
        elif self.family == 'tron':
            for a in addrs:
                try:
                    m = build.tron_onchain(http, [a]).get(a)
                    if m:
                        m['totalSupply'] = build.abi_uint(build.tron_call(http, a, 'totalSupply()'))
                        meta[a] = m
                except Exception as e:
                    self.err('trongrid', a, e)
        else:
            for i in range(0, len(addrs), 100):
                chunk = addrs[i:i + 100]
                try:
                    meta.update(build.solana_onchain(http, chunk))
                    # identical request to the one solana_onchain just made -> served from the cache
                    res = build.solana_rpc(http, 'getMultipleAccounts',
                                           [chunk, {'encoding': 'jsonParsed', 'commitment': 'finalized'}])
                    for mint, acc in zip(chunk, res['value']):
                        data = (acc or {}).get('data')
                        info = (data.get('parsed') or {}).get('info') if isinstance(data, dict) else None
                        if mint in meta and info:
                            meta[mint]['totalSupply'] = to_int(info.get('supply'))
                            meta[mint]['mintAuthority'] = info.get('mintAuthority')
                            meta[mint]['freezeAuthority'] = info.get('freezeAuthority')
                except Exception as e:
                    self.err('solana-rpc', f'chunk {i}', e)
        return meta

    def trust_wallet(self, a: str):
        url = f'{self.tw_base}/{self.net["trustWalletChain"]}/assets/{self.tw_dir(a)}/info.json'
        d = self.http.json(url, allow_404=True)
        if d is None:
            return None
        return {'status': d.get('status'), 'decimals': d.get('decimals'), 'symbol': d.get('symbol'),
                'name': d.get('name')}

    def blockscout(self, a: str) -> dict:
        d = self.http.json(f'{BLOCKSCOUT[self.key]}/api/v2/tokens/{a}', allow_404=True)
        if not isinstance(d, dict) or not d.get('address_hash', d.get('address')):
            return {'holders': None, 'holdersSource': 'blockscout', 'holdersError': 'token not indexed by Blockscout'}
        return {'holders': to_int(d.get('holders_count', d.get('holders'))), 'holdersSource': 'blockscout',
                'blockscout': {'reputation': d.get('reputation'), 'decimals': to_int(d.get('decimals')),
                               'symbol': d.get('symbol'), 'name': d.get('name'), 'totalSupply': d.get('total_supply')}}

    def blockscout_top10(self, a: str, total_supply) -> float | None:
        supply = to_int(total_supply)
        if not supply:
            return None
        d = self.http.json(f'{BLOCKSCOUT[self.key]}/api/v2/tokens/{a}/holders', allow_404=True)
        items = (d or {}).get('items') or []
        if not items:
            return None
        return round(100 * sum(to_int(x.get('value')) or 0 for x in items[:10]) / supply, 2)

    def geckoterminal(self, a: str) -> dict:
        d = self.http.json(GECKOTERMINAL.format(a), allow_404=True)
        attrs = ((d or {}).get('data') or {}).get('attributes') if isinstance(d, dict) else None
        if not attrs:
            return {'holders': None, 'holdersSource': 'geckoterminal', 'holdersError': 'token not found on GeckoTerminal'}
        h = attrs.get('holders') or {}
        dist = h.get('distribution_percentage') or {}
        out = {'holders': to_int(h.get('count')), 'holdersSource': 'geckoterminal',
               'topHoldersPct': to_float(dist.get('top_10')),
               'geckoterminal': {'gtScore': attrs.get('gt_score'), 'gtVerified': attrs.get('gt_verified'),
                                 'decimals': to_int(attrs.get('decimals')), 'symbol': attrs.get('symbol'),
                                 'name': attrs.get('name')}}
        if out['holders'] is None:
            out['holdersError'] = 'GeckoTerminal has no holder count'
        return out

    def tronscan(self, a: str) -> dict | None:
        d = self.http.json(build.TRONSCAN_TOKEN.format(a))
        recs = (d or {}).get('trc20_tokens') or []
        recs = [r for r in recs if r.get('contract_address') in (None, a)]
        if not recs:
            return None
        r = recs[0]
        return {'holders': to_int(r.get('holders_count')), 'decimals': to_int(r.get('decimals')),
                'symbol': r.get('symbol'), 'name': r.get('name'), 'transfer24h': to_int(r.get('transfer24h')),
                'transferCount': to_int(r.get('transfer_num')), 'volume24hUsd': to_float(r.get('volume24h')),
                'level': r.get('level'), 'vip': r.get('vip'),
                'tags': {k: r[k] for k in ('redTag', 'greyTag', 'blueTag', 'publicTag') if r.get(k)}}

    def tronscan_top10(self, a: str, total_supply) -> float | None:
        d = self.http.json(TRONSCAN_HOLDERS.format(a))
        items = (d or {}).get('trc20_tokens') or []
        supply = to_int(total_supply)
        if not items or not supply:
            return None
        burned = sum(to_int(x.get('balance')) or 0 for x in items if x.get('holder_address') == build.TRON_ZERO_OWNER)
        top = sum(to_int(x.get('balance')) or 0 for x in items if x.get('holder_address') != build.TRON_ZERO_OWNER)
        live = supply - burned
        return round(100 * top / live, 2) if live > 0 else None

    def jupiter(self, mints: list[str]) -> dict[str, dict]:
        out = {}
        mints = sorted(mints)
        for i in range(0, len(mints), 100):
            chunk = mints[i:i + 100]
            try:
                res = self.http.json(JUPITER_SEARCH + ','.join(chunk))
                wanted = set(chunk)
                for t in res or []:
                    if isinstance(t, dict) and t.get('id') in wanted:
                        out[t['id']] = t
            except Exception as e:
                self.err('jupiter', f'search chunk {i}', e)
        return out

    # ---- rules
    def value_rule(self, t):
        v, need = t.get('valueUsd'), self.rule['value']
        if v is None:
            return {'status': 'fail', 'detail': 'value unknown (no market cap and no on-chain supply)'}
        if v >= need:
            return {'status': 'pass', 'detail': f'value {fmt_usd(v)} >= {fmt_usd(need)}'}
        return {'status': 'near' if v >= NEAR * need else 'fail', 'detail': f'value {fmt_usd(v)} < {fmt_usd(need)}'}

    def volume_rule(self, t):
        r, vol, v = self.rule, t.get('volume24hUsd') or 0, t.get('valueUsd') or 0
        if self.key == 'solana':
            liq = (t.get('jupiter') or {}).get('liquidity') or 0
            if vol >= r['volume'] or liq >= r['liquidity']:
                return {'status': 'pass', 'detail': f'volume {fmt_usd(vol)} / liquidity {fmt_usd(liq)}'
                                                    f' meets {fmt_usd(r["volume"])} / {fmt_usd(r["liquidity"])}'}
            near = vol >= NEAR * r['volume'] or liq >= NEAR * r['liquidity']
            return {'status': 'near' if near else 'fail',
                    'detail': f'volume {fmt_usd(vol)} < {fmt_usd(r["volume"])} and liquidity {fmt_usd(liq)} < '
                              f'{fmt_usd(r["liquidity"])}'}
        if vol >= r['volume']:
            return {'status': 'pass', 'detail': f'volume {fmt_usd(vol)} >= {fmt_usd(r["volume"])}'}
        if 'altValue' in r and v >= r['altValue'] and vol >= r['altVolume']:
            return {'status': 'pass', 'detail': f'volume {fmt_usd(vol)} >= {fmt_usd(r["altVolume"])} with value '
                                                f'>= {fmt_usd(r["altValue"])}'}
        near = vol >= NEAR * r['volume'] or ('altValue' in r and v >= r['altValue'] and vol >= NEAR * r['altVolume'])
        return {'status': 'near' if near else 'fail', 'detail': f'volume {fmt_usd(vol)} < {fmt_usd(r["volume"])}'}

    def holders_rule(self, t):
        h, need = t.get('holders'), self.rule['holders']
        if h is None:
            why = t.get('holdersError') or ('not fetched (value/volume rule not met)' if not t.get('holdersFetched')
                                            else 'unknown')
            return {'status': 'unknown', 'detail': f'holders unknown: {why}'}
        if h >= need:
            return {'status': 'pass', 'detail': f'holders {h:,} >= {need:,}'}
        return {'status': 'near' if h >= NEAR * need else 'fail', 'detail': f'holders {h:,} < {need:,}'}

    def listing_rule(self, t):
        tw = t.get('trustWallet')
        tw_ok = bool(tw and tw.get('status') == 'active')
        indep = [n for n in t.get('lists', []) if n != 'coingecko-tokenlist']
        kind = self.rule['listing']
        if kind == 'tronscan':
            ok = t.get('tronscan') is not None
            return {'status': 'pass' if ok else 'fail', 'detail': 'TronScan record' if ok else 'no TronScan record'}
        if kind == 'jupiter-verified':
            ok = bool((t.get('jupiter') or {}).get('verified'))
            return {'status': 'pass' if ok else 'fail', 'detail': 'Jupiter verified' if ok else 'not Jupiter verified'}
        if tw_ok:
            return {'status': 'pass', 'detail': 'active Trust Wallet record' + (f' + {", ".join(indep)}' if indep else '')}
        if kind == 'trustwallet-or-1-list':
            if indep:
                return {'status': 'pass', 'detail': f'listed by {", ".join(indep)}'}
            return {'status': 'fail', 'detail': 'no active Trust Wallet record and no independent list'}
        # smartchain: Trust Wallet, or two independent lists and >= 20k holders
        h = t.get('holders') or 0
        if len(indep) >= 2 and h >= 20000:
            return {'status': 'pass', 'detail': f'listed by {", ".join(indep)} with {h:,} holders'}
        return {'status': 'fail', 'detail': f'no active Trust Wallet record; {len(indep)} independent list(s)'
                                            f'{" (" + ", ".join(indep) + ")" if indep else ""}, holders {fmt_int(t.get("holders"))}'
                                            f' (needs 2 lists and >= 20,000 holders)'}

    def evaluate(self, t):
        rules = {'onchain': {'status': 'pass', 'detail': f'decimals {t["decimals"]} on-chain'} if t.get('decimals') is not None
                 else {'status': 'fail', 'detail': 'on-chain decimals unavailable'},
                 'value': self.value_rule(t), 'volume': self.volume_rule(t), 'holders': self.holders_rule(t),
                 'listing': self.listing_rule(t)}
        if self.rule.get('notDeprecated'):
            dep = any(f.split(':')[0] == 'deprecated' for f in t['flags'])
            rules['notDeprecated'] = {'status': 'fail' if dep else 'pass',
                                      'detail': 'deprecated contract' if dep else 'not marked deprecated'}
        t['rules'] = rules
        bad = {k: r for k, r in rules.items() if r['status'] != 'pass'}
        if not bad:
            t['status'] = 'eligible'
            t['eligibleReason'] = '; '.join(r['detail'] for r in rules.values())
            return
        t['failReason'] = '; '.join(r['detail'] for r in bad.values())
        hard = [k for k, r in bad.items() if r['status'] == 'fail' and k not in ('listing', 'notDeprecated')]
        misses = [k for k, r in bad.items() if r['status'] in ('fail', 'near')]
        unknown = [k for k, r in bad.items() if r['status'] == 'unknown']
        # near miss: one rule short with everything else known, only data missing, or a value/volume
        # shortfall for which holders were simply not fetched
        near = (not hard and rules['onchain']['status'] == 'pass' and 'notDeprecated' not in misses and (
            (len(misses) == 1 and not unknown) or (not misses and unknown) or
            (len(misses) == 1 and misses[0] in ('value', 'volume') and unknown == ['holders'])))
        t['status'] = 'nearMiss' if near else 'rejected'

    # ---- flags
    def flag(self, t, name: str, detail: str | None = None):
        f = name if detail is None else f'{name}:{detail}'
        if f not in t['flags']:
            t['flags'].append(f)

    def heuristics(self, t):
        name, sym, cgid = t['name'] or '', t['symbol'] or '', t['coingeckoId']
        oc_sym = t.get('onchainSymbol') or ''
        text = f'{name} | {sym} | {oc_sym} | {cgid}'
        syms = {s for s in (sym, oc_sym) if s}
        jtags = set((t.get('jupiter') or {}).get('tags') or [])
        if TOKENIZED_RE.search(text) or jtags & JUPITER_STOCK_TAGS:
            self.flag(t, 'tokenizedStockOrFund')
        if (RECEIPT_NAME_RE.search(name) or any(RECEIPT_SYMBOL_RE.match(s) for s in syms)
                or ATOKEN_RE.match(oc_sym) or RECEIPT_CASED_RE.match(oc_sym)):
            self.flag(t, 'receiptOrVault')
        if jtags & {'yb', 'jup-lend-earn'}:
            self.flag(t, 'receiptOrVault', 'jupiter-tag')
        if LIQUID_STAKING_RE.search(text) or 'lst' in jtags:
            self.flag(t, 'liquidStaking')
        if LEVERAGED_RE.search(name) or any(LEVERAGED_RE.search(s) for s in syms):
            self.flag(t, 'leveraged')
        if LP_RE.search(name) or any(LP_RE.search(s) for s in syms):
            self.flag(t, 'lpToken')
        ts_sym = (t.get('tronscan') or {}).get('symbol') or ''
        if DEPRECATED_RE.search(name) or any(s.upper().endswith('OLD') and len(s) > 4 for s in syms | {ts_sym}):
            self.flag(t, 'deprecated')
        if t.get('bridgedFrom') or BRIDGE_RE.search(name):
            self.flag(t, 'bridged')
        # decimals across sources (on-chain is the source of truth)
        dec = t.get('decimals')
        by_src = t['decimalsBySource']
        if dec is not None:
            bad = {s: d for s, d in by_src.items() if s not in ('onchain', 'coinmarketcap') and d != dec}
            if bad:
                self.flag(t, 'decimalsDisagreement', ','.join(f'{s}={d}' for s, d in sorted(bad.items())))
            if 'coinmarketcap' in by_src and by_src['coinmarketcap'] != dec:
                self.flag(t, 'cmcDecimalsDisagreement', str(by_src['coinmarketcap']))
            if dec > 24:
                self.flag(t, 'weirdDecimals', str(dec))
        else:
            self.flag(t, 'onchainUnavailable')
            if len(set(by_src.values())) > 1:
                self.flag(t, 'decimalsDisagreement', ','.join(f'{s}={d}' for s, d in sorted(by_src.items())))
        # symbols: CoinGecko vs on-chain vs Trust Wallet
        cg_n, oc_n = build.norm_symbol(sym), build.norm_symbol(oc_sym)
        tw_n = build.norm_symbol((t.get('trustWallet') or {}).get('symbol'))
        mism = []
        if oc_n and cg_n != oc_n:
            mism.append(f'coingecko={sym}/onchain={oc_sym}')
        if tw_n and oc_n and tw_n != oc_n:
            mism.append(f'trustwallet={t["trustWallet"]["symbol"]}/onchain={oc_sym}')
        if tw_n and not oc_n and tw_n != cg_n:
            mism.append(f'trustwallet={t["trustWallet"]["symbol"]}/coingecko={sym}')
        if mism:
            self.flag(t, 'symbolMismatch', ';'.join(mism))
        shown = oc_sym or sym
        if shown and (not shown.isascii() or not shown.isprintable()):
            self.flag(t, 'nonAsciiSymbol')
        for s in {cg_n, oc_n} - {''}:
            if s in self.pinned_symbols:
                self.flag(t, 'symbolCollidesWithPinned', self.pinned_symbols[s])
        if t.get('otherCoingeckoIds'):
            self.flag(t, 'multipleCoingeckoIds', ','.join(t['otherCoingeckoIds'][:4]))
        # holders / listing quality
        pct = t.get('topHoldersPct')
        if pct is None:
            self.flag(t, 'holderConcentrationUnknown')
        elif pct > 100.5:  # indexer balances and supply out of sync
            self.flag(t, 'holderDataInconsistent', f'top10={pct:.1f}%')
        elif pct >= 90:
            self.flag(t, 'highHolderConcentration', f'top10={pct:.1f}%')
        tw = t.get('trustWallet')
        if tw and tw.get('status') != 'active':
            self.flag(t, 'trustWalletInactive', str(tw.get('status')))
        rep = (t.get('blockscout') or {}).get('reputation')
        if rep and rep != 'ok':
            self.flag(t, 'blockscoutReputation', rep)
        ts = t.get('tronscan') or {}
        tags = ts.get('tags') or {}
        if tags.get('redTag'):  # TronScan's warning label
            self.flag(t, 'tronscanTag', f'redTag={tags["redTag"]}')
        if tags.get('greyTag'):  # a category label such as "SUN PUMP,Meme"
            self.flag(t, 'tronscanLabel', tags['greyTag'])
        if self.key == 'tron' and ts and (ts.get('transfer24h') or 0) < 100:
            self.flag(t, 'lowTransfers24h', str(ts.get('transfer24h')))
        j = t.get('jupiter') or {}
        if j.get('organicScoreLabel') == 'low':
            self.flag(t, 'lowOrganicScore', f'{j.get("organicScore") or 0:.1f}')
        if self.key == 'solana' and j and (j.get('volume24hUsd') or 0) < 1e5:
            self.flag(t, 'lowJupiterVolume', fmt_usd(j.get('volume24hUsd') or 0))
        if j.get('mintAuthorityDisabled') is False:
            self.flag(t, 'mintAuthorityActive')
        if self.key == 'solana' and t.get('tokenProgram') == build.TOKEN_2022:
            self.flag(t, 'token2022')
        if not t.get('iconCandidate'):
            self.flag(t, 'noIcon')

    # ---- main
    def run(self) -> dict:
        t_start = time.monotonic()
        ctx, http = self.ctx, self.http
        self.load_lists()
        self.log(f'lists: {", ".join(f"{k}={len(v)}" for k, v in self.lists.items())}')

        # 1. candidates: exact platform addresses
        by_addr: dict[str, list[str]] = collections.defaultdict(list)
        for c in ctx.coins:
            raw = ((c.get('platforms') or {}).get(self.platform) or '').strip()
            if not raw:
                continue
            a = self.norm(raw)
            if not addr_ok(a, self.family):
                self.stats['invalidAddress'] += 1
                continue
            by_addr[a].append(c['id'])
        self.stats['coingeckoAddresses'] = len(by_addr)
        mk = lambda i: ctx.markets.get(i) or {}
        tokens: list[dict] = []
        for a, ids in by_addr.items():
            if a in self.pinned:
                self.stats['pinnedSkipped'] += 1
                continue
            ids.sort(key=lambda i: (-(mk(i).get('market_cap') or 0), -(mk(i).get('total_volume') or 0), i))
            m = mk(ids[0])
            t = {'address': a, 'coingeckoId': ids[0], 'otherCoingeckoIds': ids[1:], 'flags': [], 'errors': [],
                 'excludedBefore': self.excluded.get(a)}
            if not m or not m.get('current_price'):
                self.stats['noMarketData'] += 1
                if t['excludedBefore']:
                    t.update(name=t['excludedBefore'].get('name'), symbol=t['excludedBefore'].get('symbol'),
                             status='noMarketData')
                    tokens.append(t)
                continue
            mc, fdv, vol = m.get('market_cap') or 0, m.get('fully_diluted_valuation') or 0, m.get('total_volume') or 0
            t.update(name=m.get('name'), symbol=(m.get('symbol') or '').upper(), marketCapRank=m.get('market_cap_rank'),
                     priceUsd=m.get('current_price'), marketCapUsd=mc, fdvUsd=fdv or None, volume24hUsd=vol,
                     image=m.get('image'), marketDataUpdated=m.get('last_updated'))
            canon = canonical_for(m, ctx.big)
            if canon and (mc == 0 or BRIDGE_RE.search(m.get('name') or '')):
                t['bridgedFrom'] = {'coingeckoId': canon['id'], 'symbol': canon['symbol'].upper(),
                                    'marketCapUsd': canon['market_cap']}
            if mc > 0 and mc >= PREFILTER['marketCapUsd'] and vol >= PREFILTER['volume24hUsd']:
                t['prefilter'] = 'marketCap'
            elif mc == 0 and fdv >= PREFILTER['marketCapUsd'] and vol >= PREFILTER['volume24hUsd']:
                t['prefilter'] = 'fdv'
                self.flag(t, 'marketCapZeroUsedFdv')
            elif mc == 0 and canon and canon['market_cap'] >= PREFILTER['bridgedCanonicalMarketCapUsd']:
                t['prefilter'] = 'bridgedCanonical'
            elif mc == 0 and vol >= PREFILTER['volume24hUsd']:
                t['prefilter'] = 'noMarketCap'
            if t.get('prefilter') or t['excludedBefore']:
                if not t.get('prefilter'):
                    t['status'] = 'notPrefiltered'
                tokens.append(t)
        pre = sorted((t for t in tokens if t.get('prefilter')), key=lambda t: t['address'])
        self.stats['prefiltered'] = len(pre)
        self.log(f'{len(by_addr)} CoinGecko addresses, {self.stats["pinnedSkipped"]} pinned skipped, '
                 f'{self.stats["noMarketData"]} without market data, {len(pre)} pre-filtered')

        # 2. on-chain decimals / symbol / supply, then per-network value
        meta = self.onchain([t['address'] for t in pre])
        self.log(f'on-chain metadata for {len(meta)}/{len(pre)}')
        for t in pre:
            oc = meta.get(t['address']) or {}
            dec, raw_supply = oc.get('decimals'), oc.get('totalSupply')
            t['decimals'], t['onchainSymbol'], t['rawSupply'] = dec, oc.get('symbol'), raw_supply
            if self.family == 'solana':
                t['tokenProgram'] = oc.get('tokenProgram')
            supply = raw_supply / 10 ** dec if raw_supply is not None and dec is not None and dec <= 77 else None
            t['supply'] = supply
            sv = supply * t['priceUsd'] if supply is not None else None
            t['supplyValueUsd'] = sv
            mc = t['marketCapUsd']
            if mc > 0 and sv is not None:
                t['valueUsd'], t['valueBasis'] = min(mc, sv), ('marketCap' if mc <= sv else 'onchainSupply')
                if sv < 0.5 * mc:
                    self.flag(t, 'volumeGlobalMultichain')  # CoinGecko volume covers every chain, not just this one
            elif mc > 0:
                t['valueUsd'], t['valueBasis'] = mc, 'marketCap (supply unavailable)'
                self.flag(t, 'supplyUnavailable')
            elif sv is not None:
                t['valueUsd'], t['valueBasis'] = sv, 'onchainSupply (no market cap)'
                self.flag(t, 'valueFromSupply')
                if not t.get('bridgedFrom'):
                    # CoinGecko has no circulating supply for a non-bridged token: the value is FDV-like
                    # (whole supply x price) and not comparable with market caps.
                    self.flag(t, 'noMarketCap')
            else:
                t['valueUsd'], t['valueBasis'] = None, 'unknown'
            if not oc:
                t['errors'].append('on-chain metadata unavailable')

        # 3. TronScan / Jupiter for every pre-filtered token (cheap; they also carry holders and liquidity)
        if self.family == 'tron':
            for t in pre:
                try:
                    t['tronscan'] = self.tronscan(t['address'])
                except Exception as e:
                    self.err('tronscan', t['address'], e)
                    t['errors'].append(f'tronscan: {str(e)[:120]}')
                    t['tronscan'] = None
                ts = t['tronscan'] or {}
                t['holders'], t['holdersSource'], t['holdersFetched'] = ts.get('holders'), 'tronscan', True
                if t['tronscan'] is None and not t.get('holdersError'):
                    t['holdersError'] = 'no TronScan record'
        if self.family == 'solana':
            jup = self.jupiter([t['address'] for t in pre])
            for t in pre:
                j = jup.get(t['address'])
                listed = self.jup_verified.get(t['address'])
                # the live search result wins; the (older) verified-list snapshot is only a fallback
                verified = bool(j.get('isVerified')) if j is not None else listed is not None
                if j is None and listed is not None:
                    j = listed
                t['holdersFetched'] = True
                if j is None:
                    t['jupiter'] = None
                    t['holders'], t['holdersSource'] = None, 'jupiter'
                    t['holdersError'] = 'not found on Jupiter'
                    continue
                s24 = j.get('stats24h') or {}
                audit = j.get('audit') or {}
                t['jupiter'] = {'verified': verified, 'inVerifiedList': listed is not None,
                                'organicScore': j.get('organicScore'), 'organicScoreLabel': j.get('organicScoreLabel'),
                                'liquidity': j.get('liquidity'), 'holders': j.get('holderCount'),
                                'volume24hUsd': (s24.get('buyVolume') or 0) + (s24.get('sellVolume') or 0),
                                'tags': j.get('tags') or [], 'decimals': j.get('decimals'), 'symbol': j.get('symbol'),
                                'tokenProgram': j.get('tokenProgram'),
                                'mintAuthorityDisabled': audit.get('mintAuthorityDisabled'),
                                'freezeAuthorityDisabled': audit.get('freezeAuthorityDisabled')}
                t['holders'], t['holdersSource'] = to_int(j.get('holderCount')), 'jupiter'
                t['topHoldersPct'] = to_float(audit.get('topHoldersPercentage'))

        # 4. Trust Wallet for everything that could matter (value within the near-miss band)
        band = [t for t in pre if self.value_rule(t)['status'] in ('pass', 'near')]
        band_ids = {id(t) for t in band}
        band += [t for t in pre if t['excludedBefore'] and id(t) not in band_ids]

        def tw(t):
            try:
                t['trustWallet'] = self.trust_wallet(t['address'])
            except Exception as e:
                self.err('trustwallet', t['address'], e)
                t['errors'].append(f'trustwallet: {str(e)[:120]}')
                t['trustWallet'] = None
        with concurrent.futures.ThreadPoolExecutor(8) as pool:
            list(pool.map(tw, band))
        self.log(f'Trust Wallet lookups: {len(band)} ({sum(1 for t in band if t.get("trustWallet"))} records)')

        # 5. holders for tokens that pass the value/volume rule (EVM)
        vv = [t for t in pre if self.value_rule(t)['status'] == 'pass' and self.volume_rule(t)['status'] == 'pass']
        self.stats['valueVolumePass'] = len(vv)
        if self.evm:
            if self.key == 'smartchain':
                # GeckoTerminal is heavily rate limited. Holder counts only decide eligibility when the
                # listing rule can still pass (active Trust Wallet record, or >= 2 independent lists).
                def listing_possible(t):
                    tw_rec = t.get('trustWallet')
                    indep = [n for n, table in self.lists.items() if n != 'coingecko-tokenlist' and t['address'] in table]
                    return bool(tw_rec and tw_rec.get('status') == 'active') or len(indep) >= 2
                todo = [t for t in vv if listing_possible(t)]
                for t in vv:
                    if not listing_possible(t):
                        t['holdersSource'] = 'geckoterminal'
                        t['holdersError'] = 'not fetched (listing rule cannot pass: no active Trust Wallet record, < 2 lists)'
                self.stats['holdersSkippedListing'] = len(vv) - len(todo)
                self.log(f'{len(vv)} pass value/volume; fetching holders for {len(todo)} that can meet the listing rule')
                for n, t in enumerate(todo, 1):
                    self._holders(t, self.geckoterminal)
                    if n % 25 == 0:
                        self.log(f'  GeckoTerminal {n}/{len(todo)}')
            else:
                self.log(f'{len(vv)} pass value/volume; fetching holders')
                with concurrent.futures.ThreadPoolExecutor(4) as pool:
                    list(pool.map(lambda t: self._holders(t, self.blockscout), vv))
        self.stats['holdersKnown'] = sum(1 for t in vv if t.get('holders') is not None)

        # 6. holder concentration for likely-eligible tokens (Blockscout / TronScan top 10)
        conc = [t for t in vv if t.get('holders') is not None and t['holders'] >= self.rule['holders']
                and t.get('topHoldersPct') is None]
        if self.key in BLOCKSCOUT:
            def top10(t):
                try:
                    supply = t.get('rawSupply') or (t.get('blockscout') or {}).get('totalSupply')
                    t['topHoldersPct'] = self.blockscout_top10(t['address'], supply)
                except Exception as e:
                    self.err('blockscout-holders', t['address'], e)
            with concurrent.futures.ThreadPoolExecutor(4) as pool:
                list(pool.map(top10, conc))
        elif self.family == 'tron':
            for t in conc:
                try:
                    t['topHoldersPct'] = self.tronscan_top10(t['address'], t.get('rawSupply'))
                except Exception as e:
                    self.err('tronscan-holders', t['address'], e)

        # 7. listings, flags, rules
        for t in pre:
            a = t['address']
            t.setdefault('trustWallet', None)
            found, by_src = [], {}
            if t.get('decimals') is not None:
                by_src['onchain'] = t['decimals']
            tw_rec = t.get('trustWallet')
            if tw_rec and tw_rec.get('decimals') is not None:
                by_src['trustwallet'] = to_int(tw_rec['decimals'])
            for name, table in self.lists.items():
                if a in table:
                    found.append(name)
                    if table[a] is not None and to_int(table[a]) is not None:
                        by_src[name] = to_int(table[a])
            if t.get('tronscan'):
                found.append('tronscan')
                if t['tronscan'].get('decimals') is not None:
                    by_src['tronscan'] = t['tronscan']['decimals']
            for src in ('jupiter', 'blockscout', 'geckoterminal'):
                d = (t.get(src) or {}).get('decimals')
                if d is not None:
                    by_src[src] = to_int(d)
            t['lists'], t['decimalsBySource'] = sorted(found), by_src
            if tw_rec and tw_rec.get('status') == 'active':
                t['iconCandidate'] = f'{self.tw_base}/{self.net["trustWalletChain"]}/assets/{self.tw_dir(a)}/logo.png'
            elif t.get('image') and 'missing' not in t['image'].rsplit('/', 1)[-1]:
                t['iconCandidate'] = t['image']
            else:
                t['iconCandidate'] = None
            self.heuristics(t)
            self.evaluate(t)

        # symbol collisions among eligible candidates
        eligible = [t for t in pre if t['status'] == 'eligible']
        seen = collections.defaultdict(list)
        for t in eligible:
            seen[build.norm_symbol(t.get('onchainSymbol') or t['symbol'])].append(t)
        for sym, group in seen.items():
            if sym and len(group) > 1:
                for t in group:
                    self.flag(t, 'symbolCollidesWithCandidate',
                              ','.join(x['coingeckoId'] for x in group if x is not t)[:120])
        for t in tokens:
            t['needsReview'] = any(f.split(':')[0] in REVIEW_FLAGS for f in t['flags'])

        # 8. output
        key_value = lambda t: -(t.get('valueUsd') or 0)
        eligible = sorted((t for t in pre if t['status'] == 'eligible' and not t['excludedBefore']), key=key_value)
        near = sorted((t for t in pre if t['status'] == 'nearMiss' and not t['excludedBefore']), key=key_value)
        rejected = sorted((t for t in pre if t['status'] == 'rejected' and not t['excludedBefore']),
                          key=lambda t: -(t.get('marketCapUsd') or t.get('valueUsd') or 0))
        prev = sorted((t for t in tokens if t['excludedBefore']), key=key_value)
        found_prev = {t['address'] for t in prev}
        missing_prev = [e for a, e in self.excluded.items() if a not in found_prev]
        self.stats['eligible'], self.stats['nearMiss'] = len(eligible), len(near)
        self.stats['rejected'] = sum(1 for t in pre if t['status'] == 'rejected' and not t['excludedBefore'])
        self.stats['eligibleNeedsReview'] = sum(1 for t in eligible if t['needsReview'])
        self.stats['previouslyExcludedSeen'] = len(prev)
        self.stats['previouslyExcludedNowEligible'] = sum(1 for t in prev if t.get('status') == 'eligible')
        doc = {
            'network': self.key,
            'chainFamily': self.family,
            **({'chainId': self.net['chainId']} if self.evm else {}),
            'coingeckoPlatform': self.platform,
            'generatedAt': now_iso(),
            'marketDataAsOf': ctx.market_asof,
            'trustWalletCommit': ctx.sel['trustWalletCommit'],
            'pinnedCount': len(self.net['tokens']),
            'desiredTotal': DESIRED_TOTAL[self.key],
            'thresholds': {'eligibility': RULE_TEXT[self.key], 'rule': self.rule, 'prefilter': PREFILTER,
                           'nearMissFactor': NEAR,
                           'value': 'min(CoinGecko market cap, on-chain total supply x price); supply x price when '
                                    'the market cap is 0'},
            'stats': dict(self.stats),
            'apiErrors': dict(self.errors),
            'apiErrorSamples': self.error_samples,
            'eligible': [render(t, self.key) for t in eligible],
            'nearMiss': [render(t, self.key) for t in near],
            # compact audit trail: every other pre-filtered token and why it failed
            'rejected': [{'address': t['address'], 'coingeckoId': t['coingeckoId'], 'symbol': t.get('symbol'),
                          'name': t.get('name'), 'marketCapUsd': _round_usd(t.get('marketCapUsd')),
                          'valueUsd': _round_usd(t.get('valueUsd')), 'volume24hUsd': _round_usd(t.get('volume24hUsd')),
                          'holders': t.get('holders'), 'failReason': t.get('failReason')} for t in rejected],
            'previouslyExcluded': [render(t, self.key) for t in prev] + [
                {'address': e['address'], 'symbol': e['symbol'], 'name': e['name'], 'previousReason': e['reason'],
                 'status': 'notInCoinGeckoPlatformMap'} for e in missing_prev],
        }
        out = ctx.out_dir / f'candidates-{self.key}.json'
        tmp = out.with_suffix('.tmp')
        tmp.write_text(json.dumps(doc, ensure_ascii=False, indent=1) + '\n')
        tmp.replace(out)
        self.log(f'done in {time.monotonic() - t_start:.0f}s: eligible {len(eligible)} '
                 f'({self.stats["eligibleNeedsReview"]} need review), near-miss {len(near)}, '
                 f'previously excluded {len(prev)} -> {out}')
        return doc

    def _holders(self, t, fetch):
        t['holdersFetched'] = True
        try:
            t.update(fetch(t['address']))
        except Exception as e:
            self.err(fetch.__name__, t['address'], e)
            t['holders'] = None
            t['holdersError'] = f'{fetch.__name__} error: {str(e)[:120]}'
            t['errors'].append(t['holdersError'])


def _round_usd(x):
    if x is None:
        return None
    return round(x) if abs(x) >= 100 else round(x, 4)


def render(t: dict, key: str) -> dict:
    out = {
        'address': t['address'],
        'coingeckoId': t['coingeckoId'],
        'name': t.get('name'),
        'symbol': t.get('symbol'),
        'onchainSymbol': t.get('onchainSymbol'),
        'decimals': t.get('decimals'),
    }
    if key == 'solana':
        out['tokenProgram'] = t.get('tokenProgram')
    out.update({
        'marketCapRank': t.get('marketCapRank'),
        'priceUsd': t.get('priceUsd'),
        'marketCapUsd': _round_usd(t.get('marketCapUsd')),
        'fdvUsd': _round_usd(t.get('fdvUsd')),
        'volume24hUsd': _round_usd(t.get('volume24hUsd')),
        'supply': None if t.get('supply') is None else float(f'{t["supply"]:.10g}'),
        'valueUsd': _round_usd(t.get('valueUsd')),
        'valueBasis': t.get('valueBasis'),
        'holders': t.get('holders'),
        'holdersSource': t.get('holdersSource'),
        'topHoldersPct': t.get('topHoldersPct'),
        'trustWallet': t.get('trustWallet'),
        'lists': t.get('lists', []),
        'decimalsBySource': t.get('decimalsBySource'),
    })
    if key == 'solana':
        j = t.get('jupiter')
        out['jupiter'] = None if j is None else {
            'verified': j['verified'], 'organicScore': None if j.get('organicScore') is None else round(j['organicScore'], 2),
            'organicScoreLabel': j.get('organicScoreLabel'), 'liquidity': _round_usd(j.get('liquidity')),
            'volume24hUsd': _round_usd(j.get('volume24hUsd')), 'tags': j.get('tags')}
    if key == 'tron':
        out['tronscan'] = t.get('tronscan')
    if key == 'smartchain' and t.get('geckoterminal'):
        out['geckoterminal'] = {k: t['geckoterminal'].get(k) for k in ('gtScore', 'gtVerified')}
    if t.get('blockscout'):
        out['blockscoutReputation'] = t['blockscout'].get('reputation')
    if t.get('bridgedFrom'):
        out['bridgedFrom'] = t['bridgedFrom']
    if t.get('otherCoingeckoIds'):
        out['otherCoingeckoIds'] = t['otherCoingeckoIds']
    out.update({
        'prefilter': t.get('prefilter'),
        'flags': t.get('flags', []),
        'needsReview': t.get('needsReview', False),
        'iconCandidate': t.get('iconCandidate'),
        'status': t.get('status'),
    })
    if t.get('rules'):
        out['rules'] = {k: f'{r["status"]}: {r["detail"]}' for k, r in t['rules'].items()}
    if t.get('eligibleReason'):
        out['eligibleReason'] = t['eligibleReason']
    if t.get('failReason'):
        out['failReason'] = t['failReason']
    if t.get('excludedBefore'):
        out['previousReason'] = t['excludedBefore'].get('reason')
    if t.get('errors'):
        out['errors'] = t['errors']
    return out


# --------------------------------------------------------------------------- summary

def write_summary(ctx, docs: dict[str, dict], seconds: float):
    lines = [
        '# Token candidate discovery',
        '',
        f'- Generated: {now_iso()} (this invocation took {seconds / 60:.1f} min; cached responses are reused)',
        f'- CoinGecko market data as of: {ctx.market_asof}',
        f'- Trust Wallet commit: `{ctx.sel["trustWalletCommit"]}`',
        f'- Script: `scripts/discover-token-candidates.py` (cache: `{ctx.http.cache}`)',
        f'- HTTP 429 responses handled this run: '
        f'{", ".join(f"{h}={n}" for h, n in ctx.http.rate_limited.items()) or "none"}',
        '- "Clean" = eligible with no review-level flag (tokenized stock/fund, receipt/vault, LP, leveraged, '
        'deprecated, decimals/symbol disagreement, symbol collision, holder concentration >= 90%, ...).',
        '',
        '| Network | Pinned | Desired total | CG addresses | Pre-filtered | Value/vol pass | Eligible | '
        'Eligible w/ review flags | Clean eligible | Near-miss | Prev. excluded now eligible | '
        'Pinned + clean eligible |',
        '| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |',
    ]
    for key in NETWORK_ORDER:
        d = docs.get(key)
        if not d:
            continue
        s = d['stats']
        clean = s['eligible'] - s['eligibleNeedsReview']
        lines.append(f'| {key} | {d["pinnedCount"]} | {d["desiredTotal"]} | {s.get("coingeckoAddresses", 0)} | '
                     f'{s.get("prefiltered", 0)} | {s.get("valueVolumePass", 0)} | {s["eligible"]} | '
                     f'{s["eligibleNeedsReview"]} | {clean} | {s["nearMiss"]} | '
                     f'{s.get("previouslyExcludedNowEligible", 0)} | {d["pinnedCount"] + clean} |')
    lines += ['', '## Can the desired totals be reached?', '']
    for key in NETWORK_ORDER:
        d = docs.get(key)
        if not d:
            continue
        s = d['stats']
        need = d['desiredTotal'] - d['pinnedCount']
        clean = s['eligible'] - s['eligibleNeedsReview']
        if clean >= need:
            verdict = f'yes: {clean} clean eligible candidates for {need} open slots'
        elif s['eligible'] >= need:
            verdict = (f'only with flagged tokens: {clean} clean + {s["eligibleNeedsReview"]} flagged eligible for '
                       f'{need} open slots')
        else:
            verdict = (f'NO under these thresholds: {s["eligible"]} eligible ({clean} clean) for {need} open slots; '
                       f'{s["nearMiss"]} near-misses')
        causes = collections.Counter(k for t in d['nearMiss'] for k, r in (t.get('rules') or {}).items()
                                     if not r.startswith('pass'))
        why = ', '.join(f'{k} {n}' for k, n in causes.most_common())
        lines.append(f'- **{key}** — {verdict}.' + (f' Near-miss gaps by rule: {why}.' if why else ''))
    lines += ['', '## Data quality', '']
    for key in NETWORK_ORDER:
        d = docs.get(key)
        if not d:
            continue
        items = d['eligible'] + d['nearMiss']
        dec = [f'{t["symbol"]} `{t["address"]}` ({next(f for f in t["flags"] if f.startswith("decimalsDisagreement"))})'
               for t in items if any(f.startswith('decimalsDisagreement') for f in t['flags'])]
        cmc = sum(1 for t in items if any(f.startswith('cmcDecimalsDisagreement') for f in t['flags']))
        sym = [f'{t["symbol"]} ({next(f for f in t["flags"] if f.startswith("symbolMismatch")).split(":", 1)[1]})'
               for t in d['eligible'] if any(f.startswith('symbolMismatch') for f in t['flags'])]
        coll = sorted({t['symbol'] for t in d['eligible'] if any(f.startswith('symbolCollidesWith') for f in t['flags'])})
        errs = ', '.join(f'{k}={v}' for k, v in d['apiErrors'].items()) or 'none'
        lines.append(f'### {key}')
        lines.append('')
        lines.append(f'- API errors: {errs}')
        lines.append(f'- Decimals disagreements (eligible + near-miss, excluding CoinMarketCap list): '
                     f'{"; ".join(dec) if dec else "none"}')
        lines.append(f'- CoinMarketCap-list-only decimals disagreements: {cmc}')
        lines.append(f'- Symbol mismatches among eligible ({len(sym)}): {"; ".join(sym[:40]) or "none"}'
                     f'{" …" if len(sym) > 40 else ""}')
        lines.append(f'- Eligible symbols colliding with pinned or other candidates ({len(coll)}): '
                     f'{", ".join(coll[:60]) or "none"}')
        lines.append('')
    lines += ['## Top eligible candidates (by value)', '',
              'Rank order by `valueUsd`; † = has a review-level flag (see the JSON for details).', '']
    for key in NETWORK_ORDER:
        d = docs.get(key)
        if not d:
            continue
        top = d['eligible'][:150]
        lines.append(f'### {key} ({len(d["eligible"])} eligible, showing {len(top)})')
        lines.append('')
        lines.append(', '.join(f'{i}. {t["symbol"]}{"†" if t["needsReview"] else ""}' for i, t in enumerate(top, 1))
                     or '(none)')
        lines.append('')
    (ctx.out_dir / 'summary.md').write_text('\n'.join(lines) + '\n')


# --------------------------------------------------------------------------- main

class Context:
    pass


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--cache-dir', default=os.path.join(tempfile.gettempdir(), 'bittool-signer-token-registry-cache'))
    ap.add_argument('--out-dir', default=os.path.join(tempfile.gettempdir(), 'bittool-signer-token-candidates'))
    ap.add_argument('--network', action='append', choices=NETWORK_ORDER)
    ap.add_argument('--offline', action='store_true')
    ap.add_argument('--refresh', action='append', default=[], choices=sorted(REFRESH_GROUPS) + ['all'])
    args = ap.parse_args()
    started = time.monotonic()

    ctx = Context()
    ctx.http = Http(pathlib.Path(args.cache_dir), args.offline, args.refresh)
    ctx.out_dir = pathlib.Path(args.out_dir)
    ctx.out_dir.mkdir(parents=True, exist_ok=True)
    ctx.sel = json.loads(build.SELECTION.read_text())
    ctx.tw_base = f'https://raw.githubusercontent.com/trustwallet/assets/{ctx.sel["trustWalletCommit"]}/blockchains'

    list_url = f'{build.COINGECKO}/coins/list?include_platform=true'
    ctx.coins = ctx.http.json(list_url)
    print(f'CoinGecko coins: {len(ctx.coins)}', flush=True)
    # Markets for every coin on any of the six platforms, in fixed 250-id batches (the same URLs on every
    # run, whatever --network says, so a warm cache serves them all).
    platforms = [n['coingeckoPlatform'] for n in ctx.sel['networks']]
    ids = sorted({c['id'] for c in ctx.coins if any((c.get('platforms') or {}).get(p) for p in platforms)})
    ctx.markets, mtimes = {}, []
    for i in range(0, len(ids), 250):
        url = f'{build.COINGECKO}/coins/markets?vs_currency=usd&per_page=250&page=1&ids=' + ','.join(ids[i:i + 250])
        try:
            for m in ctx.http.json(url) or []:
                ctx.markets[m['id']] = m
            p = ctx.http._path(url, None)
            if p.exists():
                mtimes.append(p.stat().st_mtime)
        except BuildError as e:
            print(f'  ! markets batch {i // 250}: {e}', file=sys.stderr, flush=True)
        if (i // 250) % 10 == 9:
            print(f'  markets {i + 250}/{len(ids)}', flush=True)
    fmt = lambda ts: datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z')
    ctx.market_asof = f'{fmt(min(mtimes))} .. {fmt(max(mtimes))}' if mtimes else 'unknown'
    print(f'market data for {len(ctx.markets)}/{len(ids)} coins (as of {ctx.market_asof})', flush=True)
    ctx.big = collections.defaultdict(list)
    for m in ctx.markets.values():
        if (m.get('market_cap') or 0) >= PREFILTER['bridgedCanonicalMarketCapUsd'] and m.get('current_price'):
            ctx.big[(m.get('symbol') or '').lower()].append(m)

    nets = [n for n in ctx.sel['networks'] if not args.network or n['key'] in args.network]
    docs: dict[str, dict] = {}

    def run(net):
        try:
            return net['key'], Discovery(ctx, net).run()
        except Exception:
            print(f'[{net["key"]}] FAILED:\n{traceback.format_exc()}', file=sys.stderr, flush=True)
            return net['key'], None

    with concurrent.futures.ThreadPoolExecutor(len(nets)) as pool:
        for key, doc in pool.map(run, nets):
            if doc:
                docs[key] = doc
    # keep the summary complete when only some networks were re-run
    for key in NETWORK_ORDER:
        path = ctx.out_dir / f'candidates-{key}.json'
        if key not in docs and path.exists():
            docs[key] = json.loads(path.read_text())
    seconds = time.monotonic() - started
    write_summary(ctx, docs, seconds)
    print(f'finished in {seconds / 60:.1f} min; wrote {ctx.out_dir}/summary.md', flush=True)
    return 0 if all(n['key'] in docs for n in nets) else 1


if __name__ == '__main__':
    sys.exit(main())
