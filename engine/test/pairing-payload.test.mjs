import test from 'node:test';
import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { UR, URDecoder, UREncoder } from '@ngraveio/bc-ur';
import { CryptoAccount, CryptoHDKey, CryptoMultiAccounts, extend } from '@keystonehq/bc-ur-registry';
import { derivePublicIndex } from '../src/public-index.js';
import { createPublicPairing, describeQR, describeUR, encodeQR, CBOR_TAG_NAMES, UR_FIELD_NAMES } from '../protocols.js';
import { dispatch } from '../src/index.js';

const MN = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const A = derivePublicIndex({ mnemonic: MN }), FP = 0x73c5da0a;
const ur = frames => { const d = new URDecoder(); frames.forEach(f => d.receivePart(f)); assert.ok(d.isComplete()); return d.resultUR(); };
const one = (object, name) => { assert.deepEqual(Object.keys(object), [name]); return object[name]; };
const plain = value => JSON.parse(JSON.stringify(value));
const components = path => path.slice(2).split('/').flatMap(p => [Number(p.replace("'", '')), p.endsWith("'")]);

// Every request ConnectView can make.
const requests = [
  ...['native', 'taproot', 'nested', 'legacy'].flatMap(profile => ['accountXpub', 'address'].map(outputMode => ({ chain: 'bitcoin', profile, outputMode }))),
  ...['multisig-native', 'multisig-nested'].map(profile => ({ chain: 'bitcoin', profile, outputMode: 'accountXpub' })),
  ...['wallet', 'address'].map(outputMode => ({ chain: 'evm', profile: 'standard', outputMode })),
  ...['standard', 'trust', 'legacy'].flatMap(profile => ['wallet', 'address'].map(outputMode => ({ chain: 'solana', profile, outputMode }))),
  ...[0, 99, 100, 2147483647].map(index => ({ chain: 'tron', profile: 'standard', outputMode: 'address', index })),
];

test('every coin-level export carries the payload read back from its own frames', () => {
  for (const request of requests) for (const fragmentLength of [undefined, 40]) {
    const qr = createPublicPairing({ publicIndex: A, ...request, fragmentLength });
    if (qr.type === 'address') {
      assert.equal(qr.payloadFormat, 'text'); assert.equal(qr.payload, qr.frames[0]); assert.equal(qr.payload, qr.address);
      assert.equal(qr.payloadBytes, Buffer.byteLength(qr.address));
      continue;
    }
    const { cbor, type } = ur(qr.frames);
    assert.equal(type, qr.type); assert.equal(qr.payloadFormat, 'json'); assert.equal(qr.payloadBytes, cbor.length);
    assert.deepEqual(plain(qr.payload), plain(describeUR(type, cbor)));
    // Split into many fountain parts, the frames still describe the same object.
    if (fragmentLength) assert.deepEqual(plain(qr.payload), plain(createPublicPairing({ publicIndex: A, ...request }).payload));
    // Public material only.
    const text = JSON.stringify(qr.payload);
    assert.ok(!/xprv|tprv|"is-private":true|"is-master":true/.test(text));
  }
});

