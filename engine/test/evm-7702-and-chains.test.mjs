import test from 'node:test';
import assert from 'node:assert/strict';
import { Transaction, computeAddress } from 'ethers/transaction';
import { hashAuthorization, verifyAuthorization } from 'ethers/hash';
import { SigningKey } from 'ethers/crypto';
import { parseEVM, signEVM } from '../src/evm.js';
import { deriveAccounts, withSeed, withKey, PATHS } from '../src/keys.js';
import { execute } from '../src/index.js';
import { derivePublicIndex } from '../src/public-index.js';
import { decodeQR, encodeQR } from '../protocols.js';
import { UR, UREncoder } from '@ngraveio/bc-ur';

const MN = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const ME = deriveAccounts({ mnemonic: MN }).accounts[1];
const MY_KEY = withSeed(MN, '', (seed, root) => withKey(seed, root, 'evm', PATHS.evm, k => '0x' + Buffer.from(k).toString('hex')));
const OTHER_KEY = '0x' + '22'.repeat(32);
const DELEGATE = '0x00000000219ab540356cBB839Cbe05303d7705Fa';
const ZERO = '0x0000000000000000000000000000000000000000';

// The helper's transactions use outer nonce 0, so this wallet's own first entry
// applies at nonce 1: EIP-7702 increments the sender's nonce before the list.
const authorization = (chainId, delegate, key, nonce = 1) => {
  const unsigned = { address: delegate, nonce, chainId };
  return { ...unsigned, signature: new SigningKey(key).sign(hashAuthorization(unsigned)) };
};
/** The form a request actually arrives in: RLP bytes from an eth-sign-request. */
const serialized = (list, chainId = 1) => Transaction.from({
  type: 4, chainId, nonce: 0, to: ME.address, value: 0, data: '0x',
  gasLimit: 100000, maxFeePerGas: 2n, maxPriorityFeePerGas: 1n, authorizationList: list }).unsignedSerialized;
const request = (list, chainId = 1) => ({ chain: 'evm', kind: 'transaction', address: ME.address, transaction: serialized(list, chainId) });
const review = r => parseEVM(r).review;
const value = (out, label) => out.fields.find(f => f.label === label)?.value;

