// Proposed engine test: every signed-response type the app can produce carries a
// payload view decoded again from its own frames, named per registry, and public only.
import test from 'node:test';
import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { UR, URDecoder, UREncoder } from '@ngraveio/bc-ur';
import { CryptoPSBT, extend } from '@keystonehq/bc-ur-registry';
import { EthSignRequest, ETHSignature } from '@keystonehq/bc-ur-registry-eth';
import { SolSignRequest, SolSignature } from '@keystonehq/bc-ur-registry-sol';
import { Transaction as EthTx, getBytes, verifyMessage, verifyTypedData, recoverAddress, Signature, HDNodeWallet } from 'ethers';
import { Transaction, p2wpkh, p2tr, NETWORK } from '@scure/btc-signer';
import { HDKey } from '@scure/bip32';
import { mnemonicToSeedSync } from '@scure/bip39';
import { base58, base58check, base32nopad } from '@scure/base';
import { sha256 } from '@noble/hashes/sha2.js';
import { ed25519 } from '@noble/curves/ed25519.js';
import { secp256k1 } from '@noble/curves/secp256k1.js';
import { execute } from '../src/index.js';
import { derivePublicIndex, derivePublicKeyAt } from '../src/public-index.js';
import { decodeQR, encodeQR, encodeResponse, describeQR } from '../protocols.js';
import { bytesToHex, hexToBytes, toBase64, concat, short, utf8 } from '../src/util.js';
import { solanaKey } from '../src/keys.js';

const MN = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const A = derivePublicIndex({ mnemonic: MN }), FP = A.masterFingerprint;
const UUID = '8f235e99-e6e8-4044-a51d-51ec3ec942b0', UUID_HEX = UUID.replace(/-/g, '');
const single = item => item.toUREncoder(1000).nextPart();
const urOf = frames => { const d = new URDecoder(); frames.forEach(f => d.receivePart(f)); assert.ok(d.isComplete()); return d.resultUR(); };

// The app's exact order: decodeQR -> resolveSigningPlan -> signPlanTask -> encodeResponse.
function signFrames(frames, fragmentLength) {
  const { request } = execute({ operation: 'decodeQR', frames });
  const plan = execute({ operation: 'resolveSigningPlan', request, wallets: [{ localWalletId: 'w', publicIndex: A }] });
  assert.equal(plan.status, 'ready', plan.message);
  const result = execute({ operation: 'signPlanTask', request, plan, taskId: plan.tasks[0].id, mnemonic: MN, riskAcknowledged: true });
  const response = execute({ operation: 'encodeResponse', request, result, ...(fragmentLength ? { fragmentLength } : {}) });
  return { request, result, response };
}

