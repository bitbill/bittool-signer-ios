// Solana NFT review tests (SOL-NFT-1 … SOL-NFT-7). Synthetic transactions only; the
// fee payer is the public BIP39 test mnemonic's Solana account.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { base58 } from '@scure/base';
import { ed25519 } from '@noble/curves/ed25519.js';
import { parseSolana } from '../src/solana.js';
import { execute } from '../src/index.js';
import { deriveAccounts } from '../src/keys.js';
import { concat, short, toBase64, fromBase64, hexToBytes, utf8 } from '../src/util.js';

const MN = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const ME = deriveAccounts({ mnemonic: MN }).accounts.find(a => a.chain === 'solana').address;

// Program IDs (declare_id! / IDL metadata.address in the official repositories).
const SYSTEM = '11111111111111111111111111111111';
const TOKEN = 'TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA';
const TOKEN2022 = 'TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb';
const ATA = 'ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL';
const COMPUTE = 'ComputeBudget111111111111111111111111111111';
const TM = 'metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s';
const BGUM = 'BGUMAp9Gq7iTEuizy4pqaxsTyUCBK68MDfK752saRPUY';
const CORE = 'CoREENxT6tW1HoK8ypY1SxRMZTcVPm7R94rH4PZNhX7d';
const SYSVAR_IX = 'Sysvar1nstructions1111111111111111111111111';
const AUTH_RULES = 'auth9SigNpDKz4sJJ1DfCTuZrZNSAgh9sFD3rboVmgg';
const SPL_NOOP = 'noopb9bkMVfRPU8AsbpTUg8AQkHtKwMYZiFUjNRtMmV', SPL_CMT = 'cmtDvXumGCrqC1Age74AVPhSRVXJMd8PJS91L8KbNCK';
const MPL_NOOP = 'mnoopTCrg4p8ry25e4bcWA9XZjbNjMTfgYVGGEdRsf3', MPL_CMT = 'mcmt6YrQEMKw8Mw43FmpRLmf7BqRnFMKmAcbxE3xkAW';
const USDC = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';
// Anchor sighashes as published in mpl-bubblegum clients/js/src/generated/instructions/*.ts.
const BG_TRANSFER = [163, 52, 200, 231, 140, 3, 69, 186], BG_TRANSFER_V2 = [119, 40, 6, 235, 234, 221, 248, 49];
const BG_DELEGATE = [90, 147, 75, 178, 85, 88, 4, 137], BG_DELEGATE_V2 = [95, 87, 125, 140, 181, 131, 128, 227];

// Independent PDA derivation: node:crypto SHA-256 plus a BigInt ed25519 on-curve test.
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
const u32 = n => { const b = new Uint8Array(4); new DataView(b.buffer).setUint32(0, n, true); return b; };
const bytes = (...parts) => concat(...parts.map(p => p instanceof Uint8Array ? p : new Uint8Array(p)));

// Builds a legacy or v0 (static keys, no lookup tables) message. Programs are read-only unsigned keys at the end.
function tx(ixs, { version = 'legacy', signers = [ME] } = {}) {
  const programs = [...new Set(ixs.map(ix => ix.program))], keys = [...signers];
  for (const ix of ixs) for (const a of ix.accounts) if (!keys.includes(a) && !programs.includes(a)) keys.push(a);
  keys.push(...programs);
  const at = x => keys.indexOf(x);
  const message = concat(...(version === 'v0' ? [new Uint8Array([0x80])] : []), new Uint8Array([signers.length, 0, programs.length]), short(keys.length), ...keys.map(x => base58.decode(x)), new Uint8Array(32).fill(5), short(ixs.length),
    ...ixs.flatMap(ix => [new Uint8Array([at(ix.program)]), short(ix.accounts.length), new Uint8Array(ix.accounts.map(at)), short(ix.data.length), ix.data]), ...(version === 'v0' ? [short(0)] : []));
  return { chain: 'solana', kind: 'transaction', message: toBase64(message) };
}
const review = (ixs, options) => parseSolana(tx(ixs, options)).review;
const fieldValue = (r, label, n) => r.fields.find(f => n ? f.label === `Instruction ${n} · ${label}` : f.label.endsWith('· ' + label))?.value;
const hasWarning = (r, text) => r.warnings.some(w => w.includes(text));
const noNote = r => assert.equal(r.display.note, undefined, 'NFT flows never set the green verified note');

// Instruction builders -----------------------------------------------------------------------
const ataIx = (owner, mint, program = TOKEN, idempotent = true) => ({ program: ATA, accounts: [ME, ata(owner, mint, program), owner, mint, SYSTEM, program], data: new Uint8Array(idempotent ? [1] : []) });
const transferChecked = ({ source, mint, destination, owner = ME, amount = 1n, decimals = 0, program = TOKEN, extra = [] }) =>
  ({ program, accounts: [source, mint, destination, owner, ...extra], data: bytes([12], u64(amount), [decimals]) });
