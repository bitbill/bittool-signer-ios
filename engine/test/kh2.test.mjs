import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mnemonicToSeedSync } from '@scure/bip39';
import { signKhV2, verifyKhV2, khV2Message, khV2FromSignature, khV2SignatureBytes, bitcoinMessageDigest,
         khV2PublicIdentity, requireKhV2, KH_V2_PATH, KH_V2_AUTH_INDEX, KH_V2_MESSAGE_PREFIX } from '../src/kh2.js';
import { derivePublicIndex, validatePublicIndex } from '../src/public-index.js';
import { execute } from '../src/index.js';

const MN = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';

/** Ownbit's published KH v2 vectors, which the backend's own implementation is
 * checked against. They pin the digest, the 65-byte layout, recovery and the
 * S-folding inside `kh2` independently of BitTool's derivation. */
const OWNBIT = [
  { name: 'key01 epoch 1', epoch: 1, publicKey: '0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798',
    signature: 'H+QkGqqNN6WleQ2GXm+egxEfoy29cgFbeTK2weNWa9SjalsU+V2yYxn45bK5aEOEQSe+iYEgftyCtIXnWgGf04E=',
    kh2: '202afd68637ff5ea9cf31362be78242bbfa3c399765c7035c3cf0700ceccf4a5' },
  { name: 'key01 epoch 2', epoch: 2, publicKey: '0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798',
    signature: 'H83RKH8dUSaPmluw8AB/aquOWRHSCjieCwzPWJ//4ZtAKZdRhzgKI1Z82TIe0h7tEIh8bNOVH6LQBoRUd/tOh48=',
    kh2: 'b9c8544303e5cf4dd5b0d21e13990ccae5d8faa770d4be27932ff795c572843c' },
  { name: 'key02 epoch 1', epoch: 1, publicKey: '02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5',
    signature: 'H148MsTzVO7Ejon1zBMsx065AlJBKKNcCXr0ikgrEsLHTRjTNBdnUjObxbj2a0refWnpN4AbeSZo+xMbvRtAp+0=',
    kh2: '4c6d49f91b5fe091a17558d0b2615cdb9922a655933bf68a26bc8f1a3d1abf1c' },
  { name: 'key02 epoch 2', epoch: 2, publicKey: '02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5',
    signature: 'IIZLRgBm5s495SrLQjW+2jmq9s5VPsM+mttRrVfGV0adHNbAV00pdBts2ypwf540iQn3hth3m4nfKfb62/EDRqU=',
    kh2: '8efb3e5cfd04feab1928e76a20ca70cf39c1666b06f914e2f6058235a1623bb0' },
];
/** The same R as `key01 epoch 1` with S in the high half and the matching header.
 * It must not verify (malleated), but it has to fold to the same `kh2`. */
const HIGH_S = { signature: 'IOQkGqqNN6WleQ2GXm+egxEfoy29cgFbeTK2weNWa9SjlaTrBqJNnOYHGk1Gl7x7vZLwU2WOycO5C0x3Ms6WbcA=',
  publicKey: OWNBIT[0].publicKey, kh2: OWNBIT[0].kh2 };
/** Ownbit's HD vector is on BitTool's own identity path and the same test phrase,
 * so BitTool Signer has to reproduce it byte for byte. */
const BITTOOL = [
  { epoch: 1, signature: 'IDbq1RPzOmq1q37JrcXcPBa9vVjrpG0B+9/ltJXQjfWlDGoP/gwHDMeGFH5XdL693wnhbeAsBdfRj7x70s94Lm4=',
    kh2: '4fb494ddc6dac144c283c3a24f92156937c855a1b2e3997981ef510465d948fc' },
  { epoch: 2, signature: 'HyJlRiut4wBA9pcd0q6BFqC1ghMJUhpRd82P3pUS+LNLBY0MOquhqW11cNTf1QGYSHUJ3b8N930O+SvrVOIdYqE=',
    kh2: 'af8fde9ee528be6f31de021820fa7490b1584b0b753b29e12443927135ec5292' },
];
const PUBLIC_KEY = '02a61d47c2a0326f197d2d42bfc27b4171f7870e6b3d7ad37f3f210c3d602bab1c';
const ADDRESS = '1N8ju3BdMHttCNBJ4d8v3eCrpzdLk1m9Vo';

test('The signed digest is the Bitcoin Signed Message digest of exactly one sentence', () => {
  assert.equal(KH_V2_MESSAGE_PREFIX, 'OwnbitAuth:v2:epoch=');
  assert.equal(khV2Message(1), 'OwnbitAuth:v2:epoch=1');
  assert.equal(khV2Message(7), 'OwnbitAuth:v2:epoch=7');
  // Recomputed here from the rule rather than from the module: 0x18, the magic
  // string, the message length, the message, hashed with SHA-256 twice.
  const independent = message => {
    const magic = Buffer.from('Bitcoin Signed Message:\n', 'utf8'), body = Buffer.from(message, 'utf8');
    const preimage = Buffer.concat([Buffer.from([magic.length]), magic, Buffer.from([body.length]), body]);
    return createHash('sha256').update(createHash('sha256').update(preimage).digest()).digest();
  };
  for (const epoch of [1, 2, 9, 1000000])
    assert.deepEqual(Buffer.from(bitcoinMessageDigest(khV2Message(epoch))), independent(khV2Message(epoch)), String(epoch));
  // There is no way to ask for another text, and no epoch outside 1..1000000.
  for (const bad of [0, -1, 1.5, '1', null, undefined, 1000001, Number.MAX_SAFE_INTEGER])
    assert.throws(() => khV2Message(bad), /epoch/, String(bad));
});

