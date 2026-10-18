// Regression tests for the 2026-09-21 security review (F1–F18) and engine
// performance changes. Public test mnemonics and synthetic requests only.
import test from 'node:test';
import assert from 'node:assert/strict';
import { Transaction, Interface, TypedDataEncoder, verifyTypedData, keccak256, concat as hexConcat, getBytes } from 'ethers';
import { EthSignRequest, ETHSignature } from '@keystonehq/bc-ur-registry-eth';
import { URDecoder, UR, UREncoder } from '@ngraveio/bc-ur';
import { base58, base58check } from '@scure/base';
import { sha256 } from '@noble/hashes/sha2.js';
import { mnemonicToSeedSync } from '@scure/bip39';
import { Transaction as BitcoinTx, p2wpkh, NETWORK } from '@scure/btc-signer';
import { HDKey } from '@scure/bip32';
import { dispatch } from '../src/index.js';
import { QRCollector } from '../protocols.js';
import { bytesToHex, hexToBytes } from '../src/util.js';

const MN = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const call = (operation, params = {}) => {
  const out = JSON.parse(dispatch(JSON.stringify({ operation, ...params })));
  if (!out.ok) { const error = new Error(out.error.message); error.code = out.error.code; throw error; }
  return out.result;
};
const index = call('derivePublicIndex', { mnemonic: MN });
const wallets = [{ localWalletId: 'wallet-a', publicIndex: index }];
const signer = index.evmDefaultAddress.address;
const seedHex = bytesToHex(mnemonicToSeedSync(MN, ''));

function sign(request, { riskAcknowledged = true, useSeed = false } = {}) {
  const plan = call('resolveSigningPlan', { request, wallets });
  assert.equal(plan.status, 'ready', plan.message);
  const secret = useSeed ? { seed: seedHex } : { mnemonic: MN };
  const result = call('signPlanTask', { request, plan, taskId: plan.tasks[0].id, riskAcknowledged, ...secret });
  return { plan, result };
}

// F1 / F7 / F14 ---------------------------------------------------------------
const daiPermit = allowed => ({
  types: {
    EIP712Domain: [{ name: 'name', type: 'string' }, { name: 'version', type: 'string' }, { name: 'chainId', type: 'uint256' }, { name: 'verifyingContract', type: 'address' }],
    Permit: [{ name: 'holder', type: 'address' }, { name: 'spender', type: 'address' }, { name: 'nonce', type: 'uint256' }, { name: 'expiry', type: 'uint256' }, { name: 'allowed', type: 'bool' }],
  },
  primaryType: 'Permit',
  domain: { name: 'Dai Stablecoin', version: '1', chainId: 1, verifyingContract: '0x6B175474E89094C44Da98b954EedeAC495271d0F' },
  message: { holder: signer, spender: '0x' + 'ba'.repeat(20), nonce: 0, expiry: 0, allowed },
});

test('F1: EIP-712 values must match their declared type; truthy strings are never signed as bool', () => {
  for (const allowed of ['false', '0', 'no', 'False', ' ', 1, null]) {
    assert.throws(() => call('review', { request: { chain: 'evm', kind: 'typedData', typedData: daiPermit(allowed) } }), e => e.code === 'TYPED_DATA');
  }
  const request = { chain: 'evm', kind: 'typedData', path: "m/44'/60'/0'/0/0", address: signer, masterFingerprint: index.masterFingerprint, typedData: daiPermit(false) };
  const review = call('review', { request });
  assert.ok(!review.warnings.some(w => w.includes('UNLIMITED')));
  assert.equal(review.fields.find(f => f.label === 'Unlimited permit').value, 'No (revokes allowance)');
  const unlimited = call('review', { request: { ...request, typedData: daiPermit(true) } });
  assert.ok(unlimited.warnings.some(w => w.includes('UNLIMITED')));
  assert.equal(unlimited.display.amount, 'Unlimited');
  const { result } = sign(request);
  const { EIP712Domain, ...types } = daiPermit(false).types;
  assert.equal(verifyTypedData(daiPermit(false).domain, types, daiPermit(false).message, '0x' + result.signature), signer);
});

