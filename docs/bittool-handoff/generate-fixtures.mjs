// Documentation fixture generator. Uses only the public BIP39 test mnemonic.
// Run: node generate-fixtures.mjs /path/to/BitTool Signer/engine
// Never pass real wallet material. Nothing is broadcast or fetched from a network.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';
import { createHash } from 'node:crypto';
import assert from 'node:assert/strict';

const here = path.dirname(fileURLToPath(import.meta.url));
const engine = path.resolve(process.argv[2] || path.join(here, '../../engine'));
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const sourcePaths = ['protocols.js', ...fs.readdirSync(path.join(engine, 'src')).filter(p => p.endsWith('.js')).map(p => 'src/' + p),
  'test/protocols.test.js', 'test/wallet-pairing.test.mjs', 'package.json', 'package-lock.json', 'data/token-registry.engine.json'];
const before = new Map(sourcePaths.map(p => [p, sha(fs.readFileSync(path.join(engine, p)))]));
const bundleBefore = sha(fs.readFileSync(path.join(engine, '../BitToolSigner/Resources/signer.js')));
const require = createRequire(path.join(engine, 'package.json'));
const dep = name => import(pathToFileURL(require.resolve(name)).href);
const local = name => import(pathToFileURL(path.join(engine, name)).href);
const { UR, UREncoder, URDecoder } = await dep('@ngraveio/bc-ur');
const { Transaction: BitcoinTx, p2wpkh, p2pkh } = await dep('@scure/btc-signer');
const { base58, base58check } = await dep('@scure/base');
const { sha256 } = await dep('@noble/hashes/sha2.js');
const { secp256k1 } = await dep('@noble/curves/secp256k1.js');
const { ed25519 } = await dep('@noble/curves/ed25519.js');
const { Transaction, getBytes, verifyMessage, verifyTypedData, recoverAddress, Signature } = await dep('ethers');
const { createWalletPairing, decodeWalletPairing, canonicalCBOR, decodeQR, encodeQR, encodeResponse } = await local('protocols.js');
const { derivePublicIndex, derivePublicKeyAt } = await local('src/public-index.js');
const { execute } = await local('src/index.js');
const { resolveSigningPlan, signPlanTask } = await local('src/resolver.js');
const MN = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const publicIndex = derivePublicIndex({ mnemonic: MN });
const buf = (hex) => Buffer.from(hex, 'hex');
const out = path.join(here, 'fixtures'); fs.mkdirSync(out, { recursive: true });
const save = (name, value) => fs.writeFileSync(path.join(out, name), JSON.stringify(value, null, 2) + '\n');

// A minimal encoder for the concrete fixture types, not a production CBOR library.
function head(major, n) {
  if (n < 24) return Buffer.from([major * 32 + n]);
  if (n < 256) return Buffer.from([major * 32 + 24, n]);
  if (n < 65536) { const b = Buffer.alloc(3); b[0] = major * 32 + 25; b.writeUInt16BE(n, 1); return b; }
  const b = Buffer.alloc(5); b[0] = major * 32 + 26; b.writeUInt32BE(n, 1); return b;
}
function cbor(v) {
  if (Buffer.isBuffer(v) || v instanceof Uint8Array) return Buffer.concat([head(2, v.length), Buffer.from(v)]);
  if (typeof v === 'string') { const b = Buffer.from(v); return Buffer.concat([head(3, b.length), b]); }
  if (typeof v === 'number') { assert.ok(Number.isInteger(v) && v >= 0 && v <= 0xffffffff); return head(0, v); }
  if (typeof v === 'boolean') return Buffer.from([v ? 245 : 244]);
  if (Array.isArray(v)) return Buffer.concat([head(4, v.length), ...v.map(cbor)]);
  if (v instanceof Map) return Buffer.concat([head(5, v.size), ...[...v].flatMap(([k, x]) => [cbor(k), cbor(x)])]);
  if (v?.tag) return Buffer.concat([head(6, v.tag), cbor(v.value)]);
  throw new Error('Unsupported fixture value');
}
function frames(type, bytes, size = 180) { return new UREncoder(new UR(bytes, type), size).encodeWhole().map(s => s.toUpperCase()); }
function readFrames(parts) { const d = new URDecoder(); [...parts].reverse().forEach(p => d.receivePart(p)); assert.ok(d.isSuccess()); return d.resultUR(); }
const tag = (tag, value) => ({ tag, value });
function keypath(fullPath) {
  return tag(304, new Map([[1, fullPath.split('/').slice(1).flatMap(p => [Number(p.replace("'", '')), p.endsWith("'")])], [2, parseInt(publicIndex.masterFingerprint, 16)]]));
}
const pairing = createWalletPairing({ publicIndex });
assert.deepEqual(decodeWalletPairing({ frames: [...pairing.frames].reverse() }), pairing.payload);
const inner = canonicalCBOR(pairing.payload), outer = readFrames(pairing.frames).cbor;
assert.deepEqual(Buffer.from(outer), cbor(inner));
save('wallet-pairing-current.json', {
  warning: 'PUBLIC, UNFUNDED TEST VECTOR ONLY. Never send assets to these addresses.',
  protocolVersion: 1, logicalPayload: pairing.payload, innerCBORHex: inner.toString('hex'),
  innerCBORBytes: inner.length, innerCBORSHA256: sha(inner), urCBORHex: Buffer.from(outer).toString('hex'),
  frames: pairing.frames, verify: pairing.verify, solanaAccountCount: pairing.payload.accounts.find(a => a.chain === 'sol').accounts.length,
});
const noMode = { ...pairing.payload }; delete noMode.mode;
const noModeBytes = canonicalCBOR(noMode);
save('wallet-pairing-no-mode-receiver-extension.json', {
  note: 'Proposed BitTool Wallet receiver compatibility with the attached draft; NOT emitted by this BitTool Signer snapshot. All other fields unchanged. The current BitTool Signer reference decoder rejects absent mode.',
  logicalPayload: noMode, innerCBORHex: noModeBytes.toString('hex'), innerCBORSHA256: sha(noModeBytes),
  frames: frames('bytes', cbor(noModeBytes), 200),
});

