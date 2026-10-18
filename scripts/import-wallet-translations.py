#!/usr/bin/env python3
"""Reuses BitTool Wallet's translations for the strings the two apps share.

    python3 scripts/import-wallet-translations.py [--wallet PATH] [LANG ...]

Both apps are the same product family, so where a sentence is word-for-word the
same the translation should be too: a user who knows "恢复短语" in Wallet should
not meet "助记词" here. About a quarter of this app's strings match; the rest is
its own copy and is translated in `translations/<language>.json` by hand.

Matching is on the English text, not on keys (the two apps key their strings
differently). A match is exact, or exact after normalising the punctuation
Wallet and this app happen to differ on: curly vs straight quotes, non-breaking
and narrow spaces, dashes, a trailing full stop, and case. Anything looser would
start importing sentences that only look alike.

The script never overwrites an existing translation unless --replace is given,
so hand-written wording wins by default; and it refuses any import whose format
specifiers do not match the source, the same rule write-localizations.py applies.
"""
import argparse, json, pathlib, plistlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
KEYS = ROOT / 'engine/data/interface-strings.json'
DEFAULT_WALLET = pathlib.Path.home() / 'Documents/wallet-ios-core/wallet-ios-core/wallet-ios-core/Modules/Base'
TABLES = ('UI.strings', 'PublicProtocol.strings', 'SecurityCenter.strings')
PAIR = re.compile(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.S)
SPEC = re.compile(r'%(?:\d+\$)?[@a-z]+')


def unescape(text):
    return (text.replace('\\"', '"').replace('\\n', '\n')
                .replace('\\t', '\t').replace('\\\\', '\\'))


def table(wallet, language):
    """Wallet's strings for one language, merged across its tables."""
    out = {}
    for name in TABLES:
        path = wallet / f'{language}.lproj' / name
        if not path.exists():
            continue
        raw = path.read_bytes()
        try:
            out.update(plistlib.loads(raw))          # binary plist form
            continue
        except Exception:
            pass
        for key, value in PAIR.findall(raw.decode('utf-8', errors='replace')):
            out[unescape(key)] = unescape(value)
    return out


def normalised(text):
    """The same sentence, with the punctuation the two apps differ on removed."""
    for a, b in (('’', "'"), ('‘', "'"), ('“', '"'), ('”', '"'),
                 ('‑', '-'), ('–', '-'), ('—', '-'), (' ', ' '),
                 (' ', ' ')):
        text = text.replace(a, b)
    return re.sub(r'\s+', ' ', text).strip().rstrip('.').lower()


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('languages', nargs='*', help='language codes; default: every translations/*.json')
    parser.add_argument('--wallet', type=pathlib.Path, default=DEFAULT_WALLET, help="BitTool Wallet's Modules/Base")
    parser.add_argument('--replace', action='store_true', help='overwrite existing translations too')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args(argv)

    if not args.wallet.exists():
        sys.exit(f'Wallet strings not found at {args.wallet}. Pass --wallet.')
    english = table(args.wallet, 'en')
    if not english:
        sys.exit(f'No English strings in {args.wallet}.')

    keys = json.loads(KEYS.read_text())
    # Wallet's English text -> its key. First wins: the tables are read in a
    # fixed order, so the same source text always resolves the same way.
    by_text, by_norm = {}, {}
    for key, value in english.items():
        by_text.setdefault(value.strip(), key)
        by_norm.setdefault(normalised(value), key)

    languages = args.languages or sorted(p.stem for p in (ROOT / 'translations').glob('*.json'))
    for language in languages:
        path = ROOT / f'translations/{language}.json'
        if not path.exists():
            print(f'{language}: no translations file, skipped'); continue
        theirs = table(args.wallet, language)
        if not theirs:
            print(f'{language}: Wallet has no strings for it, skipped'); continue
        data = json.loads(path.read_text())
        strings = data.setdefault('strings', {})
        imported = kept = mismatched = 0
        for source in keys:
            key = by_text.get(source.strip()) or by_norm.get(normalised(source))
            if key is None or key not in theirs:
                continue
            value = theirs[key].strip()
            if not value:
                continue
            if sorted(SPEC.findall(source)) != sorted(SPEC.findall(value)):
                mismatched += 1          # positional %1$@ vs %@ and the like
                continue
            if strings.get(source) and not args.replace:
                kept += 1; continue
            strings[source] = value; imported += 1
        print(f'{language}: {imported} imported, {kept} kept, {mismatched} skipped for specifiers')
        if not args.dry_run and imported:
            data['strings'] = {k: strings[k] for k in keys if k in strings}
            path.write_text(json.dumps(data, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main(sys.argv[1:])
