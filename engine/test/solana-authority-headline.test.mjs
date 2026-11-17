// A change of control leads the Solana review (BTS-02, earlier BTS-07). A transfer
// of one lamport used to become the headline and the Activity summary of a
// transaction that also handed a token account, a mint or a stake to someone else.
// Synthetic transactions only; the fee payer is the public test mnemonic.
import test from 'node:test';
import assert from 'node:assert/strict';
import { base58 } from '@scure/base';
import { parseSolana } from '../src/solana.js';
import { deriveAccounts } from '../src/keys.js';
import { concat, short, toBase64 } from '../src/util.js';

const MN = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const ME = deriveAccounts({ mnemonic: MN }).accounts.find(a => a.chain === 'solana').address;
const SYSTEM = '11111111111111111111111111111111';
const TOKEN = 'TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA';
const STAKE = 'Stake11111111111111111111111111111111111111';
const CLOCK = 'SysvarC1ock11111111111111111111111111111111';
const k = n => base58.encode(new Uint8Array(32).fill(n));
const u64 = n => { const b = new Uint8Array(8); new DataView(b.buffer).setBigUint64(0, BigInt(n), true); return b; };
const u32 = n => { const b = new Uint8Array(4); new DataView(b.buffer).setUint32(0, n, true); return b; };
const bytes = (...parts) => concat(...parts.map(p => p instanceof Uint8Array ? p : new Uint8Array(p)));

/** A legacy message signed by the test wallet; programs are read-only keys at the end. */
function tx(ixs) {
  const programs = [...new Set(ixs.map(ix => ix.program))], keys = [ME];
  for (const ix of ixs) for (const a of ix.accounts) if (!keys.includes(a) && !programs.includes(a)) keys.push(a);
  keys.push(...programs);
  const at = x => keys.indexOf(x);
  const message = concat(new Uint8Array([1, 0, programs.length]), short(keys.length), ...keys.map(x => base58.decode(x)), new Uint8Array(32).fill(5), short(ixs.length),
    ...ixs.flatMap(ix => [new Uint8Array([at(ix.program)]), short(ix.accounts.length), new Uint8Array(ix.accounts.map(at)), short(ix.data.length), ix.data]));
  return { chain: 'solana', kind: 'transaction', message: toBase64(message) };
}
const review = ixs => parseSolana(tx(ixs)).review;
const value = (r, label) => r.fields.find(f => f.label.endsWith('· ' + label))?.value;
const ALSO = 'This transaction changes permissions and also moves funds. Check every transfer below as carefully as the permission change.';
const BOTH = 'Changes permissions and moves funds · review each below';

const dust = (to = k(0x71)) => ({ program: SYSTEM, accounts: [ME, to], data: bytes([2, 0, 0, 0], u64(1n)) });
const approve = (account, delegate) => ({ program: TOKEN, accounts: [account, delegate, ME], data: bytes([4], u64((1n << 64n) - 1n)) });
const setAuthority = (target, type, next) => ({ program: TOKEN, accounts: [target, ME],
  data: next ? bytes([6, type, 1], base58.decode(next)) : bytes([6, type, 0]) });
const assign = owner => ({ program: SYSTEM, accounts: [ME], data: bytes([1, 0, 0, 0], base58.decode(owner)) });
const authorize = (stake, next, kind) => ({ program: STAKE, accounts: [stake, CLOCK, ME], data: bytes(u32(1), base58.decode(next), u32(kind)) });
const authorizeChecked = (stake, next, kind) => ({ program: STAKE, accounts: [stake, CLOCK, ME, next], data: bytes(u32(10), u32(kind)) });

const CASES = [
  { name: 'SPL Approve', ix: approve(k(0x11), k(0x12)), action: 'Approve delegate', headline: 'Lets another address spend these tokens',
    counterparty: k(0x12), summary: `Approve ${k(0x12)} as token delegate` },
  { name: 'SetAuthority (account owner)', ix: setAuthority(k(0x13), 2, k(0x14)), action: 'Change token authority', headline: 'Hands this authority to another address',
    counterparty: k(0x14), summary: `Change token authority (Account owner) to ${k(0x14)}` },
  { name: 'SetAuthority (mint, to none)', ix: setAuthority(k(0x15), 0), action: 'Change token authority', headline: 'Removes this authority',
    counterparty: undefined, summary: 'Remove token authority (Mint tokens)' },
  { name: 'System Assign', ix: assign(k(0x16)), action: 'Assign account owner program', headline: 'Hands this account to another program',
    counterparty: k(0x16), summary: `Assign account to program ${k(0x16)}` },
  { name: 'Stake Authorize (withdraw)', ix: authorize(k(0x17), k(0x18), 1), action: 'Change stake authority', headline: 'Hands stake authority to another address',
    counterparty: k(0x18), summary: `Change stake withdraw authority to ${k(0x18)}` },
];

