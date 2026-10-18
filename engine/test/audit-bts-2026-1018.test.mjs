// Regressions for the four findings of the 18 October 2026 review
// (BTS-SEC-2026-1018). Each one was reproduced before being fixed.
import test from 'node:test';
import assert from 'node:assert/strict';
import { base58 } from '@scure/base';
import { Transaction, p2wpkh } from '@scure/btc-signer';
import { execute } from '../src/index.js';
import { withSeed, withKey } from '../src/keys.js';
import { bitcoinDisplay } from '../src/bitcoin.js';
import { stable, toBase64 } from '../src/util.js';
import { resolveSigningPlan } from '../src/resolver.js';
import { derivePublicIndex } from '../src/public-index.js';

const MN = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';

// F-01 -------------------------------------------------------------------------
const SAFE_TYPES = [['to','address'],['value','uint256'],['data','bytes'],['operation','uint8'],['safeTxGas','uint256'],
  ['baseGas','uint256'],['gasPrice','uint256'],['gasToken','address'],['refundReceiver','address'],['nonce','uint256']]
  .map(([name, type]) => ({ name, type }));
const ZERO = '0x' + '00'.repeat(20);
const safeTx = m => ({ chain: 'evm', kind: 'typedData', typedData: { types: { SafeTx: SAFE_TYPES }, primaryType: 'SafeTx',
  domain: { chainId: 1, verifyingContract: '0x' + '5a'.repeat(20) },
  message: { to: '0x' + '33'.repeat(20), value: '1', data: '0x', operation: 0, safeTxGas: '0', baseGas: '0',
             gasPrice: '0', gasToken: ZERO, refundReceiver: ZERO, nonce: '4', ...m } } });

test('F-01: a value encoded on a Safe DELEGATECALL is never shown as an amount paid', () => {
  const hundred = (100n * 10n ** 18n).toString();
  // Safe's Executor passes value to `call` only. The same number means
  // "100 ETH leaves the Safe" for one operation and "nothing moves" for the other.
  const paid = execute({ operation: 'review', request: safeTx({ value: hundred, operation: 0 }) });
  assert.equal(paid.display.amount, '100');
  assert.ok(!paid.warnings.some(w => w.includes('does not transfer it')));

  const delegated = execute({ operation: 'review', request: safeTx({ value: hundred, operation: 1 }) });
  assert.notEqual(delegated.display.amount, '100', 'a delegatecall transfers nothing');
  assert.ok(delegated.warnings.some(w => w.includes('does not transfer it')),
    'the ignored value is still reported, not silently dropped');
  assert.ok(delegated.fields.some(f => f.label === 'Ignored delegatecall value'));
  assert.equal(delegated.riskLevel, 'high');
});

test('F-01: a batch call that spends native value is always described in the headline', () => {
  // Twelve calls, with the only one that moves money last. The headline shows
  // three by default, so before the fix the transfer fell off the end.
  const item = (to, value, data = '0x') => {
    const body = to.slice(2) + value.toString(16).padStart(64, '0')
      + ((data.length - 2) / 2).toString(16).padStart(64, '0') + data.slice(2);
    return '00' + body;
  };
  const calls = [];
  for (let i = 0; i < 11; i++) calls.push(item('0x' + String(i + 10).repeat(20).slice(0, 40), 0n));
  calls.push(item('0x' + 'ab'.repeat(20), 77n * 10n ** 18n));
  const payload = '0x8d80ff0a' + (32).toString(16).padStart(64, '0')
    + (calls.join('').length / 2).toString(16).padStart(64, '0')
    + calls.join('') + '0'.repeat((64 - (calls.join('').length % 64)) % 64);
  const review = execute({ operation: 'review', request: { chain: 'evm', kind: 'transaction', transaction: {
    type: 2, chainId: 1, nonce: 0, to: '0x' + '40'.repeat(20), value: '0', gasLimit: '900000',
    maxFeePerGas: '1000000000', maxPriorityFeePerGas: '1', data: payload } } });
  assert.ok(review.display.headline.includes('77'),
    `the paying call must appear in the headline: ${review.display.headline}`);
});

// F-02 -------------------------------------------------------------------------
const SYSTEM = new Uint8Array(32);
const TOKEN = base58.decode('TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA');
const key = n => { const k = new Uint8Array(32); k[31] = n; return k; };
const u32 = n => { const b = new Uint8Array(4); new DataView(b.buffer).setUint32(0, n, true); return b; };
const u64 = n => { const b = new Uint8Array(8); new DataView(b.buffer).setBigUint64(0, BigInt(n), true); return b; };
const cat = (...a) => { const t = new Uint8Array(a.reduce((s, x) => s + x.length, 0)); let o = 0; for (const x of a) { t.set(x, o); o += x.length; } return t; };
function solana(ins) {
  const keys = [key(1), key(2), key(3), key(4), SYSTEM, TOKEN];
  const parts = [new Uint8Array([1, 0, 2]), new Uint8Array([keys.length]), ...keys, new Uint8Array(32), new Uint8Array([ins.length])];
  for (const i of ins) parts.push(new Uint8Array([i.p]), new Uint8Array([i.a.length]), new Uint8Array(i.a), new Uint8Array([i.d.length]), i.d);
  return { chain: 'solana', kind: 'transaction', message: Buffer.from(cat(...parts)).toString('base64') };
}
const burnChecked = (amount, decimals = 6) => cat(new Uint8Array([15]), u64(amount), new Uint8Array([decimals]));
const sendLamports = n => cat(u32(2), u64(n));