const wallets = [{ localWalletId: 'public-fixture-wallet', publicIndex }];
const vectors = []; let seq = 0;
function signVector(name, type, mapOrFrames, info, verify) {
  const inputFrames = Array.isArray(mapOrFrames) ? mapOrFrames : frames(type, cbor(mapOrFrames));
  const decoded = decodeQR({ frames: inputFrames }); assert.equal(decoded.complete, true);
  const request = decoded.request;
  const plan = resolveSigningPlan({ request, wallets }); assert.equal(plan.status, 'ready', name + ': ' + plan.message); assert.equal(plan.tasks.length, 1);
  // Explicit consent for these fixed public, unfunded fixtures only; never a production authorization shortcut.
  const result = signPlanTask({ request, plan, taskId: plan.tasks[0].id, mnemonic: MN, riskAcknowledged: true });
  verify(result, request);
  const response = encodeResponse({ request, result });
  const responseUR = readFrames(response.frames);
  // Decode the response with a separate CBOR implementation and compare exact wire bytes.
  const wireResponse = require('cbor-sync').decode(responseUR.cbor);
  if (type === 'crypto-psbt') assert.deepEqual(Buffer.from(wireResponse), Buffer.from(result.psbt, 'base64'));
  else {
    assert.deepEqual(Buffer.from(wireResponse[1]), buf(request.transport.requestId));
    assert.deepEqual(Buffer.from(wireResponse[2]), buf(result.qrSignature || result.signature));
  }
  vectors.push({ name, ...info,
    request: { type, frames: inputFrames, urCBORHex: Buffer.from(readFrames(inputFrames).cbor).toString('hex'), ...(request.transport.requestId ? { requestIdHex: request.transport.requestId } : {}) },
    expected: { signerAddress: result.address ?? info.signerAddress, responseType: response.type,
      responseURCBORHex: Buffer.from(responseUR.cbor).toString('hex'), responseFrames: response.frames,
      ...(result.qrSignature || result.signature ? { signatureHex: result.qrSignature || result.signature } : {}),
      ...(result.psbt ? { signedPSBTBase64: result.psbt } : {}),
      ...(result.serializedTransaction ? { serializedTransaction: result.serializedTransaction } : {}),
      ...(result.txID ? { txID: result.txID } : {}),
      ...(result.signerIndex !== undefined ? { signerSlot: result.signerIndex } : {}) },
  });
}
function id() { const b = buf('8f235e99e6e84044a51d51ec3ec942b0'); b[15] = ++seq; return tag(37, b); }
const evm = derivePublicKeyAt(publicIndex, 'evm', "m/44'/60'/0'/0/0");
const ethMap = (bytes, type, chainId) => new Map([[1, id()], [2, bytes], [3, type], ...(chainId ? [[4, chainId]] : []), [5, keypath(evm.path)], [6, buf(evm.address.slice(2))], [7, 'BitTool Wallet public interoperability fixture']]);
const message = Buffer.from('BitTool Wallet + BitTool Signer: public interoperability test.');
signVector('evm-personal', 'eth-sign-request', ethMap(message, 3, 1), { signingBytesHex: message.toString('hex'), dataType: 3 }, r => assert.equal(verifyMessage(message, '0x' + r.signature), evm.address));
for (const [type, chainId] of [[2, 1], [0, 43114]]) {
  const tx = Transaction.from({ type, chainId, nonce: 7, gasLimit: 21000n, to: '0x000000000000000000000000000000000000dead', value: 1n,
    ...(type === 2 ? { maxFeePerGas: 30000000000n, maxPriorityFeePerGas: 1000000000n } : { gasPrice: 30000000000n }) });
  signVector('evm-' + (type ? 'eip1559' : 'legacy-multibyte-v'), 'eth-sign-request', ethMap(Buffer.from(getBytes(tx.unsignedSerialized)), type ? 4 : 1, chainId),
    { signingBytesHex: tx.unsignedSerialized.slice(2), unsignedHash: tx.unsignedHash, dataType: type ? 4 : 1, chainId }, r => {
      const raw = buf(r.qrSignature), v = BigInt('0x' + raw.subarray(64).toString('hex'));
      const parity = type ? v : v - BigInt(chainId) * 2n - 35n;
      const sig = Signature.from({ r: '0x' + raw.subarray(0, 32).toString('hex'), s: '0x' + raw.subarray(32, 64).toString('hex'), yParity: Number(parity) });
      assert.equal(recoverAddress(tx.unsignedHash, sig), evm.address);
    });
}
const typedData = { domain: { name: 'BitTool Wallet fixture', version: '1', chainId: 1, verifyingContract: '0x' + '22'.repeat(20) }, primaryType: 'Message', types: { Message: [{ name: 'contents', type: 'string' }] }, message: { contents: 'Public test only. No asset authorization.' } };
signVector('evm-eip712', 'eth-sign-request', ethMap(Buffer.from(JSON.stringify(typedData)), 2, 1), { typedData, dataType: 2 }, r => assert.equal(verifyTypedData(typedData.domain, typedData.types, typedData.message, '0x' + r.signature), evm.address));

