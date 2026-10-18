// Regressions for the three open findings of the R2 reassessment
// (BTS-SEC-2026-1018 R2). Each was reproduced against the committed code
// before being fixed.
import test from 'node:test';
import assert from 'node:assert/strict';
import { base58 } from '@scure/base';
import { Transaction, p2wpkh } from '@scure/btc-signer';
import { execute } from '../src/index.js';
import { withSeed, withKey } from '../src/keys.js';
import { stable, toBase64 } from '../src/util.js';
import { resolveSigningPlan } from '../src/resolver.js';
import { derivePublicIndex } from '../src/public-index.js';

const MN = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const OTHER = 'legal winner thank year wave sausage worth useful legal winner thank yellow';

// R2-01 -----------------------------------------------------------------------
// Safe's Executor hands `value` to CALL only; DELEGATECALL takes none and runs
// with the Safe's own balance and storage. Both entry points and every
// recursive transition have to agree about that.

const SAFE_TYPES = [['to','address'],['value','uint256'],['data','bytes'],['operation','uint8'],['safeTxGas','uint256'],
  ['baseGas','uint256'],['gasPrice','uint256'],['gasToken','address'],['refundReceiver','address'],['nonce','uint256']]
  .map(([name, type]) => ({ name, type }));
const ZERO = '0x' + '00'.repeat(20);
const word = n => BigInt(n).toString(16).padStart(64, '0');

/** One packed MultiSend item: operation, target, value, calldata. */
const item = (to, value, op = 0, data = '0x') =>
  (op ? '01' : '00') + to.slice(2) + word(value) + word((data.length - 2) / 2) + data.slice(2);
/** `multiSend(bytes)` calldata wrapping packed items. */
function multiSend(items) {
  const packed = items.join('');
  return '0x8d80ff0a' + word(32) + word(packed.length / 2) + packed + '0'.repeat((64 - (packed.length % 64)) % 64);
}
/** `execTransaction(to, value, data, operation, ...)` calldata: ten head words,
 *  with `data` and `signatures` as the two dynamic tails. */
function execTransaction({ to, value, data = '0x', operation }) {
  const body = data.slice(2);
  const padded = body + '0'.repeat((64 - (body.length % 64)) % 64);
  const dataAt = 10 * 32, signaturesAt = dataAt + 32 + padded.length / 2;
  const head = [to, value, dataAt, operation, 0, 0, 0, ZERO, ZERO, signaturesAt].map(word).join('');
  return '0x6a761202' + head + word(body.length / 2) + padded + word(0);
}
const tx = (to, data, value = '0') => execute({ operation: 'review', request: { chain: 'evm', kind: 'transaction',
  transaction: { type: 2, chainId: 1, nonce: 0, to, value, gasLimit: '2000000',
                 maxFeePerGas: '1000000000', maxPriorityFeePerGas: '1', data } } });
const safeTx = m => execute({ operation: 'review', request: { chain: 'evm', kind: 'typedData',
  typedData: { types: { SafeTx: SAFE_TYPES }, primaryType: 'SafeTx',
    domain: { chainId: 1, verifyingContract: '0x' + '5a'.repeat(20) },
    message: { to: '0x' + '33'.repeat(20), value: '1', data: '0x', operation: 0, safeTxGas: '0', baseGas: '0',
               gasPrice: '0', gasToken: ZERO, refundReceiver: ZERO, nonce: '4', ...m } } } });

const MULTISEND = '0x' + 'a4'.repeat(20);
const PAYEE = '0x' + 'ab'.repeat(20);
const ETH = v => (BigInt(v) * 10n ** 18n).toString();

test('R2-01 A: native currency a nested delegate branch spends is part of the amount', () => {
  // A Safe delegatecalls MultiSend; one of its branches delegatecalls another
  // MultiSend, which pays 40 ETH out of the Safe. Nothing at the top level
  // carries a value, so only propagation through the delegate makes it visible.
  const nested = multiSend([item(PAYEE, ETH(40))]);
  const outer = multiSend([item('0x' + '11'.repeat(20), 0n), item(MULTISEND, 0n, 1, nested)]);
  const review = safeTx({ to: MULTISEND, value: '0', data: outer, operation: 1 });

  assert.equal(review.display.amount, '40', `the Safe pays 40 ETH: ${JSON.stringify(review.display)}`);
  assert.ok(review.display.headline.includes('40'), review.display.headline);
});

