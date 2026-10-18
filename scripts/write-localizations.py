#!/usr/bin/env python3
"""Turns a language's JSON translation file into its .lproj strings files.

    python3 scripts/write-localizations.py translations/<language>.json

The key list is Xcode's own extraction (xcodebuild -exportLocalizations) plus
the static text the offline engine produces -- its Details field labels, display
actions and review titles, which `ReviewText` translates as the interface draws
them. The script refuses a file that misses a string or that changes the format
specifiers in one: "%@" and "%lld" are filled in at runtime, and a translation
that drops or reorders them would format against the wrong value.

The file's `infoPlist` map is written to InfoPlist.strings, which is where iOS
reads the camera and Face ID usage descriptions from.
"""
import json, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
KEYS = ROOT / 'engine/data/interface-strings.json'
SPEC = re.compile(r'%(?:\d+\$)?[@a-z]+')


def main(path):
    keys = json.loads(KEYS.read_text())
    data = json.loads(pathlib.Path(path).read_text())
    language, strings = data['language'], data['strings']
    missing = [k for k in keys if k not in strings]
    extra = [k for k in strings if k not in keys]
    if missing: sys.exit(f'{language}: {len(missing)} strings missing, first: {missing[0]!r}')
    if extra: sys.exit(f'{language}: {len(extra)} strings are not in the interface, first: {extra[0]!r}')
    for key in keys:
        check_specifiers(language, key, strings[key])
        if not strings[key].strip(): sys.exit(f'{language}: empty translation for {key!r}')
    folder = ROOT / f'BitToolSigner/{language}.lproj'
    folder.mkdir(exist_ok=True)
    name = data.get('name', language)
    write(folder / 'Localizable.strings', name, 'Keys are the English source text.',
          [(key, strings[key]) for key in keys])
    # Info.plist usage descriptions are keyed by their plist name, not by text.
    info = data.get('infoPlist', {})
    for plist_key, value in info.items():
        if not value.strip(): sys.exit(f'{language}: empty Info.plist value for {plist_key!r}')
    write(folder / 'InfoPlist.strings', name, 'Keys are Info.plist names.', sorted(info.items()))
    print(f'{language}: {len(keys)} strings, {len(info)} Info.plist keys')


def check_specifiers(language, source, translation):
    """`%@` and `%lld` are filled in at runtime, in the order they appear.

    Comparing the two sets is not enough: "Showing the first %@ of %@" and a
    translation that swaps them have the same set and print the wrong numbers.
    So the sequence must match exactly — unless the translation uses positional
    specifiers (`%1$@`), which is how a language says it needs another order.
    """
    wanted, got = SPEC.findall(source), SPEC.findall(translation)
    # Two specifiers of the same type cannot be told apart by their shape, so a
    # swap would print the right kind of value in the wrong place and no check
    # could see it. Those strings must say which is which.
    repeated = len(wanted) != len(set(wanted))
    positional = [s for s in got if '$' in s]
    if repeated and not positional:
        sys.exit(f'{language}: {source!r} repeats a specifier, so the translation must number them '
                 f'(%1$@, %2$@ …) to say which value goes where; got {translation!r}')
    if positional:
        if len(positional) != len(got):
            sys.exit(f'{language}: mixes positional and plain specifiers in {source!r} -> {translation!r}')
        places = sorted(int(s[1:s.index('$')]) for s in positional)
        if places != list(range(1, len(wanted) + 1)):
            sys.exit(f'{language}: positional specifiers must cover 1..{len(wanted)} in {source!r} -> {translation!r}')
        kinds = sorted(s[s.index('$') + 1:] for s in positional)
        if kinds != sorted(s.lstrip('%') for s in wanted):
            sys.exit(f'{language}: positional specifier types differ for {source!r} -> {translation!r}')
        return
    if wanted != got:
        sys.exit(f'{language}: format specifiers differ or are reordered for {source!r} -> {translation!r}\n'
                 f'  source:      {wanted}\n  translation: {got}\n'
                 f'  use %1$@ / %2$@ if this language needs a different order')


def write(path, name, note, pairs):
    lines = [f'/* {name}. {note} */']
    for key, value in pairs:
        lines.append('"%s" = "%s";' % (key.replace('"', '\\"'), value.replace('"', '\\"')))
    path.write_text('\n'.join(lines) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else sys.exit(__doc__))
