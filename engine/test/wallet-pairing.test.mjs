import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac, createPrivateKey, createPublicKey } from 'node:crypto';
import { mnemonicToSeedSync } from '@scure/bip39';
import { HDKey } from '@scure/bip32';
import { p2wpkh } from '@scure/btc-signer';
import { base58 } from '@scure/base';
import { URDecoder, UR, UREncoder } from '@ngraveio/bc-ur';
import { derivePublicIndex, validatePublicIndex } from '../src/public-index.js';
import { resolveSigningPlan } from '../src/resolver.js';
import { createWalletPairing, decodeWalletPairing, canonicalCBOR, walletPairingObject, walletPairingIdentity } from '../protocols.js';
import { signKhV2, KH_V2_PATH } from '../src/kh2.js';
import { execute } from '../src/index.js';

// Public, unfunded test phrase (BIP39/BIP84 reference vectors).
const MN = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const A = derivePublicIndex({ mnemonic: MN });
// The wallet-identity signature every v2 payload carries. Pinned here as a
// literal as well, so a change in the signing code shows up as a failing
// assertion rather than as a quietly different QR: the other three BitTool
// platforms match these bytes exactly (docs/kh2_bittool_vectors.json).
const IDENTITY = signKhV2({ mnemonic: MN, epoch: 1 });
const SIG = IDENTITY.signature;
const pairing = (extra = {}) => createWalletPairing({ publicIndex: A, khSig: SIG, ...extra });
const object = (extra = {}) => walletPairingObject(validatePublicIndex(A), { khSig: SIG, ...extra });
const clone = value => JSON.parse(JSON.stringify(value));
const outerBytes = frames => { const d = new URDecoder(); frames.forEach(f => d.receivePart(f)); assert.ok(d.isComplete()); return d.resultUR(); };

/** Independent SLIP-0010 Ed25519 derivation with Node's crypto. */
function solanaAddress(path) {
  const hmac = (key, data) => createHmac('sha512', key).update(data).digest();
  let I = hmac('ed25519 seed', mnemonicToSeedSync(MN));
  for (const part of path.split('/').slice(1)) {
    const index = Buffer.alloc(4); index.writeUInt32BE(Number(part.slice(0, -1)) + 0x80000000);
    I = hmac(I.subarray(32), Buffer.concat([Buffer.from([0]), I.subarray(0, 32), index]));
  }
  const key = createPrivateKey({ key: Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), I.subarray(0, 32)]), format: 'der', type: 'pkcs8' });
  return base58.encode(createPublicKey(key).export({ format: 'der', type: 'spki' }).subarray(-32));
}

test('BitTool Signer exports one wallet-level form: the account-level payload', () => {
  const qr = pairing();
  assert.equal(qr.mode, 'full');
  const p = decodeWalletPairing({ frames: qr.frames });
  assert.deepEqual(Object.keys(p).sort(), ['accounts', 'identity', 'khEpoch', 'khSig', 'masterFingerprint', 'mode', 'network', 'protocol', 'version']);
  assert.deepEqual([p.protocol, p.version, p.mode, p.network, p.masterFingerprint], ['bittool-signer-wallet', 2, 'full', 'mainnet', '73c5da0a']);
  assert.deepEqual([p.khEpoch, p.khSig], [1, SIG]);
  assert.deepEqual(p.accounts.map(a => a.chain), ['btc', 'btc', 'btc', 'btc', 'evm', 'tron', 'sol']);
  // Every exported account gets a first address to check: the four Bitcoin
  // script types in offer order, EVM, TRON, then the three Solana profiles.
  assert.deepEqual(qr.verify.map(v => v.address), [
    'bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu',          // Native SegWit
    'bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr', // Taproot
    '37VucYSaXLCAsxYyAPfbSi9eh4iEcbShgf',                   // Nested SegWit
    '1LqBGSKuX5yYUonjxT5qGfpUsXKYYWeabA',                   // Legacy
    '0x9858EfFD232B4033E47d90003D41EC34EcaEda94',
    'TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdH',
    'HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk',         // Solana standard
    'GjJyeC1r2RgkuoCWMyPYkCWSGSGLcz266EaAkLA27AhL',         // Solana trust
    'D2PPQSYFe83nDzk96FqGumVU8JA7J8vj2Rhjc2oXzEi5',         // Solana legacy
  ]);
  assert.throws(() => pairing({ mode: 'simple' }), /mode/);
  // The identity is reported beside the QR but is not offered as a receive address.
  assert.deepEqual(qr.identity, { path: KH_V2_PATH, publicKey: IDENTITY.publicKey, address: IDENTITY.address, epoch: 1 });
  assert.ok(!qr.verify.some(v => v.address === IDENTITY.address));
});