test('payload names match the registries and an independent parser', () => {
  extend.cbor.patchTags([409]);
  const scripts = { native: ['witness-public-key-hash'], taproot: ['taproot'], nested: ['script-hash', 'witness-public-key-hash'], legacy: ['public-key-hash'],
    'multisig-native': ['witness-script-hash'], 'multisig-nested': ['script-hash', 'witness-script-hash'] };
  for (const [profile, wrappers] of Object.entries(scripts)) {
    const node = A.bitcoinPublicNodes.find(n => n.scriptProfile === profile), qr = createPublicPairing({ publicIndex: A, chain: 'bitcoin', profile });
    assert.deepEqual(Object.keys(qr.payload), ['master-fingerprint', 'output-descriptors']);
    assert.equal(qr.payload['master-fingerprint'], FP);
    let hd = qr.payload['output-descriptors'][0]; for (const name of [...wrappers, 'crypto-hdkey']) hd = one(hd, name);
    const cbor = ur(qr.frames).cbor;
    const reg = profile === 'taproot' ? CryptoHDKey.fromDataItem(extend.decodeToDataItem(cbor).getData()[2][0].getData())
      : CryptoAccount.fromCBOR(cbor).getOutputDescriptors()[0].getHDKey();
    assert.equal(reg.getBip32Key(), node.xpub);
    assert.equal(hd['key-data'], node.publicKey); assert.equal(hd['chain-code'], node.chainCode);
    assert.equal(hd['parent-fingerprint'], parseInt(node.parentFingerprint, 16)); assert.equal(hd['is-private'], false);
    const origin = one(hd.origin, 'crypto-keypath');
    assert.deepEqual(origin.components, components(node.originPath)); assert.equal(origin['source-fingerprint'], FP);
    assert.equal(origin.depth, reg.getOrigin().getDepth()); assert.deepEqual(plain(one(hd['use-info'], 'crypto-coin-info')), {});
    assert.equal(hd.name, 'BitTool Signer'); assert.equal(hd.note, 'BitTool Signer public account');
  }
  const evm = createPublicPairing({ publicIndex: A, chain: 'evm', outputMode: 'wallet' }).payload;
  assert.equal(evm['key-data'], A.evmAccountNode.publicKey); assert.equal(evm['chain-code'], A.evmAccountNode.chainCode);
  assert.equal(one(evm['use-info'], 'crypto-coin-info').type, 60);
  assert.deepEqual(one(evm.children, 'crypto-keypath').components, [0, false, [], false]);
  assert.equal(CryptoHDKey.fromCBOR(ur(createPublicPairing({ publicIndex: A, chain: 'evm' }).frames).cbor).getBip32Key(), A.evmAccountNode.xpub);
  for (const key of A.solanaPublicKeys) {
    const qr = createPublicPairing({ publicIndex: A, chain: 'solana', profile: key.profile });
    assert.deepEqual(Object.keys(qr.payload), ['master-fingerprint', 'keys', 'device', 'version']);
    const hd = one(qr.payload.keys[0], 'crypto-hdkey');
    assert.equal(hd['key-data'], key.publicKey); assert.equal(hd['chain-code'], undefined);
    assert.equal(hd['key-data'], CryptoMultiAccounts.fromCBOR(ur(qr.frames).cbor).getKeys()[0].getKey().toString('hex'));
    assert.deepEqual(one(hd.origin, 'crypto-keypath').components, components(key.path));
    assert.equal(one(hd['use-info'], 'crypto-coin-info').type, 501);
    assert.equal(qr.payload.device, 'BitTool Signer'); assert.equal(qr.payload.version, '1.0.0');
  }
  // A one-key object is a tag only: no tag name is also a field name.
  const fields = new Set(Object.values(UR_FIELD_NAMES).flat());
  for (const name of Object.values(CBOR_TAG_NAMES)) assert.equal(fields.has(name), false, name);
});

test('the same helper describes signing responses', () => {
  const id = '9b1deb4d3b7d4bad9bdd2b0d7b3dcb6d';
  const eth = describeQR(encodeQR({ type: 'eth-signature', payload: 'ab'.repeat(64) + '1b', requestId: id }));
  assert.deepEqual(plain(eth.payload), { 'request-id': { uuid: id }, signature: 'ab'.repeat(64) + '1b' });
  const sol = describeQR(encodeQR({ type: 'sol-signature', payload: 'cd'.repeat(64), requestId: id }));
  assert.deepEqual(plain(sol.payload), { 'request-id': { uuid: id }, signature: 'cd'.repeat(64) });
  // A UR that holds one byte string is shown as hex.
  const bytes = describeQR({ type: 'bytes', frames: [UREncoder.encodeSinglePart(new UR(Buffer.from('4401020304', 'hex'), 'bytes'))] });
  assert.deepEqual(bytes, { payloadFormat: 'hex', payload: '01020304', payloadBytes: 5 });
  // A BBQr frame is never mistaken for a plain-text payload.
  assert.throws(() => describeQR({ frames: ['B$2P0100AAAA'] }), /one frame/);
});

test('the payload crosses the JSON dispatch boundary unchanged', () => {
  const response = JSON.parse(dispatch(JSON.stringify({ operation: 'createPublicPairing', publicIndex: A, chain: 'bitcoin', profile: 'native', outputMode: 'accountXpub' })));
  assert.equal(response.ok, true); assert.equal(response.result.payloadFormat, 'json');
  assert.equal(response.result.payload['master-fingerprint'], FP);
  const address = JSON.parse(dispatch(JSON.stringify({ operation: 'createPublicPairing', publicIndex: A, chain: 'tron', outputMode: 'address', index: 5 }))).result;
  assert.equal(address.payloadFormat, 'text'); assert.equal(address.payload, address.address);
});
