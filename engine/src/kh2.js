import { secp256k1 } from '@noble/curves/secp256k1.js';
import { sha256 } from '@noble/hashes/sha2.js';
import { p2pkh } from '@scure/btc-signer';
import { withSeedInput, withKey } from './keys.js';
import { derivePublicKeyAt, seedWalletKeyId } from './public-index.js';
import { check, concat, utf8, bytesToHex, hexToBytes, toBase64, fromBase64, equal } from './util.js';

// ---------------------------------------------------------------------------
// KH v2 wallet-identity signature (docs/Wallet-Pairing-v2.md).
//
// A wallet proves it holds the private key behind the extended public key it is
// known by, by signing one fixed sentence. The backend derives the same key as
// the non-hardened child AUTH_INDEX of the extended key the wallet registered
// and checks the signature against it; it never sees a private key.
//
// BitTool Wallet registers the BIP44 receive-branch xpub (`m/44'/0'/0'/0`) as
// its identity — for a hot wallet and for a watch wallet paired from BitTool
// Signer alike — so the signing key is that branch's child AUTH_INDEX and the
// verifying address is its P2PKH (`1…`) address.

/** The non-hardened child index the identity key lives at. Fixed by the backend. */
export const KH_V2_AUTH_INDEX = 1000000000;
/** The only text this module will ever sign, completed with the epoch. */
export const KH_V2_MESSAGE_PREFIX = 'OwnbitAuth:v2:epoch=';
/** The account whose receive branch is the wallet's registered identity. */
export const KH_V2_ACCOUNT_PATH = "m/44'/0'/0'";
/** The identity key: receive branch, child AUTH_INDEX. */
export const KH_V2_PATH = KH_V2_ACCOUNT_PATH + '/0/' + KH_V2_AUTH_INDEX;
/** Signatures are 65 bytes: header, R, S. The header is 27 + recovery id, plus
 * 4 because the key is compressed, so 31..34 for a key BitTool Signer holds. */
const SIGNATURE_BYTES = 65, HEADER_MIN = 27, HEADER_MAX = 42, COMPRESSED_HEADER = 4;
const ORDER = secp256k1.Point.Fn.ORDER, HALF_ORDER = ORDER >> 1n;

/** The sentence for one epoch. Nothing else can be signed: there is deliberately
 * no way to pass a message in, so this module cannot be turned into an oracle
 * for arbitrary text that happens to arrive in a QR code. */
export function khV2Message(epoch) {
  check(Number.isSafeInteger(epoch) && epoch >= 1 && epoch <= 1000000, 'EPOCH', 'Unsupported wallet identity epoch.');
  return KH_V2_MESSAGE_PREFIX + epoch;
}

/** Bitcoin's compact size, for the message length inside the signed preimage. */
function varint(n) {
  if (n < 0xfd) return new Uint8Array([n]);
  check(n <= 0xffff, 'LIMIT', 'Message is too long to sign.');
  return new Uint8Array([0xfd, n & 0xff, n >>> 8]);
}

/** The digest a Bitcoin message signature covers: SHA-256 twice over the
 * length-prefixed magic string and the length-prefixed message. */
export function bitcoinMessageDigest(message) {
  const magic = utf8('Bitcoin Signed Message:\n'), body = utf8(message);
  return sha256(sha256(concat(varint(magic.length), magic, varint(body.length), body)));
}

/** Decodes a base64 signature into its 65 bytes, rejecting anything that is not
 * one: wrong length, a header outside the range, or R/S outside 1..n-1. */
export function khV2SignatureBytes(signature) {
  check(typeof signature === 'string' && signature.length === 88, 'SIGNATURE', 'Invalid wallet identity signature.');
  const bytes = fromBase64(signature, SIGNATURE_BYTES);
  check(bytes.length === SIGNATURE_BYTES, 'SIGNATURE', 'Invalid wallet identity signature.');
  check(bytes[0] >= HEADER_MIN && bytes[0] <= HEADER_MAX, 'SIGNATURE', 'Invalid wallet identity signature header.');
  for (const half of [bytes.subarray(1, 33), bytes.subarray(33, 65)]) {
    const value = BigInt('0x' + bytesToHex(half));
    check(value > 0n && value < ORDER, 'SIGNATURE', 'Wallet identity signature is out of range.');
  }
  return bytes;
}

