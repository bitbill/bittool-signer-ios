import test from 'node:test';
import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { deflateRawSync } from 'node:zlib';
import { createRequire } from 'node:module';
import { UR, URDecoder, UREncoder } from '@ngraveio/bc-ur';
import { CryptoAccount, CryptoHDKey, CryptoMultiAccounts, CryptoPSBT } from '@keystonehq/bc-ur-registry';
import { EthSignRequest, ETHSignature } from '@keystonehq/bc-ur-registry-eth';
import { SolSignRequest, SolSignature } from '@keystonehq/bc-ur-registry-sol';
import { HDKey } from '@scure/bip32';
import { base58, base32nopad } from '@scure/base';
import { getBytes, verifyMessage, verifyTypedData, Transaction, recoverAddress } from 'ethers';
import { execute, dispatch } from '../src/index.js';
import { createPairing, decodeQR, decodePayload, encodeQR, encodeResponse, parseProtocolJSON, ProtocolError } from '../protocols.js';

const id = Buffer.from('8f235e99e6e84044a51d51ec3ec942b0', 'hex');
const fingerprint = Buffer.from('1234abcd', 'hex');
const path = "m/44'/60'/0'/0/0";
const uuid = '8f235e99-e6e8-4044-a51d-51ec3ec942b0';
const single = item => item.toUREncoder(1000).nextPart();
const readFrames = frames => { const decoder = new URDecoder(); frames.forEach(f => decoder.receivePart(f)); assert.ok(decoder.isComplete()); return decoder.resultUR(); };
const tpHeader = 'tron:signTransaction-version=1.0&protocol=TokenPocket&network=tron&chain_id=11111&data=';
// ETH currently pins a different registry release; its CBOR encoder requires
// DataItem instances from that same dependency, not the top-level BTC registry.
const { CryptoKeypath, PathComponent } = createRequire(import.meta.resolve('@keystonehq/bc-ur-registry-eth'))('@keystonehq/bc-ur-registry');
const registryPath = (path, fingerprint) => new CryptoKeypath(path.replace(/^m\//, '').split('/').map(part => new PathComponent({ index: Number(part.replace("'", '')), hardened: part.endsWith("'") })), fingerprint);

test('native dispatch preserves controlled protocol diagnostics without reflecting payload content', () => {
  const response = input => JSON.parse(dispatch(JSON.stringify(input)));
  assert.throws(() => decodeQR({ frames: ['unsupported-sensitive-fixture'] }), error =>
    error instanceof ProtocolError && error.code === 'QR_PROTOCOL' && error.message === 'Unsupported signing QR format');
  assert.deepEqual(response({ operation: 'decodeQR', frames: ['unsupported-sensitive-fixture'] }), {
    ok: false, error: { code: 'QR_PROTOCOL', message: 'Unsupported signing QR format' }
  });
  assert.deepEqual(response({ operation: 'decodeQR', frames: ['x'.repeat(4301)] }), {
    ok: false, error: { code: 'QR_PROTOCOL', message: 'QR frame size exceeds limits' }
  });
  assert.deepEqual(response({ operation: 'decodeQR', frames: ['ur:sensitive-metadata/aaaa'] }), {
    ok: false, error: { code: 'QR_PROTOCOL', message: 'Unsupported signing UR type' }
  });
  assert.deepEqual(response({ operation: 'decodeQR', frames: ['{"sensitive-key":1,"sensitive-key":2}'] }), {
    ok: false, error: { code: 'QR_PROTOCOL', message: 'Unsupported signing QR format' }
  });
  assert.equal(response({ operation: 'unknown' }).error.code, 'OPERATION');
});

test('native dispatch keeps upstream exceptions generic', () => {
  const generic = { ok: false, error: { code: 'INVALID_REQUEST', message: 'The payload is malformed, unsupported or inconsistent. No signature was produced.' } };
  assert.deepEqual(JSON.parse(dispatch(JSON.stringify({ operation: 'decodeQR', frames: ['ur:eth-sign-request/zz'] }))), generic);
});

test('imToken-style opaque request ID survives typed-transaction signing and independent response decoding', () => {
  const mnemonic = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
  const account = execute({ operation: 'deriveAccounts', mnemonic }).accounts.find(a => a.chain === 'evm');
  const transaction = Transaction.from({ type: 2, chainId: 1, nonce: 0, gasLimit: 21000n, maxFeePerGas: 2000000000n, maxPriorityFeePerGas: 1000000000n, to: '0x' + '22'.repeat(20), value: 1n });
  const base = EthSignRequest.constructETHRequest(Buffer.from(getBytes(transaction.unsignedSerialized)), 4, account.path, account.masterFingerprint, undefined, 1, account.address, 'imToken synthetic fixture');
  const requestId = Buffer.from('r-' + 'q'.repeat(34));
  const wire = new EthSignRequest({ requestId, signData: base.getSignData(), dataType: base.getDataType(), derivationPath: registryPath(base.getDerivationPath(), base.getSourceFingerprint()), chainId: base.getChainId(), address: base.getSignRequestAddress(), origin: base.getOrigin() });
  const decoded = JSON.parse(dispatch(JSON.stringify({ operation: 'decodeQR', frames: [single(wire)] })));
  assert.equal(decoded.ok, true);
  const { request } = decoded.result;
  assert.equal(request.transport.requestId, requestId.toString('hex'));
  assert.equal(request.transaction, transaction.unsignedSerialized);
  const review = execute({ operation: 'review', request });
  const result = execute({ operation: 'sign', request, mnemonic, reviewedHash: review.requestHash });
  const response = encodeResponse({ request, result });
  const independent = ETHSignature.fromCBOR(readFrames(response.frames).cbor);
  assert.deepEqual(independent.getRequestId(), requestId);
  assert.equal(recoverAddress(transaction.unsignedHash, '0x' + independent.getSignature().toString('hex')), account.address);
});

test('Ethereum opaque IDs are bounded bytes while Solana remains UUID-only', () => {
  const base = EthSignRequest.constructETHRequest(Buffer.from('fixture'), 3, path, fingerprint.toString('hex'));
  const withID = requestId => new EthSignRequest({ requestId, signData: base.getSignData(), dataType: base.getDataType(), derivationPath: registryPath(base.getDerivationPath(), base.getSourceFingerprint()) });
  for (const length of [1, 16, 36, 64]) {
    const requestId = Buffer.alloc(length, 0xff);
    const { request } = decodeQR({ frames: [single(withID(requestId))] });
    const encoded = encodeQR({ type: 'eth-signature', payload: 'ab'.repeat(65), requestId: request.transport.requestId });
    assert.deepEqual(ETHSignature.fromCBOR(readFrames(encoded.frames).cbor).getRequestId(), requestId);
  }
  for (const length of [0, 65]) {
    assert.throws(() => decodeQR({ frames: [single(withID(Buffer.alloc(length)))] }), /requestId has invalid length/);
    assert.throws(() => encodeQR({ type: 'eth-signature', payload: 'ab'.repeat(65), requestId: '00'.repeat(length) }), /requestId has invalid length/);
  }
  const rawQR = (cbor, type = 'eth-sign-request') => new UREncoder(new UR(Buffer.from(cbor, 'hex'), type), 800).nextPart();
  assert.throws(() => decodeQR({ frames: [rawQR('a101d8264101')] }), /Invalid request UUID tag/);
  assert.throws(() => decodeQR({ frames: [rawQR('a101d8256161')] }), /requestId must be bytes/);
  assert.throws(() => decodeQR({ frames: [rawQR('a101d8255824' + 'ff'.repeat(36), 'sol-sign-request')] }), /requestId has invalid length/);
  assert.throws(() => encodeQR({ type: 'sol-signature', payload: 'ab'.repeat(64), requestId: 'ff'.repeat(36) }), /requestId has invalid length/);
  const canonical = encodeQR({ type: 'eth-signature', payload: 'ab'.repeat(65), requestId: uuid });
  assert.deepEqual(ETHSignature.fromCBOR(readFrames(canonical.frames).cbor).getRequestId(), id);
  assert.throws(() => encodeQR({ type: 'eth-signature', payload: 'ab'.repeat(65), requestId: 'ab-cd' }), /Invalid hexadecimal bytes/);
});

test('MetaMask registry personal request retains UUID, path, fingerprint, and exact message bytes', () => {
  const wire = EthSignRequest.constructETHRequest(Buffer.from('00ff262be4b8ad', 'hex'), 3, path, fingerprint.toString('hex'), uuid, undefined, '01'.repeat(20), 'MetaMask');
  const { request } = decodeQR({ frames: [single(wire)] });
  assert.equal(request.kind, 'personal'); assert.equal(request.message, '0x00ff262be4b8ad');
  assert.equal(request.path, "m/44'/60'/0'/0/0"); assert.equal(request.masterFingerprint, '1234abcd');
  assert.equal(request.transport.requestId, id.toString('hex'));
  const signature = '11'.repeat(64) + '1b';
  const response = readFrames(encodeResponse({ request, result: { signature } }).frames);
  assert.equal(response.type, 'eth-signature');
  const parsed = ETHSignature.fromCBOR(response.cbor);
  assert.deepEqual(parsed.getRequestId(), id); assert.equal(parsed.getSignature().toString('hex'), signature);
});

test('Ethereum legacy response preserves variable length EIP155 v', () => {
  const signature = '22'.repeat(64) + '02004b';
  const qr = encodeQR({ type: 'eth-signature', payload: signature, requestId: id.toString('hex') });
  assert.equal(ETHSignature.fromCBOR(readFrames(qr.frames).cbor).getSignature().toString('hex'), signature);
});

test('Solflare message request/response uses raw Ed25519 key and detached 64-byte signature', () => {
  const pub = Buffer.alloc(32, 7);
  const wire = SolSignRequest.constructSOLRequest(Buffer.from('Hello, Solflare'), "m/44'/501'/0'/0'", fingerprint.toString('hex'), 2, uuid, pub.toString('hex'), 'Solflare');
  const { request } = decodeQR({ frames: [single(wire)] });
  assert.equal(request.chain, 'solana'); assert.equal(request.kind, 'message');
  assert.equal(request.address, base58.encode(pub)); assert.equal(request.masterFingerprint, '1234abcd');
  const signature = 'a5'.repeat(64);
  const response = readFrames(encodeResponse({ request, result: { signature } }).frames);
  const parsed = SolSignature.fromCBOR(response.cbor);
  assert.equal(response.type, 'sol-signature'); assert.deepEqual(parsed.getRequestId(), id);
  assert.equal(parsed.getSignature().toString('hex'), signature);
});

test('UR fountain recovers from unordered redundant frames without original first fragments', () => {
  const body = Buffer.concat([Buffer.from('70736274ff', 'hex'), Buffer.from(Array.from({ length: 1450 }, (_, i) => i % 251))]);
  const wire = new CryptoPSBT(body).toUR(); const encoder = new UREncoder(wire, 80);
  for (let i = 0; i < encoder.fragmentsLength; i++) encoder.nextPart();
  const mixed = Array.from({ length: encoder.fragmentsLength * 6 }, () => encoder.nextPart());
  const incomplete = decodeQR({ frames: [mixed[0]] }); assert.equal(incomplete.complete, false);
  const decoded = decodeQR({ frames: [...mixed.reverse(), mixed[0]] });
  assert.equal(decoded.complete, true); assert.equal(decoded.request.psbt, body.toString('base64'));
});

test('scanner rejects mixed fountain sessions and corrupted bytewords', () => {
  const make = fill => new UREncoder(new CryptoPSBT(Buffer.concat([Buffer.from('70736274ff', 'hex'), Buffer.alloc(300, fill)])).toUR(), 80);
  const a = make(1), b = make(2);
  assert.throws(() => decodeQR({ frames: [a.nextPart(), b.nextPart()] }), /Mixed UR fountain/);
  assert.throws(() => decodeQR({ frames: ['ur:crypto-psbt/aaaaaaaaaaaaaa'] }));
});

test('unsafe CBOR, duplicate labels, and unknown signing types are rejected', () => {
  const qr = cbor => new UREncoder(new UR(Buffer.from(cbor, 'hex'), 'eth-sign-request'), 800).nextPart();
  assert.throws(() => decodeQR({ frames: [qr('a203010303')] }), /Duplicate CBOR map key/);
  assert.throws(() => decodeQR({ frames: [qr('a1041b0020000000000000')] }), /exact numeric range/);
  const invalid = EthSignRequest.constructETHRequest(Buffer.from([0xc0]), 9, path, fingerprint.toString('hex'));
  assert.throws(() => decodeQR({ frames: [single(invalid)] }), /data type/);
  assert.throws(() => decodeQR({ frames: ['x'.repeat(4301)] }), /frame size/);
});

test('strict JSON rejects duplicate keys, rounded amounts, bad encoding, and trailing data', () => {
  assert.throws(() => parseProtocolJSON('{"value":1,"value":2}'), /Duplicate/);
  assert.throws(() => parseProtocolJSON('{"value":9007199254740993}'), /Unsafe/);
  assert.throws(() => parseProtocolJSON('{"a":1}false'), /Trailing/);
  assert.throws(() => decodeQR({ frames: [tpHeader + '%7B%22tx%22%3A1%7D'] }), /Unsupported/);
  assert.throws(() => decodeQR({ frames: ['tronlink:something'] }), /Unsupported/);
});

test('plain PSBT returns the matching static representation', () => {
  const payload = Buffer.from('70736274ff0000', 'hex');
  for (const encoding of ['hex', 'base64']) {
    const { request } = decodeQR({ frames: [payload.toString(encoding)] });
    assert.deepEqual(encodeResponse({ request, result: { psbt: payload.toString('base64') } }).frames, [payload.toString(encoding)]);
  }
});

test('MetaMask UR completes decode, review, real signing, response and independent signer recovery', () => {
  const mnemonic = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
  const account = execute({ operation: 'deriveAccounts', mnemonic }).accounts.find(a => a.chain === 'evm');
  const wire = EthSignRequest.constructETHRequest(Buffer.from('BitTool Signer interoperability'), 3, account.path, account.masterFingerprint, uuid, undefined, account.address, 'MetaMask');
  const { request } = execute({ operation: 'decodeQR', frames: [single(wire)] });
  const review = execute({ operation: 'review', request });
  const result = execute({ operation: 'sign', request, mnemonic, reviewedHash: review.requestHash });
  const response = execute({ operation: 'encodeResponse', request, result });
  const envelope = ETHSignature.fromCBOR(readFrames(response.frames).cbor);
  assert.deepEqual(envelope.getRequestId(), id);
  assert.equal(verifyMessage(getBytes(request.message), '0x' + envelope.getSignature().toString('hex')), account.address);
});

test('EIP712 JSON inside the public UR preserves nested fields and verifiable signing', () => {
  const mnemonic = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
  const account = execute({ operation: 'deriveAccounts', mnemonic }).accounts.find(a => a.chain === 'evm');
  const typedData = { domain: { name: 'BitTool Signer test', version: '1', chainId: 1, verifyingContract: '0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC' }, primaryType: 'Message', types: { Message: [{ name: 'contents', type: 'string' }] }, message: { contents: 'No funds: fixture only' } };
  const wire = EthSignRequest.constructETHRequest(Buffer.from(JSON.stringify(typedData)), 2, account.path, account.masterFingerprint, uuid, 1, account.address);
  const { request } = decodeQR({ frames: [single(wire)] });
  const review = execute({ operation: 'review', request });
  const result = execute({ operation: 'sign', request, mnemonic, reviewedHash: review.requestHash });
  assert.equal(verifyTypedData(typedData.domain, typedData.types, typedData.message, '0x' + result.signature), account.address);
});

test('file import accepts full-size public PSBT and rejects private JSON transports', () => {
  const binary = Buffer.concat([Buffer.from('70736274ff', 'hex'), Buffer.alloc(131072 - 5, 1)]);
  assert.equal(decodePayload({ payload: binary.toString('base64') }).request.psbt, binary.toString('base64'));
  assert.throws(() => decodePayload({ payload: 'A'.repeat(262145) }), /payload exceeds/);
  for (const frame of ['{"chain":"evm","kind":"personal","message":"0x41"}', tpHeader + '{}', 'tp:multiFragment-version=1.0&protocol=TokenPocket&data={}', 'ur:keystone-sign-request/aaaa']) {
    assert.throws(() => decodeQR({ frames: [frame] }), /Unsupported/);
    assert.throws(() => decodePayload({ payload: frame }), /Unsupported/);
  }
  assert.throws(() => encodeResponse({request:{chain:'tron',transport:{type:'tokenpocket'}},result:{signature:'aa'.repeat(65)}}), /Unsupported response profile/);
});

test('BBQR hex and base32 reconstruct PSBT in reverse order and return matching protocol', () => {
  const data = Buffer.concat([Buffer.from('70736274ff', 'hex'), Buffer.from(Array.from({ length: 801 }, (_, i) => i % 256))]);
  for (const encoding of ['H', '2']) {
    const qr = encodeQR({ type: 'bbqr-psbt', payload: data.toString('hex'), fragmentLength: 100, bbqrEncoding: encoding });
    assert.ok(qr.frames.length > 1); assert.equal(qr.frames[0].slice(0, 4), `B$${encoding}P`);
    const { request } = decodeQR({ frames: [...qr.frames].reverse() }); assert.equal(request.psbt, data.toString('base64'));
    assert.equal(request.transport.type, 'bbqr-psbt'); assert.equal(decodeQR({ frames: [qr.frames[1]] }).complete, false);
    const reply = encodeResponse({ request, result: { psbt: request.psbt } }); assert.ok(reply.frames[0].startsWith(`B$${encoding}P`));
    const encoded = qr.frames.map(part => part.slice(8)).join('');
    assert.deepEqual(encoding === 'H' ? Buffer.from(encoded, 'hex') : Buffer.from(base32nopad.decode(encoded)), data);
  }
});

test('BBQR Z raw-DEFLATE uses the specified 10-bit zlib window and rejects decompression bombs', () => {
  const data = Buffer.concat([Buffer.from('70736274ff', 'hex'), Buffer.alloc(20000, 7)]);
  const compressed = deflateRawSync(data, { windowBits: 10, level: 9 });
  const qr = 'B$ZP0100' + base32nopad.encode(compressed);
  const { request } = decodeQR({ frames: [qr] }); assert.equal(request.psbt, data.toString('base64'));
  assert.ok(encodeResponse({ request, result: { psbt: request.psbt } }).frames[0].startsWith('B$2P'));
  const bomb = deflateRawSync(Buffer.alloc(500000, 1), { windowBits: 10, level: 9 });
  assert.throws(() => decodeQR({ frames: ['B$ZP0100' + base32nopad.encode(bomb)] }), /decompressed payload exceeds/);
  assert.throws(() => decodeQR({ frames: [qr.slice(0, -4)] }));
});

test('BBQR rejects mixed headers, conflicting indexes, invalid alphabet and unequal blocks', () => {
  assert.throws(() => decodeQR({ frames: ['B$HP020070736274FF', 'B$2P0201AAAA'] }), /Mixed BBQR/);
  assert.throws(() => decodeQR({ frames: ['B$HP020070736274FF', 'B$HP02007073627400'] }), /Conflicting BBQR/);
  assert.throws(() => decodeQR({ frames: ['B$HP0100GG'] }), /encoded data/);
  assert.throws(() => decodeQR({ frames: ['B$2P0200ABC', 'B$2P0201DE'] }), /5-byte boundary/);
  assert.throws(() => decodeQR({ frames: ['B$HP030070736274FF', 'B$HP0301FF'] }), /Unequal BBQR/);
  assert.throws(() => decodeQR({ frames: ['B$HP020070736274FF', 'B$HP0201' + 'FF'.repeat(10)] }), /Oversized final/);
});