function tmTransfer({ mint = k(0x33), to = k(0x22), owner = ME, authority = ME, amount = 1n, edition = true, records = true, rules = true, tokenProgram = TOKEN, data, accounts } = {}) {
  const src = ata(owner, mint, tokenProgram), dst = ata(to, mint, tokenProgram);
  const a = accounts ?? [src, owner, dst, to, mint, tmPda(mint), edition ? tmPda(mint, utf8('edition')) : TM,
    records ? tmPda(mint, utf8('token_record'), base58.decode(src)) : TM, records ? tmPda(mint, utf8('token_record'), base58.decode(dst)) : TM,
    authority, ME, SYSTEM, SYSVAR_IX, tokenProgram, ATA, rules ? AUTH_RULES : TM, rules ? k(0x44) : TM];
  return { program: TM, accounts: a, data: data ?? bytes([49, 0], u64(amount), [0]) };
}
// root, data_hash and creator_hash (32 bytes each); nonce and index follow per instruction.
const leafArgs = () => bytes(new Uint8Array(32).fill(1), new Uint8Array(32).fill(2), new Uint8Array(32).fill(3));
function bgTransfer({ tree = k(0x55), owner = ME, delegate = owner, to = k(0x22), nonce = 7, proof = [k(0x66)], config, data } = {}) {
  return { program: BGUM, accounts: [config ?? pda([tree], BGUM), owner, delegate, to, tree, SPL_NOOP, SPL_CMT, SYSTEM, ...proof], data: data ?? bytes(BG_TRANSFER, leafArgs(), u64(nonce), u32(nonce)) };
}
function bgTransferV2({ tree = k(0x56), payer = ME, authority = BGUM, owner = ME, delegate = BGUM, to = k(0x22), collection = BGUM, nonce = 9, options = [[0], [0]], proof = [k(0x67)] } = {}) {
  return { program: BGUM, accounts: [pda([tree], BGUM), payer, authority, owner, delegate, to, tree, collection, MPL_NOOP, MPL_CMT, SYSTEM, ...proof], data: bytes(BG_TRANSFER_V2, leafArgs(), ...options, u64(nonce), u32(nonce)) };
}
const coreTransfer = ({ asset = k(0x77), collection = CORE, payer = ME, authority = CORE, to = k(0x22), system = CORE, log = CORE, extra = [], data = new Uint8Array([14, 0]) } = {}) =>
  ({ program: CORE, accounts: [asset, collection, payer, authority, to, system, log, ...extra], data });

// SOL-NFT-1 ------------------------------------------------------------------------------------
test('SOL-NFT-1: ATA create + transferChecked(1, 0 decimals) shows the recipient wallet with hedged NFT wording (legacy and v0)', () => {
  const mint = k(0x33), recipient = k(0x22);
  for (const version of ['legacy', 'v0']) for (const idempotent of [true, false]) {
    const r = review([ataIx(recipient, mint, TOKEN, idempotent), transferChecked({ source: ata(ME, mint), mint, destination: ata(recipient, mint) })], { version });
    assert.deepEqual(r.display, { action: 'Send Token (likely NFT)', headline: '1 token (0 decimals)', counterpartyLabel: 'To', counterparty: recipient, assetKind: 'nftOrToken', assetContract: mint, assetContractLabel: 'Mint', fee: '0.000005 SOL max' });
    assert.equal(r.summary, '1 token (0 decimals)'); assert.equal(r.decodeStatus, 'fullyDecoded'); assert.equal(r.riskLevel, 'warning'); noNote(r);
    assert.equal(fieldValue(r, 'Recipient wallet (owner of destination token account)'), recipient);
    assert.equal(fieldValue(r, 'Action'), idempotent ? 'Create token account if absent' : 'Create token account', 'the supporting ATA instruction stays in the details');
    assert.ok(hasWarning(r, 'This looks like an NFT (1 unit, 0 decimals)')); assert.ok(!hasWarning(r, 'recipient wallet is not included'));
    assert.ok(!JSON.stringify(r.display).includes('Send NFT'), 'the decimals-0 pattern never claims a proven NFT');
  }
});

test('SOL-NFT-1: without the ATA instruction the counterparty stays the token account with a warning', () => {
  const mint = k(0x33), destination = ata(k(0x22), mint);
  const r = review([transferChecked({ source: ata(ME, mint), mint, destination })]);
  assert.equal(r.display.counterpartyLabel, 'To token account'); assert.equal(r.display.counterparty, destination);
  assert.equal(r.display.action, 'Send Token (likely NFT)'); assert.ok(hasWarning(r, 'The recipient wallet is not included in this transaction')); noNote(r);
});

test('SOL-NFT-1: recipient resolution fails closed on mint, order, program, re-owning and opaque instructions', () => {
  const mint = k(0x33), mint2 = k(0x34), recipient = k(0x22), source = ata(ME, mint), destination = ata(recipient, mint);
  // CloseAccount adds its own SOL movement, so the headline then lists transfers instead of one counterparty.
  const unresolved = (ixs, why, single = true) => { const r = review(ixs); if (single) assert.equal(r.display.counterpartyLabel, 'To token account', why); assert.equal(fieldValue(r, 'Recipient wallet (owner of destination token account)'), undefined, why); assert.ok(hasWarning(r, 'recipient wallet is not included'), why); noNote(r); return r; };
  // The ATA instruction proves a different mint's account.
  unresolved([ataIx(recipient, mint2), transferChecked({ source, mint, destination: ata(recipient, mint2) })], 'mint mismatch');
  // The ATA instruction runs after the transfer.
  const after = unresolved([transferChecked({ source, mint, destination }), ataIx(recipient, mint)], 'ATA after transfer');
  assert.equal(after.display.action, 'Sign Transaction', 'an unrelated ATA instruction is not folded');
  // Token program mismatch: the Token-2022 ATA is used with a classic transfer.
  unresolved([ataIx(recipient, mint, TOKEN2022), transferChecked({ source, mint, destination: ata(recipient, mint, TOKEN2022) })], 'token program mismatch');
  // SetAuthority(AccountOwner) or CloseAccount on the destination between the two instructions.
  unresolved([ataIx(recipient, mint), { program: TOKEN, accounts: [destination, recipient], data: bytes([6, 2, 1], base58.decode(k(0x99))) }, transferChecked({ source, mint, destination })], 'SetAuthority in between');
  unresolved([ataIx(recipient, mint), { program: TOKEN, accounts: [destination, recipient, recipient], data: new Uint8Array([9]) }, transferChecked({ source, mint, destination })], 'CloseAccount in between', false);
  // Any opaque instruction anywhere in the transaction, even after the transfer.
  const opaque = unresolved([ataIx(recipient, mint), transferChecked({ source, mint, destination }), { program: k(0x98), accounts: [destination], data: new Uint8Array([1]) }], 'opaque instruction');
  assert.equal(opaque.riskLevel, 'high');
  // An unchecked transfer carries no mint, so the ATA's mint cannot be matched.
  const unchecked = unresolved([ataIx(recipient, mint), { program: TOKEN, accounts: [source, destination, ME], data: bytes([3], u64(1)) }], 'unchecked transfer');
  assert.deepEqual([unchecked.display.amount, unchecked.display.symbol], ['1', 'raw unit']);
});

