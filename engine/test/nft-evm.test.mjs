// NFT review displays for EVM/TRON calldata and EIP-712 marketplace orders
// (Seaport, Blur, LooksRare). Public test mnemonic and synthetic requests only.
import test from 'node:test';
import assert from 'node:assert/strict';
import { Interface, TypedDataEncoder, verifyTypedData, Transaction, id as keccakText } from 'ethers';
import { base58check } from '@scure/base';
import { sha256 } from '@noble/hashes/sha2.js';
import { execute } from '../src/index.js';
import { deriveAccounts } from '../src/keys.js';
import { concat, utf8, bytesToHex, hexToBytes } from '../src/util.js';
import { tokenIdText, indexWarning, reviewNftOrder } from '../src/nft-orders.js';

const MN = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const accounts = deriveAccounts({ mnemonic: MN }).accounts;
const ME = accounts[1].address;                               // 0x9858…Da94, the EVM test signer
const ATT = '0xBAbAbabAbabaBABaBAbABabaBAbAbaBaBAbABaBa';
const BAYC = '0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D';
const USDC = '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48';
const WETH = '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2';
const CREATOR = '0x1234567890123456789012345678901234567890';
const ZERO = '0x0000000000000000000000000000000000000000';
const MAX = ((1n << 256n) - 1n).toString();
const review = request => execute({ operation: 'review', request });
const sign = request => execute({ operation: 'sign', request, mnemonic: MN });
const fails = (f, code) => assert.throws(f, e => e.code === code, `Expected ${code}`);
const field = (r, label) => r.fields.find(f => f.label === label)?.value;
const severe = w => /^(HIGH RISK|UNLIMITED|HIGH FEE)/i.test(w);

const abi = new Interface([
  'function approve(address spender,uint256 amount)',
  'function transferFrom(address from,address to,uint256 amount)',
  'function safeTransferFrom(address from,address to,uint256 tokenId)',
  'function safeTransferFrom(address from,address to,uint256 tokenId,bytes data)',
  'function setApprovalForAll(address operator,bool approved)',
  'function safeTransferFrom(address from,address to,uint256 id,uint256 amount,bytes data)',
  'function safeBatchTransferFrom(address from,address to,uint256[] ids,uint256[] amounts,bytes data)',
  'function multiSend(bytes transactions)',
]);
const call = (name, args) => abi.encodeFunctionData(name, args);
const evmTx = (to, data, { chainId = 1, value = '0', from } = {}) => ({ chain: 'evm', kind: 'transaction',
  transaction: { type: 2, chainId, nonce: 0, to, value, data, gasLimit: '200000', maxFeePerGas: '1000000000', maxPriorityFeePerGas: '1', ...(from ? { from } : {}) } });
const packMultiSend = calls => '0x' + calls.map(([to, data, op = 0]) => op.toString(16).padStart(2, '0') + to.slice(2) + '0'.repeat(64)
  + ((data.length - 2) / 2).toString(16).padStart(64, '0') + data.slice(2)).join('');

// ---------------------------------------------------------------------------
// Calldata: ERC-20/ERC-721 ambiguity, collection approvals, ERC-1155, MultiSend.

