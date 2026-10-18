#!/usr/bin/env python3
"""Refreshes the two CoinMarketCap inputs of the expanded token registry.

  engine/data/cmc-snapshot.json   which tokens are in the CMC top N, and their
                                  names, symbols, logo URLs and contracts
  engine/data/cmc-onchain.json    decimals (plus symbol, and the Solana token
                                  program) read from the chains themselves

The listing is only used to decide *which* tokens are worth bundling and to get
artwork. Decimals are never taken from it: a wrong decimals value would misstate
every amount the app displays, so each one is read from the contract. Symbols are
read from the contract too, and the contract wins (see build-expanded-registry).

The CoinMarketCap key is read from the CMC_API_KEY environment variable and is
never written to disk:

    CMC_API_KEY=... python3 scripts/refresh-cmc-snapshot.py

Stages can be run separately; the on-chain stage keeps what it already has, so it
can be re-run until the public RPC endpoints have answered for every contract.

    python3 scripts/refresh-cmc-snapshot.py --stage onchain

Then rebuild the registry with scripts/build-expanded-registry.py.
"""
import argparse, collections, json, os, pathlib, time, urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
SNAPSHOT = ROOT / 'engine/data/cmc-snapshot.json'
ONCHAIN = ROOT / 'engine/data/cmc-onchain.json'
CMC = 'https://pro-api.coinmarketcap.com'
# A browser user agent: several public RPC endpoints reject the default one.
USER_AGENT = ('Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 '
              '(KHTML, like Gecko) Version/17.0 Safari/605.1.15')
# CoinMarketCap platform name -> the chain identity the app uses.
PLATFORMS = {'Ethereum': ('evm', '1'), 'BNB Smart Chain (BEP20)': ('evm', '56'),
             'Arbitrum': ('evm', '42161'), 'Base': ('evm', '8453'), 'Optimism': ('evm', '10'),
             'Polygon': ('evm', '137'), 'Gnosis Chain': ('evm', '100'), 'Avalanche C-Chain': ('evm', '43114'),
             'Tron20': ('tron', None), 'Solana': ('solana', None)}
# Endpoint plus the number of contracts per batched request. Public endpoints
# differ in how large a JSON-RPC batch they accept; several are listed per chain
# so a refresh can finish even when one is rate limiting.
EVM_RPC = {'1': [('https://ethereum-rpc.publicnode.com', 15), ('https://cloudflare-eth.com', 10),
                 ('https://rpc.flashbots.net', 5), ('https://eth.llamarpc.com', 20)],
           '56': [('https://bsc-dataseed.bnbchain.org', 20), ('https://bsc-rpc.publicnode.com', 15)],
           '8453': [('https://mainnet.base.org', 10), ('https://base-rpc.publicnode.com', 15)],
           '42161': [('https://arb1.arbitrum.io/rpc', 20), ('https://arbitrum-one-rpc.publicnode.com', 15)],
           '10': [('https://mainnet.optimism.io', 10), ('https://optimism-rpc.publicnode.com', 15)],
           '137': [('https://polygon-bor-rpc.publicnode.com', 20), ('https://polygon.drpc.org', 10)],
           '100': [('https://rpc.gnosischain.com', 20)],
           '43114': [('https://api.avax.network/ext/bc/C/rpc', 20)]}
SOLANA_RPC = 'https://api.mainnet-beta.solana.com'
TRON_RPC = 'https://api.trongrid.io/wallet/triggerconstantcontract'
DECIMALS, SYMBOL = '0x313ce567', '0x95d89b41'


def identity(family, chain_id, address):
    return f"{family}:{chain_id or ''}:{address.lower() if family == 'evm' else address}"


def request(url, data=None, headers=None, tries=3, timeout=90):
    body = json.dumps(data).encode() if data is not None else None
    head = {'User-Agent': USER_AGENT, 'Accept': 'application/json'}
    if body: head['Content-Type'] = 'application/json'
    head.update(headers or {})
    for attempt in range(tries):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, data=body, headers=head), timeout=timeout) as response:
                return json.load(response)
        except Exception as error:
            if attempt == tries - 1:
                print(f'   failed {url}: {error}', flush=True)
                return None
            time.sleep((5 if '429' in str(error) else 2) * (attempt + 1))