test('SOL-NFT-1: ordinary token transfers keep plain wording, fixed pluralisation and registry assets', () => {
  const mint = k(0x35), recipient = k(0x22);
  const small = review([transferChecked({ source: ata(ME, mint), mint, destination: ata(recipient, mint), amount: 5n, decimals: 6 })]);
  assert.deepEqual([small.display.action, small.display.amount, small.display.symbol, small.display.assetKind], ['Send tokens', '0.000005', 'tokens', undefined]);
  assert.ok(!JSON.stringify(small.display).includes('NFT') && !small.warnings.some(w => w.includes('NFT')));
  const one = review([transferChecked({ source: ata(ME, mint), mint, destination: ata(recipient, mint), amount: 1_000_000n, decimals: 6 })]);
  assert.deepEqual([one.display.amount, one.display.symbol, one.summary], ['1', 'token', '1 token']);
  const two = review([ataIx(recipient, mint), transferChecked({ source: ata(ME, mint), mint, destination: ata(recipient, mint), amount: 2n, decimals: 0 })]);
  assert.deepEqual([two.display.action, two.display.amount, two.display.symbol, two.display.counterparty, two.display.assetKind], ['Send tokens', '2', 'tokens', recipient, undefined]);
  const usdc = review([ataIx(recipient, USDC), transferChecked({ source: ata(ME, USDC), mint: USDC, destination: ata(recipient, USDC), amount: 2_500_000n, decimals: 6 })]);
  assert.deepEqual([usdc.display.action, usdc.display.amount, usdc.display.symbol, usdc.display.counterpartyLabel, usdc.display.counterparty], ['Send tokens', '2.5', 'USDC', 'To', recipient]);
  assert.equal(usdc.asset.symbol, 'USDC'); assert.equal(usdc.display.assetKind, undefined);
});

// SOL-NFT-2 ------------------------------------------------------------------------------------
test('SOL-NFT-2: Token Metadata TransferV1 with the edition PDA is a proven NFT send (legacy and v0) and signs', () => {
  const mint = k(0x33), to = k(0x22);
  for (const version of ['legacy', 'v0']) {
    const request = tx([tmTransfer({ mint, to })], { version }), r = parseSolana(request).review;
    assert.deepEqual(r.display, { action: 'Send NFT', headline: '1 NFT', counterpartyLabel: 'To', counterparty: to, assetKind: 'nft', assetContract: mint, assetContractLabel: 'Mint', fee: '0.000005 SOL max' });
    assert.deepEqual([r.summary, r.decodeStatus, r.riskLevel], ['1 NFT', 'fullyDecoded', 'warning']); noNote(r);
    assert.equal(fieldValue(r, 'Program name'), 'Metaplex Token Metadata');
    assert.equal(fieldValue(r, 'Destination account type'), 'Associated token account of the recipient wallet');
    assert.equal(fieldValue(r, 'Edition account'), tmPda(mint, utf8('edition'))); assert.equal(fieldValue(r, 'Token records supplied'), 'Yes'); assert.equal(fieldValue(r, 'Rule set'), k(0x44));
    assert.ok(hasWarning(r, 'rule set will be evaluated on-chain'));
    const out = execute({ operation: 'sign', request, mnemonic: MN });
    assert.ok(ed25519.verify(hexToBytes(out.signature), fromBase64(request.message), base58.decode(ME)));
  }
  // A preceding ATA create for the same recipient account is folded into the single action.
  const folded = review([ataIx(to, mint), tmTransfer({ mint, to })]);
  assert.equal(folded.display.action, 'Send NFT'); assert.equal(folded.display.counterparty, to);
});

test('SOL-NFT-2: without a matching edition the transfer is hedged as a Metaplex token in raw units', () => {
  const noEdition = review([tmTransfer({ edition: false, records: false, rules: false })]);
  assert.deepEqual([noEdition.display.action, noEdition.display.headline, noEdition.display.assetKind, noEdition.display.amount], ['Send Metaplex token', '1 raw unit', 'nftOrToken', undefined]);
  assert.ok(hasWarning(noEdition, 'Decimals are not included in this instruction')); assert.equal(fieldValue(noEdition, 'Edition account'), 'Not supplied');
  assert.equal(fieldValue(noEdition, 'Token records supplied'), 'No'); assert.equal(noEdition.summary, '1 raw unit');
  const five = review([tmTransfer({ amount: 5n })]);
  assert.deepEqual([five.display.action, five.display.headline, five.display.assetKind], ['Send Metaplex token', '5 raw units', 'nftOrToken']);
});

test('SOL-NFT-2: delegate authority, Token-2022, authorization data and wrong PDAs', () => {
  const delegate = k(0x21), mint = k(0x33);
  const byDelegate = review([tmTransfer({ owner: k(0x23), authority: delegate })], { signers: [ME, delegate] });
  assert.equal(byDelegate.riskLevel, 'high'); assert.ok(hasWarning(byDelegate, 'HIGH RISK: The transfer authority ' + delegate + ' is not the token owner'));
  const t22 = review([tmTransfer({ tokenProgram: TOKEN2022 })]);
  assert.deepEqual([t22.riskLevel, t22.decodeStatus], ['high', 'partiallyDecoded']); assert.ok(hasWarning(t22, 'Token-2022'));
  const auth = review([tmTransfer({ data: bytes([49, 0], u64(1), [1], [1, 0, 0, 0, 1, 0, 0, 0, 0x61, 3], u64(1)) })]);
  assert.equal(auth.decodeStatus, 'partiallyDecoded'); assert.ok(hasWarning(auth, 'Authorization rule payload is not decoded')); assert.equal(auth.display.action, 'Send NFT');
  assert.equal(fieldValue(auth, 'Authorization data (not decoded)'), '01000000010000006103' + '0100000000000000');
  const good = tmTransfer({ mint }).accounts;
  for (const [i, label] of [[5, 'metadata'], [6, 'edition'], [7, 'token record'], [8, 'token record']]) {
    const accounts = [...good]; accounts[i] = k(0x90 + i);
    assert.throws(() => review([tmTransfer({ accounts })]), e => e.code === 'INSTRUCTION', 'wrong ' + label + ' PDA is refused');
  }
});