test('A one-lamport transfer never becomes the headline of a change of control', () => {
  for (const c of CASES) {
    for (const [order, ixs] of [['transfer first', [dust(), c.ix]], ['control first', [c.ix, dust()]]]) {
      const r = review(ixs), why = `${c.name}, ${order}`;
      assert.equal(r.display.action, c.action, why);
      assert.equal(r.display.headline, BOTH, `${why}: the headline names both effects`);
      assert.equal(r.display.counterparty, c.counterparty, why);
      assert.equal(r.display.amount, undefined, `${why}: no amount stands in for the change`);
      assert.equal(r.summary, c.summary + ' and 1 transfer of 0.000000001 SOL', `${why}: the Activity summary names both`);
      assert.equal(r.warnings[0], ALSO, `${why}: and the first warning says to check each`);
      assert.equal(r.riskLevel, 'high', why);
    }
    const many = review([dust(k(0x71)), c.ix, dust(k(0x72))]);
    assert.equal(many.summary, c.summary + ' and 2 transfers', c.name);
  }
});

test('A change of control on its own reads the same, without the transfer note', () => {
  for (const c of CASES) {
    const r = review([c.ix]);
    assert.deepEqual([r.display.action, r.display.headline, r.display.counterparty, r.summary], [c.action, c.headline, c.counterparty, c.summary], c.name);
    assert.ok(!r.warnings.includes(ALSO), c.name);
  }
  // Removing an authority names no new holder.
  assert.ok(!('counterparty' in review([setAuthority(k(0x15), 0)]).display));
});

test('Several changes of control are counted, not reduced to the first', () => {
  const r = review([approve(k(0x11), k(0x12)), setAuthority(k(0x13), 2, k(0x14))]);
  assert.equal(r.display.action, 'Change permissions');
  assert.equal(r.display.headline, 'Several permission changes · review each below');
  assert.equal(r.display.counterparty, undefined, 'no single holder stands in for two changes');
  assert.equal(r.summary, '2 permission changes');
  const withFunds = review([approve(k(0x11), k(0x12)), setAuthority(k(0x13), 2, k(0x14)), dust()]);
  assert.equal(withFunds.display.headline, BOTH);
  assert.equal(withFunds.summary, '2 permission changes and 1 transfer of 0.000000001 SOL');
});

test('Stake Authorize and AuthorizeChecked are decoded and say what the new authority can do', () => {
  const withdraw = review([authorize(k(0x17), k(0x18), 1)]);
  assert.deepEqual([value(withdraw, 'Action'), value(withdraw, 'Authority type'), value(withdraw, 'New authority'), value(withdraw, 'Current authority')],
                   ['Change stake authority', 'Withdraw', k(0x18), ME]);
  assert.ok(withdraw.warnings.includes('HIGH RISK: The new withdraw authority can withdraw every lamport in this stake account and can replace both of its authorities.'));
  const stake = review([authorize(k(0x17), k(0x18), 0)]);
  assert.equal(value(stake, 'Authority type'), 'Stake');
  assert.ok(stake.warnings.includes('HIGH RISK: The new stake authority can delegate, deactivate, split or merge this stake account.'));
  // AuthorizeChecked has the new authority sign as an account rather than carry it in data.
  const checked = review([authorizeChecked(k(0x17), k(0x19), 1)]);
  assert.deepEqual([value(checked, 'New authority'), checked.display.counterparty], [k(0x19), k(0x19)]);
  assert.equal(checked.decodeStatus, 'fullyDecoded', 'no longer shown as raw bytes');
  assert.throws(() => review([authorize(k(0x17), k(0x18), 2)]), /Unsupported stake authority type/);
});

test('A trivial approval does not hide a transfer that empties the wallet', () => {
  // The mirror image of the dust case: 1000 SOL out, beside an approval of zero
  // tokens. Leading with the approval alone would bury the transfer.
  const drain = { program: SYSTEM, accounts: [ME, k(0x71)], data: bytes([2, 0, 0, 0], u64(1000_000_000_000n)) };
  const zero = { program: TOKEN, accounts: [k(0x11), k(0x12), ME], data: bytes([4], u64(0n)) };
  for (const ixs of [[drain, zero], [zero, drain]]) {
    const r = review(ixs);
    assert.equal(r.display.headline, BOTH);
    assert.equal(r.warnings[0], ALSO);
    assert.match(r.summary, / and 1 transfer of 1000 SOL$/, 'the amount is kept in the Activity summary');
    assert.equal(value(r, 'Amount (SOL)'), '1000', 'and the transfer is in the details');
  }
});