def fetch_snapshot(limit):
    key = os.environ.get('CMC_API_KEY')
    if not key: raise SystemExit('CMC_API_KEY is not set; the key must never be written into the repo')
    headers = {'X-CMC_PRO_API_KEY': key}
    listing = request(f'{CMC}/v1/cryptocurrency/map?limit={limit}&sort=cmc_rank&aux=platform', headers=headers)
    if not listing: raise SystemExit('could not read the CoinMarketCap listing')
    ranked = {str(coin['id']): coin for coin in listing['data']}
    print(f"listing: {len(ranked)} coins, {listing['status']['credit_count']} credits")

    info, ids = {}, list(ranked)
    for start in range(0, len(ids), 100):
        batch = ids[start:start + 100]
        page = request(f"{CMC}/v2/cryptocurrency/info?id={','.join(batch)}&aux=logo,platform,status", headers=headers)
        if page: info.update(page['data'])
        print(f'  info {len(info)}/{len(ids)}', flush=True)
        time.sleep(1.2)

    tokens, contracts = [], 0
    for cmc_id, coin in info.items():
        listed = ranked.get(cmc_id)
        if not listed or not coin.get('logo'): continue
        found = []
        for entry in coin.get('contract_address') or []:
            platform = PLATFORMS.get(((entry.get('platform') or {}).get('name')))
            address = (entry.get('contract_address') or '').strip()
            if not platform or not address: continue
            family, chain_id = platform
            if family == 'evm':
                if not address.startswith('0x') or len(address) != 42: continue
                address = address.lower()
            record = {'chainFamily': family}
            if chain_id: record['chainId'] = chain_id
            record['address'] = address
            found.append(record)
        if not found: continue
        contracts += len(found)
        tokens.append({'cmcId': int(cmc_id), 'rank': listed.get('rank') or listed.get('cmc_rank'),
                       'symbol': coin.get('symbol'), 'name': coin.get('name'),
                       'logo': coin['logo'], 'contracts': found})
    tokens.sort(key=lambda token: token['rank'] or 10 ** 6)
    snapshot = {'schemaVersion': 1, 'source': 'coinmarketcap',
                'fetchedAt': time.strftime('%Y-%m-%d'), 'ranking': 'cmc_rank', 'limit': limit,
                'note': 'Listing membership and names/symbols/logos only. Decimals are never taken '
                        'from here; see cmc-onchain.json.',
                'tokens': tokens}
    SNAPSHOT.write_text(json.dumps(snapshot, indent=1, ensure_ascii=False) + '\n')
    print(f'snapshot: {len(tokens)} tokens, {contracts} contracts on supported chains')


def abi_string(value):
    """symbol() is usually a string, but some early tokens return bytes32."""
    raw = bytes.fromhex(value[2:]) if value.startswith('0x') else b''
    if len(raw) >= 64:
        length = int.from_bytes(raw[32:64], 'big')
        if 0 < length <= 64 and len(raw) >= 64 + length:
            return raw[64:64 + length].decode('utf-8', 'ignore').strip('\x00').strip()
    return raw.rstrip(b'\x00').decode('utf-8', 'ignore').strip() if raw else ''


def read_evm(assets, wanted):
    for chain_id, endpoints in EVM_RPC.items():
        for url, size in endpoints:
            todo = [address for family, chain, address in wanted if family == 'evm' and chain == chain_id
                    and identity('evm', chain_id, address) not in assets]
            if not todo: break
            added = 0
            for start in range(0, len(todo), size):
                batch = todo[start:start + size]
                calls = []
                for position, address in enumerate(batch):
                    calls.append({'jsonrpc': '2.0', 'id': 2 * position, 'method': 'eth_call',
                                  'params': [{'to': address, 'data': DECIMALS}, 'latest']})
                    calls.append({'jsonrpc': '2.0', 'id': 2 * position + 1, 'method': 'eth_call',
                                  'params': [{'to': address, 'data': SYMBOL}, 'latest']})
                answers = request(url, calls, tries=2)
                for item in answers if isinstance(answers, list) else []:
                    tag, value = item.get('id'), item.get('result')
                    if not isinstance(tag, int) or not isinstance(value, str) or value in ('', '0x'): continue
                    position = tag // 2
                    if position >= len(batch): continue
                    key = identity('evm', chain_id, batch[position])
                    if tag % 2 == 0:
                        try: places = int(value, 16)
                        except ValueError: continue
                        if 0 <= places <= 30:
                            assets.setdefault(key, {})['decimals'] = places
                            added += 1
                    elif key in assets:
                        symbol = abi_string(value)
                        if symbol: assets[key]['symbol'] = symbol
                time.sleep(0.2)
            print(f"  chain {chain_id} via {url.split('/')[2]}: +{added}", flush=True)


