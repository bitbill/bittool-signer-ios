// The card headline names the most consequential thing a request does. Four shapes
// used to lead with the harmless part: a Solana dust transfer beside an undecoded
// program, a Safe transaction with no chain ID ("Safe: Send", no amount), a Safe
// batch that folded a token transfer into "(+1 more)", and an EIP-7702 delegation
// of the whole account shown as "Send 0 ETH". Synthetic requests; public test mnemonic.
import test from 'node:test';
import assert from 'node:assert/strict';
import { base58 } from '@scure/base';
import { Interface, Transaction, SigningKey, getAddress, hashAuthorization, ZeroAddress } from 'ethers';
import { parseSolana } from '../src/solana.js';
import { parseEVM } from '../src/evm.js';
import { deriveAccounts, withSeed, withKey, PATHS } from '../src/keys.js';
import { concat, short, toBase64 } from '../src/util.js';

const MN = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const accounts = deriveAccounts({ mnemonic: MN }).accounts;

// ---------------------------------------------------------------- Solana
const SOL = accounts.find(a => a.chain === 'solana').address;
const SYSTEM = '11111111111111111111111111111111', TOKEN = 'TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA';
const k = n => base58.encode(new Uint8Array(32).fill(n));
const u64 = n => { const b = new Uint8Array(8); new DataView(b.buffer).setBigUint64(0, BigInt(n), true); return b; };
const bytes = (...parts) => concat(...parts.map(p => p instanceof Uint8Array ? p : new Uint8Array(p)));
function solTx(ixs) {
  const programs = [...new Set(ixs.map(ix => ix.program))], keys = [SOL];
  for (const ix of ixs) for (const a of ix.accounts) if (!keys.includes(a) && !programs.includes(a)) keys.push(a);
  keys.push(...programs);
  const at = x => keys.indexOf(x);
  const message = concat(new Uint8Array([1, 0, programs.length]), short(keys.length), ...keys.map(x => base58.decode(x)), new Uint8Array(32).fill(5), short(ixs.length),
    ...ixs.flatMap(ix => [new Uint8Array([at(ix.program)]), short(ix.accounts.length), new Uint8Array(ix.accounts.map(at)), short(ix.data.length), ix.data]));
  return parseSolana({ chain: 'solana', kind: 'transaction', message: toBase64(message) }).review;
}
const dust = { program: SYSTEM, accounts: [SOL, k(0x71)], data: bytes([2, 0, 0, 0], u64(1000n)) };
const approve = { program: TOKEN, accounts: [k(0x11), k(0x12), SOL], data: bytes([4], u64(1n)) };
// An unknown program handed the wallet as a writable signer: it could move anything.
const unknown = { program: k(0x98), accounts: [SOL, k(0x72)], data: new Uint8Array([7, 7, 7]) };
const UNDECODED = 'HIGH RISK: This transaction runs instructions that BitTool Signer cannot decode beside the ones it can. An undecoded instruction can move any funds this wallet controls, so the amounts and changes shown are not the whole story.';

test('A Solana transfer beside an undecoded instruction does not stand alone as the headline', () => {
  for (const ixs of [[dust, unknown], [unknown, dust]]) {
    const r = solTx(ixs);
    assert.deepEqual([r.display.action, r.display.headline, r.display.amount, r.display.counterparty],
      ['Sign Transaction', 'Moves funds and runs undecoded instructions · review each below', undefined, undefined]);
    assert.equal(r.summary, '0.000001 SOL and 1 undecoded instruction', 'the Activity record keeps the amount and names the rest');
    assert.equal(r.warnings[0], UNDECODED);
    assert.equal(r.riskLevel, 'high');
  }
  // A change of permission beside it, with and without a transfer.
  assert.equal(solTx([approve, unknown]).display.headline, 'Changes permissions and runs undecoded instructions · review each below');
  assert.equal(solTx([approve, dust, unknown]).display.headline, 'Changes permissions, moves funds and runs undecoded instructions · review each below');
  assert.equal(solTx([dust, unknown, unknown]).summary, '0.000001 SOL and 2 undecoded instructions');
  // Alone, an undecoded instruction reads as before, and so does a transfer alone.
  const alone = solTx([unknown]);
  assert.equal(alone.display.headline, undefined);
  assert.ok(!alone.warnings.includes(UNDECODED));
  assert.deepEqual([solTx([dust]).display.amount, solTx([dust]).summary], ['0.000001', '0.000001 SOL']);
});

