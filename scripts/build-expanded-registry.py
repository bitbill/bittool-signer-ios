#!/usr/bin/env python3
"""Merges the curated token registry with the CoinMarketCap top-2000 snapshot and
writes everything the app ships.

Inputs (all committed, so a build is reproducible and offline):
  engine/data/token-registry.json   curated records produced by build-token-registry.py
  engine/data/cmc-snapshot.json     CMC listing membership, names, symbols, logo URLs
  engine/data/cmc-onchain.json      decimals (and Solana token program) read from chains

Outputs:
  engine/data/token-registry.merged.json     full records with provenance
  BitToolSigner/Resources/token-registry.json    the same records without build provenance
  engine/data/token-registry.engine.json     compact projection bundled into signer.js
  BitToolSigner/Resources/TokenIcons.pack        every distinct artwork, concatenated
  BitToolSigner/Resources/TokenIcons.index.json  icon id -> [offset, length] in that file

Rules:
  * A curated record always wins: its name, symbol, decimals and artwork are kept.
  * A CMC record is only included when decimals were read from the chain. CMC is
    never a source of decimals, and where the contract answers symbol(), the
    contract's answer is shown rather than the listing's ticker.
  * Icons are named by the SHA-256 of their bytes, so identical artwork shared by
    several chains is stored once.

Refresh the CMC inputs with scripts/refresh-cmc-snapshot.py (needs CMC_API_KEY).

Artwork for a listed token is its CoinMarketCap logo. --icon-cache points at a
directory of <cmcId>.png files to use instead of downloading; BitTool ships the
same set (bittool/Resources/TokenIcons), which covered 1,451 of the 1,483 logos
this build needed, and the remaining 32 were fetched from CoinMarketCap.

Run: python3 scripts/build-expanded-registry.py [--icon-cache DIR] [--limit N]
"""
import argparse, hashlib, json, pathlib, re, shutil, subprocess, sys, unicodedata, urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
CURATED = ROOT / 'engine/data/token-registry.json'
SNAPSHOT = ROOT / 'engine/data/cmc-snapshot.json'
ONCHAIN = ROOT / 'engine/data/cmc-onchain.json'
MERGED = ROOT / 'engine/data/token-registry.merged.json'
APP_REGISTRY = ROOT / 'BitToolSigner/Resources/token-registry.json'
ENGINE_REGISTRY = ROOT / 'engine/data/token-registry.engine.json'
ICON_PACK = ROOT / 'BitToolSigner/Resources/TokenIcons.pack'
ICON_INDEX = ROOT / 'BitToolSigner/Resources/TokenIcons.index.json'
CURATED_ICONS = ROOT / 'engine/data/curated-icons'
# The app copy drops build provenance; the engine copy is columnar, because it is
# embedded in signer.js and parsed in a fresh VM on every sensitive operation.
APP_FIELDS = ('chainFamily', 'chainId', 'assetAddress', 'name', 'symbol', 'decimals', 'icon', 'tokenProgram',
              'rank', 'cmcId', 'metadataSource')
MAX_ICON_PX = 128
# Display order, the key used in counts, the name and native ticker shown in the
# app, and the chain logo in the asset catalog where one is bundled.
NETWORKS = {('evm', '1'): ('ethereum', 'Ethereum', 'ETH', 'ChainEthereum'),
            ('evm', '56'): ('smartchain', 'BNB Smart Chain', 'BNB', 'ChainBNB'),
            ('evm', '42161'): ('arbitrum', 'Arbitrum One', 'ETH', 'ChainArbitrum'),
            ('evm', '8453'): ('base', 'Base', 'ETH', 'ChainBase'),
            ('tron', None): ('tron', 'TRON', 'TRX', 'ChainTron'),
            ('solana', None): ('solana', 'Solana', 'SOL', 'ChainSolana'),
            ('evm', '10'): ('optimism', 'OP Mainnet', 'ETH', None),
            ('evm', '137'): ('polygon', 'Polygon PoS', 'POL', None),
            ('evm', '100'): ('gnosis', 'Gnosis', 'xDAI', None),
            ('evm', '43114'): ('avalanche', 'Avalanche C-Chain', 'AVAX', None)}
USER_AGENT = 'BitToolSignerRegistryBuild/1.0'


class BuildError(Exception):
    pass


def identity(record):
    family, address = record['chainFamily'], record['assetAddress']
    return f"{family}:{record.get('chainId') or ''}:{address.lower() if family == 'evm' else address}"


def printable(value, limit):
    """Any script is fine (plenty of listed tokens use CJK), control characters are not."""
    text = (value or '').strip()
    if not text or len(text) > limit: return None
    if any(unicodedata.category(ch) in ('Cc', 'Cf', 'Cs', 'Co', 'Cn') for ch in text): return None
    return text