test('SOL-NFT-2: TransferV1 shapes that are not exact stay opaque', () => {
  const opaque = (ix, why) => { const r = review([ix]); assert.equal(r.decodeStatus, 'opaque', why); assert.equal(r.riskLevel, 'high', why); assert.equal(r.display.assetKind, undefined, why); assert.equal(fieldValue(r, 'Program name'), 'Metaplex Token Metadata'); return r; };
  const variant = opaque(tmTransfer({ data: bytes([49, 1], u64(1), [0]) }), 'unknown TransferArgs variant');
  assert.equal(fieldValue(variant, 'Instruction'), 'Transfer (not decoded)');
  opaque(tmTransfer({ accounts: tmTransfer().accounts.slice(0, 16) }), '16 accounts');
  opaque(tmTransfer({ data: bytes([49, 0], u64(1), [0], [0]) }), 'trailing byte after None');
  opaque(tmTransfer({ data: bytes([49, 0], u64(1), [2]) }), 'invalid option tag');
  const badSysvar = tmTransfer().accounts; badSysvar[12] = k(0x91);
  opaque(tmTransfer({ accounts: badSysvar }), 'wrong sysvar');
  const badRules = tmTransfer({ rules: false }).accounts; badRules[16] = k(0x92);
  opaque(tmTransfer({ accounts: badRules }), 'rule set without the rules program');
});

// SOL-NFT-3 ------------------------------------------------------------------------------------
test('SOL-NFT-3: Bubblegum transfer V1 derives the asset ID and names the new owner (legacy and v0)', () => {
  const tree = k(0x55), to = k(0x22), id = pda([utf8('asset'), tree, u64(7)], BGUM);
  assert.equal(id, '84uhHqJu8TUxA3mmp4rgEpwoi2HX9SzFYusUycQmXnff', 'independent derivation matches the audit probe');
  for (const version of ['legacy', 'v0']) {
    const r = review([bgTransfer({ tree, to })], { version });
    assert.deepEqual(r.display, { action: 'Send compressed NFT', headline: '1 NFT', counterpartyLabel: 'To', counterparty: to, assetKind: 'nft', assetContract: id, assetContractLabel: 'Asset ID', fee: '0.000005 SOL max' });
    assert.deepEqual([r.summary, r.decodeStatus, r.riskLevel], ['Send compressed NFT', 'fullyDecoded', 'warning']); noNote(r);
    assert.equal(fieldValue(r, 'Asset ID (derived from tree and nonce)'), id); assert.equal(fieldValue(r, 'Proof accounts'), '1'); assert.equal(fieldValue(r, 'Leaf index'), '7');
    assert.equal(fieldValue(r, 'Leaf delegate'), undefined); assert.ok(hasWarning(r, 'committed only as hashes'));
  }
});

test('SOL-NFT-3: Bubblegum V1 signer rules and fail-closed shapes', () => {
  const delegate = k(0x21), owner = k(0x23);
  const asDelegate = review([bgTransfer({ owner, delegate })], { signers: [ME, delegate] });
  assert.equal(asDelegate.riskLevel, 'high'); assert.ok(hasWarning(asDelegate, 'HIGH RISK: You are transferring an NFT owned by ' + owner + ' as its delegate'));
  assert.equal(fieldValue(asDelegate, 'Leaf delegate'), delegate);
  const nobody = review([bgTransfer({ owner, delegate })]);
  assert.ok(hasWarning(nobody, 'Neither the leaf owner nor the leaf delegate signs'));
  const opaque = (ix, why) => assert.equal(review([ix]).decodeStatus, 'opaque', why);
  opaque(bgTransfer({ config: k(0x57) }), 'wrong tree config');
  opaque(bgTransfer({ data: bytes(BG_TRANSFER, leafArgs(), u64(7), u32(7)).slice(0, 115) }), '115-byte data');
  opaque({ ...bgTransfer(), accounts: bgTransfer().accounts.map(a => a === SPL_NOOP ? MPL_NOOP : a) }, 'V2 noop on a V1 transfer');
  opaque({ ...bgTransfer(), accounts: bgTransfer().accounts.slice(0, 7) }, '7 accounts');
  const burn = review([{ program: BGUM, accounts: [k(0x10)], data: bytes(createHash('sha256').update('global:burn').digest().subarray(0, 8), [0]) }]);
  assert.equal(fieldValue(burn, 'Instruction'), 'burn (not decoded)'); assert.ok(hasWarning(burn, 'This burns a compressed NFT')); assert.equal(burn.decodeStatus, 'opaque');
});

