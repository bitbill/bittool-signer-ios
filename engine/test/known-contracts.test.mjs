import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { lookupContract, describeContract, knownContractCount } from '../src/known-contracts.js';
import { parseEVM } from '../src/evm.js';
import { parseTron } from '../src/tron.js';
import { Interface } from 'ethers';

const library = JSON.parse(readFileSync(new URL('../data/known-contracts.json', import.meta.url), 'utf8'));
const CATEGORIES = new Set(['dex', 'aggregator', 'infra', 'wallet', 'bridge', 'lending', 'staking', 'other', 'nft', 'perp', 'token']);
const PERMIT2 = '0x000000000022D473030F116dDEE9F6B43aC78BA3';
const UNLISTED = '0x1234567890AbcdEF1234567890aBcdef12345678';
const USDC = '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48';
const erc20 = new Interface(['function approve(address spender,uint256 amount)', 'function transfer(address to,uint256 amount)']);
const tx = (to, data) => ({ chain: 'evm', kind: 'transaction', transaction: { type: 2, chainId: 1, nonce: 0, to, data, value: '0', gasLimit: '100000', maxFeePerGas: '2', maxPriorityFeePerGas: '1' } });

test('every record is usable: shape, chain-correct addresses, no duplicates', () => {
  assert.equal(library.contracts.length, knownContractCount);
  assert.ok(knownContractCount > 1500);
  const seen = new Set();
  for (const c of library.contracts) {
    const key = `${c.chainFamily}:${c.chainId}:${c.address.toLowerCase()}`;
    assert.ok(!seen.has(key), 'duplicate ' + key); seen.add(key);
    assert.ok(c.name.length > 0 && c.name.length <= 80, c.address);
    assert.ok(c.protocol.length > 0 && c.protocol.length <= 48, c.address);
    assert.ok(CATEGORIES.has(c.category), c.category);
    if (c.chainFamily === 'evm') assert.match(c.address, /^0x[0-9a-f]{40}$/);
    else if (c.chainFamily === 'tron') assert.match(c.address, /^T[1-9A-HJ-NP-Za-km-z]{33}$/);
    else assert.match(c.address, /^[1-9A-HJ-NP-Za-km-z]{32,44}$/);
    assert.ok(['evm', 'tron', 'solana'].includes(c.chainFamily));
  }
});

test('lookup is case-insensitive on EVM and falls back to the every-chain entries', () => {
  const mainnet = lookupContract('evm', '1', PERMIT2);
  assert.equal(mainnet.name, 'Permit2');
  assert.equal(lookupContract('evm', '1', PERMIT2.toLowerCase()).name, 'Permit2');
  // Permit2 is deployed at the same address everywhere, so it resolves on a
  // chain that has no entry of its own, and says so.
  assert.equal(lookupContract('evm', '43114', PERMIT2).everyChain, true);
  assert.equal(lookupContract('evm', '1', UNLISTED), undefined);
  assert.equal(lookupContract('tron', undefined, 'TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t').protocol, 'Tether');
  // A TRON address is never matched against the EVM tables.
  assert.equal(lookupContract('evm', '1', 'TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t'), undefined);
  assert.equal(describeContract('evm', '1', UNLISTED, 'spender').known, false);
});

test('approving a known spender names it; approving an unlisted one warns and raises the risk', () => {
  const known = parseEVM(tx(USDC, erc20.encodeFunctionData('approve', [PERMIT2, 1000n]))).review;
  assert.equal(known.contract.name, 'Permit2');
  assert.equal(known.contract.protocol, 'Uniswap');
  assert.equal(known.contract.role, 'spender');
  assert.ok(known.fields.some(f => f.label === 'Spender (known contract)' && f.value.includes('Permit2 — Uniswap · infra')));
  assert.ok(!known.warnings.some(w => w.includes('not in the bundled list')));

  const unlisted = parseEVM(tx(USDC, erc20.encodeFunctionData('approve', [UNLISTED, 1000n]))).review;
  assert.equal(unlisted.contract.known, false);
  assert.equal(unlisted.riskLevel, 'high', 'approvals are already high risk');
  assert.ok(unlisted.warnings.some(w => w.includes('The spender is not in the bundled list')));
});

