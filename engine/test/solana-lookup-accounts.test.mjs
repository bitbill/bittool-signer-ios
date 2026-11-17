// Solana instructions whose accounts come from an address lookup table (BTS-10).
// Solana v0 loads non-signer accounts from tables, so a swap's token account, owner
// or mint often arrives that way. Those transactions are reviewed, not refused; what
// cannot be proven offline is said to be unproven, and is never used to name a
// recipient. Synthetic transactions only; the fee payer is the public test mnemonic.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { base58 } from '@scure/base';
import { parseSolana } from '../src/solana.js';
import { deriveAccounts } from '../src/keys.js';
import { concat, short, toBase64, utf8 } from '../src/util.js';
import { ed25519 } from '@noble/curves/ed25519.js';
import { derivePublicIndex } from '../src/public-index.js';
import { resolveSigningPlan, signPlanTask } from '../src/resolver.js';

const MN = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const ME = deriveAccounts({ mnemonic: MN }).accounts.find(a => a.chain === 'solana').address;
const SYSTEM = '11111111111111111111111111111111';
const TOKEN = 'TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA';
const ATA = 'ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL';
const TM = 'metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s';
const SYSVAR_IX = 'Sysvar1nstructions1111111111111111111111111';
const AUTH_RULES = 'auth9SigNpDKz4sJJ1DfCTuZrZNSAgh9sFD3rboVmgg';
const TABLE = base58.encode(new Uint8Array(32).fill(0x0e));

// Independent PDA derivation: node:crypto SHA-256 and a BigInt ed25519 on-curve test.
const P = 2n ** 255n - 19n, mod = x => ((x % P) + P) % P;
const pow = (b, e) => { let r = 1n; b = mod(b); while (e > 0n) { if (e & 1n) r = r * b % P; b = b * b % P; e >>= 1n; } return r; };
const D = mod(-121665n * pow(121666n, P - 2n));
function onCurve(bytes) { let y = 0n; for (let i = 31; i >= 0; i--) y = (y << 8n) | BigInt(i === 31 ? bytes[i] & 0x7f : bytes[i]); y = mod(y); const w = mod(mod(y * y - 1n) * pow(mod(D * y * y + 1n), P - 2n)); return w === 0n || pow(w, (P - 1n) / 2n) === 1n; }
function pda(seeds, program) {
  for (let bump = 255; bump >= 0; bump--) {
    const h = createHash('sha256'); for (const s of seeds) h.update(typeof s === 'string' ? base58.decode(s) : s);
    h.update(Uint8Array.of(bump)); h.update(base58.decode(program)); h.update('ProgramDerivedAddress');
    const d = new Uint8Array(h.digest()); if (!onCurve(d)) return base58.encode(d);
  }
}
const ata = (owner, mint, program = TOKEN) => pda([owner, program, mint], ATA);
const tmPda = (mint, ...extra) => pda([utf8('metadata'), TM, mint, ...extra], TM);
const k = n => base58.encode(new Uint8Array(32).fill(n));
const u64 = n => { const b = new Uint8Array(8); new DataView(b.buffer).setBigUint64(0, BigInt(n), true); return b; };
const bytes = (...parts) => concat(...parts.map(p => p instanceof Uint8Array ? p : new Uint8Array(p)));

/** A v0 message in which the accounts listed in `loaded` come from one lookup
 * table (as its writable entries, in that order) and everything else is static. */
function tx(ixs, { loaded = [] } = {}) {
  const programs = [...new Set(ixs.map(ix => ix.program))], keys = [ME];
  for (const ix of ixs) for (const a of ix.accounts) if (!keys.includes(a) && !programs.includes(a) && !loaded.includes(a)) keys.push(a);
  const readonly = programs.filter(p => !keys.includes(p) && !loaded.includes(p));
  keys.push(...readonly);
  const resolved = [...keys, ...loaded], at = x => resolved.indexOf(x);
  const message = concat(new Uint8Array([0x80]), new Uint8Array([1, 0, readonly.length]), short(keys.length), ...keys.map(x => base58.decode(x)),
    new Uint8Array(32).fill(5), short(ixs.length),
    ...ixs.flatMap(ix => [new Uint8Array([at(ix.program)]), short(ix.accounts.length), new Uint8Array(ix.accounts.map(at)), short(ix.data.length), ix.data]),
    ...(loaded.length ? [short(1), base58.decode(TABLE), short(loaded.length), new Uint8Array(loaded.map((_, i) => i)), short(0)] : [short(0)]));
  return { chain: 'solana', kind: 'transaction', message: toBase64(message) };
}
/** How the engine shows an account that table entry `i` supplies. */
const entry = i => `[lookup table ${TABLE} · entry ${i}]`;
const review = (ixs, options) => parseSolana(tx(ixs, options)).review;
const value = (r, label) => r.fields.find(f => f.label.endsWith('· ' + label))?.value;
const warned = (r, text) => r.warnings.some(w => w.includes(text));
const UNPROVEN = 'The token account, owner or mint of this instruction comes from an address lookup table, so BitTool Signer cannot check that the token account belongs to that owner.';