// ---------------------------------------------------------------- burns (BTS-02, Revision 17)
// A burn beside a change of control used to be counted as a transfer: "Remove token
// authority (Mint tokens) and 1 transfer", under "Changes permissions and moves funds".
// A burn is its own effect, named as a burn in the headline, the summary and the
// first warning, next to the transfers that really are transfers.
const burn = (mint, amount, account = k(0x5a)) => ({ program: TOKEN, accounts: [account, mint, ME], data: bytes([8], u64(amount)) });
const revokeMint = setAuthority(k(0x31), 0);
const approveZero = { program: TOKEN, accounts: [k(0x11), k(0x41), ME], data: bytes([4], u64(0n)) };
const BURNS = 'This transaction changes permissions and also destroys assets. Check every burn below as carefully as the permission change.';
const ALL_THREE = 'This transaction changes permissions, destroys assets and moves funds. Check every burn and transfer below as carefully as the permission change.';
const DESTROYED = /^HIGH RISK: This permanently destroys /;

test('A burn beside a change of control is named as a burn, never as a transfer', () => {
  const cases = [
    { name: 'revoke mint authority + fungible burn', control: revokeMint, burn: burn(k(0x31), 1_000_000_000n),
      summary: 'Remove token authority (Mint tokens) and burn 1000000000 raw units' },
    { name: 'approve 0 + NFT burn', control: approveZero, burn: burn(k(0x32), 1n, k(0x5b)),
      summary: `Approve ${k(0x41)} as token delegate and burn 1 raw unit` },
  ];
  for (const c of cases) {
    for (const [order, ixs] of [['control first', [c.control, c.burn]], ['burn first', [c.burn, c.control]]]) {
      const r = review(ixs), why = `${c.name}, ${order}`;
      assert.equal(r.display.headline, 'Changes permissions and destroys assets · review each below', why);
      assert.equal(r.summary, c.summary, why);
      assert.equal(r.warnings[0], BURNS, why);
      assert.ok(!r.warnings.includes(ALSO), `${why}: nothing here moves funds`);
      assert.ok(r.warnings.some(w => DESTROYED.test(w)), `${why}: the burn warning stays`);
      assert.equal(r.display.amount, undefined, why);
      assert.equal(r.riskLevel, 'high', why);
    }
    // With a dust transfer as well, in each position: all three are named, and only
    // the real transfer is counted as one.
    for (const ixs of [[c.control, c.burn, dust()], [dust(), c.control, c.burn], [c.burn, dust(), c.control]]) {
      const r = review(ixs);
      assert.equal(r.display.headline, 'Changes permissions, destroys assets and moves funds · review each below', c.name);
      assert.equal(r.summary, c.summary + ' and 1 transfer of 0.000000001 SOL', c.name);
      assert.equal(r.warnings[0], ALL_THREE, c.name);
      assert.ok(r.warnings.some(w => DESTROYED.test(w)), c.name);
      assert.equal(r.riskLevel, 'high', c.name);
    }
    assert.equal(review([c.control, c.burn, dust(k(0x71)), dust(k(0x72))]).summary, c.summary + ' and 2 transfers', c.name);
  }
  // Burns of several assets are each named, as the burn headline names them.
  assert.equal(review([revokeMint, burn(k(0x31), 5n), burn(k(0x33), 7n, k(0x5c))]).summary,
    'Remove token authority (Mint tokens) and burn 5 raw units + 7 raw units');
  // Two permission changes and a burn.
  const two = review([approveZero, revokeMint, burn(k(0x31), 5n)]);
  assert.deepEqual([two.display.action, two.display.headline, two.summary],
    ['Change permissions', 'Changes permissions and destroys assets · review each below', '2 permission changes and burn 5 raw units']);
});

test('A burn without a change of control keeps its own headline', () => {
  const alone = review([burn(k(0x31), 5n)]);
  assert.equal(alone.display.action, 'Burn');
  assert.equal(alone.summary, 'Burn 5 raw units');
  const withDust = review([burn(k(0x31), 5n), dust()]);
  assert.match(withDust.display.headline, /^Destroys 5 raw units · 1 other transfer below$/);
  assert.ok(!withDust.warnings.includes(BURNS) && !withDust.warnings.includes(ALL_THREE));
});