test('A burn beside an undecoded instruction names both, and a marketplace keeps its own headline', () => {
  const burn = { program: TOKEN, accounts: [k(0x5a), k(0x31), SOL], data: bytes([8], u64(5n)) };
  const cases = [
    [[burn, unknown], 'Destroys assets and runs undecoded instructions · review each below', 'Burn 5 raw units and 1 undecoded instruction'],
    [[unknown, burn, dust], 'Destroys assets, moves funds and runs undecoded instructions · review each below', 'Burn 5 raw units and 1 transfer and 1 undecoded instruction'],
    [[approve, burn, unknown], 'Changes permissions, destroys assets and runs undecoded instructions · review each below',
      `Approve ${k(0x12)} as token delegate and burn 5 raw units and 1 undecoded instruction`],
    [[approve, burn, dust, unknown], 'Changes permissions, destroys assets, moves funds and runs undecoded instructions · review each below',
      `Approve ${k(0x12)} as token delegate and burn 5 raw units and 1 transfer of 0.000001 SOL and 1 undecoded instruction`],
  ];
  for (const [ixs, headline, summary] of cases) {
    const r = solTx(ixs);
    assert.deepEqual([r.display.headline, r.summary, r.warnings[0], r.riskLevel], [headline, summary, UNDECODED, 'high']);
    assert.ok(r.warnings.some(w => w.startsWith('HIGH RISK: This permanently destroys ')), 'the burn warning stays');
  }
  // A marketplace instruction is named by its marketplace, alone and beside a transfer, as before.
  const MARKET = 'M2mx93ekt1fmXSVkTrUL9xVFHkmME8HTUi5Cyc5aF7K';
  const listing = { program: MARKET, accounts: [SOL, k(0x73)], data: new Uint8Array([9, 9]) };
  assert.deepEqual([solTx([listing]).display.headline, solTx([listing]).summary], ['Magic Eden M2 · not decoded', 'NFT marketplace action (not decoded)']);
  const sale = solTx([listing, dust]);
  assert.deepEqual([sale.display.headline, sale.summary], ['Magic Eden M2 · not decoded', '0.000001 SOL']);
  assert.ok(!sale.warnings.includes(UNDECODED));
  // Beside another program that cannot be decoded, the marketplace name does not cover it.
  const both = solTx([listing, dust, unknown]);
  assert.deepEqual([both.display.headline, both.summary], ['Moves funds and runs undecoded instructions · review each below', '0.000001 SOL and 1 undecoded instruction']);
  // A transaction with nothing decoded at all is counted, as before.
  assert.deepEqual([solTx([unknown, unknown]).display.headline, solTx([unknown, unknown]).summary], [undefined, '2 instructions']);
});

// ---------------------------------------------------------------- EVM helpers
const ME = accounts.find(a => a.chain === 'evm').address;
const MY_KEY = withSeed(MN, '', (seed, root) => withKey(seed, root, 'evm', PATHS.evm, key => '0x' + Buffer.from(key).toString('hex')));
const ATTACKER = getAddress('0xbad000000000000000000000000000000000bad0');
const USDC = '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48', DAI = '0x6B175474E89094C44Da98b954EedeAC495271d0F';
const WETH = '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2', USDT = '0xdAC17F958D2ee523a2206206994597C13D831ec7';
const SAFE = '0x4444444444444444444444444444444444444444', MULTISEND = '0x40A2aCCbd92BCA938b02010E17A5b8929b49130D';
const iface = new Interface(['function transfer(address,uint256)', 'function approve(address,uint256)', 'function multiSend(bytes)']);
const SAFE_TYPES = [['to', 'address'], ['value', 'uint256'], ['data', 'bytes'], ['operation', 'uint8'], ['safeTxGas', 'uint256'], ['baseGas', 'uint256'],
  ['gasPrice', 'uint256'], ['gasToken', 'address'], ['refundReceiver', 'address'], ['nonce', 'uint256']].map(([name, type]) => ({ name, type }));
const safeTx = (message, domain) => parseEVM({ chain: 'evm', kind: 'typedData', address: ME, chainId: 1, typedData: {
  primaryType: 'SafeTx', types: { SafeTx: SAFE_TYPES }, domain,
  message: { value: '0', data: '0x', operation: 0, safeTxGas: '0', baseGas: '0', gasPrice: '0', gasToken: ZeroAddress, refundReceiver: ZeroAddress, nonce: '7', ...message } } }).review;
const packMulti = calls => '0x' + calls.map(({ to, data }) => '00' + to.slice(2).toLowerCase() + '0'.repeat(64) + ((data.length - 2) / 2).toString(16).padStart(64, '0') + data.slice(2)).join('');
const NO_NETWORK = 'HIGH RISK: This Safe signature names no network, so it can be executed on every chain where this Safe exists. Check the amount and recipient as if it will run on all of them.';