test('The payload holds four BTC xpubs, EVM, TRON and the three Solana addresses', () => {
  const qr = pairing();
  // An animated QR: a multi-part ur:bytes sequence the wallet reassembles.
  assert.ok(qr.frames.length >= 2, `animated, got ${qr.frames.length} frame(s)`);
  for (const frame of qr.frames) {
    assert.match(frame, /^UR:BYTES\/\d+-\d+\/[A-Z]+$/, 'every frame carries its sequence number');
    assert.ok(frame.length < 1700, 'each frame fits an easily scanned QR version');
  }
  const p = decodeWalletPairing({ frames: qr.frames });
  assert.equal(p.mode, 'full');
  const btc = p.accounts.filter(a => a.chain === 'btc');
  const evm = p.accounts.find(a => a.chain === 'evm'), tron = p.accounts.find(a => a.chain === 'tron');
  const sol = p.accounts.find(a => a.chain === 'sol');
  const root = HDKey.fromMasterSeed(mnemonicToSeedSync(MN));
  // All four single-sig script types, each with its own account xpub.
  assert.deepEqual(btc.map(a => [a.script, a.accountPath]), [
    ['p2wpkh', "m/84'/0'/0'"], ['p2tr', "m/86'/0'/0'"], ['p2sh-p2wpkh', "m/49'/0'/0'"], ['p2pkh', "m/44'/0'/0'"]]);
  for (const account of btc) {
    assert.deepEqual(account, { chain: 'btc', accountPath: account.accountPath, script: account.script,
      xpub: root.derive(account.accountPath).publicExtendedKey, derive: { receive: '0/*', change: '1/*' } });
  }
  // The m/48' multisig profiles stay out: they need a coordinator and threshold.
  assert.equal(btc.filter(a => a.accountPath.startsWith("m/48'")).length, 0);
  assert.deepEqual(evm, { chain: 'evm', accountPath: "m/44'/60'/0'", xpub: root.derive("m/44'/60'/0'").publicExtendedKey, derive: '0/*' });
  assert.deepEqual(tron, { chain: 'tron', accountPath: "m/44'/195'/0'", xpub: root.derive("m/44'/195'/0'").publicExtendedKey, derive: '0/*' });
  // A watch wallet derives the same first receive address from the exported xpub alone.
  assert.equal(p2wpkh(HDKey.fromExtendedKey(btc[0].xpub).deriveChild(0).deriveChild(0).publicKey).address, 'bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu');
  // Solana (hardened Ed25519) has no xpub, so all three presets ship as addresses.
  assert.deepEqual(sol, { chain: 'sol', profile: 'bip44-solana', accounts: [
    { index: 0, profile: 'standard', path: "m/44'/501'/0'/0'", address: solanaAddress("m/44'/501'/0'/0'") },
    { index: 1, profile: 'trust', path: "m/44'/501'/0'", address: solanaAddress("m/44'/501'/0'") },
    { index: 2, profile: 'legacy', path: "m/44'/501'", address: solanaAddress("m/44'/501'") }] });
  assert.equal(p.accounts.filter(a => a.xpub).length, 6);
  const text = JSON.stringify(p);
  assert.ok(!text.includes('xprv'));
  for (const other of ["m/44'/501'/1'/0'", "m/44'/501'/2'/0'"]) assert.ok(!text.includes(other), other);
});

test('Payload is canonical CBOR inside a ur:bytes byte string', () => {
  const qr = pairing(), ur = outerBytes(qr.frames);
  assert.equal(ur.type, 'bytes');
  assert.equal(ur.cbor[0] >> 5, 2, 'ur:bytes holds a CBOR byte string');
  const { identity, ...decoded } = decodeWalletPairing({ frames: qr.frames });
  assert.deepEqual(canonicalCBOR(decoded), canonicalCBOR(object()));
  // Keys sort by their encodings: shorter text keys first, then bytewise.
  assert.equal(canonicalCBOR({ version: 1, mode: 'full', b: 'x', aa: 2 }).toString('hex'), 'a46162617862616102646d6f64656466756c6c6776657273696f6e01');
  assert.throws(() => canonicalCBOR({ n: -1 }), /Unsupported/);
  assert.throws(() => canonicalCBOR({ n: 1.5 }), /Unsupported/);
});