test('SOL-NFT-3: Bubblegum transfer_v2 resolves placeholders and shows the fee as a detail, not a movement', () => {
  const tree = k(0x56), to = k(0x22), id = pda([utf8('asset'), tree, u64(9)], BGUM);
  const r = review([bgTransferV2({ tree, to })]);
  assert.deepEqual(r.display, { action: 'Send compressed NFT', headline: '1 NFT', counterpartyLabel: 'To', counterparty: to, assetKind: 'nft', assetContract: id, assetContractLabel: 'Asset ID', fee: '0.000005 SOL max' });
  assert.equal(fieldValue(r, 'Signing authority'), ME); assert.equal(fieldValue(r, 'Core collection'), 'Not supplied');
  assert.equal(fieldValue(r, 'Bubblegum transfer fee (SOL)'), '0.000006'); assert.equal(fieldValue(r, 'Flags'), 'Not supplied (default)');
  assert.equal(r.riskLevel, 'warning'); assert.equal(r.decodeStatus, 'fullyDecoded');
  const withOptions = review([bgTransferV2({ options: [bytes([1], new Uint8Array(32).fill(0xab)), [1, 4]], collection: k(0x58) })]);
  assert.equal(fieldValue(withOptions, 'Asset data hash'), 'ab'.repeat(32)); assert.equal(fieldValue(withOptions, 'Flags'), '4');
  assert.equal(fieldValue(withOptions, 'Core collection'), k(0x58)); assert.ok(hasWarning(withOptions, 'Collection plugins'));
  const delegate = k(0x21), owner = k(0x23);
  const asDelegate = review([bgTransferV2({ owner, delegate, authority: delegate })], { signers: [ME, delegate] });
  assert.equal(asDelegate.riskLevel, 'high'); assert.ok(hasWarning(asDelegate, 'HIGH RISK: The signing authority ' + delegate + ' is not the NFT owner ' + owner));
  assert.equal(review([bgTransferV2({ options: [[2], [0]] })]).decodeStatus, 'opaque', 'Option tag 2 stays opaque');
  assert.equal(review([{ ...bgTransferV2(), accounts: bgTransferV2().accounts.map(a => a === MPL_CMT ? SPL_CMT : a) }]).decodeStatus, 'opaque', 'V1 compression program on V2');
});

test('SOL-NFT-6: Bubblegum delegate and delegate_v2 name the new delegate and the derived asset', () => {
  const tree = k(0x55), newDelegate = k(0x24), id = pda([utf8('asset'), tree, u64(3)], BGUM);
  const v1 = review([{ program: BGUM, accounts: [pda([tree], BGUM), ME, ME, newDelegate, tree, SPL_NOOP, SPL_CMT, SYSTEM], data: bytes(BG_DELEGATE, leafArgs(), u64(3), u32(3)) }]);
  assert.equal(v1.display.action, 'Approve compressed-NFT delegate'); assert.equal(fieldValue(v1, 'New delegate'), newDelegate);
  assert.deepEqual([v1.display.assetKind, v1.display.assetContract, v1.display.assetContractLabel], ['nft', id, 'Asset ID']);
  assert.equal(v1.riskLevel, 'high'); assert.ok(hasWarning(v1, 'can transfer or burn this compressed NFT')); assert.ok(!hasWarning(v1, 'freeze'), 'V1 trees have no freeze');
  const tree2 = k(0x56);
  const v2 = review([{ program: BGUM, accounts: [pda([tree2], BGUM), ME, BGUM, BGUM, newDelegate, tree2, MPL_NOOP, MPL_CMT, SYSTEM], data: bytes(BG_DELEGATE_V2, leafArgs(), [0], [0], [1, 0], u64(3), u32(3)) }]);
  assert.equal(v2.display.action, 'Approve compressed-NFT delegate'); assert.equal(fieldValue(v2, 'Leaf owner'), ME); assert.equal(fieldValue(v2, 'Previous delegate'), ME); assert.equal(fieldValue(v2, 'Flags'), '0');
  assert.equal(v2.display.assetContract, pda([utf8('asset'), tree2, u64(3)], BGUM));
  assert.equal(v2.riskLevel, 'high'); assert.ok(hasWarning(v2, 'HIGH RISK: The new delegate ' + newDelegate + ' can transfer, burn or freeze this compressed NFT'));
  assert.ok(hasWarning(v2, 'While it is frozen, you cannot transfer it or change the delegate.'));
  const clear = review([{ program: BGUM, accounts: [pda([tree], BGUM), ME, newDelegate, ME, tree, SPL_NOOP, SPL_CMT, SYSTEM], data: bytes(BG_DELEGATE, leafArgs(), u64(3), u32(3)) }]);
  assert.equal(clear.display.action, 'Remove compressed-NFT delegate'); assert.equal(clear.riskLevel, 'warning');
});

// SOL-NFT-4 ------------------------------------------------------------------------------------
test('SOL-NFT-4: Core TransferV1 hides placeholders and shows Not supplied for the collection (legacy and v0)', () => {
  const asset = k(0x77), to = k(0x22);
  for (const version of ['legacy', 'v0']) {
    const r = review([coreTransfer({ asset, to })], { version });
    assert.deepEqual(r.display, { action: 'Send Core NFT', headline: '1 NFT', counterpartyLabel: 'To', counterparty: to, assetKind: 'nft', assetContract: asset, assetContractLabel: 'Asset ID', fee: '0.000005 SOL max' });
    assert.deepEqual([r.summary, r.decodeStatus, r.riskLevel], ['Send Core NFT', 'fullyDecoded', 'warning']); noNote(r);
    assert.equal(fieldValue(r, 'Collection'), 'Not supplied'); assert.equal(fieldValue(r, 'Signing authority'), ME); assert.equal(fieldValue(r, 'Accounts'), undefined);
    assert.ok(hasWarning(r, 'current owner is not included'));
  }
  const explicit = review([coreTransfer({ collection: k(0x78), authority: k(0x21), system: SYSTEM, log: SPL_NOOP })], { signers: [ME, k(0x21)] });
  assert.equal(fieldValue(explicit, 'Signing authority'), k(0x21)); assert.equal(fieldValue(explicit, 'Collection'), k(0x78));
  const adapters = review([coreTransfer({ extra: [k(0x79), k(0x7a)] })]);
  assert.deepEqual([adapters.riskLevel, adapters.decodeStatus], ['high', 'partiallyDecoded']); assert.equal(fieldValue(adapters, 'Additional accounts (plugin adapters)'), k(0x79) + '\n' + k(0x7a));
});