test('approve on a non-registry contract is ambiguous and never shown as a revoke', () => {
  const r = review(evmTx(BAYC, call('approve', [ATT, 0])));
  assert.equal(r.display.action, 'Approve (NFT or token)');
  assert.notEqual(r.display.action, 'Revoke Approval');
  assert.match(r.display.headline, /NFT #0 — or 0 raw token units if this is an ERC-20/);
  assert.deepEqual([r.display.assetKind, r.display.assetContract, r.display.tokenId, r.display.counterpartyLabel, r.display.counterparty], ['nftOrToken', BAYC, '0', 'Spender', ATT]);
  assert.equal(r.riskLevel, 'high');
  assert.match(field(r, 'Interpretation'), /ERC-721: approves .* token #0\. ERC-20: sets the allowance .* to 0/);
  assert.equal(field(r, 'Contract (NFT or token)'), BAYC);
  assert.equal(r.display.note, undefined);
  assert.ok(!r.summary.includes('Revoke'));
  // Unlimited value on an ambiguous contract keeps the red UNLIMITED warning.
  const unlimited = review(evmTx(BAYC, call('approve', [ATT, MAX])));
  assert.equal(unlimited.display.amount, 'Unlimited');
  assert.ok(unlimited.warnings.some(w => w.startsWith('UNLIMITED')));
});

test('registry ERC-20 approvals keep the fungible display, including revoke for 0', () => {
  const revoke = review(evmTx(USDC, call('approve', [ATT, 0])));
  assert.equal(revoke.display.action, 'Revoke Approval');
  assert.equal(revoke.display.assetKind, undefined);
  const spend = review(evmTx(USDC, call('approve', [ATT, 5_000_000])));
  assert.deepEqual([spend.display.action, spend.display.amount, spend.display.symbol], ['Approve Spending', '5', 'USDC']);
});

test('approve(0x0, id) is shown as clearing an NFT approval, without claiming an ERC-20 rule', () => {
  const r = review(evmTx(BAYC, call('approve', [ZERO, 1234])));
  assert.equal(r.display.action, 'Clear NFT Approval (if ERC-721)');
  assert.equal(r.display.headline, 'NFT #1234');
  assert.equal(r.riskLevel, 'warning');
  assert.equal(r.display.note, undefined);
  assert.ok(r.warnings.some(w => w.includes('Many ERC-20 implementations reject a zero spender')));
  assert.ok(!r.warnings.concat(field(r, 'Interpretation')).some(w => /standard ERC-20 contracts reject/i.test(w)));
});

test('transferFrom on a non-registry contract is "NFT or token"; registry tokens stay fungible', () => {
  const r = review(evmTx('0x' + '22'.repeat(20), call('transferFrom', [ME, ATT, 10n ** 18n])));
  assert.equal(r.display.action, 'Transfer (NFT or token)');
  assert.notEqual(r.display.action, 'Send NFT');
  assert.match(r.display.headline, /raw units if ERC-20/);
  assert.equal(r.display.assetKind, 'nftOrToken');
  assert.ok(field(r, 'Interpretation').includes('The contract type cannot be confirmed offline'));
  assert.equal(r.title, 'Transfer asset (type unconfirmed)');
  const usdc = review(evmTx(USDC, call('transferFrom', [ME, ATT, 1_500_000])));
  assert.deepEqual([usdc.display.action, usdc.display.amount, usdc.display.symbol, usdc.display.assetKind], ['Transfer', '1.5', 'USDC', undefined]);
});

test('ERC-721 safeTransferFrom is an NFT with full token ID fields and an NFT summary', () => {
  const r = review(evmTx(BAYC, call('safeTransferFrom(address,address,uint256)', [ME, ATT, 42])));
  assert.deepEqual([r.display.action, r.display.headline, r.display.assetKind, r.display.assetContract, r.display.tokenId], ['Send NFT', 'NFT #42', 'nft', BAYC, '42']);
  assert.equal(r.display.assetContractLabel, 'NFT contract (not verified)');
  assert.equal(field(r, 'Token ID'), '42');
  assert.equal(field(r, 'Token ID (hex)'), '0x' + '2a'.padStart(64, '0'));
  assert.ok(r.summary.includes('#42') && !r.summary.includes('raw units'));
  assert.equal(field(r, 'Receiver callback bytes'), undefined);
  const withData = review(evmTx(BAYC, call('safeTransferFrom(address,address,uint256,bytes)', [ME, ATT, 42, '0xbeef'])));
  assert.equal(field(withData, 'Receiver callback bytes'), '0xbeef');
  // Native value on an NFT call leads the display but keeps the NFT fields and the recipient;
  // the asset contract's caption says it receives the value.
  const valued = review(evmTx(BAYC, call('safeTransferFrom(address,address,uint256)', [ME, ATT, 42]), { value: '1000000000000000000' }));
  assert.deepEqual([valued.display.amount, valued.display.symbol, valued.display.assetKind, valued.display.tokenId], ['1', 'ETH', 'nft', '42']);
  assert.deepEqual([valued.display.headline, valued.display.counterpartyLabel, valued.display.counterparty], ['NFT #42', 'To', ATT]);
  assert.equal(valued.display.assetContractLabel, 'NFT contract (not verified) · receives the 1 ETH');
  assert.ok(valued.warnings.includes('This call also sends 1 ETH to the contract.'));
  assert.ok(valued.summary.includes('also sends 1 ETH'));
  const operator = review(evmTx(BAYC, call('setApprovalForAll', [ATT, true]), { value: '5' }));
  assert.deepEqual([operator.display.counterpartyLabel, operator.display.counterparty, operator.display.assetContract], ['Operator', ATT, BAYC]);
  // A Safe execTransaction carrying value pays the Safe, not the inner NFT contract.
  const exec = new Interface(['function execTransaction(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,bytes signatures)']);
  const safe = '0x' + '5a'.repeat(20);
  const wrapped = review(evmTx(safe, exec.encodeFunctionData('execTransaction', [BAYC, 0, call('safeTransferFrom(address,address,uint256)', [ME, ATT, 42]), 0, 0, 0, 0, ZERO, ZERO, '0x']), { value: '5' }));
  assert.deepEqual([wrapped.display.counterpartyLabel, wrapped.display.assetContractLabel], ['Contract', 'NFT contract (not verified)']);
});

test('long ENS token IDs are abbreviated in the headline with full decimal and hex fields; ENS is a mainnet detail only', () => {
  const ens = '0x57f1887a8BF19b14fC0dF6Fd9B2acc9Af147eA85', label = BigInt(keccakText('vitalik'));
  const r = review(evmTx(ens, call('safeTransferFrom(address,address,uint256)', [ME, ATT, label])));
  assert.equal(r.display.headline, 'NFT #79233663…80642508 (77 digits)');
  assert.equal(r.display.tokenId, label.toString());
  assert.equal(field(r, 'Token ID'), label.toString());
  assert.equal(field(r, 'Token ID (hex)'), '0xaf2caa1c2ca1d027f1ac823b529d0a67cd144264b2789fa2ea4d63a67c7103cc');
  assert.match(field(r, 'Known contract (Ethereum)'), /^ENS \.eth registrar/);
  assert.ok(!JSON.stringify(r).includes('vitalik'));
  assert.equal(r.display.note, undefined);
  const base = review(evmTx(ens, call('safeTransferFrom(address,address,uint256)', [ME, ATT, label]), { chainId: 8453 }));
  assert.equal(field(base, 'Known contract (Ethereum)'), undefined);
  assert.equal(tokenIdText(999_999_999_999n), '#999999999999');
  assert.equal(tokenIdText(1_000_000_000_000n), '#10000000…00000000 (13 digits)');
});

test('setApprovalForAll(true) is a red HIGH RISK warning naming the contract; revoke stays a warning', () => {
  const r = review(evmTx(BAYC, call('setApprovalForAll', [ATT, true])));
  assert.equal(r.riskLevel, 'high');
  const w = r.warnings.find(x => x.startsWith('HIGH RISK:'));
  assert.ok(w && w.includes(`in contract ${BAYC}`) && w.includes(ATT) && w.includes('including ones received later'));
  assert.equal(r.display.action, 'Approve All NFTs');
  assert.ok(r.display.headline.includes('0xBC4C…f13D'));
  assert.deepEqual([r.display.assetContract, r.display.assetContractLabel, r.display.counterpartyLabel, r.display.counterparty], [BAYC, 'NFT contract (not verified)', 'Operator', ATT]);
  assert.equal(r.display.note, undefined);
  assert.equal(field(r, 'Collection contract'), BAYC);
  assert.equal(field(r, 'Recipient / contract'), undefined);
  // A well-known operator gets no label and no lower risk.
  const conduit = review(evmTx(BAYC, call('setApprovalForAll', ['0x1E0049783F008A0085193E00003D00cd54003c71', true])));
  assert.equal(conduit.riskLevel, 'high'); assert.equal(conduit.display.note, undefined);
  const revoke = review(evmTx(BAYC, call('setApprovalForAll', [ATT, false])));
  assert.equal(revoke.riskLevel, 'warning');
  assert.equal(revoke.display.action, 'Revoke NFT Approval');
  assert.ok(!revoke.warnings.some(severe));
});

test('ERC-1155 single transfer shows quantity × ID without raw-unit wording', () => {
  const r = review(evmTx(BAYC, call('safeTransferFrom(address,address,uint256,uint256,bytes)', [ME, ATT, 7, 3, '0x'])));
  assert.deepEqual([r.display.action, r.display.headline, r.display.assetKind, r.display.tokenId], ['Send ERC-1155 Token', '3 × #7', 'multiToken', '7']);
  assert.equal(field(r, 'Quantity'), '3');
  assert.equal(field(r, 'Receiver callback bytes'), undefined);
  assert.equal(r.summary, 'Send 3 × #7 (0xBC4C…f13D)');
  assert.ok(!r.summary.includes('raw units'));
});

test('ERC-1155 batch uses one Items field, flags duplicates and zero quantities, and keeps the 32-item cap', () => {
  const r = review(evmTx(BAYC, call('safeBatchTransferFrom', [ME, ATT, [1, 1, 2], [2, 3, 0], '0x'])));
  assert.equal(r.display.action, 'Send ERC-1155 Batch');
  assert.equal(r.display.headline, '3 items · IDs #1, #2');
  assert.equal(r.display.assetKind, 'multiToken');
  assert.equal(field(r, 'Items'), '#1 × 2\n#1 × 3\n#2 × 0');
  assert.equal(field(r, 'Distinct token IDs'), '2');
  assert.equal(field(r, 'Total quantity'), '5');
  assert.ok(r.warnings.some(w => w.includes('Token #1 appears 2 times') && w.includes('total quantity is 5')));
  assert.ok(r.warnings.some(w => w.includes('quantity 0')));
  assert.equal(field(r, 'Receiver callback bytes'), undefined);
  assert.ok(r.summary.startsWith('Send ERC-1155 batch: 3 items'));
  const ids = Array.from({ length: 32 }, (_, i) => i + 1);
  const full = review(evmTx(BAYC, call('safeBatchTransferFrom', [ME, ATT, ids, ids.map(() => 1), '0x01'])));
  assert.equal(full.fields.filter(f => f.label === 'Items').length, 1);
  assert.equal(full.fields.filter(f => /^Token \d+$/.test(f.label)).length, 0);
  assert.equal(field(full, 'Receiver callback bytes'), '0x01');
  assert.match(full.display.headline, /^32 items · IDs #1, #2 \(\+30 more\)$/);
  fails(() => review(evmTx(BAYC, call('safeBatchTransferFrom', [ME, ATT, [...ids, 33], [...ids, 33].map(() => 1), '0x']))), 'LIMIT');
});

test('MultiSend headline lists inner NFT calls by risk and indexes their warnings once', () => {
  const data = call('multiSend', [packMultiSend([[BAYC, call('safeTransferFrom(address,address,uint256)', [ME, ATT, 42])], [BAYC, call('setApprovalForAll', [ATT, true])]])]);
  const r = review(evmTx('0x' + '5a'.repeat(20), data));
  assert.equal(r.display.headline, '2 calls: Approve All NFTs (All your NFTs in 0xBC4C…f13D); Send NFT (NFT #42)');
  assert.ok(r.warnings.some(w => w.startsWith('HIGH RISK: Call 2: ') && w.includes(BAYC)));
  assert.equal(r.warnings.filter(w => w.startsWith('Contract identity')).length, 1);
  assert.equal(r.riskLevel, 'high');
  assert.ok(r.summary.includes('Approve All NFTs'));
  // Delegatecalls and UNLIMITED warnings keep their red prefixes with the call index.
  const risky = review(evmTx('0x' + '5a'.repeat(20), call('multiSend', [packMultiSend([[BAYC, call('approve', [ATT, MAX])], [BAYC, call('safeTransferFrom(address,address,uint256)', [ME, ATT, 1]), 1]])])));
  assert.ok(risky.warnings.some(w => w.startsWith('UNLIMITED') && w.includes('(Call 1)')));
  assert.ok(risky.warnings.some(w => w === 'HIGH RISK: Call 2 uses DELEGATECALL.'));
  assert.equal(indexWarning('HIGH FEE: x', 'Order 2'), 'HIGH FEE: Order 2: x');
});

test('Safe execTransaction keeps the inner NFT display without duplicated generic warnings', () => {
  const exec = new Interface(['function execTransaction(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,bytes signatures)']);
  const data = exec.encodeFunctionData('execTransaction', [BAYC, 0, call('safeTransferFrom(address,address,uint256)', [ME, ATT, 42]), 0, 0, 0, 0, ZERO, ZERO, '0x']);
  const r = review(evmTx('0x' + '5a'.repeat(20), data));
  assert.deepEqual([r.display.action, r.display.headline, r.display.assetKind], ['Safe: Send NFT', 'NFT #42', 'nft']);
  assert.equal(r.warnings.filter(w => w.startsWith('Contract identity')).length, 1);
  assert.equal(r.summary, 'Safe: Send NFT #42 (0xBC4C…f13D)');
});

test('JSON EVM transactions may carry from: it is shown, excluded from hashing and checked at signing', () => {
  const request = evmTx('0x000000000000000000000000000000000000dEaD', '0x', { value: '1000', from: ME });
  const r = review(request);
  assert.equal(field(r, 'Sender'), ME);
  const out = sign(request);
  assert.equal(Transaction.from(out.serializedTransaction).from, ME);
  const { from, ...plain } = request.transaction;
  assert.equal(out.digest, Transaction.from(plain).unsignedHash);
  fails(() => sign(evmTx('0x000000000000000000000000000000000000dEaD', '0x', { from: ATT })), 'SIGNER');
  fails(() => review(evmTx('0x000000000000000000000000000000000000dEaD', '0x', { from: '0x1234' })), 'TRANSACTION');
  fails(() => review(evmTx('0x000000000000000000000000000000000000dEaD', '0x', { from: ME.replace('Ef', 'eF') })), 'TRANSACTION');
  // from: null means absent (as in ethers): accepted, not shown, and not hashed.
  const absent = evmTx('0x000000000000000000000000000000000000dEaD', '0x', { value: '1000' });
  absent.transaction.from = null;
  assert.equal(field(review(absent), 'Sender'), undefined);
  assert.equal(sign(absent).digest, out.digest);
});

// ---------------------------------------------------------------------------
// TRON: the same decoder, with Base58 contracts.

function tronCall(contractBase58, data, callValue = 0) {
  const B58 = base58check(sha256);
  const varint = n => { n = BigInt(n); const out = []; do { let b = Number(n & 127n); n >>= 7n; if (n) b |= 128; out.push(b); } while (n); return new Uint8Array(out); };
  const pbN = (f, v) => concat(varint(f << 3), varint(v)), pbB = (f, b) => concat(varint((f << 3) | 2), varint(b.length), b);
  const trigger = concat(pbB(1, B58.decode(accounts[2].address)), pbB(2, B58.decode(contractBase58)), ...(callValue ? [pbN(3, callValue)] : []), pbB(4, hexToBytes(data)));
  const any = concat(pbB(1, utf8('type.googleapis.com/protocol.TriggerSmartContract')), pbB(2, trigger));
  const raw = concat(pbB(1, new Uint8Array([0, 1])), pbB(4, new Uint8Array(8)), pbN(8, 1800000060000), pbB(11, concat(pbN(1, 31), pbB(2, any))), pbN(14, 1800000000000), pbN(18, 100000000));
  return { chain: 'tron', kind: 'transaction', transaction: { raw_data_hex: bytesToHex(raw) } };
}
const TRC721 = 'TJRabPrwbZy45sbavfcjinPJC18kjpRTv8';
const tronHex = a => '0x' + bytesToHex(base58check(sha256).decode(a).slice(1));

test('TRON TRC-721 transfers and approvals use Base58 contracts in the NFT display and summary', () => {
  const r = review(tronCall(TRC721, call('safeTransferFrom(address,address,uint256)', [tronHex(accounts[2].address), ATT, 42])));
  assert.deepEqual([r.display.action, r.display.headline, r.display.assetKind, r.display.assetContract, r.display.tokenId], ['Send NFT', 'NFT #42', 'nft', TRC721, '42']);
  assert.equal(r.summary, 'TRON Send NFT #42 (TJRabP…RTv8)');
  assert.equal(r.fields.filter(f => f.label === 'Contract').length, 1);
  assert.equal(field(r, 'Contract'), TRC721);
  assert.equal(field(r, 'NFT contract'), undefined);
  assert.ok(r.display.counterparty.startsWith('T'));
  const ambiguous = review(tronCall(TRC721, call('transferFrom', [tronHex(accounts[2].address), ATT, 5])));
  assert.deepEqual([ambiguous.display.action, ambiguous.display.assetKind, ambiguous.display.assetContract], ['Transfer (NFT or token)', 'nftOrToken', TRC721]);
  assert.ok(!/0x[0-9a-fA-F]{40}/.test(field(ambiguous, 'Interpretation')));
  assert.equal(field(ambiguous, 'Contract (NFT or token)'), undefined);
  const all = review(tronCall(TRC721, call('setApprovalForAll', [ATT, true])));
  assert.equal(all.riskLevel, 'high');
  assert.ok(all.warnings.some(w => w.startsWith('HIGH RISK:') && w.includes(`in contract ${TRC721}`)));
  assert.ok(all.display.headline.includes('TJRabP…RTv8'));
  // Registry USDT stays fungible.
  const usdt = review(tronCall('TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t', call('transferFrom', [tronHex(accounts[2].address), ATT, 1234])));
  assert.equal(usdt.display.assetKind, undefined);
  assert.equal(usdt.display.symbol, 'USDT');
});

test('TRON NFT calls with TRX attached keep the recipient; only address fields become Base58', () => {
  const attTron = base58check(sha256).encode(concat(new Uint8Array([0x41]), hexToBytes(ATT)));
  const r = review(tronCall(TRC721, call('safeTransferFrom(address,address,uint256)', [tronHex(accounts[2].address), ATT, 42]), 5_000_000));
  assert.deepEqual([r.display.action, r.display.amount, r.display.symbol, r.display.headline], ['Send NFT', '5', 'TRX', 'NFT #42']);
  assert.deepEqual([r.display.counterpartyLabel, r.display.counterparty, r.display.assetContract], ['To', attTron, TRC721]);
  assert.equal(r.display.assetContractLabel, 'NFT contract (not verified) · receives the 5 TRX');
  assert.equal(r.riskLevel, 'high');
  assert.equal(r.summary, 'TRON Send NFT #42 (TJRabP…RTv8) (also sends 5 TRX)');
  // 20-byte callback data is bytes, not an address; the recipient and owner are addresses.
  const callback = '0x' + '11'.repeat(20);
  const batch = review(tronCall(TRC721, call('safeBatchTransferFrom', [tronHex(accounts[2].address), ATT, [1, 2], [1, 1], callback])));
  assert.equal(field(batch, 'Receiver callback bytes'), callback);
  assert.equal(field(batch, 'Recipient'), attTron);
  assert.equal(field(batch, 'Asset owner'), accounts[2].address);
  // A clear-approval call has no counterparty; the contract appears once, in the asset box.
  const clear = review(tronCall(TRC721, call('approve', [ZERO, 7])));
  assert.deepEqual([clear.display.counterparty, clear.display.assetContract], [undefined, TRC721]);
});

// ---------------------------------------------------------------------------
// EIP-712 marketplace orders.

const typed = spec => Object.fromEntries(Object.entries(spec).map(([k, v]) => [k, v.map(([name, type]) => ({ name, type }))]));
const SEAPORT16 = '0x0000000000000068F116a894984e2DB1123eB395';
const OS_FEE = '0x0000a26b00c1F0DF003000390027140000fAa719';
const OS_ZONE = '0x000056F7000000EcE9003ca63978907a00FFD100';
const OS_CONDUIT_KEY = '0x0000007b02230091a7ed01230072f7006a004d60a8d4e71d599b8104250f0000';
const SEAPORT_TYPES = typed({
  OrderComponents: [['offerer', 'address'], ['zone', 'address'], ['offer', 'OfferItem[]'], ['consideration', 'ConsiderationItem[]'], ['orderType', 'uint8'], ['startTime', 'uint256'], ['endTime', 'uint256'], ['zoneHash', 'bytes32'], ['salt', 'uint256'], ['conduitKey', 'bytes32'], ['counter', 'uint256']],
  OfferItem: [['itemType', 'uint8'], ['token', 'address'], ['identifierOrCriteria', 'uint256'], ['startAmount', 'uint256'], ['endAmount', 'uint256']],
  ConsiderationItem: [['itemType', 'uint8'], ['token', 'address'], ['identifierOrCriteria', 'uint256'], ['startAmount', 'uint256'], ['endAmount', 'uint256'], ['recipient', 'address']],
});
const EIP712_DOMAIN = typed({ EIP712Domain: [['name', 'string'], ['version', 'string'], ['chainId', 'uint256'], ['verifyingContract', 'address']] });
const seaportDomain = (verifyingContract = SEAPORT16, chainId = 1, version = '1.6') => ({ name: 'Seaport', version, chainId, verifyingContract });
const item = (itemType, token, id, start, recipient, end = start) => ({ itemType, token, identifierOrCriteria: String(id), startAmount: String(start), endAmount: String(end), ...(recipient ? { recipient } : {}) });
const order = (offer, consideration, more = {}) => ({ offerer: ME, zone: ZERO, offer, consideration, orderType: 0, startTime: '1700000000', endTime: '1710000000',
  zoneHash: '0x' + '00'.repeat(32), salt: '12345', conduitKey: OS_CONDUIT_KEY, counter: '0', ...more });
const seaport = (message, domain = seaportDomain()) => ({ types: { ...EIP712_DOMAIN, ...SEAPORT_TYPES }, primaryType: 'OrderComponents', domain, message });
const padding = () => ({ offerer: ZERO, zone: ZERO, offer: [], consideration: [], orderType: 0, startTime: '0', endTime: '0', zoneHash: '0x' + '00'.repeat(32), salt: '0', conduitKey: '0x' + '00'.repeat(32), counter: '0' });
const bulk = (leaves, height) => {
  let tree = leaves;
  for (let i = 0; i < height - 1; i++) { const next = []; for (let j = 0; j < tree.length; j += 2) next.push([tree[j], tree[j + 1]]); tree = next; }
  return { types: { ...SEAPORT_TYPES, BulkOrder: [{ name: 'tree', type: 'OrderComponents' + '[2]'.repeat(height) }] }, primaryType: 'BulkOrder', domain: seaportDomain(), message: { tree } };
};
const td = (typedData, more = {}) => ({ chain: 'evm', kind: 'typedData', typedData, ...more });
const eth = n => (BigInt(Math.round(n * 1000)) * 10n ** 15n).toString();
const listing = (more = {}) => seaport(order([item(2, BAYC, 1234, 1)], [item(0, ZERO, 0, eth(0.95), ME), item(0, ZERO, 0, eth(0.025), OS_FEE), item(0, ZERO, 0, eth(0.025), CREATOR)], more));
/** Signs, then checks the digest against ethers and recovers the signer from the signature. */
function signAndRecover(typedData) {
  const { EIP712Domain, ...types } = typedData.types;
  const out = sign(td(typedData));
  assert.equal(out.digest, TypedDataEncoder.hash(typedData.domain, types, typedData.message));
  assert.equal(verifyTypedData(typedData.domain, types, typedData.message, '0x' + out.signature), ME);
  return out;
}

test('Seaport phishing listing (1 wei, criteria 0, never expires) is decoded with red warnings', () => {
  const t = seaport(order([item(2, BAYC, 1234, 1), item(4, BAYC, 0, 1)], [item(0, ZERO, 0, 1, ATT)], { endTime: MAX }));
  const r = review(td(t, { address: ME }));
  assert.equal(r.riskLevel, 'high');
  assert.ok(r.display.action.startsWith('List NFT for Sale (Seaport 1.6)'));
  assert.deepEqual([r.display.amount, r.display.symbol, r.display.assetKind, r.display.assetContract], ['0', 'ETH', 'nftOrder', BAYC]);
  assert.deepEqual(r.display.give, ['NFT #1234 · 0xBC4C…f13D', 'ANY 1 token · 0xBC4C…f13D']);
  assert.deepEqual(r.display.receive, ['Nothing']);
  assert.deepEqual(r.display.others, ['0.000000000000000001 ETH → 0xBAbA…BaBa (unrecognised recipient)']);
  assert.ok(r.warnings.includes('HIGH RISK: You receive nothing for the items you give.'));
  assert.ok(r.warnings.includes(`HIGH RISK: The buyer may choose ANY 1 token(s) of yours from ${BAYC}.`));
  assert.ok(r.warnings.some(w => w.startsWith('HIGH RISK: This order effectively never expires')));
  assert.ok(!JSON.stringify(r).includes('royalty'));
  assert.equal(r.display.note, undefined);
  assert.equal(field(r, 'Expires (UTC)'), 'Never (maximum value)');
  assert.ok(field(r, 'Signed values').includes('"offer"'));
  signAndRecover(t);
});

test('legitimate Seaport listing shows proceeds, fees and chain-scoped OpenSea labels only as text', () => {
  const t = listing();
  const r = review(td(t, { address: ME }));
  assert.deepEqual([r.display.action, r.display.amount, r.display.symbol, r.display.headline, r.display.tokenId], ['List NFT for Sale (Seaport 1.6)', '0.95', 'ETH', 'NFT #1234 · 0xBC4C…f13D', '1234']);
  assert.deepEqual(r.display.receive, ['0.95 ETH']);
  assert.deepEqual(r.display.others, ['0.025 ETH → 0x0000…a719 (OpenSea fee recipient)', '0.025 ETH → 0x1234…7890 (unrecognised recipient)']);
  assert.deepEqual([r.display.counterpartyLabel, r.display.counterparty], ['Marketplace', SEAPORT16]);
  assert.equal(r.decodeStatus, 'fullyDecoded');
  assert.equal(r.riskLevel, 'high');
  assert.ok(!r.warnings.some(severe), r.warnings.join('\n'));
  assert.match(field(r, 'Conduit key'), /OpenSea conduit 0x1E0049783F008A0085193E00003D00cd54003c71/);
  assert.equal(r.summary, 'Seaport listing: NFT #1234 · 0xBC4C…f13D for 0.95 ETH');
  assert.equal(r.display.note, undefined);
  // No OpenSea trust labels on BNB Smart Chain, where opensea-js does not
  // operate: no fee recipient, conduit or zone is vouched for there. The
  // contract itself is still named, because Seaport is deployed at the same
  // address on every EVM network and the known-contract library says so.
  const bsc = review(td(seaport(t.message, seaportDomain(SEAPORT16, 56))));
  assert.equal(bsc.display.action, 'List NFT for Sale (Seaport 1.6)');
  assert.ok(!/OpenSea (fee recipient|conduit|zone)/.test(JSON.stringify(bsc)), JSON.stringify(bsc.fields));
  assert.equal(bsc.contract.name, 'OpenSea Seaport 1.6');
  assert.equal(bsc.contract.everyChain, true);
  signAndRecover(t);
});

test('Seaport offer (bid) receives the NFT, so there is no false "receive nothing" or share warning', () => {
  const t = seaport(order([item(1, WETH, 0, eth(1))], [item(2, BAYC, 1234, 1, ME), item(1, WETH, 0, eth(0.025), OS_FEE), item(1, WETH, 0, eth(0.05), CREATOR)]));
  const r = review(td(t));
  assert.deepEqual([r.display.action, r.display.amount, r.display.symbol, r.display.headline], ['Make NFT Offer (Seaport 1.6)', '1', 'WETH', 'For NFT #1234 · 0xBC4C…f13D']);
  assert.deepEqual(r.display.give, ['1 WETH']);
  assert.deepEqual(r.display.receive, ['NFT #1234 · 0xBC4C…f13D']);
  assert.ok(!r.warnings.some(severe), r.warnings.join('\n'));
  assert.equal(r.summary, 'Seaport offer: 1 WETH for NFT #1234 · 0xBC4C…f13D');
  // Collection offer: the criteria item is something you receive, not a warning.
  const collection = review(td(seaport(order([item(1, WETH, 0, eth(1))], [item(4, BAYC, 0, 1, ME)]))));
  assert.equal(collection.display.headline, 'For ANY 1 token · 0xBC4C…f13D');
  assert.ok(!collection.warnings.some(severe));
});

test('Seaport listing rules: payment share, Dutch auction lower bound, criteria roots, zones and offerer', () => {
  const share = review(td(seaport(order([item(2, BAYC, 1, 1)], [item(0, ZERO, 0, eth(0.1), ME), item(0, ZERO, 0, eth(0.9), ATT)]))));
  assert.ok(share.warnings.some(w => w.startsWith('HIGH RISK: Most of the ETH payment goes to other addresses')));
  assert.ok(share.display.others[0].includes('(unrecognised recipient)'));
  const dutch = review(td(seaport(order([item(2, BAYC, 1, 1)], [item(0, ZERO, 0, eth(1), ME, eth(0.5))]))));
  assert.equal(dutch.display.amount, '0.5');
  assert.equal(dutch.display.receive[0], '1 ETH → 0.5 ETH (changes linearly over time)');
  const root = review(td(seaport(order([item(4, BAYC, '0x' + 'ab'.repeat(32), 2)], [item(0, ZERO, 0, eth(1), ME)]))));
  assert.ok(root.warnings.some(w => w.startsWith('HIGH RISK: The buyer may choose 2 token(s) of yours') && w.includes('criteria root 0xabab')));
  assert.equal(root.decodeStatus, 'partiallyDecoded');
  const restricted = review(td(seaport(order([item(2, BAYC, 1, 1)], [item(0, ZERO, 0, eth(1), ME)], { orderType: 2, zone: ATT }))));
  assert.equal(restricted.decodeStatus, 'partiallyDecoded');
  assert.ok(restricted.warnings.some(w => w.includes(`validated by zone ${ATT}`)));
  const signedZone = review(td(seaport(order([item(2, BAYC, 1, 1)], [item(0, ZERO, 0, eth(1), ME)], { orderType: 2, zone: OS_ZONE }))));
  assert.equal(signedZone.decodeStatus, 'fullyDecoded');
  assert.match(field(signedZone, 'Zone'), /OpenSea Signed Zone v2/);
  const other = review(td(listing({ offerer: CREATOR }), { address: ME }));
  assert.ok(other.warnings.some(w => w.startsWith('HIGH RISK: The order offerer') && w.includes(CREATOR)));
  const long = review(td(listing({ endTime: String(1700000000 + 400 * 86400) })));
  assert.ok(long.warnings.some(w => w.startsWith('This order stays valid for more than a year')));
  const contractType = review(td(listing({ orderType: 4 })));
  assert.ok(contractType.warnings.some(w => w.startsWith('HIGH RISK: Order type CONTRACT')));
  const unknownToken = review(td(seaport(order([item(2, BAYC, 1, 1)], [item(1, '0x' + '77'.repeat(20), 0, 5000, ME)]))));
  assert.equal(unknownToken.decodeStatus, 'partiallyDecoded');
  assert.deepEqual([unknownToken.display.amount, unknownToken.display.symbol], ['5000', 'raw units']);
});

test('Seaport BulkOrder with padding lists the real orders and signs the same digest', () => {
  const real = [order([item(2, BAYC, 1, 1)], [item(0, ZERO, 0, eth(0.5), ME)]), order([item(2, BAYC, 2, 1)], [item(0, ZERO, 0, eth(0.7), ME)])];
  const t = bulk([...real, padding(), padding()], 2);
  const r = review(td(t));
  assert.equal(r.display.action, 'Bulk List (2 orders)');
  assert.deepEqual([r.display.amount, r.display.symbol], ['1.2', 'ETH']);
  assert.equal(r.display.headline, 'NFT #1 · 0xBC4C…f13D for 0.5 ETH; NFT #2 · 0xBC4C…f13D for 0.7 ETH');
  assert.deepEqual(r.display.give, ['Order 1: NFT #1 · 0xBC4C…f13D', 'Order 2: NFT #2 · 0xBC4C…f13D']);
  assert.match(field(r, 'Bulk order'), /2 orders in a tree of 4 entries \(height 2\); 2 empty padding entries/);
  assert.ok(field(r, 'Order 2 · You give · Item 1').includes('Token ID: 2'));
  assert.equal(r.riskLevel, 'high');
  signAndRecover(t);
  // A hostile leaf inside a bulk tree is still flagged, indexed by order.
  const hostile = review(td(bulk([real[0], order([item(4, BAYC, 0, 1)], [item(0, ZERO, 0, 1, ATT)])], 1)));
  assert.ok(hostile.warnings.includes('HIGH RISK: Order 2: You receive nothing for the items you give.'));
});

test('Seaport-shaped orders for an unrecognised contract carry a HIGH RISK warning', () => {
  const r = review(td(listing().message && seaport(listing().message, seaportDomain('0x000000000000000000000000000000000000dEaD'))));
  assert.ok(r.warnings.some(w => w.startsWith('HIGH RISK: Seaport-format order for an unrecognised contract')));
  assert.equal(r.decodeStatus, 'partiallyDecoded');
  assert.equal(r.display.counterpartyLabel, 'Contract');
  assert.ok(!JSON.stringify(r).includes('OpenSea'));
  // Seaport 1.5 is recognised only at its own address; a version/contract mix-up is not.
  const v15 = review(td(seaport(listing().message, seaportDomain('0x00000000000000ADc04C56Bf30aC9d3c0aAF14dC', 1, '1.5'))));
  assert.equal(v15.display.action, 'List NFT for Sale (Seaport 1.5)');
  const mixed = review(td(seaport(listing().message, seaportDomain(SEAPORT16, 1, '1.5'))));
  assert.ok(mixed.warnings.some(w => w.includes('unrecognised contract')));
});

test('marketplace requests have undeclared keys stripped (count-only warning); digests and signatures are unchanged', () => {
  const t = listing();
  const extra = structuredClone(t);
  extra.message.totalOriginalConsiderationItems = 3;          // seaport-js OrderParameters style
  extra.message.offer[0].note = 'not signed';
  const r = review(td(extra));
  assert.ok(r.warnings.includes('The request included 2 field(s) that are not part of the signed data. They were ignored and are not shown as signed values.'));
  assert.equal(field(r, 'Ignored request keys'), '"totalOriginalConsiderationItems"\n"offer[0].note"');
  assert.ok(!r.warnings.some(w => w.includes('totalOriginalConsiderationItems')));
  assert.ok(!field(r, 'Signed values').includes('totalOriginalConsiderationItems'));
  assert.ok(!JSON.stringify(r.display).includes('not signed'));
  assert.equal(r.display.amount, '0.95');
  const out = sign(td(extra));
  const { EIP712Domain, ...types } = t.types;
  assert.equal(out.digest, TypedDataEncoder.hash(t.domain, types, t.message));
  assert.equal(verifyTypedData(t.domain, types, t.message, '0x' + out.signature), ME);
  // Missing declared fields are still refused.
  const missing = structuredClone(t); delete missing.message.counter;
  fails(() => review(td(missing)), 'TYPED_DATA');
  // Attacker-chosen key text never reaches a warning; the detail field is quoted and sanitised.
  const loud = structuredClone(t); loud.message['THIS_IS_SAFE‮VERIFIED'] = 1;
  const lr = review(td(loud));
  assert.ok(!lr.warnings.some(w => w.includes('SAFE')));
  assert.equal(field(lr, 'Ignored request keys'), '"THIS_IS_SAFE?VERIFIED"');
});

test('undeclared keys are still refused outside recognised marketplace requests', () => {
  const permit = { types: typed({ Permit: [['owner', 'address'], ['spender', 'address'], ['value', 'uint256'], ['nonce', 'uint256'], ['deadline', 'uint256']] }), primaryType: 'Permit',
    domain: { name: 'USD Coin', version: '2', chainId: 1, verifyingContract: USDC },
    message: { owner: ME, spender: ATT, value: '1', nonce: '0', deadline: '1710000000', THIS_IS_SAFE_VERIFIED_BY_BITSIGNER: true } };
  fails(() => review(td(permit)), 'TYPED_DATA');
  // A Seaport-shaped order on an unrecognised contract, or a Seaport type on another primary type, stays strict.
  const other = seaport({ ...listing().message, totalOriginalConsiderationItems: 3 }, seaportDomain('0x000000000000000000000000000000000000dEaD'));
  fails(() => review(td(other)), 'TYPED_DATA');
  const mail = { types: typed({ Mail: [['contents', 'string']] }), primaryType: 'Mail', domain: seaportDomain(), message: { contents: 'hi', extra: 1 } };
  fails(() => review(td(mail)), 'TYPED_DATA');
});

const BLUR_V1 = '0x000000000000Ad05Ccc4F10045630fb830B95127';
const BLUR_V2 = '0xb2ecfE4E4D61f8790bbb9DE2D1259B9e2410CEA5';
const blurRoot = domain => ({ types: { Root: [{ name: 'root', type: 'bytes32' }] }, primaryType: 'Root', domain, message: { root: '0x' + 'ab'.repeat(32) } });
const blurV2 = (more = {}) => ({ types: typed({ Order: [['trader', 'address'], ['collection', 'address'], ['listingsRoot', 'bytes32'], ['numberOfListings', 'uint256'], ['expirationTime', 'uint256'], ['assetType', 'uint8'], ['makerFee', 'FeeRate'], ['salt', 'uint256'], ['orderType', 'uint8'], ['nonce', 'uint256']], FeeRate: [['recipient', 'address'], ['rate', 'uint16']] }),
  primaryType: 'Order', domain: { name: 'Blur Exchange', version: '1.0', chainId: 1, verifyingContract: BLUR_V2 },
  message: { trader: ME, collection: BAYC, listingsRoot: '0x' + 'cd'.repeat(32), numberOfListings: '3', expirationTime: '1710000000', assetType: 0, makerFee: { recipient: CREATOR, rate: 50 }, salt: '7', orderType: 0, nonce: '0', ...more } });

test('Blur v1 Root and V2 Order are blind Merkle-root signatures; other roots hit the generic net', () => {
  const t = blurRoot({ name: 'Blur Exchange', version: '1.0', chainId: 1, verifyingContract: BLUR_V1 });
  const r = review(td(t));
  assert.equal(r.decodeStatus, 'opaque');
  assert.equal(r.riskLevel, 'high');
  assert.equal(r.display.assetKind, 'nftOrder');
  assert.ok(r.warnings.some(w => w.startsWith('HIGH RISK: This signs only a Merkle root of Blur orders')));
  assert.equal(r.display.amount, undefined);
  signAndRecover(t);
  const v2 = { types: typed({ Order: [['trader', 'address'], ['collection', 'address'], ['listingsRoot', 'bytes32'], ['numberOfListings', 'uint256'], ['expirationTime', 'uint256'], ['assetType', 'uint8'], ['makerFee', 'FeeRate'], ['salt', 'uint256'], ['orderType', 'uint8'], ['nonce', 'uint256']], FeeRate: [['recipient', 'address'], ['rate', 'uint16']] }),
    primaryType: 'Order', domain: { name: 'Blur Exchange', version: '1.0', chainId: 1, verifyingContract: BLUR_V2 },
    message: { trader: ME, collection: BAYC, listingsRoot: '0x' + 'cd'.repeat(32), numberOfListings: '3', expirationTime: '1710000000', assetType: 0, makerFee: { recipient: CREATOR, rate: 50 }, salt: '7', orderType: 0, nonce: '0' } };
  const r2 = review(td(v2, { address: ME }));
  assert.deepEqual([r2.decodeStatus, r2.display.action, r2.display.assetKind, r2.display.assetContract], ['opaque', 'Blur Listing (blind)', 'nftOrder', BAYC]);
  assert.ok(r2.warnings.some(w => w.startsWith('HIGH RISK: This signs only a Merkle root of Blur listings')));
  assert.ok(!r2.warnings.some(w => w.includes('differs from the requested signer')));
  const trader = review(td({ ...v2, message: { ...v2.message, trader: ATT } }, { address: ME }));
  assert.ok(trader.warnings.some(w => w.startsWith('HIGH RISK: The order trader')));
  signAndRecover(v2);
  // The same Root struct elsewhere is not Blur, but the generic opaque-root net still fires.
  for (const domain of [{ name: 'Foo', chainId: 1 }, { name: 'Blur Exchange', version: '1.0', chainId: 56, verifyingContract: BLUR_V1 }]) {
    const generic = review(td(blurRoot(domain)));
    assert.equal(generic.display.action, 'Sign Typed Data');
    assert.ok(generic.warnings.some(w => w.startsWith('HIGH RISK: This signs an opaque hash or Merkle root')));
  }
  const merkle = review(td({ types: typed({ MerkleClaim: [['index', 'uint256'], ['account', 'address']] }), primaryType: 'MerkleClaim', domain: { name: 'X', chainId: 1 }, message: { index: 1, account: ME } }));
  assert.ok(merkle.warnings.some(w => w.includes('opaque hash or Merkle root')));
});

const LOOKSRARE = '0x0000000000E655fAe4d56241588680F86E3b2377';
// Pinned from LooksRare/contracts-exchange-v2 libraries/OrderStructs.sol _MAKER_TYPEHASH.
const MAKER_TYPE = 'Maker(uint8 quoteType,uint256 globalNonce,uint256 subsetNonce,uint256 orderNonce,uint256 strategyId,uint8 collectionType,address collection,address currency,address signer,uint256 startTime,uint256 endTime,uint256 price,uint256[] itemIds,uint256[] amounts,bytes additionalParameters)';
const MAKER = typed({ Maker: MAKER_TYPE.slice(6, -1).split(',').map(p => p.split(' ').reverse()) });
const lrDomain = { name: 'LooksRareProtocol', version: '2', chainId: 1, verifyingContract: LOOKSRARE };
const maker = (more = {}) => ({ quoteType: 1, globalNonce: '0', subsetNonce: '0', orderNonce: '0', strategyId: '0', collectionType: 0, collection: BAYC, currency: ZERO, signer: ME,
  startTime: '1700000000', endTime: '1710000000', price: eth(1), itemIds: ['1234'], amounts: ['1'], additionalParameters: '0x', ...more });
const looksRare = message => ({ types: MAKER, primaryType: 'Maker', domain: lrDomain, message });

test('LooksRare v2 maker asks and bids are decoded; price-0 asks and signer mismatches are red', () => {
  assert.equal(TypedDataEncoder.from(MAKER).encodeType('Maker'), MAKER_TYPE);
  const ask = review(td(looksRare(maker()), { address: ME }));
  assert.deepEqual([ask.display.action, ask.display.amount, ask.display.symbol, ask.display.headline], ['List NFT for Sale (LooksRare)', '1', 'ETH', 'NFT #1234 · 0xBC4C…f13D']);
  assert.match(field(ask, 'Price note'), /before LooksRare protocol and creator fees/);
  assert.ok(!ask.warnings.some(severe));
  const zero = review(td(looksRare(maker({ price: '0' }))));
  assert.ok(zero.warnings.includes('HIGH RISK: You receive nothing for the items you give.'));
  assert.equal(zero.display.amount, '0');
  const mismatch = review(td(looksRare(maker({ signer: ATT })), { address: ME }));
  assert.ok(mismatch.warnings.some(w => w.startsWith('HIGH RISK: The order signer')));
  const bid = review(td(looksRare(maker({ quoteType: 0, strategyId: '1', itemIds: [], amounts: ['1'], currency: WETH }))));
  assert.deepEqual([bid.display.action, bid.display.amount, bid.display.symbol, bid.display.headline], ['Make NFT Offer (LooksRare)', '1', 'WETH', 'For ANY NFT in 0xBC4C…f13D']);
  const nativeBid = review(td(looksRare(maker({ quoteType: 0 }))));
  assert.ok(nativeBid.warnings.some(w => w.includes('rejects bids in native ETH')));
  const custom = review(td(looksRare(maker({ strategyId: '7', additionalParameters: '0x1234' }))));
  assert.equal(custom.decodeStatus, 'partiallyDecoded');
  assert.equal(field(custom, 'Additional parameters'), '0x1234');
  signAndRecover(looksRare(maker({ price: '0' })));
  // A different verifying contract is not LooksRare and stays generic.
  const other = review(td({ ...looksRare(maker()), domain: { ...lrDomain, verifyingContract: ATT } }));
  assert.equal(other.display.action, 'Sign Typed Data');
});

test('LooksRare BatchOrder skips SDK padding leaves and signs the same digest', () => {
  const pad = maker({ quoteType: 0, collection: ZERO, currency: ZERO, signer: ZERO, startTime: '0', endTime: '0', price: '0', itemIds: ['0'], amounts: ['0'] });
  const t = { types: { ...MAKER, BatchOrder: [{ name: 'tree', type: 'Maker[2][2]' }] }, primaryType: 'BatchOrder', domain: lrDomain,
    message: { tree: [[maker(), maker({ itemIds: ['5'], price: eth(2) })], [maker({ itemIds: ['6'], price: '0' }), pad]] } };
  const r = review(td(t));
  assert.equal(r.display.action, 'Bulk List (3 orders, LooksRare)');
  assert.deepEqual([r.display.amount, r.display.symbol], ['3', 'ETH']);
  assert.ok(r.warnings.includes('HIGH RISK: Order 3: You receive nothing for the items you give.'));
  assert.match(field(r, 'Batch order'), /3 orders in a tree of 4 entries \(height 2\); 1 empty padding entry/);
  signAndRecover(t);
});

// ---------------------------------------------------------------------------
// Review-hardening cases: disguised NFT items, decaying and dust proceeds,
// bulk totals and warning floods, expiry policy, Blur fees and fail-closed shapes.

test('NFT-typed Seaport items on a registry ERC-20 are never shown as NFTs', () => {
  // ERC-721 transfers use transferFrom, the ERC-20 selector: on WETH the "token ID" is an amount.
  const t = seaport(order([item(2, WETH, eth(5), 1)], [item(0, ZERO, 0, eth(0.1), ME)]));
  const r = review(td(t, { address: ME }));
  assert.ok(!r.display.action.startsWith('List NFT'));
  assert.equal(r.display.assetContract, undefined);
  assert.equal(r.display.tokenId, undefined);
  assert.equal(r.decodeStatus, 'partiallyDecoded');
  assert.deepEqual(r.display.give, ['5 WETH (typed as NFT #50000000…00000000 (19 digits)) · 0xC02a…6Cc2']);
  assert.ok(r.warnings.some(w => w.startsWith('HIGH RISK: You give · Item 1 is typed ERC-721, but ' + WETH + ' is WETH') && w.includes('moves 5 WETH')));
  signAndRecover(t);
  // A criteria item on WETH lets the taker choose the amount.
  const any = review(td(seaport(order([item(4, WETH, 0, 1)], [item(0, ZERO, 0, eth(0.1), ME)]))));
  assert.deepEqual(any.display.give, ['ANY amount of WETH (typed as an ERC-721 criteria item) · 0xC02a…6Cc2']);
  assert.ok(any.warnings.some(w => w.startsWith('HIGH RISK: You give · Item 1 is typed ERC-721') && w.includes('any ID is accepted')));
  const erc1155 = review(td(seaport(order([item(3, USDC, 7, 1)], [item(0, ZERO, 0, eth(0.1), ME)]))));
  assert.ok(erc1155.warnings.some(w => w.startsWith('HIGH RISK: You give · Item 1 is typed ERC-1155') && w.includes('cannot be predicted offline')));
  // The reverse: an ERC-20-typed item on a non-registry contract may be an ERC-721 token.
  const reverse = review(td(seaport(order([item(1, BAYC, 0, 1234)], [item(0, ZERO, 0, eth(0.1), ME)]))));
  assert.deepEqual(reverse.display.give, ['1234 raw units of 0xBC4C…f13D (or NFT #1234 if 0xBC4C…f13D is an ERC-721)']);
  assert.match(field(reverse, 'You give · Item 1'), /Interpretation: if this contract is an ERC-721, the same transfer moves token #1234 instead/);
});

test('LooksRare and Blur orders on a registry ERC-20 "collection" are red and not shown as NFTs', () => {
  const lr = review(td(looksRare(maker({ collection: WETH, itemIds: [eth(5)] }))));
  assert.equal(lr.display.action, 'Sign LooksRare Order');
  assert.equal(lr.display.assetContract, undefined);
  assert.equal(lr.display.tokenId, undefined);
  assert.deepEqual(lr.display.give, ['5 WETH (typed as NFT #50000000…00000000 (19 digits)) · 0xC02a…6Cc2']);
  assert.ok(lr.warnings.some(w => w.startsWith(`HIGH RISK: The collection is typed ERC-721, but ${WETH} is WETH`)));
  assert.equal(lr.decodeStatus, 'partiallyDecoded');
  const blur = review(td(blurV2({ collection: WETH })));
  assert.equal(blur.display.assetContract, undefined);
  assert.ok(blur.warnings.some(w => w.startsWith(`HIGH RISK: The collection is typed ERC-721, but ${WETH} is WETH`)));
});

test('Seaport proceeds that decay to 0 are red; dust prices get a notice; normal prices do not', () => {
  const decay = review(td(seaport(order([item(2, BAYC, 1, 1)], [item(0, ZERO, 0, eth(10), ME, '0')]))));
  assert.ok(decay.warnings.includes('HIGH RISK: What you receive falls to 0 by the end time, so this order can be filled for almost nothing.'));
  assert.deepEqual(decay.display.receive, ['10 ETH → 0 ETH (changes linearly over time)']);
  assert.equal(decay.display.amount, '0');
  const rising = review(td(seaport(order([item(2, BAYC, 1, 1)], [item(0, ZERO, 0, '0', ME, eth(10))]))));
  assert.ok(rising.warnings.some(w => w.startsWith('HIGH RISK: What you receive is 0 at the start time')));
  // Fees still paid while the offerer's share decays trigger the share rule as well.
  const share = review(td(seaport(order([item(2, BAYC, 1, 1)], [item(0, ZERO, 0, eth(1), ME, eth(0.01)), item(0, ZERO, 0, eth(0.1), OS_FEE)]))));
  assert.ok(share.warnings.some(w => w.startsWith('HIGH RISK: Most of the ETH payment goes to other addresses')));
  const dust = review(td(seaport(order([item(2, BAYC, 1, 1)], [item(0, ZERO, 0, 1, ME)]))));
  assert.ok(dust.warnings.includes('You receive only 0.000000000000000001 ETH for the items you give. Check that this very low price is intended.'));
  assert.ok(!dust.warnings.some(severe));
  const usdcDust = review(td(seaport(order([item(2, BAYC, 1, 1)], [item(1, USDC, 0, 99, ME)]))));
  assert.ok(usdcDust.warnings.some(w => w.startsWith('You receive only 0.000099 USDC')));
  const lrDust = review(td(looksRare(maker({ price: '1' }))));
  assert.ok(lrDust.warnings.some(w => w.startsWith('You receive only 0.000000000000000001 ETH (before fees)')));
  const normal = review(td(listing()));
  assert.ok(!normal.warnings.some(w => w.includes('very low price')));
  const unknown = review(td(seaport(order([item(2, BAYC, 1, 1)], [item(1, '0x' + '77'.repeat(20), 0, 1, ME)]))));
  assert.ok(!unknown.warnings.some(w => w.includes('very low price')), 'raw units have no known decimals');
});

test('bulk listing totals are summed only for one known currency', () => {
  const tokA = '0x' + '71'.repeat(20), tokB = '0x' + '72'.repeat(20);
  const raw = review(td(bulk([order([item(2, BAYC, 1, 1)], [item(1, tokA, 0, 1000, ME)]), order([item(2, BAYC, 2, 1)], [item(1, tokB, 0, 5, ME)])], 1)));
  assert.equal(raw.display.amount, undefined);
  assert.equal(raw.summary, 'Seaport bulk listing: 2 orders');
  const sameRaw = review(td(bulk([order([item(2, BAYC, 1, 1)], [item(1, tokA, 0, 1000, ME)]), order([item(2, BAYC, 2, 1)], [item(1, tokA, 0, 5, ME)])], 1)));
  assert.equal(sameRaw.display.amount, undefined);
  const mixed = review(td(bulk([order([item(2, BAYC, 1, 1)], [item(0, ZERO, 0, eth(1), ME)]), order([item(2, BAYC, 2, 1)], [item(1, WETH, 0, eth(1), ME)])], 1)));
  assert.equal(mixed.display.amount, undefined);
  const weth = review(td(bulk([order([item(2, BAYC, 1, 1)], [item(1, WETH, 0, eth(1), ME)]), order([item(2, BAYC, 2, 1)], [item(1, WETH, 0, eth(0.5), ME)])], 1)));
  assert.deepEqual([weth.display.amount, weth.display.symbol], ['1.5', 'WETH']);
  const lrRaw = { types: { ...MAKER, BatchOrder: [{ name: 'tree', type: 'Maker[2]' }] }, primaryType: 'BatchOrder', domain: lrDomain,
    message: { tree: [maker({ currency: tokA, price: '10' }), maker({ itemIds: ['5'], currency: tokB, price: '20' })] } };
  assert.equal(review(td(lrRaw)).display.amount, undefined);
});

test('expiry policy: after year 9999 or over 10 years is red; over a year is a notice', () => {
  const far = review(td(listing({ endTime: '1000000000000' })));
  assert.ok(far.warnings.some(w => w.startsWith('HIGH RISK: This order effectively never expires (end time 1000000000000 (after year 9999))')));
  const decade = review(td(listing({ endTime: String(1700000000 + 11 * 365 * 86400) })));
  assert.ok(decade.warnings.some(w => w.startsWith('HIGH RISK: This order stays valid for more than 10 years')));
  const year = review(td(listing({ endTime: String(1700000000 + 400 * 86400) })));
  assert.ok(year.warnings.some(w => w.startsWith('This order stays valid for more than a year')));
  assert.ok(!year.warnings.some(severe));
  const blur = review(td(blurV2({ expirationTime: '1000000000000' })));
  assert.ok(blur.warnings.some(w => w.startsWith('HIGH RISK: This order effectively never expires')));
});

test('bulk order warnings are merged across orders and capped with red ones first', () => {
  const drain = () => order([item(2, BAYC, 1, 1)], [item(0, ZERO, 0, 1, ATT)], { endTime: MAX });
  const leaves = [...Array.from({ length: 40 }, drain), ...Array.from({ length: 24 }, padding)];
  const r = review(td(bulk(leaves, 6)));
  assert.ok(r.warnings.includes('HIGH RISK: All 40 orders: You receive nothing for the items you give.'));
  assert.ok(r.warnings.some(w => w.startsWith('HIGH RISK: This bulk order contains 40 orders; only the first 32 are itemised')));
  assert.ok(r.warnings.length <= 6, r.warnings.join('\n'));
  // Distinct per-order warnings (a different end time each) are capped with a red summary line.
  const distinct = Array.from({ length: 30 }, (_, i) => order([item(2, BAYC, i + 1, 1)], [item(0, ZERO, 0, eth(1), ME)], { endTime: String(1700000000 + 11 * 365 * 86400 + i) }));
  const capped = review(td(bulk([...distinct, padding(), padding()], 5)));
  const perOrder = capped.warnings.filter(w => /Order \d+: This order stays valid for more than 10 years/.test(w));
  assert.equal(perOrder.length, 23);
  assert.ok(capped.warnings.includes('HIGH RISK: 7 more order-specific warnings are not listed here. Review every order in the signed values.'));
  // Partial groups name their orders.
  const some = review(td(bulk([drain(), order([item(2, BAYC, 2, 1)], [item(0, ZERO, 0, eth(1), ME)]), drain(), padding()], 2)));
  assert.ok(some.warnings.includes('HIGH RISK: Orders 1, 3: You receive nothing for the items you give.'));
});

test('Blur V2 maker fees above 50% are red', () => {
  const high = review(td(blurV2({ makerFee: { recipient: ATT, rate: 10000 } })));
  assert.ok(high.warnings.includes(`HIGH RISK: The maker fee is 100% (10000 bps) of each fill, paid to ${ATT}.`));
  const normal = review(td(blurV2()));
  assert.ok(!normal.warnings.some(w => w.includes('maker fee')));
});

test('mis-shaped marketplace types fall back to the generic typed-data review', () => {
  const msg = listing().message;
  const variants = {
    reordered: { ...SEAPORT_TYPES, ConsiderationItem: [SEAPORT_TYPES.ConsiderationItem.at(-1), ...SEAPORT_TYPES.ConsiderationItem.slice(0, -1)] },
    renamed: { OrderComponents: SEAPORT_TYPES.OrderComponents.map(f => f.name === 'offer' ? { name: 'offer', type: 'Offer[]' } : f), Offer: SEAPORT_TYPES.OfferItem, ConsiderationItem: SEAPORT_TYPES.ConsiderationItem },
    widened: { ...SEAPORT_TYPES, OrderComponents: SEAPORT_TYPES.OrderComponents.map(f => f.name === 'orderType' ? { name: 'orderType', type: 'uint256' } : f) },
  };
  for (const [name, types] of Object.entries(variants)) {
    const r = review(td({ types, primaryType: 'OrderComponents', domain: seaportDomain(), message: msg }));
    assert.equal(r.display.action, 'Sign Typed Data', name);
    assert.equal(r.display.assetKind, undefined, name);
  }
  // Tree heights above each protocol's cap are not recognised (checked before any leaf is read).
  const network = { chainId: '1', symbol: 'ETH', name: 'Ethereum' };
  assert.equal(reviewNftOrder({ primaryType: 'BatchOrder', types: { ...MAKER, BatchOrder: [{ name: 'tree', type: 'Maker' + '[2]'.repeat(11) }] },
    domain: lrDomain, domainFields: ['name', 'version', 'chainId', 'verifyingContract'], message: {}, network }), undefined);
  assert.equal(reviewNftOrder({ primaryType: 'BulkOrder', types: { ...SEAPORT_TYPES, BulkOrder: [{ name: 'tree', type: 'OrderComponents' + '[2]'.repeat(25) }] },
    domain: seaportDomain(), domainFields: ['name', 'version', 'chainId', 'verifyingContract'], message: {}, network }), undefined);
  const three = review(td({ types: { ...SEAPORT_TYPES, BulkOrder: [{ name: 'tree', type: 'OrderComponents[3]' }] }, primaryType: 'BulkOrder', domain: seaportDomain(), message: { tree: [msg, msg, msg] } }));
  assert.equal(three.display.action, 'Sign Typed Data');
  const lrReordered = review(td({ types: { Maker: [MAKER.Maker[1], MAKER.Maker[0], ...MAKER.Maker.slice(2)] }, primaryType: 'Maker', domain: lrDomain, message: maker() }));
  assert.equal(lrReordered.display.action, 'Sign Typed Data');
});

test('the opaque-root net does not fire on ordinary typed data', () => {
  const mail = { types: typed({ Person: [['name', 'string'], ['wallet', 'address']], Mail: [['from', 'Person'], ['to', 'Person'], ['contents', 'string']] }), primaryType: 'Mail',
    domain: { name: 'Ether Mail', version: '1', chainId: 1, verifyingContract: '0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC' },
    message: { from: { name: 'Cow', wallet: ME }, to: { name: 'Bob', wallet: ATT }, contents: 'Hello, Bob!' } };
  const r = review(td(mail));
  assert.equal(r.display.action, 'Sign Typed Data');
  assert.ok(!r.warnings.some(w => w.includes('opaque hash')));
  assert.ok(!r.warnings.some(severe));
});