test('F-02: a token burn leads the summary and demands acknowledgement', () => {
  // A large burn hidden behind a one-lamport payment: the burn is the point of
  // the transaction and must be what the main card says.
  const review = execute({ operation: 'review', request: solana([
    { p: 5, a: [1, 2, 0], d: burnChecked(1_000_000_000_000n) },
    { p: 4, a: [0, 3], d: sendLamports(1n) },
  ]) });
  assert.equal(review.display.action, 'Burn');
  // The burn leads the card. Its quantity is in the headline rather than the
  // single large amount, which R2-03 reserves for a transaction whose whole
  // effect one number describes: here a lamport transfer moves as well.
  assert.equal(review.display.amount, undefined);
  assert.ok(review.display.headline.startsWith('Destroys 1000000 '), review.display.headline);
  assert.ok(review.summary.startsWith('Burn 1000000 '), review.summary);
  assert.equal(review.riskLevel, 'high', 'destruction always needs explicit consent');
  assert.ok(review.warnings.some(w => w.startsWith('HIGH RISK') && w.includes('permanently destroys')));
});

test('F-02: a burn on its own is still the headline, and transfers are untouched', () => {
  const alone = execute({ operation: 'review', request: solana([{ p: 5, a: [1, 2, 0], d: burnChecked(5n) }]) });
  assert.equal(alone.display.action, 'Burn');
  assert.equal(alone.riskLevel, 'high');

  // A plain transfer keeps the behaviour it always had.
  const transfer = execute({ operation: 'review', request: solana([{ p: 4, a: [0, 3], d: sendLamports(1n) }]) });
  assert.notEqual(transfer.display.action, 'Burn');
  assert.notEqual(transfer.riskLevel, 'high');
});

// F-04 -------------------------------------------------------------------------
test('F-04: a Bitcoin burn produces a plan that can actually be hashed and signed', () => {
  const display = bitcoinDisplay([{ index: 0, amount: 5000n, address: 'OP_RETURN 6a00', data: true }], 1000n);
  assert.equal(display.action, 'Burn');
  // `stable` refuses undefined, and it hashes the whole plan. An explicit
  // `note: undefined` made every burn request unsignable rather than noteless.
  assert.ok(!Object.prototype.hasOwnProperty.call(display, 'note'));
  assert.doesNotThrow(() => stable({ display }));

  // End to end: the request resolves to a usable plan, not an error.
  const index = derivePublicIndex({ mnemonic: MN });
  const me = withSeed(MN, '', (seed, root) => withKey(seed, root, 'bitcoin', "m/84'/0'/0'/0/0",
    (priv, pub) => ({ pub: pub.slice(), fingerprint: root.fingerprint,
                      path: "m/84'/0'/0'/0/0".split('/').slice(1).map(x => Number(x.replace("'", '')) + (x.endsWith("'") ? 2 ** 31 : 0)) })));
  const mine = p2wpkh(me.pub);
  const prev = new Transaction();
  prev.addInput({ txid: new Uint8Array(32), index: 0 });
  prev.addOutput({ script: mine.script, amount: 100_000n });
  // allowUnknownOutputs is for building the fixture; the signer decodes OP_RETURN itself.
  const tx = new Transaction({ unknown: 'ignore', proprietary: 'ignore', allowUnknownOutputs: true });
  tx.addInput({ txid: prev.id, index: 0, nonWitnessUtxo: prev.unsignedTx,
                witnessUtxo: { script: mine.script, amount: 100_000n },
                bip32Derivation: [[me.pub, { fingerprint: me.fingerprint, path: me.path }]] });
  tx.addOutput({ script: new Uint8Array([0x6a, 0x02, 0x01, 0x02]), amount: 50_000n });  // OP_RETURN carrying value
  tx.addOutput({ script: mine.script, amount: 49_000n });
  const plan = resolveSigningPlan({ request: { chain: 'bitcoin', psbt: toBase64(tx.toPSBT()), network: 'mainnet' },
                                    wallets: [{ localWalletId: 'a', publicIndex: index }] });
  assert.equal(plan.status, 'ready', `burn requests must stay signable: ${plan.status} ${plan.message ?? ''}`);
  assert.equal(plan.review.riskLevel, 'high');
});