test('R2-01 A: a later delegate branch that spends is never what truncation hides', () => {
  // Eleven quiet calls, then a delegate branch paying 77 ETH. The headline
  // keeps three descriptions by default, so index order alone would drop it.
  const calls = [];
  for (let i = 0; i < 11; i++) calls.push(item('0x' + String(i + 10).repeat(20).slice(0, 40), 0n));
  calls.push(item(MULTISEND, 0n, 1, multiSend([item(PAYEE, ETH(77))])));
  const review = tx(MULTISEND, multiSend(calls));

  assert.ok(review.display.headline.includes('77'), `the paying branch must be described: ${review.display.headline}`);
  assert.equal(review.display.amount, '77', 'and counted in the amount');
});

test('R2-01 A: a delegate branch nobody can decode makes the amount incomplete, out loud', () => {
  const review = tx(MULTISEND, multiSend([item(PAYEE, ETH(1)), item('0x' + 'cd'.repeat(20), 0n, 1, '0xdeadbeef')]));
  assert.equal(review.decodeStatus, 'partiallyDecoded');
  assert.ok(review.warnings.some(w => w.startsWith('HIGH RISK') && w.includes('amount shown is incomplete')),
    `an unknown delegate body is an uncounted debit: ${JSON.stringify(review.warnings)}`);
  assert.equal(review.riskLevel, 'high');
});

test('R2-01 A: a CALL’s own descendants stay the target’s money, not ours', () => {
  // Calling (not delegatecalling) a MultiSend with 5 ETH: we pay 5, and what
  // that contract then forwards comes out of its own balance. Counting it
  // again would double-count and overstate what leaves the wallet.
  const review = tx(MULTISEND, multiSend([item(MULTISEND, ETH(5), 0, multiSend([item(PAYEE, ETH(5))]))]));
  assert.equal(review.display.amount, '5', `one debit of 5 ETH, not two: ${JSON.stringify(review.display)}`);
});

test('R2-01 B: execTransaction never shows a delegatecall value as paid', () => {
  const hundred = ETH(100);
  const SAFE = '0x' + '5a'.repeat(20);

  const paid = tx(SAFE, execTransaction({ to: PAYEE, value: hundred, operation: 0 }));
  assert.equal(paid.display.amount, '100', 'a CALL does pay it');
  assert.ok(!paid.warnings.some(w => w.includes('does not transfer it')));

  const delegated = tx(SAFE, execTransaction({ to: PAYEE, value: hundred, operation: 1 }));
  assert.notEqual(delegated.display.amount, '100', 'a DELEGATECALL transfers nothing');
  assert.ok(delegated.warnings.some(w => w.includes('does not transfer it')),
    `the ignored value is reported, not silently dropped: ${JSON.stringify(delegated.warnings)}`);
  assert.ok(delegated.fields.some(f => f.label === 'Ignored delegatecall value'));
  assert.equal(delegated.riskLevel, 'high');
});

test('R2-01: the original direct-value behaviour is untouched', () => {
  const direct = safeTx({ value: ETH(100), operation: 0 });
  assert.equal(direct.display.amount, '100');
  const ignored = safeTx({ value: ETH(100), operation: 1 });
  assert.notEqual(ignored.display.amount, '100');
  assert.ok(ignored.warnings.some(w => w.includes('does not transfer it')));
});

test('R2-01: the propagated amount never reaches the review as an unhashable value', () => {
  // F-04's lesson, applied to this fix: `forwards` is a BigInt that every
  // decoded call now returns, and `stable` hashes the whole review. A BigInt
  // leaking into it would make these requests unsignable rather than wrong.
  const nested = multiSend([item(PAYEE, ETH(3))]);
  for (const data of [multiSend([item(MULTISEND, 0n, 1, nested)]), execTransaction({ to: PAYEE, value: ETH(2), operation: 1 })]) {
    const review = tx(MULTISEND, data);
    assert.equal(review.forwards, undefined, 'the review carries display text, not the accounting helper');
    assert.doesNotThrow(() => stable(review));
  }
});

// R2-02 -----------------------------------------------------------------------
// The share test asks whether the fee is more than half of what is being sent.
// Change comes back to the wallet, so it was never sent.

const PATH = "m/84'/0'/0'/0/0";
const node = mn => withSeed(mn, '', (seed, root) => withKey(seed, root, 'bitcoin', PATH,
  (priv, pub) => ({ pub: pub.slice(), fingerprint: root.fingerprint,
                    path: PATH.split('/').slice(1).map(x => Number(x.replace("'", '')) + (x.endsWith("'") ? 2 ** 31 : 0)) })));
const me = node(MN), them = node(OTHER);
const index = derivePublicIndex({ mnemonic: MN });

/** A plan for one input of `input` sats paying `payment` to a stranger and
 *  returning `change` to this wallet, with derivation proving the change. */