const ataIx = ({ token, owner, mint, idempotent = true, system = SYSTEM, program = TOKEN }) =>
  ({ program: ATA, accounts: [ME, token, owner, mint, system, program], data: new Uint8Array(idempotent ? [1] : []) });
const transferChecked = ({ source, mint, destination, amount = 5_000_000n, decimals = 6 }) =>
  ({ program: TOKEN, accounts: [source, mint, destination, ME], data: bytes([12], u64(amount), [decimals]) });

test('A token account, owner or mint from a lookup table is reviewed, not refused', () => {
  const owner = k(0x21), mint = k(0x31), token = ata(owner, mint);
  for (const idempotent of [true, false]) {
    // Control: all three in the message, so the account is proven to be the owner's.
    const proven = review([ataIx({ token, owner, mint, idempotent })]);
    assert.ok(!warned(proven, UNPROVEN));
    assert.equal(value(proven, 'Token account'), token);
    // The same instruction with all three loaded from a table.
    const loaded = review([ataIx({ token, owner, mint, idempotent })], { loaded: [token, owner, mint] });
    assert.equal(loaded.decodeStatus, 'partiallyDecoded');
    assert.equal(loaded.riskLevel, 'high', 'the lookup-table gate still applies to the whole transaction');
    assert.ok(warned(loaded, UNPROVEN), loaded.warnings.join(' | '));
    assert.equal(value(loaded, 'Action'), idempotent ? 'Create token account if absent' : 'Create token account');
    assert.deepEqual([value(loaded, 'Token account'), value(loaded, 'Owner'), value(loaded, 'Mint')], [entry(0), entry(1), entry(2)]);
    // Any one of the three is enough to make it unprovable.
    assert.ok(warned(review([ataIx({ token, owner, mint, idempotent })], { loaded: [mint] }), UNPROVEN));
  }
});

test('A static associated token account that does not match its owner and mint is still refused', () => {
  const owner = k(0x21), mint = k(0x31);
  assert.throws(() => review([ataIx({ token: k(0x41), owner, mint })]), /Associated token address does not match owner and mint/);
});

test('Program accounts loaded from a table make the instruction raw bytes, not a refusal', () => {
  const owner = k(0x21), mint = k(0x31), token = ata(owner, mint);
  const r = review([ataIx({ token, owner, mint })], { loaded: [SYSTEM, TOKEN] });
  assert.equal(r.decodeStatus, 'opaque');
  assert.equal(r.riskLevel, 'high');
  assert.ok(r.fields.some(f => f.label.endsWith('· Exact instruction bytes')), 'shown as raw bytes');
});

test('An unproven token account never names its owner as the recipient', () => {
  // The attack this guards against: the account a transfer goes to is a lookup
  // entry, and an earlier instruction claims that same entry is the token account
  // of a respectable owner. If that claim were trusted, the review would read
  // "to <owner>" while the tokens went to whatever the table holds.
  const owner = k(0x21), mint = k(0x31), loadedToken = k(0x42);
  const r = review([ataIx({ token: loadedToken, owner, mint }), transferChecked({ source: k(0x51), mint, destination: loadedToken })],
                   { loaded: [loadedToken] });
  assert.notEqual(r.display.counterparty, owner, 'the headline must not name the claimed owner');
  assert.ok(!r.fields.some(f => f.label.endsWith('Recipient wallet (owner of destination token account)')),
            'and no field may present the claimed owner as the recipient');
  assert.equal(r.display.counterparty, entry(0), 'the recipient is shown as the unreadable account it is');
  assert.ok(warned(r, 'The recipient wallet is not included in this transaction, only its token account.'));

  // Control: the same two instructions with the token account in the message, and
  // provably the owner's, do name the owner.
  const token = ata(owner, mint);
  const proven = review([ataIx({ token, owner, mint }), transferChecked({ source: k(0x51), mint, destination: token })]);
  assert.equal(proven.display.counterparty, owner);
});

// Token Metadata TransferV1, exactly 17 accounts.
function tmTransfer({ mint = k(0x33), to = k(0x22) } = {}) {
  const src = ata(ME, mint), dst = ata(to, mint);
  return { program: TM, accounts: [src, ME, dst, to, mint, tmPda(mint), tmPda(mint, utf8('edition')),
    tmPda(mint, utf8('token_record'), base58.decode(src)), tmPda(mint, utf8('token_record'), base58.decode(dst)),
    ME, ME, SYSTEM, SYSVAR_IX, TOKEN, ATA, AUTH_RULES, k(0x44)], data: bytes([49, 0], u64(1n), [0]) };
}

