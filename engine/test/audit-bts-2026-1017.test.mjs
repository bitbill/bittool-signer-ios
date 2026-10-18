import test from 'node:test';
import assert from 'node:assert/strict';
import { bitcoinDisplay } from '../src/bitcoin.js';
import { parseEVM } from '../src/evm.js';
import { parseTron } from '../src/tron.js';
import { Interface, getAddress } from 'ethers';

/** Regressions for the findings in security audit BTS-SEC-2026-1017.
 * Each test fails on the behaviour the audit reproduced. */

// BTS-01: value sent to an OP_RETURN is destroyed. It must never be folded
// into "everything came back to your wallet".
const change = new Set([0]);
const out = (index, amount, data = false) =>
  ({ index, amount, address: data ? 'OP_RETURN 6a00' : 'bc1qexample', data });

test('BTS-01: a burn is never summarised as a consolidation', () => {
  const burn = bitcoinDisplay([out(0, 999_000n), out(1, 99_000_000n, true)], 1_000n, change);
  assert.equal(burn.action, 'Burn');
  assert.equal(burn.amount, '0.99');
  assert.match(burn.headline, /Destroys 0\.99 BTC/);
  assert.doesNotMatch(burn.headline, /return to your wallet/);
  // A data output carrying nothing is still just a data output.
  const zero = bitcoinDisplay([out(0, 999_000n), out(1, 0n, true)], 1_000n, change);
  assert.equal(zero.action, 'Consolidate');
  assert.equal(zero.headline, 'All outputs return to your wallet');
});

test('BTS-01: a burn leads even when the transaction also pays someone', () => {
  const mixed = bitcoinDisplay([out(0, 999_000n), out(1, 5_000_000n), out(2, 99_000_000n, true)], 1_000n, change);
  assert.equal(mixed.action, 'Burn');
  assert.match(mixed.headline, /Destroys 0\.99 BTC/);
  assert.match(mixed.headline, /0\.05 BTC to bc1qexample/);
  // Several burns are counted together.
  const two = bitcoinDisplay([out(0, 1n, true), out(1, 2n, true)], 0n, new Set());
  assert.equal(two.amount, '0.00000003');
});

// BTS-02: the batch headline must state what leaves the wallet, not what the
// batch forwards internally.
const MULTISEND = getAddress('0x9641d764fc13c8B624c04430C7356C1C7C8102e2');
const RECIPIENT = getAddress('0x1111111111111111111111111111111111111111');
const abi = new Interface(['function multiSend(bytes transactions)']);
const innerCall = wei => Buffer.concat([
  Buffer.from([0]), Buffer.from(RECIPIENT.slice(2), 'hex'),
  Buffer.from(wei.toString(16).padStart(64, '0'), 'hex'),
  Buffer.from((0).toString(16).padStart(64, '0'), 'hex')]);
const batch = (outer, inner) => parseEVM({ chain: 'evm', kind: 'transaction', transaction: {
  type: 2, chainId: 1, nonce: 0, to: MULTISEND, value: outer.toString(),
  data: abi.encodeFunctionData('multiSend', ['0x' + innerCall(inner).toString('hex')]),
  gasLimit: '500000', maxFeePerGas: '2000000000', maxPriorityFeePerGas: '1000000000' } }).review;

test('BTS-02: the batch amount is what the wallet pays, not the inner total', () => {
  const r = batch(100n * 10n ** 18n, 10n ** 15n);
  assert.equal(r.display.amount, '100');
  assert.equal(r.display.symbol, 'ETH');
  assert.match(r.display.headline, /0\.001 ETH forwarded inside the batch/);
  assert.ok(r.warnings.some(w => w.includes('pays 100 ETH to the batch contract')), JSON.stringify(r.warnings));
  // The part no inner call forwards is called out: it stays in the contract.
  assert.ok(r.warnings.some(w => w.startsWith('HIGH RISK') && w.includes('99.999 ETH')), JSON.stringify(r.warnings));
  assert.equal(r.riskLevel, 'high');
});

test('BTS-02: a batch that pays nothing still reports what it forwards', () => {
  const r = batch(0n, 10n ** 15n);
  assert.equal(r.display.amount, '0.001');
  assert.ok(!r.warnings.some(w => w.includes('batch contract but not forwarded')));
});

test('BTS-02: outer equal to inner leaves nothing stranded', () => {
  const r = batch(10n ** 15n, 10n ** 15n);
  assert.equal(r.display.amount, '0.001');
  assert.ok(r.warnings.some(w => w.includes('pays 0.001 ETH to the batch contract')));
  assert.ok(!r.warnings.some(w => w.includes('not forwarded by any call')));
});

// BTS-03: fee_limit caps energy for contract execution. It is not a ceiling on
// the whole fee, and its absence is not a promise of a free transaction.
const varint = n => { n = BigInt(n); const b = []; do { b.push(Number(n & 127n)); n >>= 7n; if (n) b[b.length - 1] |= 128; } while (n); return Buffer.from(b); };
const pbN = (k, n) => Buffer.concat([varint(k * 8), varint(n)]);
const pbB = (k, v) => Buffer.concat([varint(k * 8 + 2), varint(v.length), v]);
function trxTransfer({ feeLimit } = {}) {
  const owner = Buffer.alloc(21, 0x41), to = Buffer.alloc(21, 0x41); to[20] = 2;
  const value = Buffer.concat([pbB(1, owner), pbB(2, to), pbN(3, 1_000_000)]);
  const contract = Buffer.concat([pbN(1, 1), pbB(2, Buffer.concat([
    pbB(1, Buffer.from('type.googleapis.com/protocol.TransferContract')), pbB(2, value)]))]);
  const parts = [pbB(1, Buffer.alloc(2)), pbB(4, Buffer.alloc(8)), pbN(8, 1800000060000),
                 pbB(11, contract), pbN(14, 1800000000000)];
  if (feeLimit !== undefined) parts.push(pbN(18, feeLimit));
  return parseTron({ chain: 'tron', kind: 'transaction',
                     transaction: { raw_data_hex: Buffer.concat(parts).toString('hex') } }).review;
}

test('BTS-03: no fee limit never reads as a zero fee', () => {
  const r = trxTransfer();
  assert.equal(r.display.fee, undefined, 'a missing fee_limit must not become "0 TRX max"');
  assert.equal(r.display.feeKind, undefined);
  assert.ok(r.warnings.some(w => w.includes('sets no fee limit') && w.includes('total fee is not known')),
            JSON.stringify(r.warnings));
});

test('BTS-03: a fee limit is labelled as the energy budget it is', () => {
  const r = trxTransfer({ feeLimit: 5_000_000 });
  assert.equal(r.display.fee, '5 TRX');
  assert.equal(r.display.feeKind, 'energyBudget', 'the UI caption depends on this');
  assert.ok(r.warnings.some(w => w.includes('caps only the energy') && w.includes('total fee is not known')),
            JSON.stringify(r.warnings));
  assert.ok(r.fields.some(f => f.label === 'Maximum energy fee (TRX)' && f.value === '5'));
});