test('F7: ambiguous integer and address spellings are rejected before hashing', () => {
  const base = value => ({ types: { Transfer: [{ name: 'to', type: 'address' }, { name: 'amount', type: 'uint256' }] }, primaryType: 'Transfer',
    domain: { name: 'Test', chainId: 1 }, message: { to: '0x' + '22'.repeat(20), amount: value } });
  for (const amount of ['0o777', '0b101', '  100', '1e3', '-1', '100 ', 1.5, '0x']) {
    // Non-integer JSON numbers are already refused by the canonical request hash.
    assert.throws(() => call('review', { request: { chain: 'evm', kind: 'typedData', typedData: base(amount) } }), e => ['TYPED_DATA', 'PRECISION'].includes(e.code), String(amount));
  }
  const icap = { ...base('1'), message: { to: 'XE7338O073KYGTWWZN0F2WZ0R8PX5ZPPZS', amount: '1' } };
  assert.throws(() => call('review', { request: { chain: 'evm', kind: 'typedData', typedData: icap } }), e => e.code === 'TYPED_DATA');
  const badChecksum = { ...base('1'), message: { to: '0x9858EfFD232B4033E47d90003D41EC34EcaEda95'.replace('Ef', 'eF'), amount: '1' } };
  assert.throws(() => call('review', { request: { chain: 'evm', kind: 'typedData', typedData: badChecksum } }), e => e.code === 'TYPED_DATA');
  // Integers above 2^53 are accepted only as strings, and are range-checked.
  const big = base(String((1n << 256n) - 1n));
  assert.equal(call('review', { request: { chain: 'evm', kind: 'typedData', typedData: big } }).decodeStatus, 'partiallyDecoded');
  assert.throws(() => call('review', { request: { chain: 'evm', kind: 'typedData', typedData: base(String(1n << 256n)) } }), e => e.code === 'TYPED_DATA');
});

test('F14: declared EIP712Domain order defines the separator; unused types are ignored like wallets do', () => {
  const typedData = {
    types: {
      EIP712Domain: [{ name: 'chainId', type: 'uint256' }, { name: 'name', type: 'string' }],
      Mail: [{ name: 'contents', type: 'string' }],
      Unused: [{ name: 'x', type: 'uint8' }],
    },
    primaryType: 'Mail', domain: { name: 'Order test', chainId: 1 }, message: { contents: 'hello' },
  };
  const request = { chain: 'evm', kind: 'typedData', path: "m/44'/60'/0'/0/0", address: signer, masterFingerprint: index.masterFingerprint, typedData };
  const { result } = sign(request);
  const separator = TypedDataEncoder.hashStruct('EIP712Domain', { EIP712Domain: typedData.types.EIP712Domain }, typedData.domain);
  const expected = keccak256(hexConcat(['0x1901', separator, TypedDataEncoder.from({ Mail: typedData.types.Mail }).hash(typedData.message)]));
  assert.equal(result.digest, expected);
  assert.notEqual(expected, TypedDataEncoder.hash(typedData.domain, { Mail: typedData.types.Mail }, typedData.message));
  const mismatched = structuredClone(typedData); mismatched.types.EIP712Domain.pop();
  assert.throws(() => call('review', { request: { ...request, typedData: mismatched } }), e => e.code === 'TYPED_DATA');
});

