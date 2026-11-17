import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';

/** The complete argument text of a call whose '(' is at `open`. */
function callArguments(text, open) {
  let depth = 0, i = open, quote = null, escaped = false;
  while (i < text.length) {
    const c = text[i];
    if (quote) {
      if (escaped) escaped = false;
      else if (c === '\\') escaped = true;
      else if (c === quote) quote = null;
    } else if (c === "'" || c === '"' || c === '`') quote = c;
    else if (c === '(') depth++;
    else if (c === ')' && --depth === 0) return text.slice(open + 1, i);
    i++;
  }
  return '';
}

/** Every string literal in `source`, with JS escapes resolved. */
function stringLiterals(source) {
  const out = [];
  for (let i = 0; i < source.length; i++) {
    const quote = source[i];
    if (quote !== "'" && quote !== '"' && quote !== '`') continue;
    let j = i + 1, escaped = false, buffer = '';
    for (; j < source.length; j++) {
      const c = source[j];
      if (escaped) {
        const unicode = c === 'u' && /^[0-9a-fA-F]{4}$/.test(source.slice(j + 1, j + 5));
        if (unicode) { buffer += String.fromCharCode(parseInt(source.slice(j + 1, j + 5), 16)); j += 4; }
        else buffer += ({ n: '\n', t: '\t', r: '\r' })[c] ?? c;
        escaped = false;
      } else if (c === '\\') escaped = true;
      else if (c === quote) break;
      else buffer += c;
    }
    out.push(buffer);
    i = j;
  }
  return out;
}

/** Every whole-sentence warning the engine can write. Fragments of a warning
 * built by concatenation are left out: they are translated as templates. */