test("Ownbit's published vectors verify, and a high-S copy folds to the same kh2", () => {
  for (const v of OWNBIT) {
    assert.ok(verifyKhV2({ signature: v.signature, epoch: v.epoch, publicKey: v.publicKey }), v.name);
    assert.equal(khV2FromSignature(v.signature), v.kh2, v.name);
    // The signature belongs to its own epoch and to no other.
    assert.ok(!verifyKhV2({ signature: v.signature, epoch: v.epoch === 1 ? 2 : 1, publicKey: v.publicKey }), v.name + ' epoch');
  }
  assert.ok(!verifyKhV2({ signature: HIGH_S.signature, epoch: 1, publicKey: HIGH_S.publicKey }), 'malleated S is refused');
  assert.equal(khV2FromSignature(HIGH_S.signature), HIGH_S.kh2, 'but it still identifies the same wallet');
});

test('BitTool Signer reproduces the vectors for its own identity path', () => {
  for (const v of BITTOOL) {
    const out = signKhV2({ mnemonic: MN, epoch: v.epoch });
    assert.deepEqual(out, { epoch: v.epoch, message: 'OwnbitAuth:v2:epoch=' + v.epoch, path: KH_V2_PATH,
      walletKeyId: derivePublicIndex({ mnemonic: MN }).walletKeyId,
      publicKey: PUBLIC_KEY, address: ADDRESS, signature: v.signature, kh2: v.kh2 });
    // RFC 6979: the same input always gives the same bytes, so re-signing after a
    // reinstall produces the identity the backend already stored.
    assert.deepEqual(signKhV2({ mnemonic: MN, epoch: v.epoch }), out);
  }
  assert.equal(KH_V2_PATH, "m/44'/0'/0'/0/" + KH_V2_AUTH_INDEX);
  assert.equal(KH_V2_AUTH_INDEX, 1000000000);
  // The seed the host derives natively gives the same signature as the phrase.
  assert.deepEqual(signKhV2({ seed: Buffer.from(mnemonicToSeedSync(MN)).toString('hex'), epoch: 1 }), signKhV2({ mnemonic: MN, epoch: 1 }));
  // A BIP39 passphrase is a different wallet and therefore a different identity.
  const other = signKhV2({ mnemonic: MN, passphrase: 'other', epoch: 1 });
  assert.notEqual(other.kh2, BITTOOL[0].kh2);
  assert.notEqual(other.address, ADDRESS);
});

test('The identity derived from public data alone matches the signing key', () => {
  const cache = validatePublicIndex(derivePublicIndex({ mnemonic: MN }));
  assert.deepEqual(khV2PublicIdentity(cache), { path: KH_V2_PATH, publicKey: PUBLIC_KEY, address: ADDRESS });
  assert.deepEqual(requireKhV2(cache, BITTOOL[0].signature, 1), khV2PublicIdentity(cache));
  assert.throws(() => requireKhV2(cache, BITTOOL[1].signature, 1), /does not match this wallet/);
  assert.throws(() => requireKhV2(cache, signKhV2({ mnemonic: MN, passphrase: 'other' }).signature, 1), /does not match this wallet/);
});

test('A signature that is not 65 well-formed bytes is refused before anything else', () => {
  const ok = Buffer.from(BITTOOL[0].signature, 'base64');
  assert.equal(ok.length, 65);
  assert.equal(ok[0], 32, 'header 27 + recovery id + 4 for a compressed key');
  for (const [name, value] of [
    ['empty', ''], ['not base64', '!'.repeat(88)], ['too short', Buffer.alloc(64).toString('base64')],
    ['too long', Buffer.alloc(66).toString('base64')], ['not a string', 5],
    ['header 26', Buffer.concat([Buffer.from([26]), ok.subarray(1)]).toString('base64')],
    ['header 43', Buffer.concat([Buffer.from([43]), ok.subarray(1)]).toString('base64')],
    ['zero R', Buffer.concat([ok.subarray(0, 1), Buffer.alloc(32), ok.subarray(33)]).toString('base64')],
    ['zero S', Buffer.concat([ok.subarray(0, 33), Buffer.alloc(32)]).toString('base64')],
    ['R = n', Buffer.concat([ok.subarray(0, 1), Buffer.from('fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141', 'hex'), ok.subarray(33)]).toString('base64')],
  ]) assert.throws(() => khV2SignatureBytes(value), /signature|base64/, name);
  assert.throws(() => verifyKhV2({ signature: BITTOOL[0].signature, epoch: 1, publicKey: PUBLIC_KEY.slice(2) }), /public key|hexadecimal/);
});

test('Engine dispatch signs the identity and nothing else', () => {
  assert.deepEqual(execute({ operation: 'signKhV2', mnemonic: MN, epoch: 2 }), signKhV2({ mnemonic: MN, epoch: 2 }));
  assert.equal(execute({ operation: 'signKhV2', mnemonic: MN }).epoch, 1, 'epoch 1 by default');
  // Nothing in the operation can redirect the key or the text.
  const out = execute({ operation: 'signKhV2', mnemonic: MN, path: "m/44'/0'/0'/0/0", message: 'send everything' });
  assert.equal(out.path, KH_V2_PATH);
  assert.equal(out.message, 'OwnbitAuth:v2:epoch=1');
  assert.throws(() => execute({ operation: 'signKhV2' }), /recovery phrase|seed/i);
  assert.throws(() => execute({ operation: 'signKhV2', mnemonic: MN, epoch: 0 }), /epoch/);
  const capabilities = execute({ operation: 'capabilities' });
  assert.equal(capabilities.walletIdentity.path, KH_V2_PATH);
  assert.equal(capabilities.version, '1.1.0');
});