/** `kh2` = SHA-256 over R and S with S folded into the low half, lower-case hex.
 * The folding matters: the same signature with a high S has to hash the same,
 * because that is the value the backend stores. */
export function khV2FromSignature(signature) {
  const bytes = khV2SignatureBytes(signature);
  let s = BigInt('0x' + bytesToHex(bytes.subarray(33, 65)));
  if (s > HALF_ORDER) s = ORDER - s;
  return bytesToHex(sha256(concat(bytes.subarray(1, 33), hexToBytes(s.toString(16).padStart(64, '0')))));
}

/** The public key a signature was made with, or undefined when the header's
 * recovery id does not describe a key on the curve. */
function recoverKey(bytes, digest) {
  const recovery = (bytes[0] - HEADER_MIN) & 3;
  try { return secp256k1.recoverPublicKey(concat(new Uint8Array([recovery]), bytes.subarray(1)), digest, { prehash: false }); }
  catch { return undefined; }
}

/** True when `signature` is a valid signature of this epoch's sentence by
 * `publicKey` (33 compressed bytes). Both the recovered key and an explicit
 * verification have to agree, so a malleated or re-headered signature fails. */
export function verifyKhV2({ signature, epoch, publicKey }) {
  const expected = hexToBytes(publicKey, 33);
  check(expected.length === 33 && (expected[0] === 2 || expected[0] === 3), 'SIGNER', 'Expected a compressed public key.');
  const bytes = khV2SignatureBytes(signature), digest = bitcoinMessageDigest(khV2Message(epoch));
  const recovered = recoverKey(bytes, digest);
  return !!recovered && equal(recovered, expected)
    && secp256k1.verify(bytes.subarray(1), digest, expected, { prehash: false, lowS: true });
}

/** Signs this epoch's sentence with the wallet's identity key and checks the
 * result before returning it: the signature must recover exactly the key that
 * made it. A signature that does not verify here never leaves this function. */
export function signKhV2({ mnemonic, passphrase, seed, epoch = 1 }) {
  const message = khV2Message(epoch), digest = bitcoinMessageDigest(message);
  return withSeedInput({ mnemonic, passphrase, seed }, (seedBytes, root) =>
    withKey(seedBytes, root, 'bitcoin', KH_V2_PATH, (key, publicKey) => {
      const recovered = secp256k1.sign(digest, key, { prehash: false, lowS: true, format: 'recovered' });
      // Bitcoin's message header counts from 27 and adds 4 for a compressed key.
      const bytes = concat(new Uint8Array([HEADER_MIN + COMPRESSED_HEADER + recovered[0]]), recovered.subarray(1));
      const signature = toBase64(bytes);
      check(verifyKhV2({ signature, epoch, publicKey: bytesToHex(publicKey) }), 'SIGNATURE', 'Wallet identity signature failed verification.');
      // The wallet this signature belongs to, from the same decrypted seed, so the
      // host can store it beside the right public index without deriving again.
      return { epoch, message, path: KH_V2_PATH, walletKeyId: seedWalletKeyId(root),
        publicKey: bytesToHex(publicKey), address: p2pkh(publicKey).address,
        signature, kh2: khV2FromSignature(signature) };
    }));
}

/** The identity key as the receiving wallet and the backend see it: derived from
 * public data only. Used to check a stored signature before it is exported. */
export function khV2PublicIdentity(cache) {
  const node = derivePublicKeyAt(cache, 'bitcoin', KH_V2_PATH);
  check(node.profile === 'legacy', 'PUBLIC_INDEX', 'The wallet identity key is not a BIP44 key.');
  return { path: KH_V2_PATH, publicKey: node.publicKey, address: node.address };
}

/** Checks a signature against a validated public index, the way the receiving
 * wallet will. Throws rather than returning false: a wallet-level QR must not
 * carry an identity its own public keys disagree with. */
export function requireKhV2(cache, signature, epoch) {
  const identity = khV2PublicIdentity(cache);
  check(verifyKhV2({ signature, epoch, publicKey: identity.publicKey }), 'SIGNATURE',
        'The wallet identity signature does not match this wallet.');
  return identity;
}