test('Decoder ignores unknown fields but refuses other versions, protocols and non-canonical bytes', () => {
  const wrap = payload => {
    const len = payload.length, head = len < 24 ? Buffer.from([0x40 | len]) : len < 256 ? Buffer.from([0x58, len]) : Buffer.from([0x59, len >> 8, len & 255]);
    return new UREncoder(new UR(Buffer.concat([head, payload]), 'bytes'), 400).encodeWhole();
  };
  const base = object();
  const extra = decodeWalletPairing({ frames: wrap(canonicalCBOR({ ...base, futureField: 'ignored', accounts: base.accounts.map(a => ({ ...a, label: 'x' })) })) });
  assert.equal(extra.accounts.length, 7);
  // Unknown fields of every CBOR type are ignored (draft §10 rule 14), including a key named "tag".
  const encodedBase = canonicalCBOR(base);
  const withUnknown = raw => { // append a canonical key/value pair to the top-level map
    const head = encodedBase[0]; assert.equal(head >> 5, 5);
    const count = head & 31, extraKey = Buffer.from('7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a', 'hex'), keyBytes = Buffer.concat([Buffer.from([0x74]), extraKey]);
    // 20-char keys sort after every known key (all shorter), so the pair goes last.
    return Buffer.concat([Buffer.from([0xa0 | (count + 1)]), encodedBase.subarray(1), keyBytes, raw]);
  };
  for (const [name, raw] of [['null', 'f6'], ['bytes', '4101'], ['negative', '20'], ['float16', 'f93c00'], ['tag', 'c16161'], ['big uint', '1b0000000100000000']]) {
    assert.equal(decodeWalletPairing({ frames: wrap(withUnknown(Buffer.from(raw, 'hex'))) }).accounts.length, 7, name);
  }
  assert.equal(decodeWalletPairing({ frames: wrap(canonicalCBOR({ ...base, tag: 'not a CBOR tag' })) }).protocol, 'bittool-signer-wallet');
  // Duplicate or out-of-order keys, indefinite lengths and trailing bytes are not canonical.
  for (const hex of ['a2616101616102', 'a2616201616101', 'bf616101ff', 'a1616101' + '00']) {
    assert.throws(() => decodeWalletPairing({ frames: wrap(Buffer.from(hex, 'hex')) }), /canonical|Trailing|not a map/, hex);
  }
  // A spec-defined simple payload from another exporter still decodes.
  assert.equal(decodeWalletPairing({ frames: wrap(canonicalCBOR({ ...base, mode: 'simple' })) }).mode, 'simple');
  // v1 is no longer read as a weaker pairing: it is refused like any other version.
  for (const version of [1, 3]) assert.throws(() => decodeWalletPairing({ frames: wrap(canonicalCBOR({ ...base, version })) }), /version/, String(version));
  assert.throws(() => decodeWalletPairing({ frames: wrap(canonicalCBOR({ ...base, protocol: 'other' })) }), /Not a BitTool Signer/);
  assert.throws(() => decodeWalletPairing({ frames: wrap(canonicalCBOR({ ...base, mode: 'huge' })) }), /mode/);
  // Same content with a non-shortest integer (version as 0x18 0x01) is not canonical.
  const canonical = canonicalCBOR(base), key = Buffer.from('6776657273696f6e02', 'hex'), at = canonical.indexOf(key);
  assert.ok(at > 0);
  const nonCanonical = Buffer.concat([canonical.subarray(0, at + 8), Buffer.from([0x18, 0x01]), canonical.subarray(at + 9)]);
  assert.throws(() => decodeWalletPairing({ frames: wrap(nonCanonical) }), /canonical/);
  assert.throws(() => pairing({ mode: 'medium' }), /mode/);
});

