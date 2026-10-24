// The 24 October 2026 Android review found three defects that live in the shared
// JavaScript engine, so iOS ran the identical code. Both were reproduced here
// before being fixed; these pin the acceptance criteria that report set out.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { base58 } from '@scure/base';
import { ed25519 } from '@noble/curves/ed25519.js';
import { Transaction, p2wpkh } from '@scure/btc-signer';
import { execute } from '../src/index.js';
import { withSeed, withKey } from '../src/keys.js';
import { concat, toBase64, utf8 } from '../src/util.js';
import { resolveSigningPlan } from '../src/resolver.js';
import { derivePublicIndex } from '../src/public-index.js';

// --- Solana fixtures ---------------------------------------------------------
const TM = 'metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s';
const TOKEN = 'TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA';
const SYSTEM = '11111111111111111111111111111111';
const SYSVAR_IX = 'Sysvar1nstructions1111111111111111111111111';
const ATA = 'ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL';
const ME = base58.encode(new Uint8Array(32).fill(1));
const onCurve = d => { try { ed25519.Point.fromBytes(d); return true; } catch { return false; } };
function pda(seeds, program) {
  for (let bump = 255; bump >= 0; bump--) {
    const h = createHash('sha256');
    for (const s of seeds) h.update(typeof s === 'string' ? base58.decode(s) : s);
    h.update(Uint8Array.of(bump)); h.update(base58.decode(program)); h.update('ProgramDerivedAddress');
    const d = new Uint8Array(h.digest());
    if (!onCurve(d)) return base58.encode(d);
  }
}
const ata = (owner, mint, program = TOKEN) => pda([owner, program, mint], ATA);
const tmPda = (mint, ...extra) => pda([utf8('metadata'), TM, mint, ...extra], TM);
const k = n => base58.encode(new Uint8Array(32).fill(n));
const u64 = n => { const b = new Uint8Array(8); new DataView(b.buffer).setBigUint64(0, BigInt(n), true); return b; };
const u32 = n => { const b = new Uint8Array(4); new DataView(b.buffer).setUint32(0, n, true); return b; };
const bytes = (...p) => concat(...p.map(x => x instanceof Uint8Array ? x : new Uint8Array(x)));
const short = n => { const o = []; let v = n; do { let b = v & 0x7f; v >>= 7; if (v) b |= 0x80; o.push(b); } while (v); return new Uint8Array(o); };
function message(ixs, signers = [ME]) {
  const programs = [...new Set(ixs.map(i => i.program))], keys = [...signers];
  for (const ix of ixs) for (const a of ix.accounts) if (!keys.includes(a) && !programs.includes(a)) keys.push(a);
  keys.push(...programs);
  const at = x => keys.indexOf(x);
  return toBase64(concat(new Uint8Array([signers.length, 0, programs.length]), short(keys.length),
    ...keys.map(x => base58.decode(x)), new Uint8Array(32).fill(5), short(ixs.length),
    ...ixs.flatMap(ix => [new Uint8Array([at(ix.program)]), short(ix.accounts.length),
      new Uint8Array(ix.accounts.map(at)), short(ix.data.length), ix.data])));
}
const review = ixs => execute({ operation: 'review', request: { chain: 'solana', kind: 'transaction', message: message(ixs) } });
const MINT = k(0x33), TOKEN_ACCOUNT = ata(ME, MINT);
const burnAccounts = (mint = MINT, edition = true) =>
  [ME, TM, tmPda(mint), edition ? tmPda(mint, utf8('edition')) : TM, mint, ata(ME, mint), TM, TM, TM, TM, TM, SYSTEM, SYSVAR_IX, TOKEN];
const burnV1 = (mint = MINT, amount = 1n, edition = true) =>
  ({ program: TM, accounts: burnAccounts(mint, edition), data: bytes([41, 0], u64(amount)) });
const burnNft = (mint = MINT) =>
  ({ program: TM, accounts: [tmPda(mint), ME, mint, ata(ME, mint), tmPda(mint, utf8('edition')), TOKEN], data: new Uint8Array([29]) });
const dust = { program: SYSTEM, accounts: [ME, k(0x44)], data: bytes(u32(2), u64(1)) };

test('A Metaplex burn beside a dust transfer is not summarised as the transfer', () => {
  // The reported case: one lamport moving made the destroyed NFT disappear from
  // the card and the summary entirely.
  for (const burn of [burnV1(), burnNft()]) {
    const r = review([burn, dust]);
    assert.equal(r.display.action, 'Burn', 'destruction leads the card');
    assert.ok(r.summary.startsWith('Burn 1 NFT'), r.summary);
    assert.notEqual(r.display.amount, '0.000000001', 'a dust lamport is never the headline figure');
    assert.equal(r.riskLevel, 'high');
    assert.ok(r.warnings.some(w => w.includes('permanently destroys')));
  }
});