test('A Safe transaction with no chain ID still shows what leaves the Safe, and to whom', () => {
  const send = { to: ATTACKER, value: (250n * 10n ** 18n).toString() };
  const bare = safeTx(send, { verifyingContract: SAFE });
  assert.deepEqual([bare.display.action, bare.display.amount, bare.display.symbol, bare.display.counterpartyLabel, bare.display.counterparty],
    ['Safe: Send', '250', 'native coin', 'To', ATTACKER]);
  assert.equal(bare.riskLevel, 'high', 'valid on every chain this Safe exists on: the acknowledgement is required');
  assert.equal(bare.warnings[0], NO_NETWORK);
  assert.ok(!bare.warnings.some(w => w.startsWith('Network context not included')), 'the HIGH RISK warning replaces the yellow note');
  // A token transfer keeps its raw units and recipient, and is gated the same way.
  const token = safeTx({ to: USDC, data: iface.encodeFunctionData('transfer', [ATTACKER, 10n ** 12n]) }, { verifyingContract: SAFE });
  assert.deepEqual([token.display.amount, token.display.counterparty, token.riskLevel], ['1000000000000', ATTACKER, 'high']);
  // With a chain ID nothing changes: the network names the currency and the signature stays on it.
  const pinned = safeTx(send, { chainId: 1, verifyingContract: SAFE });
  assert.deepEqual([pinned.display.amount, pinned.display.symbol, pinned.riskLevel], ['250', 'ETH', 'normal']);
  assert.ok(!pinned.warnings.includes(NO_NETWORK));
});

test('A Safe batch never folds a token transfer behind revokes', () => {
  const SPENDER = getAddress('0x1111111254eeb25477b68fb85ed929f73a960582');
  const revoke = to => ({ to, data: iface.encodeFunctionData('approve', [SPENDER, 0n]) });
  const send = { to: USDC, data: iface.encodeFunctionData('transfer', [ATTACKER, 1_000_000n * 10n ** 6n]) };
  const batch = calls => safeTx({ to: MULTISEND, data: iface.encodeFunctionData('multiSend', [packMulti(calls)]), operation: 1 }, { chainId: 1, verifyingContract: SAFE });
  const r = batch([revoke(DAI), revoke(WETH), revoke(USDT), send]);
  assert.equal(r.display.headline, '4 calls: Send (1000000 USDC); Revoke Approval (0 DAI); Revoke Approval (0 WETH) (+1 more)');
  // More value-moving calls than fit are counted by kind, never cut off.
  const many = batch([...Array(9).fill(send), revoke(DAI)]);
  assert.equal(many.display.headline, '10 calls: 9 transfers, 1 other · review each below');
});

// ---------------------------------------------------------------- EIP-7702
const signed = (auth) => ({ ...auth, signature: new SigningKey(MY_KEY).sign(hashAuthorization(auth)) });
const delegation = (authorizationList, { value = 0n, nonce = 0 } = {}) => parseEVM({ chain: 'evm', kind: 'transaction', address: ME,
  transaction: Transaction.from({ type: 4, chainId: 1, nonce, to: ME, value, data: '0x', gasLimit: 100000, maxFeePerGas: 2n, maxPriorityFeePerGas: 1n,
    authorizationList }).unsignedSerialized }).review;

test('An EIP-7702 delegation is the headline, not the empty outer call', () => {
  const own = delegation([signed({ address: ATTACKER, nonce: 1, chainId: 1 })]);
  assert.deepEqual([own.title, own.display.action, own.display.headline, own.display.counterpartyLabel, own.display.counterparty],
    ['Delegate account', 'Delegate account', 'Hands this account to a contract', 'Delegate contract', ATTACKER]);
  assert.equal(own.display.amount, undefined, 'no "0 ETH" stands in for the delegation');
  assert.equal(own.summary, `Delegate this account to ${ATTACKER}`);
  assert.equal(own.riskLevel, 'high');

  const everywhere = delegation([signed({ address: ATTACKER, nonce: 1, chainId: 0 })]);
  assert.equal(everywhere.display.headline, 'Hands this account to a contract on every chain');
  assert.equal(everywhere.summary, `Delegate this account to ${ATTACKER} on every chain`);

  // With value as well, both are named and the amount is kept in the summary.
  const paying = delegation([signed({ address: ATTACKER, nonce: 1, chainId: 1 })], { value: 10n ** 18n });
  assert.equal(paying.display.headline, 'Changes account delegation and moves funds · review each below');
  assert.equal(paying.display.counterparty, undefined);
  assert.equal(paying.summary, `Delegate this account to ${ATTACKER} and send 1 ETH`);

  const revoke = delegation([signed({ address: ZeroAddress, nonce: 1, chainId: 1 })]);
  assert.deepEqual([revoke.title, revoke.display.headline, revoke.summary, revoke.riskLevel],
    ['Remove account delegation', 'Restores this account to a plain account', 'Remove the code delegation of this account', 'normal']);

  const two = delegation([signed({ address: ATTACKER, nonce: 1, chainId: 1 }), signed({ address: ZeroAddress, nonce: 2, chainId: 1 })]);
  assert.deepEqual([two.title, two.display.headline, two.summary], ['Change account delegations', 'Several account delegations · review each below', '2 account delegations']);
});