test('SOL-NFT-4: Core shapes that are not exact, and other Core instructions, stay opaque', () => {
  const proof = review([coreTransfer({ data: new Uint8Array([14, 1, 0]) })]);
  assert.equal(proof.decodeStatus, 'opaque'); assert.equal(fieldValue(proof, 'Instruction'), 'TransferV1 (not decoded)');
  assert.equal(review([coreTransfer({ log: k(0x7b) })]).decodeStatus, 'opaque', 'random log wrapper');
  assert.equal(review([{ ...coreTransfer(), accounts: coreTransfer().accounts.slice(0, 6) }]).decodeStatus, 'opaque', '6 accounts');
  const approve = review([{ program: CORE, accounts: [k(0x77), CORE, ME, CORE, SYSTEM, CORE], data: new Uint8Array([8, 1, 0]) }]);
  assert.equal(fieldValue(approve, 'Instruction'), 'ApprovePluginAuthorityV1 (not decoded)'); assert.ok(hasWarning(approve, 'transfer, burn or freeze delegate'));
});

// SOL-NFT-5 ------------------------------------------------------------------------------------
test('SOL-NFT-5: Token-2022 transfer-hook accounts are listed and the hook is hedged', () => {
  const mint = k(0x33), hook = k(0x40), validation = pda([utf8('extra-account-metas'), mint], hook), extra1 = k(0x41), extra2 = k(0x42);
  const r = review([transferChecked({ program: TOKEN2022, source: ata(ME, mint, TOKEN2022), mint, destination: ata(k(0x22), mint, TOKEN2022), extra: [extra1, extra2, hook, validation] })]);
  assert.equal(fieldValue(r, 'Transfer hook program (supplied)'), hook); assert.equal(fieldValue(r, 'Hook validation account'), validation);
  assert.equal(fieldValue(r, 'Hook extra accounts'), extra1 + '\n' + extra2); assert.equal(fieldValue(r, 'Multisig signers'), undefined);
  assert.ok(hasWarning(r, 'supplies accounts for transfer-hook program ' + hook)); assert.ok(hasWarning(r, 'actual transfer hook is on-chain state and cannot be verified offline'));
  assert.deepEqual([r.riskLevel, r.decodeStatus, r.display.action, r.display.assetKind], ['high', 'partiallyDecoded', 'Send Token (likely NFT)', 'nftOrToken']);
  const decoy = review([transferChecked({ program: TOKEN2022, source: k(1), mint, destination: k(2), extra: [hook, k(0x43)] })]);
  assert.equal(decoy.fields.some(f => f.label.includes('hook program')), false); assert.equal(fieldValue(decoy, 'Unclassified extra accounts'), hook + '\n' + k(0x43));
});

test('SOL-NFT-5: multisig signers are separated by the required-signer set; hook extras lift the 11-account cap', () => {
  const mint = k(0x33), multisig = k(0x50), s1 = ed25519.getPublicKey(new Uint8Array(32).fill(1)), s2 = ed25519.getPublicKey(new Uint8Array(32).fill(2));
  const [a1, a2] = [base58.encode(s1), base58.encode(s2)], hook = k(0x40), validation = pda([utf8('extra-account-metas'), mint], hook);
  const r = review([transferChecked({ program: TOKEN2022, source: k(1), mint, destination: k(2), owner: multisig, extra: [a1, a2, k(0x41), hook, validation] })], { signers: [ME, a1, a2] });
  assert.equal(fieldValue(r, 'Multisig signers'), a1 + '\n' + a2); assert.equal(fieldValue(r, 'Hook extra accounts'), k(0x41)); assert.equal(fieldValue(r, 'Transfer hook program (supplied)'), hook);
  // A signing owner cannot be a multisig, so a signer among the hook extras (often the owner or payer) is not relabelled.
  const owned = review([transferChecked({ program: TOKEN2022, source: k(1), mint, destination: k(2), owner: ME, extra: [ME, hook, validation] })]);
  assert.equal(fieldValue(owned, 'Multisig signers'), undefined); assert.equal(fieldValue(owned, 'Hook extra accounts'), ME);
  assert.equal(fieldValue(owned, 'Transfer hook program (supplied)'), hook);
  const many = Array.from({ length: 14 }, (_, i) => k(0x60 + i));
  assert.equal(fieldValue(review([transferChecked({ program: TOKEN2022, source: k(1), mint, destination: k(2), extra: many })]), 'Unclassified extra accounts'), many.join('\n'));
  assert.throws(() => review([transferChecked({ source: k(1), mint, destination: k(2), extra: many })]), e => e.code === 'INSTRUCTION', 'classic Tokenkeg keeps the multisig cap');
});

// SOL-NFT-6 ------------------------------------------------------------------------------------
test('SOL-NFT-6: known NFT marketplaces are named but never decoded', () => {
  for (const [program, name] of [['M2mx93ekt1fmXSVkTrUL9xVFHkmME8HTUi5Cyc5aF7K', 'Magic Eden M2'], ['mmm3XBJg5gk8XJxEKBvdgptZz6SgK4tXvn36sodowMc', 'Magic Eden MMM'], ['TCMPhJdwDryooaGtiocG1u3xcYbRpiJzb283XfCZsDp', 'Tensor Marketplace'], ['TSWAPaqyCSx2KABk68Shruf4rp7CxcNi8hAsbdwmHbN', 'Tensor Swap'], ['TAMM6ub33ij1mbetoMyVBLeKY5iP41i4UPUJQGkhfsg', 'Tensor AMM'], ['hausS13jsjafwWwGqZTUQRmWyvyxn9EQpqMwV1PBBmk', 'Metaplex Auction House']]) {
    const r = review([{ program: COMPUTE, accounts: [], data: bytes([2], u32(200000)) }, { program, accounts: [ME, k(0x78)], data: bytes([1, 2, 3, 4, 5, 6, 7, 8], u64(5)) }]);
    assert.deepEqual([r.display.action, r.display.headline, r.decodeStatus, r.riskLevel, r.summary], ['NFT marketplace action', name + ' · not decoded', 'opaque', 'high', 'NFT marketplace action (not decoded)']);
    assert.equal(fieldValue(r, 'Program', 2), program); assert.equal(fieldValue(r, 'Program name', 2), name); assert.equal(fieldValue(r, 'Exact instruction bytes', 2), '01020304050607080500000000000000');
    assert.ok(hasWarning(r, 'HIGH RISK: This ' + name + ' NFT marketplace instruction')); noNote(r);
  }
  // A marketplace instruction next to a decoded instruction keeps the transaction partially decoded.
  const mixed = review([{ program: SYSTEM, accounts: [ME, k(0x22)], data: bytes(u32(2), u64(1000)) }, { program: 'M2mx93ekt1fmXSVkTrUL9xVFHkmME8HTUi5Cyc5aF7K', accounts: [ME], data: new Uint8Array([9]) }]);
  assert.deepEqual([mixed.display.action, mixed.display.amount, mixed.display.headline, mixed.decodeStatus], ['NFT marketplace action', '0.000001', 'Magic Eden M2 · not decoded', 'partiallyDecoded']);
  // Unknown programs are unchanged: no name and the existing partially-decoded status.
  const unknown = review([{ program: k(0x97), accounts: [ME], data: new Uint8Array([1]) }]);
  assert.deepEqual([unknown.display.action, unknown.decodeStatus, fieldValue(unknown, 'Program name')], ['Sign Transaction', 'opaque', undefined]);
});