const sol = derivePublicKeyAt(publicIndex, 'solana', "m/44'/501'/0'/0'");
const solMap = (bytes, type) => new Map([[1, id()], [2, bytes], [3, keypath(sol.path)], [4, base58.decode(sol.address)], [5, 'BitTool Wallet public fixture'], [6, type]]);
const checkSol = bytes => r => assert.ok(ed25519.verify(buf(r.signature), bytes, base58.decode(sol.address)));
signVector('solana-message', 'sol-sign-request', solMap(message, 2), { signingBytesHex: message.toString('hex'), signType: 2 }, checkSol(message));
const lamports = Buffer.alloc(8); lamports.writeBigUInt64LE(1000n);
// Legacy message: signer, recipient, System Program; one transfer. Synthetic blockhash.
const solMessage = Buffer.concat([Buffer.from([1, 0, 1, 3]), Buffer.from(base58.decode(sol.address)), Buffer.alloc(32, 4), Buffer.alloc(32), Buffer.alloc(32, 9), Buffer.from([1, 2, 2, 0, 1, 12, 2, 0, 0, 0]), lamports]);
signVector('solana-legacy-transfer', 'sol-sign-request', solMap(solMessage, 1), { signingBytesHex: solMessage.toString('hex'), signType: 1, syntheticBlockhash: true }, checkSol(solMessage));

