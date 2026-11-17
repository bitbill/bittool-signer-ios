// Records every piece of engine text the review screen can draw, by running the
// engine's own test suite and keeping what its reviews and refusals contain.
//
//     node test/support/review-text-corpus.mjs        (from engine/)
//
// writes test/fixtures/review-text-corpus.json. The native test
// ReviewTextCoverageTests reads that file and fails when any of the text would
// reach a person in English in one of the app's languages. Regenerate it after
// changing what the engine says; the warning test in engine/test checks the source.
//
// Run as `node --import` (which the script does for the test processes) the same
// file only collects: it registers review-text-hooks.mjs and writes what one test
// process saw to REVIEW_TEXT_DIR when that process exits.
import { register } from 'node:module';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const engine = fileURLToPath(new URL('../..', import.meta.url));
const KINDS = ['warning', 'refusal', 'refusalSource', 'title', 'action', 'headline', 'counterpartyLabel', 'note', 'label', 'assetContractLabel', 'amountWord', 'symbol', 'networkPhrase'];
const main = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;

if (!main && process.env.REVIEW_TEXT_DIR) {
  register(new URL('./review-text-hooks.mjs', import.meta.url));
  const seen = Object.fromEntries(KINDS.map(kind => [kind, new Set()]));
  const add = (kind, text) => { if (typeof text === 'string' && text.trim()) seen[kind].add(text); };
  // What the person reads, with the requester's own words left out: a message and
  // the type name of unrecognised typed data are drawn exactly as they arrive.
  const review = r => {
    if (!r || typeof r !== 'object' || !Array.isArray(r.warnings) || !Array.isArray(r.fields)) return;
    const d = r.display ?? {};
    const theirs = d.action === 'Sign Message' || d.action === 'Sign Typed Data';
    add('title', r.title);
    r.warnings.forEach(w => add('warning', w));
    add('action', d.action);
    if (!theirs) add('headline', d.headline);
    add('counterpartyLabel', d.counterpartyLabel);
    add('note', d.note);
    add('assetContractLabel', d.assetContractLabel);
    if (typeof d.amount === 'string' && !/^[\d.,\s]+$/.test(d.amount)) add('amountWord', d.amount);
    if (typeof d.symbol === 'string' && /^[a-z][a-z ]*$/.test(d.symbol)) add('symbol', d.symbol);
    r.fields.forEach(f => add('label', f.label));
    if (!r.network) add('networkPhrase', r.fields.find(f => f.label === 'Network')?.value);
  };
  const { EngineError } = await import(pathToFileURL(join(engine, 'src/util.js')).href);
  const { ProtocolError } = await import(pathToFileURL(join(engine, 'protocols.js')).href);
  globalThis.__reviewText = (what, value) => {
    if (what === 'error') { if (value instanceof EngineError || value instanceof ProtocolError) add('refusal', value.message); return; }
    if (typeof value === 'string') { // dispatch: the JSON the app receives
      try { const out = JSON.parse(value); if (out.ok === false) add('refusal', out.error?.message); else review(out.result?.review ?? out.result); } catch {}
      return;
    }
    if (value?.status && value.status !== 'ready' && typeof value.message === 'string') add('refusal', value.message);
    review(value?.review ?? value);
  };
  process.on('exit', () => writeFileSync(join(process.env.REVIEW_TEXT_DIR, `${process.pid}.json`),
    JSON.stringify(Object.fromEntries(KINDS.map(kind => [kind, [...seen[kind]]])))));
}

/** Whole string literals in the engine source that a person can be shown even if
 * no test produces them: every literal that starts with a severity marker, and —
 * listed separately as `refusalSource`, which the native test reports but does
 * not require — the message of every check()/ensure()/fail() and engine or
 * protocol error. Most of those guard malformed CBOR or UR framing that no real
 * wallet sends; the refusals the tests do reach are required. A literal with
 * ${…} in it is a template, and is left to the tests that fill it. */
function* sourceText() {
  const files = ['protocols.js', ...readdirSync(join(engine, 'src')).filter(f => f.endsWith('.js')).map(f => join('src', f))];
  for (const file of files) {
    const text = readFileSync(join(engine, file), 'utf8');
    const literal = /(['"`])((?:(?!\1)[^\\\n]|\\.)*)\1/g;
    let m;
    while ((m = literal.exec(text))) {
      if (m[2].includes('${')) continue;
      const value = m[2].replace(/\\u([0-9a-fA-F]{4})/g, (_, h) => String.fromCharCode(parseInt(h, 16))).replace(/\\(.)/g, '$1');
      const line = text.slice(text.lastIndexOf('\n', m.index) + 1, m.index);
      if (/^(HIGH RISK|HIGH FEE):|^UNLIMITED/.test(value) && /[.)]$/.test(value)) yield ['warning', value];
      else if (/(?:\bcheck|\bensure|\bfail|new (?:Engine|Protocol)Error)\s*\([^;]*$/.test(line) && /^[A-Z]/.test(value) && value.includes(' ') && value.length > 12) yield ['refusalSource', value];
    }
  }
}

if (main) {
  const dir = mkdtempSync(join(tmpdir(), 'review-text-'));
  try {
    const tests = readdirSync(join(engine, 'test')).filter(f => /\.test\.m?js$/.test(f)).map(f => join('test', f));
    const run = spawnSync(process.execPath, ['--import', fileURLToPath(import.meta.url), '--test', ...tests],
      { cwd: engine, env: { ...process.env, REVIEW_TEXT_DIR: dir }, stdio: ['ignore', 'pipe', 'inherit'], maxBuffer: 1 << 28 });
    // A failing test still produced its reviews; say so, since one that stops early records less.
    if (run.status !== 0) console.warn('Warning: the engine test suite did not pass; the corpus may be incomplete.');
    const merged = Object.fromEntries(KINDS.map(kind => [kind, new Set()]));
    for (const file of readdirSync(dir)) {
      const part = JSON.parse(readFileSync(join(dir, file), 'utf8'));
      for (const kind of KINDS) for (const text of part[kind] ?? []) merged[kind].add(text);
    }
    // Text no test happens to reach is still text a person can see: every whole
    // refusal written into the source, and every literal severe warning.
    for (const [kind, text] of sourceText()) merged[kind].add(text);
    const out = Object.fromEntries(KINDS.map(kind => [kind, [...merged[kind]].sort()]));
    writeFileSync(join(engine, 'test/fixtures/review-text-corpus.json'), JSON.stringify(out, null, 1) + '\n');
    console.log(KINDS.map(kind => `${kind} ${out[kind].length}`).join(' · '));
  } finally { rmSync(dir, { recursive: true, force: true }); }
}