// F2 ---------------------------------------------------------------------------
function qrSignature(txData, dataType) {
  const tx = Transaction.from(txData);
  const ur = EthSignRequest.constructETHRequest(Buffer.from(getBytes(tx.unsignedSerialized)), dataType, "m/44'/60'/0'/0/0", index.masterFingerprint, 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee', Number(tx.chainId), signer, 'test');
  const { request } = call('decodeQR', { frames: [ur.toUREncoder(400).nextPart()] });
  const { result } = sign(request);
  const response = call('encodeResponse', { request, result });
  const decoder = new URDecoder(); response.frames.forEach(frame => decoder.receivePart(frame.toLowerCase()));
  return { tx, signature: ETHSignature.fromCBOR(decoder.resultUR().cbor).getSignature() };
}

test('F2: eth-signature v is EIP-155 for legacy transactions and y-parity for typed transactions', () => {
  for (const chainId of [1, 56, 42161]) {
    const { tx, signature } = qrSignature({ type: 0, chainId, nonce: 3, gasLimit: 21000n, gasPrice: 10n ** 9n, to: '0x' + '22'.repeat(20), value: 10n ** 15n }, 1);
    const v = BigInt('0x' + Buffer.from(signature.subarray(64)).toString('hex'));
    assert.ok(v === BigInt(chainId) * 2n + 35n || v === BigInt(chainId) * 2n + 36n, `chain ${chainId} v ${v}`);
    const signed = Transaction.from({ ...tx.toJSON(), type: 0, signature: { r: '0x' + Buffer.from(signature.subarray(0, 32)).toString('hex'), s: '0x' + Buffer.from(signature.subarray(32, 64)).toString('hex'), v } });
    assert.equal(signed.from, signer); assert.equal(signed.chainId, BigInt(chainId));
  }
  const { tx, signature } = qrSignature({ type: 2, chainId: 8453, nonce: 1, gasLimit: 21000n, maxFeePerGas: 10n ** 9n, maxPriorityFeePerGas: 10n ** 8n, to: '0x' + '22'.repeat(20), value: 1n }, 4);
  assert.equal(signature.length, 65); assert.ok([0, 1].includes(signature[64]));
  const signed = Transaction.from({ ...tx.toJSON(), type: 2, signature: { r: '0x' + Buffer.from(signature.subarray(0, 32)).toString('hex'), s: '0x' + Buffer.from(signature.subarray(32, 64)).toString('hex'), yParity: signature[64] } });
  assert.equal(signed.from, signer);
});

// F3 ---------------------------------------------------------------------------
const SAFE_TYPES = [['to','address'],['value','uint256'],['data','bytes'],['operation','uint8'],['safeTxGas','uint256'],['baseGas','uint256'],['gasPrice','uint256'],['gasToken','address'],['refundReceiver','address'],['nonce','uint256']].map(([name, type]) => ({ name, type }));
test('F3: Safe gas refunds are decoded, shown and raise the risk level', () => {
  const zero = '0x' + '00'.repeat(20), attacker = '0x' + 'ba'.repeat(20);
  const safeTx = message => ({ chain: 'evm', kind: 'typedData', typedData: { types: { SafeTx: SAFE_TYPES }, primaryType: 'SafeTx', domain: { chainId: 1, verifyingContract: '0x' + '5a'.repeat(20) },
    message: { to: '0x' + '33'.repeat(20), value: '1', data: '0x', operation: 0, safeTxGas: '0', baseGas: '0', gasPrice: '0', gasToken: zero, refundReceiver: zero, nonce: '4', ...message } } });
  const plain = call('review', { request: safeTx({}) });
  assert.equal(plain.riskLevel, 'normal'); assert.ok(!plain.warnings.some(w => w.includes('refund')));
  const refund = call('review', { request: safeTx({ baseGas: '100000000', gasPrice: '1000000', gasToken: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48', refundReceiver: attacker }) });
  assert.equal(refund.riskLevel, 'high');
  assert.ok(refund.warnings.some(w => w.startsWith('HIGH RISK') && w.includes('refund') && w.toLowerCase().includes(attacker)));
  assert.equal(refund.fields.find(f => f.label === 'Refund receiver').value.toLowerCase(), attacker);
  const exec = new Interface(['function execTransaction(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,bytes signatures)']);
  const data = exec.encodeFunctionData('execTransaction', ['0x' + '33'.repeat(20), 1n, '0x', 0, 0, 5n, 7n, zero, attacker, '0x']);
  const onchain = call('review', { request: { chain: 'evm', kind: 'transaction', transaction: { type: 2, chainId: 1, nonce: 0, to: '0x' + '5a'.repeat(20), data, value: '0', gasLimit: '200000', maxFeePerGas: '1000000000', maxPriorityFeePerGas: '1' } } });
  assert.equal(onchain.riskLevel, 'high'); assert.ok(onchain.warnings.some(w => w.includes('refund')));
});

// F4 / F5 / F10 / F11 / F12 (summaries) -----------------------------------------
const key = n => new Uint8Array(32).fill(n);
const cat = (...a) => { const o = new Uint8Array(a.reduce((n, x) => n + x.length, 0)); let p = 0; for (const x of a) { o.set(x, p); p += x.length; } return o; };
const u64 = n => { const b = new Uint8Array(8); new DataView(b.buffer).setBigUint64(0, BigInt(n), true); return b; };
const u32 = n => { const b = new Uint8Array(4); new DataView(b.buffer).setUint32(0, n, true); return b; };
const me = base58.decode(index.solanaPublicKeys.find(k => k.profile === 'standard').address);
const SYSTEM = new Uint8Array(32), TOKEN = base58.decode('TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA'), COMPUTE = base58.decode('ComputeBudget111111111111111111111111111111');
const USDC = base58.decode('EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v');
function solMessage(keys, required, roSigned, roUnsigned, ixs) {
  const parts = [new Uint8Array([required, roSigned, roUnsigned, keys.length]), ...keys, key(9), new Uint8Array([ixs.length])];
  for (const ix of ixs) parts.push(new Uint8Array([ix.p, ix.a.length, ...ix.a, ix.d.length]), ix.d);
  return { chain: 'solana', kind: 'transaction', path: "m/44'/501'/0'/0'", message: Buffer.from(cat(...parts)).toString('base64') };
}

test('F4: a Solana summary never pairs one transfer amount with another transfer destination', () => {
  const request = solMessage([me, key(1), key(2), key(3), USDC, TOKEN, SYSTEM], 1, 0, 3, [
    { p: 5, a: [1, 4, 2, 0], d: cat(new Uint8Array([12]), u64(1_000_000), new Uint8Array([6])) },
    { p: 6, a: [0, 3], d: cat(u32(2), u64(90n * 10n ** 9n)) },
  ]);
  const review = call('review', { request });
  assert.equal(review.display.counterparty, undefined);
  assert.equal(review.display.amount, undefined);
  assert.match(review.display.headline, /^2 transfers/);
  assert.equal(review.asset, undefined);
  const single = call('review', { request: solMessage([me, key(3), SYSTEM], 1, 0, 1, [{ p: 2, a: [0, 1], d: cat(u32(2), u64(2n * 10n ** 9n)) }]) });
  assert.deepEqual([single.display.amount, single.display.symbol, single.display.counterparty], ['2', 'SOL', base58.encode(key(3))]);
});

test('F5: native value attached to calls and transfers leads the summary on every chain', () => {
  const evm = (to, value, data = '0x') => call('review', { request: { chain: 'evm', kind: 'transaction', transaction: { type: 2, chainId: 1, nonce: 0, to, value, data, gasLimit: '300000', maxFeePerGas: '10000000000', maxPriorityFeePerGas: '1' } } });
  const opaque = evm('0x' + '44'.repeat(20), String(25n * 10n ** 18n), '0xdeadbeef00');
  assert.deepEqual([opaque.display.amount, opaque.display.symbol, opaque.display.counterpartyLabel], ['25', 'ETH', 'Contract']);
  const transfer = evm('0x' + '9e'.repeat(20), String(3n * 10n ** 18n));
  assert.deepEqual([transfer.display.action, transfer.display.amount, transfer.display.counterpartyLabel], ['Send', '3', 'To']);
  assert.equal(transfer.network.name, 'Ethereum');
  const create = call('review', { request: solMessage([me, key(5), SYSTEM], 2, 0, 1, [{ p: 2, a: [0, 1], d: cat(u32(0), u64(500n * 10n ** 9n), u64(0), key(0xa7)) }]) });
  assert.equal(create.riskLevel, 'high'); assert.equal(create.display.amount, '500');
  const close = call('review', { request: solMessage([me, key(1), key(3), TOKEN], 1, 0, 1, [{ p: 3, a: [1, 2, 0], d: new Uint8Array([9]) }]) });
  assert.ok(close.warnings.some(w => w.includes('entire wrapped balance')));
});

test('F5/F6: TRON call value and high fee limits are surfaced', () => {
  const B58 = base58check(sha256);
  const varint = n => { n = BigInt(n); const out = []; do { let b = Number(n & 127n); n >>= 7n; if (n) b |= 128; out.push(b); } while (n); return new Uint8Array(out); };
  const pbN = (f, v) => cat(varint(f << 3), varint(v)), pbB = (f, b) => cat(varint((f << 3) | 2), varint(b.length), b);
  const utf8 = s => new TextEncoder().encode(s);
  const owner = B58.decode(index.tronAddressIndex[0].address), contract = B58.decode('TJRabPrwbZy45sbavfcjinPJC18kjpRTv8');
  const tx = (feeLimit, callValue) => {
    const trigger = cat(pbB(1, owner), pbB(2, contract), pbN(3, callValue));
    const any = cat(pbB(1, utf8('type.googleapis.com/protocol.TriggerSmartContract')), pbB(2, trigger));
    const raw = cat(pbB(1, new Uint8Array([0, 1])), pbB(4, new Uint8Array(8)), pbN(8, 1800000060000), pbB(11, cat(pbN(1, 31), pbB(2, any))), pbN(14, 1800000000000), pbN(18, feeLimit));
    return call('review', { request: { chain: 'tron', kind: 'transaction', path: "m/44'/195'/0'/0/0", transaction: { raw_data_hex: bytesToHex(raw) } } });
  };
  const valued = tx(100_000_000n, 250_000n * 1_000_000n);
  assert.deepEqual([valued.display.amount, valued.display.symbol, valued.display.counterparty], ['250000', 'TRX', 'TJRabPrwbZy45sbavfcjinPJC18kjpRTv8']);
  assert.equal(valued.riskLevel, 'high');
  const expensive = tx(5_000_000_000n, 1n);
  assert.ok(expensive.warnings.some(w => w.startsWith('HIGH FEE')));
  const binary = call('review', { request: { chain: 'tron', kind: 'message', message: 'ff'.repeat(32) } });
  assert.equal(binary.decodeStatus, 'opaque');
});

test('F6/F11/F12: EVM and Solana fees, durable nonces and unknown token transfers are flagged', () => {
  const expensive = call('review', { request: { chain: 'evm', kind: 'transaction', transaction: { type: 2, chainId: 1, nonce: 0, to: '0x' + '22'.repeat(20), value: '1000000000000000', gasLimit: '1000000', maxFeePerGas: String(50_000n * 10n ** 9n), maxPriorityFeePerGas: '1' } } });
  assert.equal(expensive.riskLevel, 'high'); assert.ok(expensive.warnings[0].startsWith('HIGH FEE'));
  const priority = call('review', { request: solMessage([me, key(3), SYSTEM, COMPUTE], 1, 0, 2, [
    { p: 3, a: [], d: cat(new Uint8Array([2]), u32(1_400_000)) },
    { p: 3, a: [], d: cat(new Uint8Array([3]), u64(10n ** 9n)) },
    { p: 2, a: [0, 1], d: cat(u32(2), u64(1)) },
  ]) });
  assert.ok(priority.warnings.some(w => w.startsWith('HIGH FEE'))); assert.equal(priority.riskLevel, 'high');
  const nonce = call('review', { request: solMessage([me, key(4), base58.decode('SysvarRecentB1ockHashes11111111111111111111'), SYSTEM], 1, 0, 2, [{ p: 3, a: [1, 2, 0], d: u32(4) }]) });
  assert.ok(nonce.warnings.some(w => w.includes('durable nonce')));
  const transfer = new Interface(['function transfer(address to,uint256 amount)']).encodeFunctionData('transfer', ['0x' + '33'.repeat(20), 5n]);
  const unknown = call('review', { request: { chain: 'evm', kind: 'transaction', transaction: { type: 2, chainId: 1, nonce: 0, to: '0x' + '77'.repeat(20), value: '0', data: transfer, gasLimit: '60000', maxFeePerGas: '1000000000', maxPriorityFeePerGas: '1' } } });
  assert.equal(unknown.riskLevel, 'warning'); assert.equal(unknown.display.symbol, 'raw units');
});

// Bitcoin verified change --------------------------------------------------------
test('BTC: only outputs re-derived from the signing wallet are treated as change', () => {
  const root = HDKey.fromMasterSeed(mnemonicToSeedSync(MN, '')), fingerprint = root.fingerprint;
  const inputKey = root.derive("m/84'/0'/0'/0/0"), changeKey = root.derive("m/84'/0'/0'/1/3");
  const prev = new BitcoinTx(); prev.addInput({ txid: new Uint8Array(32).fill(1), index: 0 }); prev.addOutputAddress(p2wpkh(inputKey.publicKey).address, 100_000n, NETWORK);
  const tx = new BitcoinTx();
  tx.addInput({ txid: prev.id, index: 0, nonWitnessUtxo: prev.toBytes(true), witnessUtxo: { script: p2wpkh(inputKey.publicKey).script, amount: 100_000n },
    bip32Derivation: [[inputKey.publicKey, { fingerprint, path: [0x80000054, 0x80000000, 0x80000000, 0, 0] }]] });
  const stranger = HDKey.fromMasterSeed(mnemonicToSeedSync(MN, 'someone else')).derive("m/84'/0'/0'/0/0").publicKey;
  const external = p2wpkh(stranger).address;
  tx.addOutputAddress(external, 30_000n, NETWORK);
  tx.addOutput({ script: p2wpkh(changeKey.publicKey).script, amount: 69_000n, bip32Derivation: [[changeKey.publicKey, { fingerprint, path: [0x80000054, 0x80000000, 0x80000000, 1, 3] }]] });
  const request = { chain: 'bitcoin', psbt: Buffer.from(tx.toPSBT()).toString('base64') };
  assert.equal(call('review', { request }).display.headline, '2 recipients · 0.00099 BTC');
  const plan = call('resolveSigningPlan', { request, wallets });
  assert.deepEqual([plan.review.display.amount, plan.review.display.counterparty], ['0.0003', external]);
  assert.ok(plan.review.fields.some(f => f.label === 'Output 2 ownership'));
  // A lying derivation (right path label, foreign script) is not treated as change.
  const forged = new BitcoinTx(); forged.addInput({ txid: prev.id, index: 0, nonWitnessUtxo: prev.toBytes(true), witnessUtxo: { script: p2wpkh(inputKey.publicKey).script, amount: 100_000n },
    bip32Derivation: [[inputKey.publicKey, { fingerprint, path: [0x80000054, 0x80000000, 0x80000000, 0, 0] }]] });
  forged.addOutputAddress(external, 30_000n, NETWORK);
  forged.addOutput({ script: p2wpkh(HDKey.fromMasterSeed(mnemonicToSeedSync(MN, 'attacker')).derive("m/84'/0'/0'/1/3").publicKey).script, amount: 69_000n, bip32Derivation: [[changeKey.publicKey, { fingerprint, path: [0x80000054, 0x80000000, 0x80000000, 1, 3] }]] });
  const lie = call('resolveSigningPlan', { request: { chain: 'bitcoin', psbt: Buffer.from(forged.toPSBT()).toString('base64') }, wallets });
  assert.equal(lie.review.display.counterparty, undefined);
  assert.ok(!lie.review.fields.some(f => f.label.endsWith('ownership')));
});

// F13 / F15 -----------------------------------------------------------------------
test('F13: incremental QR collection equals batch decoding and rejects mixed sessions', () => {
  const typedData = daiPermit(true);
  const ur = EthSignRequest.constructETHRequest(Buffer.from(JSON.stringify(typedData)), 2, "m/44'/60'/0'/0/0", index.masterFingerprint, undefined, 1, signer);
  const encoder = ur.toUREncoder(60);
  const frames = Array.from({ length: encoder.fragmentsLength * 3 }, () => encoder.nextPart());
  const collector = new QRCollector(); let status;
  for (const frame of frames) { status = collector.add(frame); if (status.complete) break; }
  assert.equal(status.complete, true);
  // The strict JSON parser yields prototype-less objects; compare canonical JSON.
  assert.equal(JSON.stringify(status.request), JSON.stringify(call('decodeQR', { frames }).request));
  call('scanBegin');
  let scanned;
  for (const frame of frames) { scanned = call('scanAdd', { frame }); if (scanned.complete) break; }
  assert.equal(JSON.stringify(scanned.request), JSON.stringify(status.request));
  const other = EthSignRequest.constructETHRequest(Buffer.from('hello'), 3, "m/44'/60'/0'/0/0", index.masterFingerprint).toUREncoder(20);
  const mixed = new QRCollector(); mixed.add(frames[0]);
  assert.throws(() => mixed.add(other.nextPart()), /Mixed UR fountain sessions/);
});

test('F15: ur:psbt requests are accepted and answered in the same type; wrapped Base64 files decode', () => {
  const root = HDKey.fromMasterSeed(mnemonicToSeedSync(MN, '')), inputKey = root.derive("m/84'/0'/0'/0/0");
  const prev = new BitcoinTx(); prev.addInput({ txid: new Uint8Array(32).fill(1), index: 0 }); prev.addOutputAddress(p2wpkh(inputKey.publicKey).address, 50_000n, NETWORK);
  const tx = new BitcoinTx();
  tx.addInput({ txid: prev.id, index: 0, nonWitnessUtxo: prev.toBytes(true), bip32Derivation: [[inputKey.publicKey, { fingerprint: root.fingerprint, path: [0x80000054, 0x80000000, 0x80000000, 0, 0] }]] });
  tx.addOutputAddress(p2wpkh(inputKey.publicKey).address, 40_000n, NETWORK);
  const psbt = tx.toPSBT();
  const cbor = Buffer.concat([Buffer.from([0x59, psbt.length >> 8, psbt.length & 255]), Buffer.from(psbt)]);
  const frame = new UREncoder(new UR(cbor, 'psbt'), 2000).nextPart();
  const { request } = call('decodeQR', { frames: [frame] });
  const { result } = sign(request);
  const response = call('encodeResponse', { request, result });
  assert.ok(response.frames.every(f => f.toLowerCase().startsWith('ur:psbt/')));
  const wrapped = Buffer.from(psbt).toString('base64').replace(/(.{64})/g, '$1\n');
  assert.equal(call('decodePayload', { payload: wrapped }).request.psbt, Buffer.from(psbt).toString('base64'));
});

// Performance path ---------------------------------------------------------------
test('Native seed input derives the same public index and signatures as the phrase', () => {
  assert.deepEqual(call('derivePublicIndex', { seed: seedHex }), index);
  assert.throws(() => call('derivePublicIndex', { seed: seedHex.slice(2) }), e => e.code === 'SEED');
  assert.throws(() => call('derivePublicIndex', { seed: seedHex, mnemonic: MN }), e => e.code === 'SEED');
  const request = { chain: 'evm', kind: 'personal', path: "m/44'/60'/0'/0/0", address: signer, message: '0x' + Buffer.from('seed path').toString('hex') };
  assert.equal(sign(request, { useSeed: true }).result.signature, sign(request).result.signature);
});