// Minimal CBOR writer for the TRON request (no TRON registry package is a dependency).
function cbor(v) {
  const head = (m, n) => n < 24 ? Buffer.from([m << 5 | n]) : n < 256 ? Buffer.from([m << 5 | 24, n]) : n < 65536 ? Buffer.from([m << 5 | 25, n >> 8, n & 255]) : Buffer.from([m << 5 | 26, n >>> 24, n >> 16 & 255, n >> 8 & 255, n & 255]);
  if (Buffer.isBuffer(v)) return Buffer.concat([head(2, v.length), v]);
  if (typeof v === 'boolean') return Buffer.from([v ? 0xf5 : 0xf4]);
  if (typeof v === 'string') return Buffer.concat([head(3, Buffer.byteLength(v)), Buffer.from(v)]);
  if (Array.isArray(v)) return Buffer.concat([head(4, v.length), ...v.map(cbor)]);
  if (v instanceof Map) return Buffer.concat([head(5, v.size), ...[...v].flatMap(([k, x]) => [cbor(k), cbor(x)])]);
  if (v && v.tag !== undefined) return Buffer.concat([head(6, v.tag), cbor(v.value)]);
  return head(0, v);
}
const keypath = path => ({ tag: 304, value: new Map([[1, path.replace(/^m\//, '').split('/').flatMap(p => [Number(p.replace("'", '')), p.endsWith("'")])], [2, parseInt(FP, 16)]]) });
const pbVar = n => { n = BigInt(n); const b = []; do { const v = Number(n & 127n); n >>= 7n; b.push(v | (n ? 128 : 0)); } while (n); return new Uint8Array(b); };
const pbN = (k, n) => concat(pbVar(k * 8), pbVar(n)), pbB = (k, b) => concat(pbVar(k * 8 + 2), pbVar(b.length), b);

const tron0 = derivePublicKeyAt(A, 'tron', "m/44'/195'/0'/0/0");
function tronRequestUR(dataType) {
  const owner = base58check(sha256).decode(tron0.address), to = base58check(sha256).decode('TJRabPrwbZy45sbavfcjinPJC18kjpRTv8');
  const any = concat(pbB(1, utf8('type.googleapis.com/protocol.TransferContract')), pbB(2, concat(pbB(1, owner), pbB(2, to), pbN(3, 1000000))));
  const raw = concat(pbB(1, new Uint8Array([0, 1])), pbB(4, new Uint8Array(8)), pbN(8, 1800000060000), pbB(11, concat(pbN(1, 1), pbB(2, any))), pbN(14, 1800000000000));
  const signData = dataType === 1 ? Buffer.from(raw) : Buffer.from('BitTool Signer public TRON message');
  const map = new Map([[1, { tag: 37, value: Buffer.from(UUID_HEX, 'hex') }], [2, signData], [3, dataType], [4, keypath(tron0.path)], [5, Buffer.from(owner)], [6, 'fixture']]);
  return UREncoder.encodeSinglePart(new UR(cbor(map), 'tron-sign-request'));
}

const evm0 = derivePublicKeyAt(A, 'evm', "m/44'/60'/0'/0/0");
const evmUR = (data, dataType, { id = UUID, chainId = 1 } = {}) => single(EthSignRequest.constructETHRequest(Buffer.from(data), dataType, evm0.path, FP, id ?? undefined, chainId, evm0.address, 'fixture'));
const sol0 = A.solanaPublicKeys.find(k => k.profile === 'standard');
function solTransaction() {
  const keys = [base58.decode(sol0.address), new Uint8Array(32).fill(4), new Uint8Array(32)];
  const u32 = n => { const b = new Uint8Array(4); new DataView(b.buffer).setUint32(0, n, true); return b; }, u64 = n => { const b = new Uint8Array(8); new DataView(b.buffer).setBigUint64(0, BigInt(n), true); return b; };
  return concat(new Uint8Array([1, 0, 1]), short(3), ...keys, new Uint8Array(32).fill(5), short(1), concat(new Uint8Array([2]), short(2), new Uint8Array([0, 1]), short(12), u32(2), u64(123456789)));
}
const solUR = (data, signType) => single(SolSignRequest.constructSOLRequest(Buffer.from(data), sol0.path, FP, signType, UUID, sol0.publicKey, 'fixture'));

function psbtFor(profile, inputs = 1) {
  const key = derivePublicKeyAt(A, 'bitcoin', (profile === 'taproot' ? "m/86'" : "m/84'") + "/0'/0'/0/0"), pub = hexToBytes(key.publicKey);
  const tx = new Transaction(), der = { fingerprint: parseInt(FP, 16), path: key.path.split('/').slice(1).map(x => Number(x.replace("'", '')) + (x.endsWith("'") ? 0x80000000 : 0)) };
  for (let i = 0; i < inputs; i++) {
    const payment = profile === 'taproot' ? p2tr(pub.slice(1)) : p2wpkh(pub);
    const prev = new Transaction(); prev.addInput({ txid: new Uint8Array(32).fill(i + 1), index: 0 }); prev.addOutput({ script: payment.script, amount: 100000n });
    const input = { txid: prev.id, index: 0, witnessUtxo: { script: payment.script, amount: 100000n } };
    if (profile === 'taproot') Object.assign(input, { tapInternalKey: pub.slice(1), tapBip32Derivation: [[pub.slice(1), { hashes: [], der }]] });
    else Object.assign(input, { nonWitnessUtxo: prev.unsignedTx, bip32Derivation: [[pub, der]] });
    tx.addInput(input);
  }
  tx.addOutputAddress('bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq', 90000n * BigInt(inputs), NETWORK);
  return Buffer.from(tx.toPSBT());
}

const cases = {
  'evm/eip1559-transaction': () => evmUR(getBytes(EthTx.from({ type: 2, chainId: 1, nonce: 0, gasLimit: 21000n, maxFeePerGas: 2000000000n, maxPriorityFeePerGas: 1000000000n, to: '0x' + '22'.repeat(20), value: 1n }).unsignedSerialized), 4),
  'evm/legacy-transaction-eip155': () => evmUR(getBytes(EthTx.from({ type: 0, chainId: 56, nonce: 0, gasLimit: 21000n, gasPrice: 1000000000n, to: '0x' + '22'.repeat(20), value: 1n }).unsignedSerialized), 1, { chainId: 56 }),
  'evm/personal-message': () => evmUR('BitTool Signer public fixture', 3),
  'evm/typed-data': () => evmUR(JSON.stringify({ domain: { name: 'BitTool Signer test', version: '1', chainId: 1, verifyingContract: '0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC' }, primaryType: 'Message', types: { Message: [{ name: 'contents', type: 'string' }] }, message: { contents: 'No funds: fixture only' } }), 2),
  'evm/personal-message-without-request-id': () => evmUR('BitTool Signer public fixture', 3, { id: null }),
  'solana/transaction': () => solUR(solTransaction(), 1),
  'solana/message': () => solUR('BitTool Signer public fixture', 2),
  'tron/transaction': () => tronRequestUR(1),
  'tron/message': () => tronRequestUR(2),
  'bitcoin/crypto-psbt': () => encodeQR({ type: 'crypto-psbt', payload: psbtFor('native').toString('hex') }).frames,
  'bitcoin/psbt': () => encodeQR({ type: 'psbt', payload: psbtFor('native').toString('hex') }).frames,
  'bitcoin/crypto-psbt-taproot': () => encodeQR({ type: 'crypto-psbt', payload: psbtFor('taproot').toString('hex') }).frames,
  'bitcoin/bbqr-base32': () => encodeQR({ type: 'bbqr-psbt', payload: psbtFor('native').toString('hex'), bbqrEncoding: '2', fragmentLength: 800 }).frames,
  'bitcoin/bbqr-hex': () => encodeQR({ type: 'bbqr-psbt', payload: psbtFor('native').toString('hex'), bbqrEncoding: 'H', fragmentLength: 800 }).frames,
  'bitcoin/psbt-base64-text': () => psbtFor('native').toString('base64'),
  'bitcoin/psbt-hex-text': () => psbtFor('native').toString('hex'),
  'bitcoin/psbt-base64-text-too-large': () => psbtFor('native', 5).toString('base64'),
};

// Private material for every key these cases sign with; none may appear anywhere in a response.
const root = HDKey.fromMasterSeed(mnemonicToSeedSync(MN));
const secrets = [root.privateExtendedKey, bytesToHex(root.privateKey), bytesToHex(mnemonicToSeedSync(MN)),
  ...["m/84'/0'/0'/0/0", "m/86'/0'/0'/0/0", "m/44'/60'/0'/0/0", "m/44'/195'/0'/0/0"].map(p => bytesToHex(root.derive(p).privateKey)),
  ...["m/84'/0'/0'", "m/86'/0'/0'", "m/44'/60'/0'", "m/44'/195'/0'"].map(p => root.derive(p).privateExtendedKey)];
const rawSecrets = [Buffer.from(solanaKey(mnemonicToSeedSync(MN), "m/44'/501'/0'/0'")),
  ...["m/84'/0'/0'/0/0", "m/86'/0'/0'/0/0", "m/44'/60'/0'/0/0", "m/44'/195'/0'/0/0"].map(p => Buffer.from(root.derive(p).privateKey))];
secrets.push(rawSecrets[0].toString('hex'));

for (const [label, make] of Object.entries(cases)) {
  test(`signed response payload: ${label}`, () => {
    const input = make(), frames = Array.isArray(input) ? input : [input];
    const { request, result, response } = signFrames(frames);
    const { payload } = response, blobs = [];
    // Shape: the frames, the export text and a payload decoded from those frames.
    assert.ok(response.frames.length > 0); assert.deepEqual(Object.keys(response).sort(), ['frames', 'payload', 'payloadBytes', 'payloadFormat', 'type']);
    assert.deepEqual({ payloadFormat: response.payloadFormat, payload, payloadBytes: response.payloadBytes }, describeQR(response));
    assert.equal(response.payloadFormat, 'json');
    // Deterministic across fragment sizes: animated frames describe the same bytes.
    if (response.frames[0].startsWith('UR:')) assert.deepEqual(execute({ operation: 'encodeResponse', request, result, fragmentLength: 40 }).payload, payload);

    if (/^UR:(ETH|SOL|TRON)-SIGNATURE\//.test(response.frames[0])) {
      const ur = urOf(response.frames); assert.equal(ur.type, response.type); assert.equal(response.payloadBytes, ur.cbor.length); blobs.push(ur.cbor);
      const expectedKeys = request.transport.requestId ? ['request-id', 'signature'] : ['signature'];
      assert.deepEqual(Object.keys(payload), expectedKeys);
      assert.equal(payload.signature, result.qrSignature || result.signature);
      if (request.transport.requestId) assert.deepEqual(payload['request-id'], { uuid: request.transport.requestId });
      // Independent parsers agree with every field.
      if (ur.type === 'eth-signature') {
        const reg = ETHSignature.fromCBOR(ur.cbor);
        assert.equal(reg.getSignature().toString('hex'), payload.signature); assert.equal(reg.getRequestId()?.toString('hex'), payload['request-id']?.uuid);
        const sig = '0x' + payload.signature;
        if (request.kind === 'personal') assert.equal(verifyMessage(getBytes(request.message), sig).toLowerCase(), evm0.address.toLowerCase());
        if (request.kind === 'typedData') { const { domain, types, message } = request.typedData; assert.equal(verifyTypedData(domain, types, message, sig).toLowerCase(), evm0.address.toLowerCase()); }
        if (request.kind === 'transaction') assert.equal(EthTx.from(result.serializedTransaction).from.toLowerCase(), evm0.address.toLowerCase());
      } else if (ur.type === 'sol-signature') {
        const reg = SolSignature.fromCBOR(ur.cbor);
        assert.equal(reg.getSignature().toString('hex'), payload.signature); assert.equal(reg.getRequestId().toString('hex'), payload['request-id'].uuid);
        const signed = request.kind === 'transaction' ? Buffer.from(request.message, 'base64') : Buffer.from(request.message, 'base64');
        assert.ok(ed25519.verify(hexToBytes(payload.signature), signed, hexToBytes(sol0.publicKey)));
      } else {
        const map = extend.decodeToDataItem(ur.cbor).getData();
        assert.equal(map[1].getTag(), 37); assert.equal(map[1].getData().toString('hex'), payload['request-id'].uuid);
        assert.equal(map[2].toString('hex'), payload.signature); assert.equal(payload.signature.length, 130);
        assert.equal(Object.keys(map).length, 2);
      }
    } else {
      // Every PSBT transport: the Base64 is the exact bytes the frames carry.
      assert.deepEqual(Object.keys(payload).sort(), ['decoded', 'psbt_base64']);
      assert.equal(payload.psbt_base64, result.psbt);
      const bytes = Buffer.from(payload.psbt_base64, 'base64'); blobs.push(bytes);
      if (response.type === 'crypto-psbt' || response.type === 'psbt') {
        const ur = urOf(response.frames); assert.equal(ur.type, response.type);
        assert.equal(CryptoPSBT.fromCBOR(ur.cbor).getPSBT().toString('base64'), payload.psbt_base64); assert.equal(response.payloadBytes, ur.cbor.length);
      } else if (response.type === 'bbqr-psbt') {
        const enc = response.frames[0][2], body = response.frames.map(f => f.slice(8)).join('');
        assert.deepEqual(enc === 'H' ? Buffer.from(body, 'hex') : Buffer.from(base32nopad.decode(body)), bytes); assert.equal(response.payloadBytes, bytes.length);
      } else {
        assert.equal(response.frames[0], response.type === 'psbt-hex' ? bytes.toString('hex') : payload.psbt_base64); assert.equal(response.payloadBytes, bytes.length);
      }
      const tx = Transaction.fromPSBT(bytes), s = payload.decoded;
      // The unsigned transaction's txid, as Bitcoin Core's decodepsbt reports it.
      assert.equal(s.tx.txid, bytesToHex(sha256(sha256(tx.unsignedTx)).reverse())); assert.equal(s.inputs.length, tx.inputsLength); assert.equal(s.tx.vout.length, tx.outputsLength);
      for (let i = 0; i < tx.inputsLength; i++) {
        const input = tx.getInput(i);
        if (input.partialSig) assert.deepEqual(s.inputs[i].partial_signatures, Object.fromEntries(input.partialSig.map(([k, v]) => [bytesToHex(k), bytesToHex(v)])));
        if (input.tapKeySig) assert.equal(s.inputs[i].taproot_key_path_sig, bytesToHex(input.tapKeySig));
        assert.ok(s.inputs[i].partial_signatures || s.inputs[i].taproot_key_path_sig, 'every input of these fixtures is signed');
      }
      assert.deepEqual(s.tx.vout[0], { n: 0, value_sat: Number(tx.getOutput(0).amount), scriptPubKey: { hex: bytesToHex(tx.getOutput(0).script), address: 'bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq' } });
    }
    // Public only: no seed, root/account private key or xprv appears in frames or payload.
    const everything = JSON.stringify(response).toLowerCase();
    for (const secret of secrets) assert.equal(everything.includes(secret.toLowerCase()), false);
    // …nor as raw bytes inside the encoded CBOR or PSBT.
    for (const blob of blobs) for (const key of rawSecrets) assert.equal(Buffer.from(blob).indexOf(key), -1);
    assert.equal(/xprv|tprv/.test(everything), false);
  });
}

test('PSBT-framed bytes that are not a transaction still show the exact bytes, without a summary', () => {
  const data = Buffer.from('70736274ff0000', 'hex');
  const { request } = decodeQR({ frames: [data.toString('base64')] });
  const response = encodeResponse({ request, result: { psbt: data.toString('base64') } });
  assert.deepEqual(response.payload, { psbt_base64: data.toString('base64') }); assert.equal(response.payloadBytes, 7);
});

test('a response whose frames do not decode to their own type is refused before display', () => {
  assert.throws(() => describeQR({ type: 'crypto-psbt', frames: ['cHNidP8AAA=='] }), /does not decode to its own type/);
  assert.throws(() => describeQR({ type: 'sol-signature', frames: encodeQR({ type: 'eth-signature', payload: 'ab'.repeat(65) }).frames }), /unexpected type/);
});