test('An EIP-7702 delegation of this wallet says so in those words', () => {
  const out = review(request([authorization(1, DELEGATE, MY_KEY)]));
  // The authority is nowhere in the entry: it is recovered from the entry's own
  // signature, which is the only way to tell whose account is being handed over.
  assert.equal(value(out, 'Authorization 1 · Account being changed'), ME.address);
  assert.equal(value(out, 'Authorization 1 · Delegates account code to'), DELEGATE);
  assert.equal(value(out, 'Authorization 1 · Applies on'), 'Ethereum');
  assert.equal(value(out, 'Authorization 1 · Account nonce'), '1');
  assert.equal(value(out, 'Account code delegations (EIP-7702)'), '1');
  const warning = out.warnings.find(w => w.includes('Authorization 1'));
  assert.match(warning, /^HIGH RISK: Authorization 1 hands this wallet's own account/);
  assert.match(warning, /can move everything in it/);
  // The delegate's code is on-chain, so this can never read as fully decoded and
  // signing it needs the acknowledgement.
  assert.equal(out.riskLevel, 'high');
  assert.equal(out.decodeStatus, 'partiallyDecoded');
});

test("Another account's delegation is not described as this wallet's", () => {
  const out = review(request([authorization(1, DELEGATE, OTHER_KEY)]));
  const authority = computeAddress(new SigningKey(OTHER_KEY));
  assert.equal(value(out, 'Authorization 1 · Account being changed'), authority);
  assert.notEqual(authority, ME.address);
  const warning = out.warnings.find(w => w.includes('Authorization 1'));
  assert.match(warning, /^HIGH RISK: Authorization 1 hands the account/);
  assert.ok(!warning.includes("this wallet's own account"));
});

test('A chain-0 authorization is called out as applying everywhere', () => {
  const out = review(request([authorization(0, DELEGATE, MY_KEY)]));
  assert.equal(value(out, 'Authorization 1 · Applies on'), 'every EVM chain');
  assert.ok(out.warnings.some(w => /signed for chain 0, so it applies on every EVM chain, not only Ethereum/.test(w)),
            out.warnings.join(' | '));
  // An authorization for some other specific chain is a mismatch, and refused.
  assert.throws(() => review(request([authorization(56, DELEGATE, MY_KEY)])), /is for chain 56, but this transaction is for chain 1/);
});

test('Removing a delegation is not dressed up as granting one', () => {
  const out = review(request([authorization(1, ZERO, MY_KEY)]));
  assert.equal(value(out, 'Authorization 1 · Removes delegation to'), 'none (0x0)');
  assert.ok(!out.fields.some(f => f.label.endsWith('Delegates account code to')));
  const warning = out.warnings.find(w => w.includes('Authorization 1'));
  assert.match(warning, /removes the code delegation on .* restores a plain account/);
  assert.ok(!warning.startsWith('HIGH RISK'));
  // Giving a permission up is not gated like taking one on.
  assert.notEqual(out.riskLevel, 'high');
  assert.equal(out.decodeStatus, 'fullyDecoded');
  // A list that both revokes and grants is still a grant.
  const mixed = review(request([authorization(1, ZERO, MY_KEY), authorization(1, DELEGATE, OTHER_KEY)]));
  assert.equal(mixed.riskLevel, 'high');
  assert.equal(mixed.decodeStatus, 'partiallyDecoded');
});

test('An invalid type 4 transaction is refused, whatever is acknowledged', () => {
  // EIP-7702 makes both invalid: the network would reject what got signed.
  assert.throws(() => review(request([])), /must carry at least one authorization/);
  const noDestination = Transaction.from({ type: 4, chainId: 1, nonce: 0, to: null, value: 0, data: '0x6000',
    gasLimit: 100000, maxFeePerGas: 2n, maxPriorityFeePerGas: 1n, authorizationList: [authorization(1, DELEGATE, OTHER_KEY)] }).unsignedSerialized;
  assert.throws(() => review({ chain: 'evm', kind: 'transaction', address: ME.address, transaction: noDestination }),
                /must name a destination address; it cannot deploy a contract/);
});

test('An EIP-7702 transaction signs and recovers to the wallet that reviewed it', () => {
  const r = request([authorization(1, DELEGATE, MY_KEY)]);
  const out = withSeed(MN, '', (seed, root) => signEVM(r, seed, root, { targets: [{ path: PATHS.evm, publicKey: ME.publicKey, address: ME.address }] }));
  assert.equal(out.address, ME.address);
  const tx = Transaction.from(out.serializedTransaction);
  assert.equal(tx.type, 4, 'the signed transaction is still type 4');
  assert.equal(tx.from, ME.address, 'and it recovers to the wallet that signed it');
  assert.equal(tx.authorizationList.length, 1);
  // The authorization inside is a separate signature and survives untouched.
  assert.equal(verifyAuthorization({ address: DELEGATE, nonce: 1n, chainId: 1n }, tx.authorizationList[0].signature), ME.address);
  // Signing anything else would have produced a different transaction hash.
  assert.equal(tx.unsignedHash, Transaction.from(r.transaction).unsignedHash);
});

test('Popular EVM chains are named; an unknown one is signed and said to be unknown', () => {
  const plain = chainId => ({ chain: 'evm', kind: 'transaction', address: ME.address,
    transaction: { type: 2, chainId, nonce: 0, to: ME.address, value: '0', data: '0x', gasLimit: '100000', maxFeePerGas: '2', maxPriorityFeePerGas: '1' } });
  // Chains that were refused outright before this round, now named. Every symbol
  // here came from the ethereum-lists registry, not from memory.
  for (const [chainId, name, symbol] of [[59144, 'Linea', 'ETH'], [534352, 'Scroll', 'ETH'], [324, 'zkSync Era', 'ETH'],
                                         [81457, 'Blast', 'ETH'], [5000, 'Mantle', 'MNT'], [42220, 'Celo', 'CELO'],
                                         [204, 'opBNB', 'BNB'], [130, 'Unichain', 'ETH'], [80094, 'Berachain', 'BERA'],
                                         [1329, 'Sei', 'SEI'], [167000, 'Taiko', 'ETH'], [2020, 'Ronin', 'RON']]) {
    const out = review(plain(chainId));
    assert.equal(out.network.name, name, String(chainId));
    assert.equal(out.network.symbol, symbol, String(chainId));
    assert.ok(!out.warnings.some(w => w.includes('does not recognise')), name);
    assert.ok(out.display.fee.endsWith(' ' + symbol), name);
  }
  // A chain with no name here still signs, is called by its number, prices nothing
  // in a guessed ticker and says all of that.
  const unknown = review(plain(7700));
  assert.equal(unknown.network.name, 'Chain 7700');
  assert.equal(unknown.network.symbol, 'native units');
  assert.ok(unknown.warnings.some(w => w.includes('does not recognise EVM chain 7700')), unknown.warnings.join(' | '));
  assert.equal(unknown.asset, undefined, 'no token registry stands behind an unnamed chain');
  assert.equal(unknown.riskLevel, 'warning');
  // Naming a chain is not the same as knowing its tokens: only the original eight
  // carry a bundled registry, so a token on any of the new ones reads as unregistered.
  const usdcTransfer = { ...plain(59144), transaction: { ...plain(59144).transaction, to: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
    data: '0xa9059cbb' + '0'.repeat(24) + ME.address.slice(2).toLowerCase() + (10n ** 6n).toString(16).padStart(64, '0') } };
  assert.equal(review(usdcTransfer).asset, undefined, 'Linea is named, but no token on it is registered here');
  // A fee is only called high where there is a reference for what normal looks
  // like; elsewhere it is shown and explicitly not judged.
  const expensive = cid => ({ ...plain(cid), transaction: { ...plain(cid).transaction, gasLimit: '1000000', maxFeePerGas: String(10n ** 14n) } });
  const onEthereum = review(expensive(1));
  assert.ok(onEthereum.warnings.some(w => w.startsWith('HIGH FEE:')), 'calibrated chain still warns');
  const onMantle = review(expensive(5000));
  assert.ok(!onMantle.warnings.some(w => w.startsWith('HIGH FEE:')), 'no guessed threshold on an uncalibrated chain');
  assert.ok(onMantle.warnings.some(w => /no reference for a normal network fee on Mantle/.test(w)), onMantle.warnings.join(' | '));
  // Chain 0 stays refused: an unprotected transaction replays on every network.
  assert.throws(() => review(plain(0)), e => e.code === 'CHAIN_ID');
  assert.equal(execute({ operation: 'capabilities' }).evm.networks, 'every EVM chain ID; 60 are named');
});

test('A type 4 payload reaches the parser through the UR transport', () => {
  // eth-sign-request dataType 4 is an EIP-2718 typed transaction; its first byte
  // is the transaction type. Transaction type 4 had to be let through here as
  // well, or a 7702 request would be refused by the transport before anything
  // could read it. (dataType 2 is EIP-712 typed data, which is a different thing.)
  const head = (major, n) => n < 24 ? Buffer.from([major * 32 + n]) : n < 256 ? Buffer.from([major * 32 + 24, n])
    : n < 65536 ? (() => { const b = Buffer.alloc(3); b[0] = major * 32 + 25; b.writeUInt16BE(n, 1); return b; })()
    : (() => { const b = Buffer.alloc(5); b[0] = major * 32 + 26; b.writeUInt32BE(n, 1); return b; })();
  const cbor = v => Buffer.isBuffer(v) ? Buffer.concat([head(2, v.length), v])
    : typeof v === 'boolean' ? Buffer.from([v ? 245 : 244])
    : typeof v === 'number' ? head(0, v)
    : Array.isArray(v) ? Buffer.concat([head(4, v.length), ...v.map(cbor)])
    : v instanceof Map ? Buffer.concat([head(5, v.size), ...[...v].flatMap(([k, x]) => [cbor(k), cbor(x)])])
    : v?.tag ? Buffer.concat([head(6, v.tag), cbor(v.value)]) : (() => { throw new Error('unsupported'); })();
  const keypath = { tag: 304, value: new Map([[1, [44, true, 60, true, 0, true, 0, false, 0, false]], [2, 0x73c5da0a]]) };
  const payload = bytes => new UREncoder(new UR(cbor(new Map([[2, bytes], [3, 4], [4, 1], [5, keypath]])), 'eth-sign-request'), 2000)
    .encodeWhole().map(s => s.toUpperCase());
  const signed = Buffer.from(serialized([authorization(1, DELEGATE, MY_KEY)]).slice(2), 'hex');
  assert.equal(signed[0], 4, 'the fixture really is a type 4 payload');
  const decoded = decodeQR({ frames: payload(signed) });
  assert.equal(decoded.complete, true);
  assert.equal(decoded.request.kind, 'transaction');
  assert.equal(review(decoded.request).decodeStatus, 'partiallyDecoded');
  // Blob transactions are still stopped at the transport, not merely later.
  const blob = Buffer.from(signed); blob[0] = 3;
  assert.throws(() => decodeQR({ frames: payload(blob) }), /Transaction data type does not match payload/);
});

// --- Which nonce this wallet's own entries take effect at (EIP-7702) ---------

/** A type 4 transaction at a chosen outer nonce. */
const at = (outer, list, extra = {}) => ({ chain: 'evm', kind: 'transaction', address: ME.address, ...extra,
  transaction: Transaction.from({ type: 4, chainId: 1, nonce: outer, to: ME.address, value: 0, data: '0x',
    gasLimit: 100000, maxFeePerGas: 2n, maxPriorityFeePerGas: 1n, authorizationList: list }).unsignedSerialized });

test("This wallet's own revocation is refused at a nonce it cannot take effect at", () => {
  // Outer nonce 5: the sender's nonce is 6 by the time the list is applied, so an
  // entry signed for 5 is skipped on-chain and the delegation stays in place.
  assert.throws(() => review(at(5, [authorization(1, ZERO, MY_KEY, 5)])),
                /Authorization 1 cannot take effect: it is signed for nonce 5, but this wallet’s nonce will be 6 when it is applied/);
  const applies = review(at(5, [authorization(1, ZERO, MY_KEY, 6)]));
  assert.match(applies.warnings.find(w => w.includes('Authorization 1')), /removes the code delegation on .* restores a plain account/);
  assert.equal(applies.decodeStatus, 'fullyDecoded');
  assert.notEqual(applies.riskLevel, 'high');
});

test('Each of this wallet’s entries that applies moves the next one’s nonce on', () => {
  assert.doesNotThrow(() => review(at(5, [authorization(1, ZERO, MY_KEY, 6), authorization(1, ZERO, MY_KEY, 7)])));
  assert.throws(() => review(at(5, [authorization(1, ZERO, MY_KEY, 6), authorization(1, ZERO, MY_KEY, 6)])),
                /Authorization 2 cannot take effect: it is signed for nonce 6, but this wallet’s nonce will be 7/);
  // A grant is held to the same rule as a revocation, and so is a chain-0 entry.
  assert.throws(() => review(at(5, [authorization(1, DELEGATE, MY_KEY, 5)])), /Authorization 1 cannot take effect/);
  assert.throws(() => review(at(5, [authorization(0, ZERO, MY_KEY, 9)])), /Authorization 1 cannot take effect/);
  // Another account's entries do not move this wallet's nonce.
  assert.doesNotThrow(() => review(at(5, [authorization(1, ZERO, OTHER_KEY, 40), authorization(1, ZERO, MY_KEY, 6)])));
});

test("Another account's revocation is described as conditional, and gated", () => {
  const out = review(at(5, [authorization(1, ZERO, OTHER_KEY, 40)]));
  const warning = out.warnings.find(w => w.includes('Authorization 1'));
  assert.match(warning, /asks to remove the code delegation on .* takes effect only if that account’s nonce is 40 when this transaction runs, which BitTool Signer cannot check offline/);
  assert.doesNotMatch(warning, /restores a plain account/);
  assert.equal(out.decodeStatus, 'partiallyDecoded', 'so the acknowledgement gate applies');
  assert.equal(out.riskLevel, 'warning');
});

test('A request that does not name its sender is held to the rule once a wallet matches it', () => {
  // Reviewed alone, the device cannot tell the entry is this wallet's, so it says
  // only what it can. The plan knows the signer and applies the nonce rule.
  const anonymous = (nonce) => {
    const { address, ...rest } = at(5, [authorization(1, ZERO, MY_KEY, nonce)], { path: PATHS.evm, masterFingerprint: '73c5da0a' });
    return rest;
  };
  const wallets = [{ localWalletId: 'a', publicIndex: derivePublicIndex({ mnemonic: MN }) }];
  const alone = review(anonymous(6));
  assert.match(alone.warnings.find(w => w.includes('Authorization 1')), /asks to remove/);
  const plan = execute({ operation: 'resolveSigningPlan', request: anonymous(6), wallets });
  assert.equal(plan.status, 'ready', plan.message);
  assert.match(plan.review.warnings.find(w => w.includes('Authorization 1')), /restores a plain account/);
  assert.equal(plan.review.decodeStatus, 'fullyDecoded');
  const refused = execute({ operation: 'resolveSigningPlan', request: anonymous(5), wallets });
  assert.notEqual(refused.status, 'ready');
  assert.match(refused.message, /cannot take effect/);
});