function engineWarnings() {
  const found = new Set();
  const files = ['protocols.js', ...readdirSync(new URL('../src', import.meta.url)).filter(f => f.endsWith('.js')).map(f => 'src/' + f)];
  for (const name of files) {
    const text = readFileSync(new URL('../' + name, import.meta.url), 'utf8');
    for (const match of text.matchAll(/warnings(?:\.push|\.unshift)\s*\(/g))
      for (const literal of stringLiterals(callArguments(text, match.index + match[0].length - 1))) found.add(literal);
    for (const match of text.matchAll(/warnings\s*[:=]\s*\[/g)) {
      let depth = 0, i = match.index + match[0].length - 1, quote = null, escaped = false, end = i;
      for (; i < text.length; i++) {
        const c = text[i];
        if (quote) { if (escaped) escaped = false; else if (c === '\\') escaped = true; else if (c === quote) quote = null; }
        else if (c === "'" || c === '"' || c === '`') quote = c;
        else if (c === '[') depth++;
        else if (c === ']' && --depth === 0) { end = i; break; }
      }
      for (const literal of stringLiterals(text.slice(match.index + match[0].length, end))) found.add(literal);
    }
  }
  // A complete sentence: starts like one and ends like one. The rest are pieces
  // the engine concatenates with a value, and those travel as `%@` templates.
  return [...found].filter(s => s.length > 12 && s.includes(' ') && !s.includes('${')
    && /^[A-Z]/.test(s) && '.)”’'.includes(s.trim().at(-1)));
}

test('Every warning the engine can write has a translation key', () => {
  const keys = new Set(JSON.parse(readFileSync(new URL('../data/interface-strings.json', import.meta.url), 'utf8')));
  const missing = engineWarnings().filter(w => !keys.has(w));
  assert.deepEqual(missing, [],
    `${missing.length} engine warning(s) would reach people in English. Add them to ` +
    `engine/data/interface-strings.json and every translations/*.json, then re-run ` +
    `scripts/write-localizations.py:\n` + missing.map(w => '  ' + w).join('\n'));
  // Guard the guard: if the scan ever stops finding warnings, this test is a no-op.
  assert.ok(engineWarnings().length > 60, 'the warning scan found suspiciously few sentences');
});

test('Every translation keeps the placeholders its English has', () => {
  const root = new URL('../../', import.meta.url);
  const keys = JSON.parse(readFileSync(new URL('engine/data/interface-strings.json', root), 'utf8'));
  const specifier = /%(?:[0-9]+\$)?[@a-z]+/g;
  for (const file of readdirSync(new URL('translations', root)).filter(f => f.endsWith('.json'))) {
    const { language, strings } = JSON.parse(readFileSync(new URL('translations/' + file, root), 'utf8'));
    for (const key of keys) {
      const value = strings[key];
      assert.ok(value, `${language}: no translation for ${JSON.stringify(key.slice(0, 50))}`);
      const want = (key.match(specifier) ?? []).length, got = (value.match(specifier) ?? []).length;
      assert.equal(got, want, `${language}: ${JSON.stringify(key.slice(0, 50))} has ${want} placeholder(s), translation has ${got}`);
    }
  }
});

// A warning the engine assembles from a branch has no whole sentence in the
// source, so the scan above cannot see it. Each form is written out here and
// checked twice: that it is a key, and that its pieces are still what the
// engine concatenates — so rewording the engine fails this test rather than
// quietly shipping an English sentence.
const ASSEMBLED = [
  { pieces: ['The leaf owner', ' or payer', ' does not sign this transaction, so it will fail on-chain.'],
    forms: ['The leaf owner does not sign this transaction, so it will fail on-chain.',
            'The leaf owner or payer does not sign this transaction, so it will fail on-chain.'] },
];

test('Every form of an assembled warning has a translation key', () => {
  const keys = new Set(JSON.parse(readFileSync(new URL('../data/interface-strings.json', import.meta.url), 'utf8')));
  const source = readdirSync(new URL('../src', import.meta.url)).filter(f => f.endsWith('.js'))
    .map(f => readFileSync(new URL('../src/' + f, import.meta.url), 'utf8')).join('\n');
  for (const { pieces, forms } of ASSEMBLED) {
    for (const piece of pieces)
      assert.ok(source.includes(piece), `the engine no longer writes ${JSON.stringify(piece)}; update ASSEMBLED`);
    for (const form of forms)
      assert.ok(keys.has(form), `${JSON.stringify(form)} has no translation key`);
  }
});

/** Every whole-sentence refusal the engine can throw. A refusal is the only
 * text on screen when it happens, so an untranslated one is worse than an
 * untranslated warning beside an otherwise translated card. Messages built
 * from a value are left out: those travel as `%@` templates. */
function engineRefusals() {
  const found = new Set();
  const files = ['protocols.js', ...readdirSync(new URL('../src', import.meta.url)).filter(f => f.endsWith('.js')).map(f => 'src/' + f)];
  for (const name of files) {
    const text = readFileSync(new URL('../' + name, import.meta.url), 'utf8');
    for (const match of text.matchAll(/\bcheck\s*\(/g)) {
      const args = callArguments(text, match.index + match[0].length - 1);
      const parts = topLevelCommas(args);
      if (parts.length < 3) continue;
      const message = parts.slice(2).join(',').trim();
      // Only a lone literal: a concatenation or template literal carries a value.
      if (!isWholeLiteral(message)) continue;
      for (const literal of stringLiterals(message)) found.add(literal);
    }
  }
  return [...found].filter(s => s.length > 3);
}

/** Is `text` a single quoted string and nothing else? A concatenation such as
 * `'a ' + n + ' b'` is not, and neither is a bare identifier. */
function isWholeLiteral(text) {
  const quote = text[0];
  if (quote !== "'" && quote !== '"') return false;
  let escaped = false;
  for (let i = 1; i < text.length; i++) {
    const c = text[i];
    if (escaped) escaped = false;
    else if (c === '\\') escaped = true;
    else if (c === quote) return i === text.length - 1;
  }
  return false;
}

/** Split an argument list on the commas that are not inside a nested group. */
function topLevelCommas(args) {
  const parts = [];
  let depth = 0, quote = null, escaped = false, current = '';
  for (const c of args) {
    if (quote) {
      current += c;
      if (escaped) escaped = false;
      else if (c === '\\') escaped = true;
      else if (c === quote) quote = null;
      continue;
    }
    if (c === "'" || c === '"' || c === '`') { quote = c; current += c; continue; }
    if ('([{'.includes(c)) depth++;
    else if (')]}'.includes(c)) depth--;
    if (c === ',' && depth === 0) { parts.push(current); current = ''; } else current += c;
  }
  parts.push(current);
  return parts;
}

test('Every refusal the engine can throw has a translation key', () => {
  const keys = new Set(JSON.parse(readFileSync(new URL('../data/interface-strings.json', import.meta.url), 'utf8')));
  const missing = engineRefusals().filter(r => !keys.has(r));
  assert.deepEqual(missing, [],
    `${missing.length} engine refusal(s) would reach people in English. Add them to ` +
    `engine/data/interface-strings.json and every translations/*.json, then re-run ` +
    `scripts/write-localizations.py:\n` + missing.map(r => '  ' + r).join('\n'));
  assert.ok(engineRefusals().length > 250, 'the refusal scan found suspiciously few messages');
});