function plan({ input, payment, change }) {
  const mine = p2wpkh(me.pub), theirs = p2wpkh(them.pub);
  const prev = new Transaction();
  prev.addInput({ txid: new Uint8Array(32), index: 0 });
  prev.addOutput({ script: mine.script, amount: input });
  const t = new Transaction({ unknown: 'ignore', proprietary: 'ignore' });
  t.addInput({ txid: prev.id, index: 0, nonWitnessUtxo: prev.unsignedTx,
               witnessUtxo: { script: mine.script, amount: input },
               bip32Derivation: [[me.pub, { fingerprint: me.fingerprint, path: me.path }]] });
  if (payment > 0n) t.addOutput({ script: theirs.script, amount: payment });
  if (change > 0n) t.addOutput({ script: mine.script, amount: change,
                                 bip32Derivation: [[me.pub, { fingerprint: me.fingerprint, path: me.path }]] });
  const result = resolveSigningPlan({ request: { chain: 'bitcoin', psbt: toBase64(t.toPSBT()), network: 'mainnet' },
                                      wallets: [{ localWalletId: 'a', publicIndex: index }] });
  assert.equal(result.status, 'ready', `${result.status} ${result.message ?? ''}`);
  return result.review;
}
const warns = review => review.warnings.some(w => w.startsWith('HIGH FEE'));

test('R2-02: change cannot buy silence for a fee worth more than the payment', () => {
  // 0.0002 BTC sent, 0.0003 BTC fee. Identical payment and fee either way;
  // the only difference is 1 BTC of change coming straight back to us.
  const bare = plan({ input: 50_000n, payment: 20_000n, change: 0n });
  assert.equal(warns(bare), true, 'the plain case has always warned');

  const padded = plan({ input: 100_050_000n, payment: 20_000n, change: 100_000_000n });
  assert.equal(warns(padded), true, 'and the change output changes nothing about the fee');
  assert.equal(padded.riskLevel, 'high', 'the consent that the warning exists for is required too');
});

test('R2-02: the figure the history keeps is what was sent, not what came back', () => {
  // The summary outlives the review. 0.0002 BTC left the wallet; 1 BTC of
  // change returning must not be added to what the receipt says was sent.
  const padded = plan({ input: 100_050_000n, payment: 20_000n, change: 100_000_000n });
  assert.equal(padded.summary, 'Send 0.0002 BTC', padded.summary);
  assert.equal(padded.display.amount, '0.0002', 'and the card agrees with it');

  const self = plan({ input: 1_000_000n, payment: 0n, change: 950_000n });
  assert.equal(self.summary, 'Every output returns to your wallet', self.summary);
});

test('R2-02: a consolidation that sends nothing out reports the fee as its whole cost', () => {
  const self = plan({ input: 1_000_000n, payment: 0n, change: 950_000n });
  assert.ok(self.warnings.some(w => w.startsWith('HIGH FEE') && w.includes('whole cost')),
    `every output returns to us: ${JSON.stringify(self.warnings)}`);
  // A consolidation whose fee is under the floor stays quiet, same as any other.
  const cheap = plan({ input: 1_000_000n, payment: 0n, change: 995_000n });
  assert.equal(warns(cheap), false, '0.00005 BTC is simply what the network costs');
});

test('R2-02: the floor and the absolute branch behave the same with change present', () => {
  // Under the floor: quiet, however the fee compares with the payment.
  assert.equal(warns(plan({ input: 10_000n, payment: 6_494n, change: 0n })), false, '0.00003506 BTC fee');
  assert.equal(warns(plan({ input: 1_010_000n, payment: 6_494n, change: 1_000_000n })), false, 'same fee, with change');
  // Large outright: loud, whatever share of the payment it is.
  assert.equal(warns(plan({ input: 200_000_000n, payment: 198_900_000n, change: 0n })), true, '0.011 BTC fee');
  assert.equal(warns(plan({ input: 300_000_000n, payment: 198_900_000n, change: 100_000_000n })), true, 'same, with change');
  // A fee that is a small share of a real payment never warns on size alone.
  assert.equal(warns(plan({ input: 100_000_000n, payment: 99_500_000n, change: 0n })), false, '0.005 BTC of 0.995 BTC');
  assert.equal(warns(plan({ input: 150_000_000n, payment: 99_500_000n, change: 50_000_000n })), false, 'same, with change');
});

// R2-03 -----------------------------------------------------------------------
// One large number on the card has to describe the whole transaction. The
// first of several burns does not.