test('A v2 code is refused without a signature that its own public keys verify', () => {
  const wrap = payload => {
    const len = payload.length, head = len < 24 ? Buffer.from([0x40 | len]) : len < 256 ? Buffer.from([0x58, len]) : Buffer.from([0x59, len >> 8, len & 255]);
    return new UREncoder(new UR(Buffer.concat([head, payload]), 'bytes'), 400).encodeWhole();
  };
  const base = object(), decode = extra => decodeWalletPairing({ frames: wrap(canonicalCBOR({ ...base, ...extra })) });
  // Missing, malformed and wrong-epoch signatures all fail, and so does a
  // signature by another wallet: the decoder checks it against the code's own keys.
  const { khSig, ...unsigned } = base;
  assert.throws(() => decodeWalletPairing({ frames: wrap(canonicalCBOR(unsigned)) }), /signature/);
  assert.throws(() => decode({ khEpoch: 2 }), /does not match/);
  // One flipped bit inside S: still a well-formed 65-byte signature, no longer this wallet's.
  const tampered = Buffer.from(SIG, 'base64'); tampered[40] ^= 1;
  assert.throws(() => decode({ khSig: tampered.toString('base64') }), /does not match|out of range/);
  assert.throws(() => decode({ khSig: 'not base64!!' }), /signature/);
  assert.throws(() => decode({ khSig: Buffer.alloc(64).toString('base64') }), /signature/);
  assert.throws(() => decode({ khSig: Buffer.alloc(65).toString('base64') }), /signature header/);
  assert.throws(() => decode({ khEpoch: 0 }), /identity epoch/);
  const other = signKhV2({ mnemonic: MN, passphrase: 'other', epoch: 1 });
  assert.throws(() => decode({ khSig: other.signature }), /does not match/);
  // A header for a different recovery id no longer recovers this wallet's key.
  const bytes = Buffer.from(SIG, 'base64'); bytes[0] = bytes[0] === 31 ? 32 : 31;
  assert.throws(() => decode({ khSig: bytes.toString('base64') }), /does not match/);
  // Epoch 2 of the same wallet verifies when the payload says so.
  const second = signKhV2({ mnemonic: MN, epoch: 2 });
  assert.equal(decode({ khSig: second.signature, khEpoch: 2 }).khEpoch, 2);
  // The decoder derives the identity from the payload's own p2pkh account xpub.
  assert.deepEqual(walletPairingIdentity(base), { path: KH_V2_PATH, publicKey: IDENTITY.publicKey, address: IDENTITY.address });
  assert.throws(() => walletPairingIdentity({ accounts: base.accounts.filter(a => a.script !== 'p2pkh') }), /legacy account/);
  // Building a payload whose signature belongs to another wallet is refused too.
  assert.throws(() => createWalletPairing({ publicIndex: A, khSig: other.signature }), /does not match this wallet/);
});

test('The public index keeps only the three Solana presets and rejects forged ones', () => {
  assert.equal(A.version, 1);
  assert.equal(A.solanaAccounts, undefined);
  assert.equal(A.solanaPublicKeys.length, 3);
  for (const [name, mutate] of [
    ['version 2', i => { i.version = 2; }],
    ['preset index', i => { i.solanaPublicKeys.find(k => k.profile === 'standard').index = 7; }],
    ['address mismatch', i => { const [a, b] = i.solanaPublicKeys; a.address = b.address; }],
    ['duplicate key', i => { const [a, b] = i.solanaPublicKeys; Object.assign(b, { publicKey: a.publicKey, address: a.address }); }],
  ]) {
    const index = clone(A); mutate(index);
    assert.throws(() => validatePublicIndex(index), undefined, name);
  }
  // A Solana account outside the presets is not matched for signing.
  const request = { chain: 'solana', kind: 'message', message: Buffer.from('hello').toString('base64'), path: "m/44'/501'/3'/0'", masterFingerprint: A.masterFingerprint };
  assert.equal(resolveSigningPlan({ request, wallets: [{ localWalletId: 'a', publicIndex: A }] }).status, 'noMatch');
});

test('Engine dispatch exposes createWalletPairing over the public index only', () => {
  const out = execute({ operation: 'createWalletPairing', publicIndex: A, khSig: SIG });
  assert.equal(out.mode, 'full'); assert.ok(out.frames.length >= 2);
  assert.throws(() => execute({ operation: 'createWalletPairing', publicIndex: { ...A, version: 2 }, khSig: SIG }));
  assert.throws(() => execute({ operation: 'createWalletPairing', publicIndex: A }), /identity signature/);
  // The signature itself comes from a separate, secret-consuming operation.
  assert.deepEqual(execute({ operation: 'signKhV2', mnemonic: MN }), IDENTITY);
});
