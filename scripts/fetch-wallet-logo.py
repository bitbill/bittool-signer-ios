#!/usr/bin/env python3
"""Fetch a wallet's official App Store icon into the asset catalog.

Build-time tool (network + Pillow); the app never downloads logos.

    python3 scripts/fetch-wallet-logo.py BRAND ASSET APP_STORE_ID [OFFICIAL_PAGE]

Example:
    python3 scripts/fetch-wallet-logo.py "OKX Wallet" wallet_okx 1327268470 https://web3.okx.com

It looks the app up with Apple's iTunes Lookup API, downloads the 512 x 512
artwork, fits it into 180 x 180 (Pillow LANCZOS, optimized PNG) and writes
BitToolSigner/Assets.xcassets/<ASSET>.imageset. It then adds or replaces the entry
for ASSET in docs/WalletLogoSources.json, recording the developer, bundle ID,
source URL and SHA-256 of the downloaded and packaged files, so the result can
be checked against the wallet's own website before it is committed.
"""
from __future__ import annotations

import datetime
import hashlib
import io
import json
import pathlib
import sys
import urllib.request

from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
ASSETS = ROOT / 'BitTool Signer' / 'Assets.xcassets'
MANIFEST = ROOT / 'docs' / 'WalletLogoSources.json'
UA = 'BitTool Signer-build/1.0 (wallet logo provenance)'
CONTENTS = {
    'images': [{'filename': 'icon.png', 'idiom': 'universal'}],
    'info': {'author': 'xcode', 'version': 1},
}


def get(url: str) -> bytes:
    request = urllib.request.Request(url, headers={'User-Agent': UA})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read(20_000_000)


def main() -> int:
    if len(sys.argv) not in (4, 5):
        print(__doc__)
        return 2
    brand, asset, app_id = sys.argv[1], sys.argv[2], int(sys.argv[3])
    official = sys.argv[4] if len(sys.argv) == 5 else None
    if not asset.startswith('wallet_') or not asset.replace('_', '').isalnum():
        sys.exit('asset must look like wallet_<name>')
    lookup_url = f'https://itunes.apple.com/lookup?id={app_id}&country=us'
    results = json.loads(get(lookup_url)).get('results') or []
    if len(results) != 1:
        sys.exit(f'App Store id {app_id} not found in the US store')
    app = results[0]
    artwork = app['artworkUrl512'].rsplit('/', 1)[0] + '/512x512bb.png'
    source = get(artwork)
    image = Image.open(io.BytesIO(source))
    image.load()
    if image.width < 256 or image.height < 256:
        sys.exit(f'artwork too small: {image.size}')
    icon = image.convert('RGBA').resize((180, 180), Image.LANCZOS)
    out = io.BytesIO()
    icon.save(out, 'PNG', optimize=True)
    packaged = out.getvalue()

    folder = ASSETS / f'{asset}.imageset'
    folder.mkdir(exist_ok=True)
    (folder / 'icon.png').write_bytes(packaged)
    (folder / 'Contents.json').write_text(json.dumps(CONTENTS, indent=2) + '\n')

    today = datetime.date.today().isoformat()
    entry = {
        'brand': brand,
        'asset': asset,
        'file': f'BitToolSigner/Assets.xcassets/{asset}.imageset/icon.png',
        'sourceType': 'Apple App Store artwork (iTunes Lookup API)',
        'appStoreURL': f'https://apps.apple.com/us/app/id{app_id}',
        'appStoreId': app_id,
        'appName': app.get('trackName'),
        'developer': app.get('sellerName') or app.get('artistName'),
        'bundleId': app.get('bundleId'),
        'officialPage': official,
        'lookupURL': lookup_url,
        'sourceURL': artwork,
        'sourceFormat': f'{image.format} {image.width}x{image.height} {image.mode}',
        'sourceSHA256': hashlib.sha256(source).hexdigest(),
        'sourceBytes': len(source),
        'conversion': 'Pillow LANCZOS resize to 180x180, optimized PNG',
        'packagedSize': '180x180',
        'packagedSHA256': hashlib.sha256(packaged).hexdigest(),
        'packagedBytes': len(packaged),
        'retrievedAt': today,
    }
    manifest = json.loads(MANIFEST.read_text())
    manifest['assets'] = [a for a in manifest['assets'] if a['asset'] != asset] + [entry]
    MANIFEST.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + '\n')
    print(json.dumps({k: entry[k] for k in ('brand', 'appName', 'developer', 'bundleId', 'packagedSHA256')}, ensure_ascii=False))
    return 0


if __name__ == '__main__':
    sys.exit(main())