const tmDelegateIx = (variantByte, { mint = k(0x33), delegate = k(0x24), revoke = false, args = [], edition = true } = {}) => ({ program: TM,
  accounts: [k(0x25), delegate, tmPda(mint), edition ? tmPda(mint, utf8('edition')) : TM, TM, mint, ata(ME, mint), ME, ME, SYSTEM, SYSVAR_IX, TOKEN, TM, TM], data: bytes([revoke ? 45 : 44, variantByte], args) });

test('SOL-NFT-6: Token Metadata Delegate uses verifier-corrected powers and derives NFT status from the role', () => {
  const mint = k(0x33), delegate = k(0x24), locked = k(0x27);
  // [byte, variant, exact DelegateArgs bytes, power, pNFT-only role]
  const cases = [[1, 'SaleV1', [u64(1), [0]], 'can transfer this NFT', true], [2, 'TransferV1', [u64(1), [0]], 'can transfer this NFT', true],
    [7, 'LockedTransferV1', [u64(1), base58.decode(locked), [0]], 'can lock this NFT and transfer it to any address without asking you again (the locked address in the arguments is not enforced by Token Metadata)', true],
    [6, 'StandardV1', [u64(1_000_000_000_000n)], 'can transfer, burn and lock up to the delegated amount', false], [4, 'UtilityV1', [u64(1), [0]], 'can burn and lock', true],
    [5, 'StakingV1', [u64(1), [0]], 'can lock this NFT', true], [3, 'DataV1', [[0]], 'gains DataV1 authority', false], [13, 'PrintDelegateV1', [[0]], 'gains PrintDelegateV1 authority', false]];
  for (const [byte, variant, args, power, nft] of cases) for (const edition of [true, false]) {
    const r = review([tmDelegateIx(byte, { mint, delegate, args: bytes(...args), edition })]);
    assert.equal(r.display.action, 'Approve ' + (nft ? 'NFT ' : 'Metaplex ') + variant + ' delegate'); assert.equal(fieldValue(r, 'Delegate'), delegate); assert.equal(fieldValue(r, 'Mint'), mint);
    assert.deepEqual([r.riskLevel, r.decodeStatus], ['high', 'partiallyDecoded']); assert.ok(hasWarning(r, 'HIGH RISK: The delegate ' + delegate + ' ' + power), variant);
    // A supplied edition PDA never upgrades a role that Token Metadata also accepts for fungible tokens.
    assert.deepEqual([r.display.assetKind, r.display.assetContract, r.display.assetContractLabel], [nft ? 'nft' : 'nftOrToken', mint, 'Mint'], variant); noNote(r);
    assert.equal(fieldValue(r, 'Arguments (not decoded)'), undefined); assert.equal(fieldValue(r, 'Authorization data (not decoded)'), undefined);
  }
  const standard = review([tmDelegateIx(6, { args: u64(1_000_000_000_000n) })]);
  assert.equal(fieldValue(standard, 'Delegated amount (raw units)'), '1000000000000'); assert.ok(fieldValue(standard, 'Asset type').startsWith('Not proven to be an NFT'));
  const lockedTransfer = review([tmDelegateIx(7, { args: bytes(u64(1), base58.decode(locked), [0]) })]);
  assert.equal(fieldValue(lockedTransfer, 'Locked address (stored, not enforced)'), locked); assert.ok(!hasWarning(lockedTransfer, 'to the locked address'));
  const withAuth = review([tmDelegateIx(1, { args: bytes(u64(1), [1], [1, 0, 0, 0]) })]);
  assert.equal(fieldValue(withAuth, 'Authorization data (not decoded)'), '01000000'); assert.ok(hasWarning(withAuth, 'Authorization rule payload is not decoded'));
  // Inexact argument bytes stay opaque.
  const opaque = (ix, why) => assert.equal(review([ix]).decodeStatus, 'opaque', why);
  opaque(tmDelegateIx(14), 'DelegateArgs has no variant 14');
  opaque({ ...tmDelegateIx(1, { args: bytes(u64(1), [0]) }), accounts: tmDelegateIx(1).accounts.slice(0, 13) }, '13 accounts');
  opaque(tmDelegateIx(6), 'StandardV1 without its amount');
  opaque(tmDelegateIx(6, { args: bytes(u64(1), [0]) }), 'StandardV1 has no authorization option');
  opaque(tmDelegateIx(1, { args: [0] }), 'SaleV1 without its amount');
  opaque(tmDelegateIx(1, { args: bytes(u64(1)) }), 'SaleV1 without the option tag');
  opaque(tmDelegateIx(1, { args: bytes(u64(1), [0], [0]) }), 'trailing byte after None');
  opaque(tmDelegateIx(1, { args: bytes(u64(1), [2]) }), 'invalid option tag');
  opaque(tmDelegateIx(1, { args: bytes(u64(1), [1]) }), 'Some without a payload');
  opaque(tmDelegateIx(7, { args: bytes(u64(1), [0]) }), 'LockedTransferV1 without its locked address');
  opaque(tmDelegateIx(3), 'DataV1 without the option tag');
});