def read_solana(assets, wanted):
    mints = [address for family, _, address in wanted if family == 'solana' and identity('solana', None, address) not in assets]
    for start in range(0, len(mints), 100):
        batch = mints[start:start + 100]
        answer = request(SOLANA_RPC, {'jsonrpc': '2.0', 'id': 1, 'method': 'getMultipleAccounts',
                                      'params': [batch, {'encoding': 'jsonParsed'}]}, tries=3)
        values = ((answer or {}).get('result') or {}).get('value') or []
        for address, account in zip(batch, values):
            data = account.get('data') if isinstance(account, dict) else None
            parsed = (data.get('parsed') or {}).get('info') if isinstance(data, dict) else None
            if isinstance(parsed, dict) and isinstance(parsed.get('decimals'), int):
                # The mint is only usable together with the program that owns it.
                assets[identity('solana', None, address)] = {'decimals': parsed['decimals'], 'program': account.get('owner')}
        time.sleep(0.3)
    print(f'  solana: {sum(1 for key in assets if key.startswith("solana:"))}', flush=True)


def read_tron(assets, wanted):
    for family, _, address in wanted:
        if family != 'tron' or identity('tron', None, address) in assets: continue
        answer = request(TRON_RPC, {'owner_address': 'T9yD14Nj9j7xAB4dbGeiX9h8unkKHxuWwb', 'contract_address': address,
                                    'function_selector': 'decimals()', 'visible': True}, tries=2)
        values = (answer or {}).get('constant_result') or []
        if values:
            try: places = int(values[0], 16)
            except ValueError: continue
            if 0 <= places <= 30: assets[identity('tron', None, address)] = {'decimals': places}
        time.sleep(0.3)
    print(f'  tron: {sum(1 for key in assets if key.startswith("tron:"))}', flush=True)


def fetch_onchain(recheck):
    snapshot = json.loads(SNAPSHOT.read_text())
    wanted = [(contract['chainFamily'], contract.get('chainId'), contract['address'])
              for token in snapshot['tokens'] for contract in token['contracts']]
    previous = json.loads(ONCHAIN.read_text()) if ONCHAIN.exists() and not recheck else {'assets': {}}
    assets = dict(previous.get('assets') or {})
    read_evm(assets, wanted)
    read_solana(assets, wanted)
    read_tron(assets, wanted)
    known = {key: value for key, value in assets.items() if isinstance(value.get('decimals'), int)}
    missing = collections.Counter(f'{family}:{chain_id or ""}' for family, chain_id, address in wanted
                                 if identity(family, chain_id, address) not in known)
    ONCHAIN.write_text(json.dumps({'schemaVersion': 1, 'checkedAt': time.strftime('%Y-%m-%d'),
                                   'method': {'evm': 'eth_call decimals()/symbol() on a public RPC endpoint',
                                              'solana': 'getMultipleAccounts (jsonParsed) mint decimals and owning token program',
                                              'tron': 'triggerconstantcontract decimals()'},
                                   'assets': dict(sorted(known.items()))}, indent=1, ensure_ascii=False) + '\n')
    print(f'on-chain: {len(known)} of {len(wanted)} contracts')
    if missing: print(f'still missing (re-run this stage): {dict(missing)}')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--stage', choices=['snapshot', 'onchain', 'both'], default='both')
    parser.add_argument('--limit', type=int, default=2000, help='how many ranks to take from the listing')
    parser.add_argument('--recheck', action='store_true', help='read every contract again instead of only the missing ones')
    arguments = parser.parse_args()
    if arguments.stage in ('snapshot', 'both'): fetch_snapshot(arguments.limit)
    if arguments.stage in ('onchain', 'both'): fetch_onchain(arguments.recheck)


if __name__ == '__main__':
    main()
