import test from 'node:test';
import assert from 'node:assert/strict';
import { base58 } from '@scure/base';
import { ed25519 } from '@noble/curves/ed25519.js';
import { derivePublicIndex } from '../src/public-index.js';
import { resolveSigningPlan, signPlanTask } from '../src/resolver.js';
import { execute } from '../src/index.js';

// Public test phrase only.
const MN = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const INDEX = derivePublicIndex({ mnemonic: MN });
const SIGNER = INDEX.solanaPublicKeys.find(k => k.profile === 'standard').address;
const SYSTEM = new Uint8Array(32);
const b64 = bytes => Buffer.from(bytes).toString('base64');
const cat = (...parts) => { const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0)); let at = 0; for (const p of parts) { out.set(p, at); at += p.length; } return out; };
const u64 = n => new Uint8Array(new BigUint64Array([n]).buffer);
const fill = n => new Uint8Array(32).fill(n);
const review = message => execute({ operation: 'review', request: { chain: 'solana', kind: 'transaction', message: b64(message) } });
const field = (out, label) => out.fields.find(f => f.label === label)?.value;

/** A v0 message: the wallet pays and signs, one SOL transfer to `destination`
 * (an index into the resolved account list), and `tables` address lookup tables. */
function v0({ destination = 1, programIndex = 2, tables = [{ account: fill(6), writable: [3], readonly: [] }] } = {}) {
  const keys = [base58.decode(SIGNER), fill(4), SYSTEM];
  const transfer = cat(new Uint8Array([programIndex]), new Uint8Array([2]), new Uint8Array([0, destination]),
                       new Uint8Array([12]), new Uint8Array([2, 0, 0, 0]), u64(1_000_000_000n));
  const lookups = cat(new Uint8Array([tables.length]), ...tables.flatMap(t =>
    [t.account, new Uint8Array([t.writable.length]), new Uint8Array(t.writable), new Uint8Array([t.readonly.length]), new Uint8Array(t.readonly)]));
  return cat(new Uint8Array([0x80]), new Uint8Array([1, 0, 1]), new Uint8Array([keys.length]), ...keys,
             fill(9), new Uint8Array([1]), transfer, lookups);
}

test('A v0 transaction with lookup tables is readable, named and gated', () => {
  const out = review(v0());
  // It is signable — refusing it made swaps and bridge claims impossible — but it
  // can never read as fully decoded, so the acknowledgement gate always applies.
  assert.equal(out.decodeStatus, 'partiallyDecoded');
  assert.equal(out.riskLevel, 'high');
  assert.ok(out.warnings[0].startsWith('HIGH RISK:'), out.warnings[0]);
  assert.match(out.warnings[0], /1 of this transaction's 4 accounts come from 1 address lookup table\b/);
  // The table itself is public data in the message, so it is shown in full.
  assert.equal(field(out, 'Address lookup tables'), base58.encode(fill(6)) + ' (1 writable, 0 read-only)');
  assert.equal(field(out, 'Accounts loaded from lookup tables'), '1');
  // The parts that are in the message still decode: amount, program and fee payer.
  assert.equal(field(out, 'Instruction 1 · Action'), 'Transfer SOL');
  assert.equal(field(out, 'Fee payer'), SIGNER);
  assert.equal(out.summary, '1 SOL');
});

test('An account that comes from a lookup table is never shown as an address', () => {
  const out = review(v0({ destination: 3 }));
  const recipient = field(out, 'Instruction 1 · Recipient');
  assert.match(recipient, /^\[lookup table [1-9A-HJ-NP-Za-km-z]+ · entry 3\]$/, recipient);
  // Square brackets are outside the base58 alphabet, so it cannot read as an address.
  assert.ok(!/^[1-9A-HJ-NP-Za-km-z]+$/.test(recipient));
  assert.ok(out.warnings.some(w => /accounts come from an address lookup table and cannot be shown/.test(w)), out.warnings.join(' | '));
  // The amount is still exact: it is in the instruction data, not in the table.
  assert.equal(field(out, 'Instruction 1 · Amount (SOL)'), '1');
});

test('A program that comes from a lookup table is shown as bytes, never guessed at', () => {
  const out = review(v0({ programIndex: 3 }));
  assert.equal(out.decodeStatus, 'opaque');
  assert.equal(out.riskLevel, 'high');
  assert.equal(field(out, 'Instruction 1 · Program'),
               'Loaded from an address lookup table; this device cannot tell which program it is');
  assert.match(field(out, 'Instruction 1 · Instruction data'), /^0x02000000/);
  assert.ok(out.warnings.some(w => w.includes('cannot say what this program is')), out.warnings.join(' | '));
  // Nothing is claimed about what it moves.
  assert.ok(!out.fields.some(f => f.label === 'Instruction 1 · Action'));
});

test('Signing a lookup-table transaction needs the risk acknowledged, then verifies', () => {
  const request = { chain: 'solana', kind: 'transaction', message: b64(v0()), address: SIGNER };
  const wallets = [{ localWalletId: 'w', publicIndex: INDEX }];
  const plan = resolveSigningPlan({ request, wallets });
  // Signers can only ever be static keys, so matching a wallet is unaffected by tables.
  assert.equal(plan.status, 'ready', plan.message);
  assert.equal(plan.tasks.length, 1);
  assert.equal(plan.tasks[0].addresses[0], SIGNER);
  assert.equal(plan.review.decodeStatus, 'partiallyDecoded');
  const task = { request, plan, taskId: plan.tasks[0].id, mnemonic: MN };
  assert.throws(() => signPlanTask(task), /Confirm this request/);
  const result = signPlanTask({ ...task, riskAcknowledged: true });
  assert.ok(ed25519.verify(Buffer.from(result.signature, 'hex'), v0(), base58.decode(SIGNER)));
});

test('Malformed lookup tables are refused', () => {
  const fails = (message, pattern) => assert.throws(() => review(message), pattern);
  fails(v0({ tables: [{ account: fill(6), writable: [], readonly: [] }] }), /loads no accounts/);
  fails(v0({ tables: [{ account: fill(6), writable: [3], readonly: [] }, { account: fill(6), writable: [4], readonly: [] }] }), /Duplicate address lookup table/);
  fails(v0({ tables: [{ account: fill(6), writable: [3, 3], readonly: [] }] }), /loads the same entry twice/);
  fails(v0({ tables: Array.from({ length: 17 }, (_, i) => ({ account: fill(20 + i), writable: [3], readonly: [] })) }), /Too many Solana address lookup tables/);
  // An instruction may not point past the resolved list.
  fails(v0({ destination: 9 }), /unresolved account/);
});

test('A transaction sent through the message path is named, not measured', () => {
  const asMessage = message => {
    try { execute({ operation: 'review', request: { chain: 'solana', kind: 'message', message: b64(message) } }); return 'accepted'; }
    catch (error) { return error.message; }
  };
  // The reported bug: a wallet forwards a whole serialized transaction as a message.
  const serialized = cat(new Uint8Array([1]), new Uint8Array(64), v0());
  assert.match(asMessage(serialized), /complete transaction, not a message/);
  assert.match(asMessage(v0()), /^This is a transaction, not a message\./);
  // Size alone no longer stands in for a diagnosis, and it says what the limit is.
  assert.match(asMessage(new TextEncoder().encode('x'.repeat(1500))), /1500 bytes.*up to 1024 bytes/);
  // A genuine sign-in message is unaffected.
  assert.equal(asMessage(new TextEncoder().encode('bittool.com wants you to sign in with your Solana account')), 'accepted');
});