test('a transfer to a recognized token is not called an unknown contract', () => {
  // USDC is in the contract library itself; this one is only in the token
  // registry, which is already enough to identify it.
  const TRX_ERC20 = '0x50327c6c5a14DCaDE707ABad2E27eB517df87AB5';
  const transfer = parseEVM(tx(TRX_ERC20, erc20.encodeFunctionData('transfer', [UNLISTED, 1000n]))).review;
  assert.equal(transfer.contract.known, false);
  assert.equal(transfer.contract.token, 'TRON (TRX)');
  assert.ok(!transfer.warnings.some(w => w.includes('not in the bundled list')), transfer.warnings.join('\n'));
  // And a token the library does list is named outright.
  const listed = parseEVM(tx(USDC, erc20.encodeFunctionData('transfer', [UNLISTED, 1000n]))).review;
  assert.equal(listed.contract.known, true);
  assert.equal(listed.contract.category, 'token');
});

const varint = n => { n = BigInt(n); const bytes = []; do { bytes.push(Number(n & 127n)); n >>= 7n; if (n) bytes[bytes.length - 1] |= 128; } while (n); return new Uint8Array(bytes); };
const concat = (...parts) => { const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0)); let at = 0; for (const p of parts) { out.set(p, at); at += p.length; } return out; };
const pbN = (key, n) => concat(varint(key * 8), varint(n));
const pbB = (key, value) => concat(varint(key * 8 + 2), varint(value.length), value);
const hex = bytes => Buffer.from(bytes).toString('hex');
const utf8 = text => new TextEncoder().encode(text);

test('TRON contract calls carry the same notice', () => {
  // USDT on TRON is in the library, so the review names it rather than warning.
  const usdt = Buffer.from('41a614f803b6fd780986a42c78ec9c7f77e6ded13c', 'hex');
  const data = Buffer.from(erc20.encodeFunctionData('transfer', [UNLISTED, 1000n]).slice(2), 'hex');
  const value = concat(pbB(1, new Uint8Array(21).fill(0x41)), pbB(2, usdt), pbB(4, data));
  const contract = concat(pbN(1, 31), pbB(2, concat(pbB(1, utf8('type.googleapis.com/protocol.TriggerSmartContract')), pbB(2, value))));
  const raw = concat(pbB(1, new Uint8Array([0, 1])), pbB(4, new Uint8Array(8)), pbN(8, 1800000060000), pbB(11, contract), pbN(14, 1800000000000), pbN(18, 100000000));
  const review = parseTron({ chain: 'tron', kind: 'transaction', transaction: { raw_data_hex: hex(raw) } }).review;
  assert.equal(review.contract.known, true);
  assert.equal(review.contract.name, 'USDT (TRC20)');
  assert.ok(review.fields.some(f => f.label === 'Contract (known)'), JSON.stringify(review.fields.map(f => f.label)));
});

test('Solana instructions name a program the library knows, and say nothing extra about one it does not', async () => {
  const { parseSolana } = await import('../src/solana.js');
  const { base58 } = await import('@scure/base');
  const { ed25519 } = await import('@noble/curves/ed25519.js');
  const { short, toBase64 } = await import('../src/util.js');
  // One instruction with no accounts, signed by the fee payer, addressed to `program`.
  const build = (program, data) => {
    const payer = ed25519.getPublicKey(new Uint8Array(32).fill(9));
    const keys = [payer, base58.decode(program)];
    const message = concat(new Uint8Array([1, 0, 1]), short(keys.length), ...keys, new Uint8Array(32).fill(8),
      short(1), new Uint8Array([1]), short(0), short(data.length), data);
    return { chain: 'solana', kind: 'transaction', message: toBase64(message),
             signatures: [toBase64(ed25519.sign(message, new Uint8Array(32).fill(9)))] };
  };
  const names = review => review.fields.filter(f => f.label.endsWith('Program (known)')).map(f => f.value);

  // Raydium's AMM v4 is in the library and is not decoded by this engine.
  const raydium = parseSolana(build('675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8', new Uint8Array([9]))).review;
  assert.deepEqual(names(raydium), ['Raydium AMM v4 — Raydium · dex']);
  // The instruction is still undecoded, so the risk it carries is unchanged.
  assert.equal(raydium.riskLevel, 'high');
  assert.equal(raydium.decodeStatus, 'opaque');

  // An address nobody published: named programs say nothing, and no warning is
  // invented beyond the one the undecoded instruction already carries.
  const unlisted = parseSolana(build(base58.encode(new Uint8Array(32).fill(7)), new Uint8Array([9]))).review;
  assert.deepEqual(names(unlisted), []);
  assert.equal(unlisted.warnings.filter(w => w.includes('known public contracts')).length, 0);

  // A program this file decodes is already named by its own Action field, so
  // it is not relabelled from the library even though the library lists it.
  assert.equal(lookupContract('solana', undefined, 'MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr').name, 'Memo Program');
  const memo = parseSolana(build('MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr', utf8('hello'))).review;
  assert.deepEqual(names(memo), []);
  assert.ok(memo.fields.some(f => f.label.endsWith('Memo')));
});