test('A Metaplex transfer to a recipient from a lookup table still reads, and says what it cannot check', () => {
  const to = k(0x22);
  const proven = review([tmTransfer({ to })]);
  assert.equal(value(proven, 'Destination account type'), 'Associated token account of the recipient wallet');
  const loaded = review([tmTransfer({ to })], { loaded: [to] });
  assert.equal(value(loaded, 'Destination account type'), 'Cannot be checked: an account comes from an address lookup table');
  assert.equal(value(loaded, 'Action'), 'Send NFT', 'everything derived from the static mint still decodes');
  assert.equal(loaded.riskLevel, 'high');
});

test('An instruction that must derive from a table account falls back to raw bytes, alone', () => {
  // Token Metadata proves its metadata account from the mint; with the mint in a
  // table there is nothing to derive from, so that one instruction is raw bytes.
  const mint = k(0x33);
  const r = review([tmTransfer({ mint }), { program: SYSTEM, accounts: [ME, k(0x61)], data: bytes([2, 0, 0, 0], u64(1000n)) }], { loaded: [mint] });
  // The whole transaction is only partially decoded: the other instruction reads.
  assert.equal(r.decodeStatus, 'partiallyDecoded');
  assert.ok(r.fields.some(f => f.label === 'Instruction 1 · Instruction data'), 'the Token Metadata instruction is raw bytes');
  assert.ok(warned(r, 'An account this instruction depends on comes from an address lookup table, so BitTool Signer cannot decode what the instruction does.'));
  assert.equal(value(r, 'Amount (SOL)'), '0.000001', 'the other instruction is still decoded');
  // The raw-bytes instruction is named beside the transfer, in the headline and the Activity summary (M-01).
  assert.deepEqual([r.display.headline, r.summary], ['Moves funds and runs undecoded instructions · review each below', '0.000001 SOL and 1 undecoded instruction']);
});

// BTS-11 (Revision 17): the accounts Token Metadata checks against the mint used to
// be compared as they stood, so a metadata, edition or token-record account loaded
// from a table — shown as "[lookup table … · entry i]" — never equalled the PDA and
// the whole transaction was refused before the raw-bytes fallback could apply.
test('A Metaplex account checked against the mint is raw bytes, not a refusal, when a table supplies it', () => {
  const mint = k(0x33), ix = tmTransfer({ mint });
  const wallets = [{ localWalletId: 'w', publicIndex: derivePublicIndex({ mnemonic: MN }) }];
  const roles = [['metadata', 5], ['edition', 6], ['source token record', 7], ['destination token record', 8]];
  for (const [role, index] of roles) {
    const request = { ...tx([ix], { loaded: [ix.accounts[index]] }), address: ME };
    const r = parseSolana(request).review;
    assert.deepEqual([r.decodeStatus, r.riskLevel], ['opaque', 'high'], role);
    assert.ok(r.fields.some(f => f.label === 'Instruction 1 · Instruction data'), `${role}: the instruction is shown as raw bytes`);
    assert.ok(warned(r, 'An account this instruction depends on comes from an address lookup table, so BitTool Signer cannot decode what the instruction does.'), role);
    assert.equal(r.display.counterparty, undefined, `${role}: nothing unproven is named as a recipient`);
    // It signs once the risk is acknowledged, and not before.
    const plan = resolveSigningPlan({ request, wallets });
    assert.equal(plan.status, 'ready', `${role}: ${plan.message}`);
    const task = { request, plan, taskId: plan.tasks[0].id, mnemonic: MN };
    assert.throws(() => signPlanTask(task), /Confirm this request/, role);
    const { signature } = signPlanTask({ ...task, riskAcknowledged: true });
    assert.ok(ed25519.verify(Buffer.from(signature, 'hex'), Buffer.from(request.message, 'base64'), base58.decode(ME)), role);
  }
  // The accounts these are derived from read as they did: a token account or the
  // mint from a table leaves nothing to derive from (raw bytes); the recipient
  // wallet from a table still reads as an NFT transfer that says what it cannot check.
  const [source, , destination, to] = ix.accounts;
  for (const [role, account] of [['source token account', source], ['destination token account', destination], ['mint', mint]]) {
    const r = review([ix], { loaded: [account] });
    assert.deepEqual([r.decodeStatus, r.riskLevel], ['opaque', 'high'], role);
  }
  const owner = review([ix], { loaded: [to] });
  assert.deepEqual([owner.decodeStatus, value(owner, 'Action'), owner.riskLevel], ['partiallyDecoded', 'Send NFT', 'high']);
  // A wrong account that is in the message is still refused, in every role.
  for (const [role, index] of roles) {
    const wrong = { ...ix, accounts: ix.accounts.map((a, i) => (i === index ? k(0x77) : a)) };
    assert.throws(() => review([wrong]), /^Error: Metaplex .* does not match/, role);
  }
});