def icon_bytes(path_or_url, cache):
    if str(path_or_url).startswith('http'):
        if path_or_url in cache: return cache[path_or_url]
        request = urllib.request.Request(path_or_url, headers={'User-Agent': USER_AGENT})
        with urllib.request.urlopen(request, timeout=60) as response: data = response.read()
        cache[path_or_url] = data
        return data
    return pathlib.Path(path_or_url).read_bytes()


def png_size(data):
    if data[:8] != b'\x89PNG\r\n\x1a\n': return None
    return int.from_bytes(data[16:20], 'big'), int.from_bytes(data[20:24], 'big')


ARTWORK = {}


def store_icon(data, scratch):
    """Keeps the artwork under its content hash, shrinking anything oversized. One
    copy is kept per distinct image, whatever chains or tokens share it."""
    size = png_size(data)
    if not size: raise BuildError('icon is not a PNG')
    if max(size) > MAX_ICON_PX:
        temporary = scratch / 'resize.png'
        temporary.write_bytes(data)
        subprocess.run(['sips', '-Z', str(MAX_ICON_PX), str(temporary)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        data = temporary.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    ARTWORK[digest[:16]] = data
    return digest[:16], digest


def write_icon_pack():
    """One file plus an index, instead of ~2,000 tiny files each rounded up to a
    4 KiB block on the device."""
    index, blob = {}, bytearray()
    for name in sorted(ARTWORK):
        data = ARTWORK[name]
        index[name] = [len(blob), len(data)]
        blob.extend(data)
    ICON_PACK.write_bytes(bytes(blob))
    ICON_INDEX.write_text(json.dumps(index, separators=(',', ':'), sort_keys=True) + '\n')
    return len(index), len(blob)


def curated_records(scratch, cache):
    registry = json.loads(CURATED.read_text())
    records = []
    for asset in registry['assets']:
        source = CURATED_ICONS / f"{asset['iconAsset']}.png"
        if not source.exists(): raise BuildError(f'missing curated icon for {asset["symbol"]}: {source}')
        name, digest = store_icon(source.read_bytes(), scratch)
        record = {key: value for key, value in asset.items() if key != 'iconAsset'}
        record['icon'] = name
        record['iconSha256'] = digest
        records.append(record)
    return registry, records


def cmc_records(existing, scratch, cache, limit, icon_cache):
    snapshot, onchain = json.loads(SNAPSHOT.read_text()), json.loads(ONCHAIN.read_text())
    chain_data, records, skipped = onchain['assets'], [], {'no decimals': 0, 'already curated': 0,
                                                          'unsupported chain': 0, 'unusable text': 0, 'no icon': 0}
    icons = {}
    for token in snapshot['tokens']:
        if limit and (token.get('rank') or 0) > limit: continue
        name, symbol = printable(token['name'], 80), printable(token['symbol'], 24)
        if not name or not symbol:
            skipped['unusable text'] += 1
            continue
        for contract in token['contracts']:
            family, chain_id = contract['chainFamily'], contract.get('chainId')
            if (family, chain_id) not in NETWORKS:
                skipped['unsupported chain'] += 1
                continue
            record = {'chainFamily': family, 'assetAddress': contract['address']}
            if chain_id: record['chainId'] = chain_id
            key = identity(record)
            if key in existing:
                skipped['already curated'] += 1
                continue
            measured = chain_data.get(key)
            if not measured or not isinstance(measured.get('decimals'), int):
                skipped['no decimals'] += 1
                continue
            if token['cmcId'] not in icons:
                local = icon_cache / f"{token['cmcId']}.png" if icon_cache else None
                try:
                    source = local if local and local.exists() else token['logo']
                    icons[token['cmcId']] = store_icon(icon_bytes(source, cache), scratch)
                except Exception as error:
                    skipped['no icon'] += 1
                    print(f"  no icon for {symbol} ({token['cmcId']}): {error}", file=sys.stderr)
                    icons[token['cmcId']] = None
            if not icons[token['cmcId']]: continue
            icon_name, digest = icons[token['cmcId']]
            # The contract's own symbol wins over the listing's. Most disagreements
            # are bridged or wrapped deployments (LINK.e, wROSE, pONT), where the
            # listing's ticker would claim the asset is the original token.
            onchain_symbol = printable(measured.get('symbol'), 24)
            shown = onchain_symbol or symbol
            record.update({'name': name, 'symbol': shown, 'decimals': measured['decimals'],
                           'icon': icon_name, 'iconSha256': digest, 'rank': token.get('rank'),
                           'cmcId': token['cmcId'], 'metadataSource': 'coinmarketcap',
                           'verifiedAt': onchain['checkedAt'], 'iconSource': token['logo'],
                           'verification': {'coinmarketcapRank': token.get('rank'), 'onchainDecimals': True,
                                            'symbolSource': 'onchain' if onchain_symbol else 'coinmarketcap',
                                            'onchainSymbol': onchain_symbol,
                                            'coinmarketcapSymbol': symbol}})
            if measured.get('program'): record['tokenProgram'] = measured['program']
            records.append(record)
            existing.add(key)
    return snapshot, records, skipped


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--limit', type=int, default=0, help='only include CMC ranks up to this value')
    parser.add_argument('--icon-cache', type=pathlib.Path, default=None,
                        help='directory of <cmcId>.png files to use instead of downloading')
    arguments = parser.parse_args()

    scratch = ROOT / '.build-icons'
    scratch.mkdir(exist_ok=True)
    cache = {}

    registry, records = curated_records(scratch, cache)
    print(f'curated records: {len(records)}')
    seen = {identity(record) for record in records}
    snapshot, added, skipped = cmc_records(seen, scratch, cache, arguments.limit, arguments.icon_cache)
    print(f'coinmarketcap records: {len(added)}  skipped: {skipped}')
    records.extend(added)

    for record in records:
        if not isinstance(record.get('decimals'), int) or not 0 <= record['decimals'] <= 30:
            raise BuildError(f'bad decimals for {record["assetAddress"]}')
        if record['icon'] not in ARTWORK:
            raise BuildError(f'missing icon for {record["assetAddress"]}')
    if len({identity(record) for record in records}) != len(records):
        raise BuildError('duplicate asset identity')

    order = {key: position for position, key in enumerate(NETWORKS)}
    counts = {}
    for record in records:
        key = NETWORKS[(record['chainFamily'], record.get('chainId'))][0]
        counts.setdefault(key, {'included': 0, 'curated': 0, 'coinmarketcap': 0})
        counts[key]['included'] += 1
        counts[key]['curated' if record.get('metadataSource') != 'coinmarketcap' else 'coinmarketcap'] += 1
    records.sort(key=lambda record: (order[(record['chainFamily'], record.get('chainId'))],
                                     record.get('rank') or 10 ** 6, record['symbol'].upper()))
    listed = []
    for (family, chain_id), (key, name, ticker, icon) in NETWORKS.items():
        if not counts.get(key): continue
        entry = {'chainFamily': family}
        if chain_id: entry['chainId'] = chain_id
        entry.update({'key': key, 'name': name, 'nativeSymbol': ticker, 'tokens': counts[key]['included']})
        if icon: entry['iconAsset'] = icon
        listed.append(entry)

    merged = {'schemaVersion': 2, 'registryVersion': registry['registryVersion'], 'collectedAt': registry['collectedAt'],
              'sources': registry['sources'], 'selection': registry['selection'],
              'coinmarketcap': {'fetchedAt': snapshot['fetchedAt'], 'limit': snapshot['limit'],
                                'note': snapshot['note']},
              'counts': counts, 'networks': listed, 'assets': records}
    MERGED.write_text(json.dumps(merged, indent=1, ensure_ascii=False) + '\n')
    app = dict(merged, assets=[{field: record[field] for field in APP_FIELDS if field in record} for record in records])
    APP_REGISTRY.write_text(json.dumps(app, separators=(',', ':'), ensure_ascii=False) + '\n')

    # Columnar, and the rows are one tab/newline separated string rather than
    # 3,000 nested arrays: a fresh JavaScriptCore VM then allocates one string
    # while evaluating the bundle, and only a token request pays to split it.
    # Names and symbols cannot contain control characters (see printable).
    networks = sorted({(record['chainFamily'], record.get('chainId')) for record in records}, key=str)
    programs = sorted({record['tokenProgram'] for record in records if record.get('tokenProgram')})
    network_index = {key: position for position, key in enumerate(networks)}
    program_index = {key: position for position, key in enumerate(programs)}
    rows = ['\t'.join(str(field) for field in (
        network_index[(record['chainFamily'], record.get('chainId'))], record['assetAddress'],
        record['name'], record['symbol'], record['decimals'], record['icon'],
        program_index[record['tokenProgram']] if record.get('tokenProgram') else -1))
        for record in records]
    for row in rows:
        if row.count('\t') != 6: raise BuildError(f'row has a tab in a field: {row}')
    compact = {'registryVersion': merged['registryVersion'],
               'networks': [[family, chain_id] for family, chain_id in networks],
               'programs': programs, 'assetCount': len(rows), 'assets': '\n'.join(rows)}
    ENGINE_REGISTRY.write_text(json.dumps(compact, separators=(',', ':'), ensure_ascii=False) + '\n')
    icon_count, icon_bytes_total = write_icon_pack()
    shutil.rmtree(scratch, ignore_errors=True)

    print(f'assets: {len(records)}  icons: {icon_count} ({icon_bytes_total // 1024} KiB packed)')
    print(f'registry: {MERGED.stat().st_size // 1024} KiB  engine: {ENGINE_REGISTRY.stat().st_size // 1024} KiB')
    for key, value in sorted(counts.items()): print(f"  {key:10s} {value['included']:5d} "
                                                    f"(curated {value['curated']}, cmc {value['coinmarketcap']})")


if __name__ == '__main__':
    try: main()
    except BuildError as error:
        print(f'build failed: {error}', file=sys.stderr)
        sys.exit(1)