const tron = derivePublicKeyAt(publicIndex, 'tron', "m/44'/195'/0'/0/0");
const b58check = base58check(sha256);
const tronMap = (bytes, type) => new Map([[1, id()], [2, bytes], [3, type], [4, keypath(tron.path)], [5, b58check.decode(tron.address)], [6, 'BitTool Wallet public fixture']]);
const checkTron = r => assert.ok(secp256k1.verify(buf(r.signature).subarray(0, 64), buf(r.digest), buf(tron.publicKey), { prehash: false, lowS: true }));
signVector('tron-message', 'tron-sign-request', tronMap(message, 2), { signingBytesHex: message.toString('hex'), dataType: 2 }, checkTron);
function vi(n) { n = BigInt(n); const b = []; do { const v = Number(n & 127n); n >>= 7n; b.push(v | (n ? 128 : 0)); } while(n); return Buffer.from(b); }
const pn = (k, n) => Buffer.concat([vi(k * 8), vi(n)]);
const pb = (k, b) => Buffer.concat([vi(k * 8 + 2), vi(b.length), Buffer.from(b)]);
const val = Buffer.concat([pb(1, b58check.decode(tron.address)), pb(2, b58check.decode('TJRabPrwbZy45sbavfcjinPJC18kjpRTv8')), pn(3, 1000000)]);
const any = Buffer.concat([pb(1, Buffer.from('type.googleapis.com/protocol.TransferContract')), pb(2, val)]);
const contract = Buffer.concat([pn(1, 1), pb(2, any)]);
const raw = Buffer.concat([pb(1, Buffer.from([0, 1])), pb(4, Buffer.alloc(8)), pn(8, 1800000060000), pb(11, contract), pn(14, 1800000000000)]);
signVector('tron-trx-transfer', 'tron-sign-request', tronMap(raw, 1), { signingBytesHex: raw.toString('hex'), dataType: 1, syntheticReferenceBlock: true }, checkTron);

const btc = derivePublicKeyAt(publicIndex, 'bitcoin', "m/84'/0'/0'/0/0");
const btcPayment = p2wpkh(buf(btc.publicKey));
const prev = new BitcoinTx(); prev.addInput({ txid: Buffer.alloc(32, 1), index: 0 }); prev.addOutput({ script: btcPayment.script, amount: 100000n });
const tx = new BitcoinTx();
tx.addInput({ txid: prev.id, index: 0, nonWitnessUtxo: prev.unsignedTx, witnessUtxo: { script: btcPayment.script, amount: 100000n }, bip32Derivation: [[buf(btc.publicKey), { fingerprint: parseInt(publicIndex.masterFingerprint, 16), path: [0x80000054, 0x80000000, 0x80000000, 0, 0] }]] });
tx.addOutput({ script: btcPayment.script, amount: 90000n });
const psbt = Buffer.from(tx.toPSBT()).toString('base64');
signVector('bitcoin-bip84-psbt', 'crypto-psbt', encodeQR({ type: 'crypto-psbt', payload: psbt, encoding: 'base64' }).frames,
  { unsignedPSBTBase64: psbt, signerAddress: btc.address, syntheticUTXO: true }, r => {
    const signed = BitcoinTx.fromPSBT(Buffer.from(r.psbt, 'base64'));
    const signatures = signed.getInput(0).partialSig; assert.equal(signatures.length, 1);
    const [pub, signature] = signatures[0]; assert.equal(signature.at(-1), 1);
    const digest = signed.preimageWitnessV0(0, p2pkh(pub).script, 1, 100000n);
    assert.ok(secp256k1.verify(signature.subarray(0, -1), digest, pub, { prehash: false, format: 'der', lowS: true }));
    signed.finalize(); assert.ok(signed.extract().length > 0);
  });
save('signing-roundtrips.json', { warning: 'PUBLIC TEST VECTORS ONLY. Synthetic transactions; never broadcast. Messages are test text, not real authorization.', vectors });

const sources = sourcePaths.map(p => ({ path: 'engine/' + p, sha256: sha(fs.readFileSync(path.join(engine, p))) }));
for (const source of sources) assert.equal(source.sha256, before.get(source.path.slice(7)), 'Source changed during generation: ' + source.path);
const bundle = fs.readFileSync(path.join(engine, '../BitToolSigner/Resources/signer.js'));
assert.equal(sha(bundle), bundleBefore, 'Bundle changed during generation');
const manifest = JSON.parse(fs.readFileSync(path.join(engine, 'bundle-manifest.json')));
assert.equal(sha(bundle), manifest.sha256); assert.equal(bundle.length, manifest.bytes);
save('source-snapshot.json', { generatedAt: new Date().toISOString(), nodeVersion: process.version, sourceType: 'Local working tree, not a release certification or Git commit snapshot', files: sources, bundle: { path: manifest.file, sha256: sha(bundle), bytes: bundle.length }, capabilities: execute({ operation: 'capabilities' }), fixtureChecks: { pairingURRoundtrip: true, signingRoundtrips: vectors.length, broadcasting: false } });
console.log(JSON.stringify({ pairingBytes: inner.length, pairingSHA256: sha(inner), frames: pairing.frames.length, signingVectors: vectors.length, bundleSHA256: sha(bundle) }, null, 2));