const SYSTEM = new Uint8Array(32);
const TOKEN = base58.decode('TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA');
const key = n => { const k = new Uint8Array(32); k[31] = n; return k; };
const u32 = n => { const b = new Uint8Array(4); new DataView(b.buffer).setUint32(0, n, true); return b; };
const u64 = n => { const b = new Uint8Array(8); new DataView(b.buffer).setBigUint64(0, BigInt(n), true); return b; };
const cat = (...a) => { const t = new Uint8Array(a.reduce((s, x) => s + x.length, 0)); let o = 0; for (const x of a) { t.set(x, o); o += x.length; } return t; };
/** `keyCount` distinct accounts, so burns can name different mints. */
function solana(ins, keyCount = 6) {
  const keys = [];
  for (let i = 1; i <= keyCount; i++) keys.push(key(i));
  keys.push(SYSTEM, TOKEN);
  const parts = [new Uint8Array([1, 0, 2]), new Uint8Array([keys.length]), ...keys, new Uint8Array(32), new Uint8Array([ins.length])];
  for (const i of ins) parts.push(new Uint8Array([i.p]), new Uint8Array([i.a.length]), new Uint8Array(i.a), new Uint8Array([i.d.length]), i.d);
  return { chain: 'solana', kind: 'transaction', message: Buffer.from(cat(...parts)).toString('base64') };
}
const TOKEN_PROGRAM = 7, SYSTEM_PROGRAM = 6;   // indexes of TOKEN and SYSTEM above
const burnChecked = (amount, decimals = 6) => cat(new Uint8Array([15]), u64(amount), new Uint8Array([decimals]));
const sendLamports = n => cat(u32(2), u64(n));
const review = ins => execute({ operation: 'review', request: solana(ins) });

test('R2-03: burns of one mint are totalled, not represented by the first', () => {
  // The reported case: a dust burn ordered ahead of a large one, same mint.
  const r = review([
    { p: TOKEN_PROGRAM, a: [1, 2, 0], d: burnChecked(1n) },
    { p: TOKEN_PROGRAM, a: [1, 2, 0], d: burnChecked(1_000_000_000_000n) },
  ]);
  assert.equal(r.display.action, 'Burn');
  assert.equal(r.display.amount, '1000000.000001', `one mint, one total: ${JSON.stringify(r.display)}`);
  assert.ok(r.display.headline.includes('in 2 burns'), r.display.headline);
  assert.ok(r.summary.startsWith('Burn 1000000.000001'), r.summary);
  // Every burn keeps its own exact warning.
  assert.equal(r.warnings.filter(w => w.startsWith('HIGH RISK') && w.includes('permanently destroys')).length, 2);
  assert.equal(r.riskLevel, 'high');
});

test('R2-03: burns of different mints are listed, never added together', () => {
  const r = review([
    { p: TOKEN_PROGRAM, a: [1, 2, 0], d: burnChecked(1n) },
    { p: TOKEN_PROGRAM, a: [3, 4, 0], d: burnChecked(500n) },
  ]);
  assert.equal(r.display.amount, undefined, 'two assets cannot share one number');
  assert.ok(r.display.headline.startsWith('Destroys 0.000001 tokens + 0.0005 tokens'), r.display.headline);
  assert.equal(r.display.counterparty, undefined, 'and they do not share one mint either');
  assert.equal(r.riskLevel, 'high');
});

test('R2-03: a burn beside a transfer does not let either stand for the whole', () => {
  const r = review([
    { p: TOKEN_PROGRAM, a: [1, 2, 0], d: burnChecked(1n) },
    { p: SYSTEM_PROGRAM, a: [0, 3], d: sendLamports(1_000n * 10n ** 9n) },
  ]);
  assert.equal(r.display.action, 'Burn');
  assert.equal(r.display.amount, undefined, 'a 0.000001 dust burn is not the headline figure');
  assert.ok(r.display.headline.includes('Destroys 0.000001'), r.display.headline);
  assert.ok(r.display.headline.includes('1 other transfer below'), r.display.headline);
  assert.ok(r.summary.includes('and 1 transfer'), r.summary);
  assert.equal(r.riskLevel, 'high');
});

test('R2-03: one burn on its own still shows its amount, and transfers are untouched', () => {
  const alone = review([{ p: TOKEN_PROGRAM, a: [1, 2, 0], d: burnChecked(5n) }]);
  assert.equal(alone.display.action, 'Burn');
  assert.equal(alone.display.amount, '0.000005');
  assert.equal(alone.display.counterparty, base58.encode(key(3)), 'the mint named by the instruction');
  assert.equal(alone.riskLevel, 'high');

  const transfer = review([{ p: SYSTEM_PROGRAM, a: [0, 3], d: sendLamports(1n) }]);
  assert.notEqual(transfer.display.action, 'Burn');
  assert.notEqual(transfer.riskLevel, 'high');
});

test('R2-03: a zero-quantity burn instruction is not an effect at all', () => {
  const r = review([{ p: TOKEN_PROGRAM, a: [1, 2, 0], d: burnChecked(0n) }]);
  assert.notEqual(r.display.action, 'Burn');
});
