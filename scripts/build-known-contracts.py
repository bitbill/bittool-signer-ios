#!/usr/bin/env python3
"""Writes the two copies of the known-contract library the app ships.

Input (committed, hand-maintained upstream in Ownbit's security centre and
imported here):
  engine/data/known-contracts.json          full records with protocol and category

Outputs:
  engine/data/known-contracts.engine.json   compact projection bundled into signer.js
  BitToolSigner/Resources/known-contracts.json  the same records for the browser in Settings

The engine copy is columnar and its rows are one tab/newline separated string,
for the same reason as the token registry: a fresh JavaScript VM is created for
every sensitive operation, and it should not pay to build 1,700 objects it may
never look at.
"""
import json, pathlib, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'engine/data/known-contracts.json'
ENGINE = ROOT / 'engine/data/known-contracts.engine.json'
APP = ROOT / 'BitToolSigner/Resources/known-contracts.json'
CATEGORIES = {'dex', 'aggregator', 'infra', 'wallet', 'bridge', 'lending', 'staking', 'other', 'nft', 'perp', 'token'}


def main():
    data = json.loads(SOURCE.read_text())
    rows, seen = [], set()
    for contract in data['contracts']:
        family, chain_id = contract['chainFamily'], contract['chainId']
        address = contract['address']
        if family == 'evm':
            if not address.startswith('0x') or len(address) != 42: sys.exit(f'bad EVM address {address}')
            address = address.lower()
        for field in ('name', 'protocol'):
            if not contract[field].strip(): sys.exit(f'{address} has an empty {field}')
            if '\t' in contract[field] or '\n' in contract[field]: sys.exit(f'{address} {field} has a separator in it')
        if contract['category'] not in CATEGORIES: sys.exit(f'{address} has category {contract["category"]!r}')
        key = (family, chain_id, address)
        if key in seen: sys.exit(f'duplicate entry for {key}')
        seen.add(key)
        rows.append((f'{family}:{chain_id}', address, contract['name'], contract['protocol'], contract['category']))
    rows.sort()
    networks = sorted({row[0] for row in rows})
    categories = sorted({row[4] for row in rows})
    compact = {'updated': data['updated'], 'count': len(rows),
               'networks': networks, 'categories': categories,
               'contracts': '\n'.join('\t'.join([str(networks.index(row[0])), row[1], row[2], row[3],
                                                 str(categories.index(row[4]))]) for row in rows)}
    ENGINE.write_text(json.dumps(compact, separators=(',', ':'), ensure_ascii=False) + '\n')
    APP.write_text(json.dumps(data, separators=(',', ':'), ensure_ascii=False) + '\n')
    print(f'{len(rows)} contracts  engine: {ENGINE.stat().st_size // 1024} KiB  app: {APP.stat().st_size // 1024} KiB')


if __name__ == '__main__':
    main()