test('SOL-NFT-6: Token Metadata Revoke uses its own RevokeArgs table and the role decides NFT status', () => {
  const migration = review([tmDelegateIx(9, { revoke: true })]);
  assert.deepEqual([migration.display.action, migration.display.assetKind], ['Revoke NFT MigrationV1 delegate', 'nft']);
  assert.equal(review([tmDelegateIx(9, { args: [0] })]).display.action, 'Approve Metaplex AuthorityItemV1 delegate');
  const print = review([tmDelegateIx(14, { revoke: true })]);
  assert.deepEqual([print.display.action, print.display.assetKind], ['Revoke Metaplex PrintDelegateV1 delegate', 'nftOrToken']);
  const standard = review([tmDelegateIx(6, { revoke: true })]);
  assert.deepEqual([standard.display.action, standard.display.assetKind], ['Revoke Metaplex StandardV1 delegate', 'nftOrToken']);
  const revoke = review([tmDelegateIx(1, { revoke: true, edition: false })]);
  assert.deepEqual([revoke.display.action, revoke.display.assetKind], ['Revoke NFT SaleV1 delegate', 'nft']); assert.ok(!hasWarning(revoke, 'can transfer'));
  assert.equal(fieldValue(revoke, 'Delegated amount (raw units)'), undefined);
  assert.equal(review([tmDelegateIx(1, { revoke: true, args: [0] })]).decodeStatus, 'opaque', 'RevokeArgs carry no data');
});

test('SOL-NFT-6: Token Metadata Lock, Unlock, Burn and BurnNft use their own account layouts', () => {
  const mint = k(0x33), token = ata(ME, mint), freeze = k(0x26);
  const lockAccounts = [freeze, ME, token, mint, tmPda(mint), tmPda(mint, utf8('edition')), TM, ME, SYSTEM, SYSVAR_IX, TOKEN, TM, TM];
  const lock = review([{ program: TM, accounts: lockAccounts, data: new Uint8Array([46, 0, 0]) }], { signers: [ME, freeze] });
  assert.equal(lock.display.action, 'Lock NFT'); assert.equal(fieldValue(lock, 'Mint'), mint); assert.equal(fieldValue(lock, 'Token account'), token);
  assert.equal(fieldValue(lock, 'Authority (delegate or freeze authority)'), freeze); assert.ok(hasWarning(lock, 'HIGH RISK: Locking freezes this token')); assert.equal(lock.display.assetKind, 'nft');
  const unlock = review([{ program: TM, accounts: lockAccounts, data: new Uint8Array([47, 0, 0]) }], { signers: [ME, freeze] });
  assert.equal(unlock.display.action, 'Unlock NFT'); assert.equal(unlock.riskLevel, 'high');
  // Without the edition a non-programmable token takes the fungible freeze-authority path, so NFT is not claimed.
  const noEdition = lockAccounts.map((a, i) => i === 5 ? TM : a);
  const lockToken = review([{ program: TM, accounts: noEdition, data: new Uint8Array([46, 0, 0]) }], { signers: [ME, freeze] });
  assert.deepEqual([lockToken.display.action, lockToken.display.assetKind, lockToken.riskLevel], ['Lock Metaplex token', 'nftOrToken', 'high']);
  assert.ok(hasWarning(lockToken, 'HIGH RISK: Locking freezes this token'));
  const unlockToken = review([{ program: TM, accounts: noEdition, data: new Uint8Array([47, 0, 0]) }], { signers: [ME, freeze] });
  assert.deepEqual([unlockToken.display.action, unlockToken.display.assetKind], ['Unlock Metaplex token', 'nftOrToken']);
  assert.equal(review([{ program: TM, accounts: lockAccounts.map((a, i) => i === 4 ? k(0x93) : a), data: new Uint8Array([46, 0, 0]) }], { signers: [ME, freeze] }).decodeStatus, 'opaque', 'metadata not for this mint');
  const burnAccounts = [ME, TM, tmPda(mint), tmPda(mint, utf8('edition')), mint, token, TM, TM, TM, TM, TM, SYSTEM, SYSVAR_IX, TOKEN];
  const burn = review([{ program: TM, accounts: burnAccounts, data: bytes([41, 0], u64(1)) }]);
  assert.equal(burn.display.action, 'Burn NFT (irreversible)'); assert.equal(fieldValue(burn, 'Raw amount'), '1'); assert.ok(hasWarning(burn, 'This cannot be undone'));
  const burnToken = review([{ program: TM, accounts: burnAccounts.map((a, i) => i === 3 ? TM : a), data: bytes([41, 0], u64(10)) }]);
  assert.deepEqual([burnToken.display.action, burnToken.display.assetKind], ['Burn Metaplex token (irreversible)', 'nftOrToken']);
  const burnNft = review([{ program: TM, accounts: [tmPda(mint), ME, mint, token, tmPda(mint, utf8('edition')), TOKEN], data: new Uint8Array([29]) }]);
  assert.deepEqual([burnNft.display.action, burnNft.riskLevel, burnNft.display.assetKind], ['Burn NFT (irreversible)', 'high', 'nft']);
  assert.equal(review([{ program: TM, accounts: [tmPda(mint), ME, mint, token, k(0x94), TOKEN], data: new Uint8Array([29]) }]).decodeStatus, 'opaque', 'BurnNft with a wrong master edition');
});

test('SOL-NFT-6: other Token Metadata instructions are named and stay opaque', () => {
  const r = review([{ program: TM, accounts: [k(0x33)], data: new Uint8Array([50, 0]) }]);
  assert.deepEqual([fieldValue(r, 'Instruction'), r.decodeStatus, r.riskLevel], ['Update (not decoded)', 'opaque', 'high']);
});