test('A Metaplex burn alone names what it destroys', () => {
  const nft = review([burnV1()]);
  assert.deepEqual([nft.display.action, nft.display.headline, nft.summary], ['Burn', 'Destroys 1 NFT', 'Burn 1 NFT']);
  // Metaplex carries no decimals, so a non-NFT burn stays in raw units rather
  // than being given invented ones.
  const token = review([burnV1(MINT, 10n, false)]);
  assert.equal(token.display.headline, 'Destroys 10 raw units');
  assert.equal(token.display.assetKind, 'nftOrToken');
});

test('Several Metaplex burns are grouped by mint, and different mints are not merged', () => {
  const same = review([burnV1(MINT), burnNft(MINT)]);
  assert.equal(same.display.action, 'Burn');
  assert.ok(same.display.headline.includes('in 2 burns'), same.display.headline);
  const other = k(0x55);
  const mixed = review([burnV1(MINT), burnV1(other)]);
  assert.equal(mixed.display.amount, undefined, 'two mints cannot share one number');
  assert.equal(mixed.display.counterparty, undefined, 'and they do not share one mint either');
  assert.ok(mixed.display.headline.startsWith('Destroys 1 NFT + 1 NFT'), mixed.display.headline);
});

test('A zero-amount Metaplex token burn is not presented as a destruction', () => {
  const r = review([burnV1(MINT, 0n, false)]);
  assert.notEqual(r.display.action, 'Burn');
});

// --- Bitcoin -----------------------------------------------------------------
const MN = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const PATH = "m/84'/0'/0'/0/0";
const me = withSeed(MN, '', (seed, root) => withKey(seed, root, 'bitcoin', PATH, (priv, pub) => ({
  pub: pub.slice(), fingerprint: root.fingerprint,
  path: PATH.split('/').slice(1).map(x => Number(x.replace("'", '')) + (x.endsWith("'") ? 2 ** 31 : 0)) })));
const index = derivePublicIndex({ mnemonic: MN });
const mine = p2wpkh(me.pub);

/** One input, optionally burning to OP_RETURN, paying a stranger and returning change. */
function plan({ input, burn = 0n, payment = 0n, change = 0n }) {
  const prev = new Transaction();
  prev.addInput({ txid: new Uint8Array(32), index: 0 });
  prev.addOutput({ script: mine.script, amount: input });
  const t = new Transaction({ unknown: 'ignore', proprietary: 'ignore', allowUnknownOutputs: true });
  t.addInput({ txid: prev.id, index: 0, nonWitnessUtxo: prev.unsignedTx, witnessUtxo: { script: mine.script, amount: input },
               bip32Derivation: [[me.pub, { fingerprint: me.fingerprint, path: me.path }]] });
  if (burn > 0n) t.addOutput({ script: new Uint8Array([0x6a, 0x02, 0x01, 0x02]), amount: burn });
  if (payment > 0n) t.addOutput({ script: p2wpkh(new Uint8Array(33).fill(2)).script, amount: payment });
  if (change > 0n) t.addOutput({ script: mine.script, amount: change,
                                 bip32Derivation: [[me.pub, { fingerprint: me.fingerprint, path: me.path }]] });
  const r = resolveSigningPlan({ request: { chain: 'bitcoin', psbt: toBase64(t.toPSBT()), network: 'mainnet' },
                                 wallets: [{ localWalletId: 'a', publicIndex: index }] });
  assert.equal(r.status, 'ready', `${r.status} ${r.message ?? ''}`);
  return r.review;
}

test('A Bitcoin burn is never summarised as a consolidation', () => {
  // The reported case: destroying 0.0005 BTC with change returning read as
  // "every output returns to your wallet" in the history and the receipt.
  const r = plan({ input: 100_000n, burn: 50_000n, change: 49_000n });
  assert.equal(r.summary, 'Burn 0.0005 BTC');
  assert.equal(r.display.action, 'Burn', 'the card was already right; the summary is what drifted');
});

test('A Bitcoin burn is never counted as money sent', () => {
  // Without verified change the parser used to fold the burn into the amount
  // sent, overstating the payment by exactly what was destroyed.
  const r = plan({ input: 100_000n, burn: 50_000n, payment: 49_000n });
  assert.equal(r.summary, 'Burn 0.0005 BTC and send 0.00049 BTC');
});

test('The Bitcoin summary states payment, destruction and change separately', () => {
  assert.equal(plan({ input: 100_000n, burn: 50_000n, change: 29_000n, payment: 20_000n }).summary,
    'Burn 0.0005 BTC and send 0.0002 BTC');
  assert.equal(plan({ input: 100_000n, payment: 50_000n, change: 49_000n }).summary, 'Send 0.0005 BTC');
  assert.equal(plan({ input: 100_000n, change: 99_000n }).summary, 'Every output returns to your wallet');
  // A zero-value OP_RETURN carries data only and destroys nothing.
  assert.equal(plan({ input: 100_000n, change: 99_000n, burn: 0n }).summary, 'Every output returns to your wallet');
});
