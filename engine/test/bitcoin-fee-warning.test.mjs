import test from 'node:test';
import assert from 'node:assert/strict';
import { Transaction, p2wpkh } from '@scure/btc-signer';
import { withSeed, withKey } from '../src/keys.js';
import { parseBitcoin } from '../src/bitcoin.js';
import { toBase64 } from '../src/util.js';

const MN = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const OTHER = 'legal winner thank year wave sausage worth useful legal winner thank yellow';
const PATH = "m/84'/0'/0'/0/0";
const node = (mn = MN) => withSeed(mn, '', (seed, root) => withKey(seed, root, 'bitcoin', PATH,
  (priv, pub) => ({ pub: pub.slice(), fingerprint: root.fingerprint,
                    path: PATH.split('/').slice(1).map(x => Number(x.replace("'", '')) + (x.endsWith("'") ? 2 ** 31 : 0)) })));
const me = node(), them = node(OTHER);

/** One input of `input` satoshis paying `output` satoshis; the rest is the fee. */
function review(input, output) {
  const mine = p2wpkh(me.pub), theirs = p2wpkh(them.pub);
  const prev = new Transaction();
  prev.addInput({ txid: new Uint8Array(32), index: 0 });
  prev.addOutput({ script: mine.script, amount: input });
  const tx = new Transaction({ unknown: 'ignore', proprietary: 'ignore' });
  tx.addInput({ txid: prev.id, index: 0, nonWitnessUtxo: prev.unsignedTx,
                witnessUtxo: { script: mine.script, amount: input },
                bip32Derivation: [[me.pub, { fingerprint: me.fingerprint, path: me.path }]] });
  tx.addOutput({ script: theirs.script, amount: output });
  return withSeed(MN, '', (seed, root) =>
    parseBitcoin({ chain: 'bitcoin', psbt: toBase64(tx.toPSBT()), network: 'mainnet' }, seed, root).review);
}
const warns = (input, output) => review(input, output).warnings.some(w => w.startsWith('HIGH FEE'));

test('A high fee is one that is large outright, or over half of what is sent', () => {
  // 0.01 BTC and above is always worth a second look, however big the payment.
  assert.equal(warns(200_000_000n, 198_900_000n), true, '0.011 BTC fee on a 1.989 BTC payment: nowhere near half, but large outright');
  assert.equal(warns(200_000_000n, 198_000_000n), true, '0.02 BTC fee on a 1.98 BTC payment');
  assert.equal(warns(2_000_000n, 1_000_000n), true, 'exactly the 0.01 BTC absolute threshold is not exceeded, but the fee is half');

  // Over half of the amount sent, once the fee is itself worth mentioning.
  assert.equal(warns(50_000n, 20_000n), true, '0.0003 BTC fee on a 0.0002 BTC payment');
  assert.equal(warns(31_000n, 20_000n), true, '0.00011 BTC fee just over the floor');
});

test('Small fees stay quiet, which is the point of the floor', () => {
  // The reported case: 0.00003506 BTC fee on a 0.00006494 BTC payment. That is
  // over half, but a few thousand satoshis is what the network costs.
  assert.equal(warns(10_000n, 6_494n), false, 'the fee is 54% of the payment but only 0.00003506 BTC');
  // Right at the floor and just under it.
  assert.equal(warns(11_000n, 1_000n), false, '0.0001 BTC exactly: not over the floor');
  assert.equal(warns(10_999n, 1_000n), false, 'just under the floor');
  assert.equal(warns(11_001n, 1_000n), true, 'one satoshi over the floor, and over half');
});

test('A fee that is a small share of the payment never warns on size alone', () => {
  assert.equal(warns(100_000_000n, 99_500_000n), false, '0.005 BTC on a 0.995 BTC payment');
  assert.equal(warns(1_000_000n, 990_000n), false, '0.0001 BTC on a 0.0099 BTC payment');
});
