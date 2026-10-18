/** Offline QR transport. Wire formats are verified against the upstream registries.
 * Signing, account ownership, and transaction verification remain the engine's responsibility.
 */
import { Buffer } from 'buffer';
import { UR, URDecoder, UREncoder } from '@ngraveio/bc-ur';
import { HDKey } from '@scure/bip32';
import { base58, base58check, base32nopad } from '@scure/base';
import { sha256 } from '@noble/hashes/sha2.js';
import { validatePublicIndex, derivePublicKeyAt, BITCOIN_PROFILES, SOLANA_PROFILES } from './src/public-index.js';
import { requestHash as hashRequest } from './src/util.js';
import { psbtSummary } from './src/bitcoin.js';
import { Inflate } from 'fflate';

export const QR_LIMITS = Object.freeze({ payloadBytes: 131072, frames: 2048, frameChars: 4300, retainedChars: 1048576 });
// Only controlled, payload-free diagnostics may cross the native dispatch boundary.
export class ProtocolError extends Error {
  constructor(message) { super(message); this.name = 'ProtocolError'; this.code = 'QR_PROTOCOL'; }
}
const fail = message => { throw new ProtocolError(message); };
const ensure = (condition, message) => { if (!condition) fail(message); };
const hex = (value, length) => {
  ensure(typeof value === 'string', 'Expected hexadecimal string');
  const text = value.replace(/^0x/, '');
  ensure(text.length % 2 === 0 && /^[0-9a-f]*$/i.test(text), 'Invalid hexadecimal bytes');
  const bytes = Buffer.from(text, 'hex');
  ensure(length === undefined || bytes.length === length, 'Unexpected byte length');
  return bytes;
};
const bytes = (value, name, length) => {
  ensure(Buffer.isBuffer(value), `${name} must be bytes`);
  ensure(length === undefined || value.length === length, `${name} has invalid length`);
  return value;
};
function requestIdBytes(value, ethereum) {
  const id = bytes(value, 'requestId');
  // imToken uses an opaque 36-byte correlation ID under the registry's UUID
  // tag. Keystone accepts/echoes the bytes as supplied. Do not normalize them
  // into a UUID or change the existing Solana UUID constraint.
  ensure(ethereum ? id.length > 0 && id.length <= 64 : id.length === 16, 'requestId has invalid length');
  return id;
}
const b64 = value => {
  ensure(typeof value === 'string' && /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value), 'Invalid base64 bytes');
  return Buffer.from(value, 'base64');
};
const checkSize = data => { ensure(data.length > 0 && data.length <= QR_LIMITS.payloadBytes, 'QR payload exceeds supported size'); return data; };

// Only definite CBOR is accepted. Reject duplicate map labels, unsafe integers,
// excessive nesting, unsupported floats, and trailing data before upstream parsers run.
function readCBOR(input) {
  const data = checkSize(Buffer.from(input));
  let offset = 0, nodes = 0;
  const take = n => {
    ensure(n >= 0 && offset + n <= data.length, 'Truncated CBOR');
    const result = data.subarray(offset, offset + n); offset += n; return result;
  };
  const item = depth => {
    ensure(depth <= 24 && ++nodes <= 20000, 'CBOR complexity limit exceeded');
    const first = take(1)[0], major = first >> 5, info = first & 31;
    ensure(info <= 27, 'Indefinite or reserved CBOR encoding is unsupported');
    if (major === 7) {
      ensure(info === 20 || info === 21 || info === 22, 'Unsupported CBOR simple value');
      return info === 22 ? null : info === 21;
    }
    let size = BigInt(info);
    if (info >= 24) { size = 0n; for (const n of take(2 ** (info - 24))) size = (size << 8n) | BigInt(n); }
    ensure(size <= BigInt(Number.MAX_SAFE_INTEGER), 'CBOR integer exceeds exact numeric range');
    const n = Number(size);
    if (major === 0) return n;
    if (major === 1) return -1 - n;
    if (major === 2 || major === 3) {
      const value = take(n);
      if (major === 2) return value;
      const text = value.toString('utf8');
      ensure(Buffer.from(text, 'utf8').equals(value), 'Invalid UTF-8');
      return text;
    }
    if (major === 4) { ensure(n <= 20000, 'CBOR array too large'); return Array.from({ length: n }, () => item(depth + 1)); }
    if (major === 5) {
      ensure(n <= 10000, 'CBOR map too large');
      const map = new Map();
      for (let i = 0; i < n; i++) {
        const key = item(depth + 1);
        ensure(typeof key === 'number' || typeof key === 'string', 'Unsupported CBOR map key');
        ensure(!map.has(key), 'Duplicate CBOR map key'); map.set(key, item(depth + 1));
      }
      return map;
    }
    if (major === 6) return { tag: n, value: item(depth + 1) };
    fail('Unsupported CBOR type');
  };
  const result = item(0); ensure(offset === data.length, 'Trailing CBOR data'); return result;
}

function writeCBOR(value) {
  const head = (major, number) => {
    if (number < 24) return Buffer.from([(major << 5) | number]);
    if (number < 256) return Buffer.from([(major << 5) | 24, number]);
    if (number < 65536) { const b = Buffer.alloc(3); b[0] = (major << 5) | 25; b.writeUInt16BE(number, 1); return b; }
    const b = Buffer.alloc(5); b[0] = (major << 5) | 26; b.writeUInt32BE(number, 1); return b;
  };
  if (Buffer.isBuffer(value)) return Buffer.concat([head(2, value.length), value]);
  if (typeof value === 'boolean') return Buffer.from([value ? 0xf5 : 0xf4]);
  if (typeof value === 'string') { const data = Buffer.from(value, 'utf8'); return Buffer.concat([head(3, data.length), data]); }
  if (Array.isArray(value)) return Buffer.concat([head(4, value.length), ...value.map(writeCBOR)]);
  if (value instanceof Map) return Buffer.concat([head(5, value.size), ...[...value].flatMap(([k, v]) => [writeCBOR(k), writeCBOR(v)])]);
  if (value && value.tag !== undefined) return Buffer.concat([head(6, value.tag), writeCBOR(value.value)]);
  if (typeof value === 'number' && Number.isInteger(value) && value >= 0 && value <= 0xffffffff) return head(0, value);
  fail('Unsupported response CBOR value');
}

// A small strict JSON parser protects values that would otherwise be silently
// overwritten (duplicate keys) or rounded before transaction review.
export function parseProtocolJSON(text, maxBytes = QR_LIMITS.payloadBytes) {
  ensure(Number.isInteger(maxBytes) && maxBytes > 0 && maxBytes <= QR_LIMITS.retainedChars, 'Invalid JSON size limit');
  ensure(typeof text === 'string' && Buffer.byteLength(text) <= maxBytes, 'JSON payload too large');
  let p = 0, count = 0;
  const space = () => { while (/\s/.test(text[p] || '') && p < text.length) p++; };
  const string = () => {
    const start = p++; let escaped = false;
    while (p < text.length) {
      const c = text[p++];
      if (c === '"' && !escaped) return JSON.parse(text.slice(start, p));
      if (c === '\\' && !escaped) escaped = true; else escaped = false;
    }
    fail('Unterminated JSON string');
  };
  const value = depth => {
    ensure(depth <= 32 && ++count <= 20000, 'JSON complexity limit exceeded'); space();
    if (text[p] === '"') return string();
    if (text[p] === '{') {
      p++; const result = Object.create(null); const keys = new Set(); space();
      if (text[p] === '}') { p++; return result; }
      while (p < text.length) {
        space(); ensure(text[p] === '"', 'Invalid JSON object key'); const key = string();
        ensure(!keys.has(key), 'Duplicate JSON key'); keys.add(key); space();
        ensure(text[p++] === ':', 'Invalid JSON object'); result[key] = value(depth + 1); space();
        const end = text[p++]; if (end === '}') return result; ensure(end === ',', 'Invalid JSON object');
      }
    }
    if (text[p] === '[') {
      p++; const result = []; space(); if (text[p] === ']') { p++; return result; }
      while (p < text.length) {
        result.push(value(depth + 1)); space(); const end = text[p++];
        if (end === ']') return result; ensure(end === ',', 'Invalid JSON array');
      }
    }
    for (const [literal, result] of [['true', true], ['false', false], ['null', null]]) {
      if (text.startsWith(literal, p)) { p += literal.length; return result; }
    }
    const match = /^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/.exec(text.slice(p));
    ensure(match, 'Invalid JSON value'); p += match[0].length; const result = Number(match[0]);
    ensure(Number.isFinite(result) && (!Number.isInteger(result) || Number.isSafeInteger(result)), 'Unsafe JSON number; encode large integers as strings');
    return result;
  };
  const result = value(0); space(); ensure(p === text.length, 'Trailing JSON data'); return result;
}

function pathFromCBOR(value) {
  ensure(value?.tag === 304 && value.value instanceof Map, 'Invalid crypto-keypath');
  const map = value.value, parts = map.get(1);
  ensure(Array.isArray(parts) && parts.length >= 2 && parts.length <= 20 && parts.length % 2 === 0, 'Invalid signing path');
  const path = [];
  for (let i = 0; i < parts.length; i += 2) {
    ensure(Number.isInteger(parts[i]) && parts[i] >= 0 && parts[i] < 0x80000000 && typeof parts[i + 1] === 'boolean', 'Signing path must be concrete');
    path.push(`${parts[i]}${parts[i + 1] ? "'" : ''}`);
  }
  const fp = map.get(2); let masterFingerprint;
  if (fp !== undefined) { ensure(Number.isInteger(fp) && fp >= 0 && fp <= 0xffffffff, 'Invalid fingerprint'); const b = Buffer.alloc(4); b.writeUInt32BE(fp); masterFingerprint = b.toString('hex'); }
  return { path: `m/${path.join('/')}`, ...(masterFingerprint === undefined ? {} : { masterFingerprint }) };
}

function requestFromUR(ur) {
  const data = readCBOR(ur.cbor), transport = { type: ur.type, payloadEncoding: 'cbor', payloadBytes: Buffer.from(ur.cbor).toString('hex') };
  if (ur.type === 'crypto-psbt' || ur.type === 'psbt') {
    const psbt = bytes(data, 'PSBT'); ensure(psbt.subarray(0, 5).toString('hex') === '70736274ff', 'Invalid PSBT magic');
    return { chain: 'bitcoin', psbt: psbt.toString('base64'), transport };
  }
  ensure(['eth-sign-request', 'sol-sign-request', 'tron-sign-request'].includes(ur.type), 'Unsupported signing UR type');
  ensure(data instanceof Map, 'Sign request must be a CBOR map');
  const isEth = ur.type === 'eth-sign-request', isTron = ur.type === 'tron-sign-request';
  ensure([...data.keys()].every(key => Number.isInteger(key) && key >= 1 && key <= (isEth ? 7 : 6)), 'Unsupported signing request field');
  if (data.has(1)) { const id = data.get(1); ensure(id?.tag === 37, 'Invalid request UUID tag'); transport.requestId = requestIdBytes(id.value, isEth).toString('hex'); }
  const signData = bytes(data.get(2), 'signData');
  const derivation = pathFromCBOR(data.get(isEth ? 5 : isTron ? 4 : 3));
  const origin = data.get(isEth ? 7 : isTron ? 6 : 5);
  if (origin !== undefined) { ensure(typeof origin === 'string' && origin.length <= 256, 'Invalid origin'); transport.origin = origin; }
  if (isEth) {
    const dataType = data.get(3), chainId = data.get(4), address = data.get(6);
    ensure([1, 2, 3, 4].includes(dataType), 'Unsupported Ethereum signing data type'); transport.dataType = dataType;
    if (chainId !== undefined) { ensure(Number.isSafeInteger(chainId) && chainId > 0, 'Invalid Ethereum chain ID'); transport.chainId = chainId; }
    const request = { chain: 'evm', ...derivation, transport, ...(chainId === undefined ? {} : { chainId }) };
    if (address !== undefined) request.address = `0x${bytes(address, 'address', 20).toString('hex')}`;
    if (dataType === 2) {
      const text = signData.toString('utf8'); ensure(Buffer.from(text).equals(signData), 'Invalid typed data UTF-8');
      return { ...request, kind: 'typedData', typedData: parseProtocolJSON(text) };
    }
    if (dataType === 3) return { ...request, kind: 'personal', message: `0x${signData.toString('hex')}` };
    ensure(signData.length > 0 && (dataType === 1 ? signData[0] >= 0xc0 : signData[0] === 1 || signData[0] === 2), 'Transaction data type does not match payload');
    return { ...request, kind: 'transaction', transaction: `0x${signData.toString('hex')}` };
  }
  if (isTron) {
    const dataType = data.get(3); ensure(dataType === 1 || dataType === 2, 'Unsupported TRON signing data type');
    transport.dataType = dataType;
    const request = { chain: 'tron', ...derivation, transport };
    if (data.has(5)) {
      const address = bytes(data.get(5), 'address', 21); ensure(address[0] === 0x41, 'Invalid TRON address prefix');
      request.address = base58check(sha256).encode(address);
    }
    ensure(signData.length > 0, 'Empty TRON signing data');
    return dataType === 1
      ? { ...request, kind: 'transaction', transaction: { raw_data_hex: signData.toString('hex') } }
      : { ...request, kind: 'message', message: signData.toString('hex'), messageStandard: 'TIP191' };
  }
  const signType = data.get(6); ensure(signType === 1 || signType === 2, 'Unsupported Solana signing type'); transport.signType = signType;
  const request = { chain: 'solana', ...derivation, kind: signType === 1 ? 'transaction' : 'message', message: signData.toString('base64'), transport };
  if (data.has(4)) request.address = base58.encode(bytes(data.get(4), 'address', 32));
  return request;
}

export function validateRequestTransport(request) {
  if (request.transport?.payloadEncoding === 'cbor') {
    const original = requestFromUR(new UR(hex(request.transport.payloadBytes), request.transport.type));
    ensure(hashRequest(original) === hashRequest(request), 'Signing request differs from its original QR payload');
  } else if (request.transport?.payloadEncoding === 'psbt') {
    ensure(request.chain === 'bitcoin' && hex(request.transport.payloadBytes).equals(b64(request.psbt)), 'Signing request differs from its original PSBT payload');
  }
}

function inflateBounded(compressed) {
  checkSize(compressed); let size = 0; const chunks = [];
  const stream = new Inflate((chunk) => {
    size += chunk.length;
    ensure(size <= QR_LIMITS.payloadBytes, 'BBQR decompressed payload exceeds supported size');
    chunks.push(Buffer.from(chunk));
  });
  // Restrict each step's maximum expansion, then stop before accepting more input.
  // DEFLATE's maximum expansion per source byte is finite; no large one-shot buffer.
  for (let offset = 0; offset < compressed.length; offset += 128) {
    stream.push(compressed.subarray(offset, offset + 128), offset + 128 >= compressed.length);
  }
  return checkSize(Buffer.concat(chunks, size));
}

function encodeBBQR(data, fragmentLength = 180, encoding = '2') {
  checkSize(data); ensure(encoding === 'H' || encoding === '2', 'Unsupported outgoing BBQR encoding');
  ensure(Number.isInteger(fragmentLength) && fragmentLength >= 40 && fragmentLength <= 800, 'Invalid BBQR fragment length');
  ensure(data.subarray(0, 5).toString('hex') === '70736274ff', 'Invalid PSBT magic');
  const block = encoding === 'H' ? fragmentLength : Math.floor(fragmentLength / 5) * 5;
  const count = Math.ceil(data.length / block); ensure(count <= 1295, 'Too many BBQR fragments');
  const number = n => n.toString(36).toUpperCase().padStart(2, '0'); const frames = [];
  for (let i = 0; i < count; i++) {
    const fragment = data.subarray(i * block, (i + 1) * block);
    const body = encoding === 'H' ? fragment.toString('hex').toUpperCase() : base32nopad.encode(fragment);
    frames.push(`B$${encoding}P${number(count)}${number(i)}${body}`);
  }
  return { type: 'bbqr-psbt', frames };
}

/** File/paste entry point. A binary .psbt file can be passed as base64 text. */
export function decodePayload({ payload }) {
  ensure(typeof payload === 'string' && Buffer.byteLength(payload) <= QR_LIMITS.payloadBytes * 2, 'File payload exceeds supported size');
  let text = payload.trim(); ensure(text.length > 0, 'Empty signing payload');
  // PSBT files are often line-wrapped; whitespace is not part of Base64 or hex.
  if (/^(cHNidP|70736274ff)/i.test(text) && /^[A-Za-z0-9+/=\s]+$/.test(text)) text = text.replace(/\s+/g, '');
  if (text.startsWith('cHNidP') || /^70736274ff/i.test(text)) {
    const isBase64 = text.startsWith('cHNidP'); const data = checkSize(isBase64 ? b64(text) : hex(text));
    ensure(data.subarray(0, 5).toString('hex') === '70736274ff', 'Invalid PSBT magic');
    return { complete: true, progress: 1, request: { chain: 'bitcoin', psbt: data.toString('base64'), transport: { type: isBase64 ? 'psbt-base64' : 'psbt-hex', payloadEncoding: 'psbt', payloadBytes: data.toString('hex') } } };
  }
  return decodeQR({ frames: text.split(/\r?\n/).map(frame => frame.trim()).filter(Boolean) });
}

const SIGNING_UR_TYPES = ['crypto-psbt', 'psbt', 'eth-sign-request', 'sol-sign-request', 'tron-sign-request'];

/** Incremental QR assembly: each frame is validated once as it arrives. Animated
 * codes therefore cost O(frames) in total instead of re-decoding every frame. */
export class QRCollector {
  constructor() { this.frames = new Set(); this.retained = 0; this.kind = undefined; this.result = undefined; }
  add(input) {
    ensure(typeof input === 'string' && input.length > 0 && input.length <= QR_LIMITS.frameChars, 'QR frame size exceeds limits');
    const frame = input.trim();
    ensure(frame.length > 0, 'Empty QR frame');
    if (this.result || this.frames.has(frame)) return this.status();
    ensure(this.frames.size < QR_LIMITS.frames, 'Invalid QR frame count');
    this.retained += frame.length; ensure(this.retained <= QR_LIMITS.retainedChars, 'QR scan memory limit exceeded');
    this.frames.add(frame);
    const kind = frame.startsWith('B$') ? 'bbqr' : /^ur:/i.test(frame) ? 'ur' : 'static';
    ensure(!this.kind || this.kind === kind, 'Multiple unrelated QR payloads');
    this.kind = kind;
    if (kind === 'bbqr') this.#addBBQR(frame);
    else if (kind === 'ur') this.#addUR(frame);
    else this.#addStatic(frame);
    return this.status();
  }
  status() {
    if (this.result) return { complete: true, progress: 1, request: this.result };
    if (this.kind === 'bbqr') return { complete: false, progress: this.bbqr ? this.bbqr.fragments.size / this.bbqr.count : 0 };
    if (this.kind === 'ur' && this.decoder) return { complete: false, progress: Math.min(0.99, this.decoder.estimatedPercentComplete()) };
    return { complete: false, progress: 0 };
  }
  #addStatic(frame) {
    ensure(this.frames.size === 1, 'Multiple unrelated QR payloads');
    ensure(frame.startsWith('cHNidP') || /^70736274ff/i.test(frame), 'Unsupported signing QR format');
    const data = frame.startsWith('cHNidP') ? b64(frame) : hex(frame); checkSize(data);
    ensure(data.subarray(0, 5).toString('hex') === '70736274ff', 'Invalid PSBT magic');
    this.result = { chain: 'bitcoin', psbt: data.toString('base64'), transport: { type: frame.startsWith('cHNidP') ? 'psbt-base64' : 'psbt-hex', payloadEncoding: 'psbt', payloadBytes: data.toString('hex') } };
  }
  #addUR(frame) {
    const [type, parts] = URDecoder.parse(frame);
    ensure(!this.urType || this.urType === type, 'Mixed UR types');
    ensure(SIGNING_UR_TYPES.includes(type), 'Unsupported signing UR type');
    this.urType = type;
    ensure(parts.length === 1 || parts.length === 2, 'Invalid UR frame');
    if (parts.length === 2) {
      ensure(!this.single, 'Multiple static QR payloads');
      ensure(/^\d+-\d+$/.test(parts[0]), 'Invalid fountain sequence');
      const [seq, count] = parts[0].split('-').map(Number);
      ensure(Number.isInteger(seq) && seq >= 1 && seq <= 0xffffffff && Number.isInteger(count) && count >= 1 && count <= QR_LIMITS.frames, 'Fountain sequence exceeds limits');
      const decodedPart = readCBOR(URDecoder.decodeBody(type, parts[1]).cbor);
      ensure(Array.isArray(decodedPart) && decodedPart.length === 5, 'Invalid fountain fragment');
      const [partSeq, partCount, length, checksum, fragment] = decodedPart;
      ensure(partSeq === seq && partCount === count && Number.isInteger(length) && length > 0 && length <= QR_LIMITS.payloadBytes && Number.isInteger(checksum) && checksum >= 0 && checksum <= 0xffffffff, 'Invalid fountain fragment metadata');
      bytes(fragment, 'fragment'); ensure(fragment.length >= 1 && count === Math.ceil(length / fragment.length), 'Inconsistent fountain fragment size');
      const key = `${type}:${count}:${length}:${checksum}:${fragment.length}`;
      ensure(!this.session || this.session === key, 'Mixed UR fountain sessions'); this.session = key;
    } else {
      ensure(this.frames.size === 1, 'Multiple static QR payloads');
      this.single = true;
    }
    this.decoder ??= new URDecoder();
    this.decoder.receivePart(frame);
    ensure(!this.decoder.isError(), 'UR checksum failure');
    if (this.decoder.isComplete()) this.result = requestFromUR(this.decoder.resultUR());
  }
  #addBBQR(frame) {
    const match = /^B\$([H2Z])P([0-9A-Z]{2})([0-9A-Z]{2})([0-9A-Z]+)$/.exec(frame);
    ensure(match, 'Unsupported BBQR header, file type, or alphabet');
    const [, enc, total, index, body] = match; const n = parseInt(total, 36), i = parseInt(index, 36);
    ensure(n > 0 && n <= 1295 && i < n, 'Invalid BBQR fragment index');
    const state = this.bbqr ??= { header: frame.slice(0, 6), encoding: enc, count: n, fragments: new Map() };
    ensure(state.header === frame.slice(0, 6), 'Mixed BBQR encodings or counts');
    ensure(enc === 'H' ? /^[0-9A-F]+$/.test(body) && body.length % 2 === 0 : /^[A-Z2-7]+$/.test(body), 'Invalid BBQR encoded data');
    if (i !== n - 1) {
      ensure(enc === 'H' || body.length % 8 === 0, 'Nonfinal BBQR base32 fragment must end on a 5-byte boundary');
      ensure(state.normalLength === undefined || state.normalLength === body.length, 'Unequal BBQR fragment lengths'); state.normalLength = body.length;
    }
    ensure(!state.fragments.has(i) || state.fragments.get(i) === body, 'Conflicting BBQR fragment'); state.fragments.set(i, body);
    if (state.normalLength !== undefined && state.fragments.has(n - 1)) ensure(state.fragments.get(n - 1).length <= state.normalLength, 'Oversized final BBQR fragment');
    if (state.fragments.size !== n) return;
    const encoded = Array.from({ length: n }, (_, k) => state.fragments.get(k)).join('');
    let data = checkSize(enc === 'H' ? hex(encoded) : Buffer.from(base32nopad.decode(encoded)));
    if (enc === 'Z') data = inflateBounded(data);
    ensure(data.subarray(0, 5).toString('hex') === '70736274ff', 'BBQR PSBT magic mismatch');
    this.result = { chain: 'bitcoin', psbt: data.toString('base64'), transport: { type: 'bbqr-psbt', encoding: enc, payloadEncoding: 'psbt', payloadBytes: data.toString('hex') } };
  }
}

export function decodeQR({ frames }) {
  ensure(Array.isArray(frames) && frames.length > 0 && frames.length <= QR_LIMITS.frames, 'Invalid QR frame count');
  const collector = new QRCollector();
  let status;
  for (const frame of frames) status = collector.add(frame);
  return status;
}

function qrFromUR(ur, fragmentLength = 180) {
  checkSize(ur.cbor); ensure(Number.isInteger(fragmentLength) && fragmentLength >= 40 && fragmentLength <= 800, 'Invalid QR fragment length');
  const encoder = new UREncoder(ur, fragmentLength);
  ensure(encoder.fragmentsLength <= QR_LIMITS.frames, 'Too many QR fragments');
  const frames = encoder.encodeWhole().map(frame => frame.toUpperCase());
  return { type: ur.type, frames };
}

export function encodeQR({ type, payload, encoding = 'hex', requestId, fragmentLength, bbqrEncoding = '2' }) {
  if (type === 'bbqr-psbt') return encodeBBQR(encoding === 'base64' ? b64(payload) : hex(payload), fragmentLength, bbqrEncoding);
  if (type === 'crypto-psbt' || type === 'psbt') {
    const data = encoding === 'base64' ? b64(payload) : hex(payload); checkSize(data);
    ensure(data.subarray(0, 5).toString('hex') === '70736274ff', 'Invalid PSBT magic');
    return qrFromUR(new UR(writeCBOR(data), type), fragmentLength);
  }
  ensure(['eth-signature', 'sol-signature', 'tron-signature'].includes(type), 'Unsupported QR output type');
  const signature = encoding === 'base64' ? b64(payload) : hex(payload);
  ensure(type === 'sol-signature' ? signature.length === 64 : type === 'tron-signature' ? signature.length === 65 : signature.length >= 65 && signature.length <= 73, 'Invalid signature size');
  const map = new Map();
  if (requestId !== undefined) {
    ensure(typeof requestId === 'string', 'Expected hexadecimal requestId');
    // The public API also accepts canonical UUID text. Decoded opaque IDs are
    // hex and must otherwise pass through unchanged, never as UTF-8 text.
    const canonicalUUID = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(requestId);
    const encodedId = canonicalUUID ? requestId.replace(/-/g, '') : requestId;
    map.set(1, { tag: 37, value: requestIdBytes(hex(encodedId), type === 'eth-signature') });
  }
  map.set(2, signature);
  return qrFromUR(new UR(writeCBOR(map), type), fragmentLength);
}

function responseQR({ request, result, fragmentLength }) {
  ensure(request && result, 'Missing signing response'); const transport = request.transport || { type: 'bittool-signer-json' };
  if (transport.type === 'bbqr-psbt') return encodeBBQR(b64(result.psbt), fragmentLength, transport.encoding === 'H' ? 'H' : '2');
  // Answer in the request's own UR type (the newer registry name is `psbt`).
  if (transport.type === 'crypto-psbt' || transport.type === 'psbt') return encodeQR({ type: transport.type, payload: result.psbt, encoding: 'base64', fragmentLength });
  if (transport.type === 'psbt-base64' || transport.type === 'psbt-hex') {
    const data = b64(result.psbt); const text = data.toString(transport.type === 'psbt-hex' ? 'hex' : 'base64');
    // Signed PSBTs often outgrow a static QR; use the standard animated transport.
    return text.length <= 1800 ? { type: transport.type, frames: [text] } : encodeQR({ type: 'crypto-psbt', payload: result.psbt, encoding: 'base64', fragmentLength });
  }
  if (['eth-sign-request', 'sol-sign-request', 'tron-sign-request'].includes(transport.type)) {
    return encodeQR({ type: transport.type.replace('-sign-request', '-signature'), payload: result.qrSignature || result.signature, requestId: transport.requestId, fragmentLength });
  }

  fail('Unsupported response profile');
}

/** The signed response QR plus a developer view of exactly what it carries. The
 * view is decoded again from the frames just produced (never from the values that
 * produced them), so frames that do not round-trip fail here, before display. */
export function encodeResponse(input) {
  const qr = responseQR(input);
  return { ...qr, ...describeQR(qr) };
}

// Developer payload view: what a QR code actually encodes, read back from the
// frames that were produced. Public keys and signatures only; nothing secret.

/** CBOR tags as named in the BCR-2020-006 registry of UR types and, for 400-410,
 * the BCR-2020-010 output-descriptor CDDL. BitTool Signer writes crypto-account output
 * descriptors in the Keystone/Sparrow form, without BCR-2020-015's #6.308 wrapper;
 * the view shows exactly what is encoded. */
export const CBOR_TAG_NAMES = Object.freeze({
  37: 'uuid', 303: 'crypto-hdkey', 304: 'crypto-keypath', 305: 'crypto-coin-info', 306: 'crypto-eckey',
  307: 'crypto-address', 308: 'crypto-output', 310: 'crypto-psbt', 311: 'crypto-account', 1103: 'crypto-multi-accounts',
  400: 'script-hash', 401: 'witness-script-hash', 402: 'public-key', 403: 'public-key-hash',
  404: 'witness-public-key-hash', 405: 'combo', 406: 'multisig', 407: 'sorted-multisig', 408: 'raw-script',
  409: 'taproot', 410: 'cosigner',
});
/** Integer map keys 1…n → field names, per registry type (index = key − 1).
 * crypto-hdkey, crypto-keypath, crypto-coin-info: BCR-2020-007 CDDL. crypto-account:
 * BCR-2020-015. crypto-multi-accounts keys 1-3 follow Keystone's published CDDL; 4-5
 * are Keystone bc-ur-registry's deviceId/version, kebab-cased. eth-, sol- and
 * tron-signature: Keystone UR registry. */
export const UR_FIELD_NAMES = Object.freeze({
  'crypto-hdkey': ['is-master', 'is-private', 'key-data', 'chain-code', 'use-info', 'origin', 'children', 'parent-fingerprint', 'name', 'note'],
  'crypto-keypath': ['components', 'source-fingerprint', 'depth'],
  'crypto-coin-info': ['type', 'network'],
  'crypto-account': ['master-fingerprint', 'output-descriptors'],
  'crypto-multi-accounts': ['master-fingerprint', 'keys', 'device', 'device-id', 'version'],
  'eth-signature': ['request-id', 'signature', 'origin'],
  'sol-signature': ['request-id', 'signature'],
  'tron-signature': ['request-id', 'signature'],
});

/** One UR's CBOR as named JSON: map keys get their registry field names (an
 * unknown integer key stays as its number), a tagged item becomes a one-key object
 * named after its tag (`tag-<n>` if unregistered), byte strings become lowercase
 * hex and everything else is kept as decoded by the strict reader. */
export function describeUR(type, cbor) {
  const describe = (value, schema) => {
    if (Buffer.isBuffer(value)) return value.toString('hex');
    if (Array.isArray(value)) return value.map(item => describe(item));
    if (value instanceof Map) {
      const names = UR_FIELD_NAMES[schema] || [], out = Object.create(null);
      for (const [key, item] of value) {
        const name = typeof key === 'number' ? names[key - 1] ?? String(key) : key;
        ensure(!Object.hasOwn(out, name), 'Ambiguous UR field name'); out[name] = describe(item);
      }
      return out;
    }
    if (value && typeof value === 'object') return { [CBOR_TAG_NAMES[value.tag] ?? `tag-${value.tag}`]: describe(value.value, CBOR_TAG_NAMES[value.tag]) };
    return value;
  };
  return describe(readCBOR(cbor), type);
}

/** Every transport a signed PSBT can leave in (see responseQR). */
const PSBT_QR_TYPES = new Set(['crypto-psbt', 'psbt', 'bbqr-psbt', 'psbt-base64', 'psbt-hex']);

/** The payload view of produced frames: 'json' for a registry map, 'hex' for a UR
 * that holds one byte string, 'text' for a plain-text QR code (an address), whose
 * text is its own payload. UR frames are decoded again (fountain parts included),
 * so the view shows the bytes actually encoded. */
export function describeQR({ type, frames }) {
  ensure(Array.isArray(frames) && frames.length > 0, 'No QR frames to describe');
  if (PSBT_QR_TYPES.has(type)) return describePSBTQR({ type, frames });
  if (!/^ur:/i.test(frames[0])) {
    ensure(frames.length === 1 && !frames[0].startsWith('B$'), 'A plain-text QR code has one frame');
    return { payloadFormat: 'text', payload: frames[0], payloadBytes: Buffer.byteLength(frames[0], 'utf8') };
  }
  const decoder = new URDecoder(); for (const frame of frames) decoder.receivePart(frame);
  ensure(decoder.isComplete() && decoder.isSuccess(), 'The exported QR code does not decode');
  const ur = decoder.resultUR(); ensure(!type || ur.type === type, 'The exported QR code has an unexpected type');
  return { payloadFormat: Buffer.isBuffer(readCBOR(ur.cbor)) ? 'hex' : 'json', payload: describeUR(ur.type, ur.cbor), payloadBytes: ur.cbor.length };
}

/** A signed PSBT QR decoded back to its bytes: UR parts in one URDecoder pass (these
 * are the frames just produced, so the request collector's per-part checks would only
 * decode everything twice), BBQr and plain text through that collector. `psbt_base64`
 * is the PSBT itself; `decoded` is derived from it for reference (it sorts first, so
 * it stays visible when a large PSBT is cut for display) and is omitted when the
 * bytes are only PSBT-framed. */
function describePSBTQR({ type, frames }) {
  let data, payloadBytes;
  if (type === 'crypto-psbt' || type === 'psbt') {
    ensure(frames.every(frame => /^ur:/i.test(frame)), 'The PSBT QR code does not decode to its own type');
    const decoder = new URDecoder(); for (const frame of frames) decoder.receivePart(frame);
    ensure(decoder.isComplete() && decoder.isSuccess(), 'The PSBT QR code does not decode to its own type');
    const ur = decoder.resultUR(); ensure(ur.type === type, 'The PSBT QR code does not decode to its own type');
    data = readCBOR(ur.cbor); payloadBytes = ur.cbor.length;
    ensure(Buffer.isBuffer(data), 'The PSBT QR code does not decode to its own type');
  } else {
    const status = decodeQR({ frames });
    ensure(status.complete && status.request?.chain === 'bitcoin' && status.request.transport?.type === type, 'The PSBT QR code does not decode to its own type');
    data = hex(status.request.transport.payloadBytes); payloadBytes = data.length;
  }
  ensure(data.subarray(0, 5).toString('hex') === '70736274ff', 'Invalid PSBT magic');
  const payload = { psbt_base64: data.toString('base64') };
  try { payload.decoded = psbtSummary(data); } catch { /* not a parseable transaction: bytes only */ }
  return { payloadFormat: 'json', payload, payloadBytes };
}

function keyPath(path, fingerprint, wildcard = false) {
  ensure(typeof path === 'string' && /^(?:[mM]\/)?[0-9*'\/]+$/.test(path), 'Invalid account derivation path');
  const parts = path.replace(/^[mM]\//, '').split('/'); ensure(parts.length > 0 && parts.length <= 10, 'Invalid account depth');
  const components = parts.flatMap(part => {
    if (part === '*' && wildcard) return [[], false];
    ensure(/^\d+'?$/.test(part), 'Invalid account path component'); const index = Number(part.replace("'", ''));
    ensure(index >= 0 && index < 0x80000000 && Number.isInteger(index), 'Invalid account path index');
    return [index, part.endsWith("'")];
  });
  const map = new Map([[1, components]]);
  if (fingerprint) map.set(2, fingerprint.readUInt32BE(0));
  if (!wildcard) map.set(3, parts.length);
  return { tag: 304, value: map };
}

function publicNode(account, chain, fingerprint, leaf = false) {
  let publicKey = hex(account.publicKey), chainCode, parentFingerprint, path = account.path;
  if (account.xpub && !leaf) {
    ensure(/^(xpub|tpub)/.test(account.xpub), 'Only public extended keys may be exported');
    const versions = account.xpub.startsWith('tpub') ? { private: 0x04358394, public: 0x043587cf } : undefined;
    const node = HDKey.fromExtendedKey(account.xpub, versions);
    ensure(!node.privateKey, 'Private key export is forbidden'); publicKey = Buffer.from(node.publicKey); chainCode = Buffer.from(node.chainCode);
    parentFingerprint = Buffer.alloc(4); parentFingerprint.writeUInt32BE(node.parentFingerprint);
    path = account.accountPath; ensure(typeof path === 'string', 'Account xpub requires accountPath');
    ensure(path.replace(/^m\//, '').split('/').length === node.depth, 'Account xpub depth does not match path');
  }
  ensure(chain === 'solana' ? publicKey.length === 32 : publicKey.length === 33 && [2, 3].includes(publicKey[0]), 'Invalid public key encoding');
  // Registry crypto-hdkey tag 303; the top-level UR omits its own tag.
  const coin = { bitcoin: 0, evm: 60, tron: 195, solana: 501 }[chain];
  const useInfo = new Map(); if (coin) useInfo.set(1, coin);
  if (account.network === 'testnet') useInfo.set(2, 1);
  const map = new Map([[2, false], [3, publicKey], [5, { tag: 305, value: useInfo }], [6, keyPath(path, fingerprint)]]);
  if (chainCode) map.set(4, chainCode);
  if (parentFingerprint) map.set(8, parentFingerprint.readUInt32BE(0));
  if (chainCode && chain === 'evm') map.set(7, keyPath('0/*', undefined, true));
  map.set(9, 'BitTool Signer'); map.set(10, 'BitTool Signer public account');
  return map;
}

/** Public exports are selected by key/script semantics, never a wallet brand. */
export function createPublicPairing({ publicIndex, chain, profile, outputMode, index = 0, fragmentLength }) {
  const cache = validatePublicIndex(publicIndex), fingerprint = hex(cache.masterFingerprint, 4);
  ensure(['bitcoin', 'evm', 'tron', 'solana'].includes(chain), 'Unsupported pairing chain');
  // TRON exports any non-hardened receive index (m/44'/195'/0'/0/i); other chains export index 0.
  ensure(Number.isInteger(index) && index >= 0 && (chain === 'tron' ? index < 0x80000000 : index === 0), 'Invalid pairing address index');
  let account, leaf, path, address, mode = outputMode;
  if (chain === 'bitcoin') {
    profile = profile || 'native'; ensure(Object.hasOwn(BITCOIN_PROFILES, profile), 'Unsupported Bitcoin profile');
    account = cache.bitcoinPublicNodes.find(node => node.scriptProfile === profile);
    const cosigner = profile.startsWith('multisig-'); mode = mode || 'accountXpub';
    // crypto-account carries account-level HD keys only (BCR-2020-015); a lone leaf key is not exported.
    ensure(cosigner ? mode === 'accountXpub' : ['accountXpub', 'address'].includes(mode), 'Unsupported Bitcoin export mode');
    leaf = derivePublicKeyAt(cache, chain, account.originPath + '/0/0');
    path = mode === 'accountXpub' ? account.originPath : leaf.path; address = leaf.address;
    if (mode === 'address') return { type: 'address', frames: [address], text: address, address, path, profile, outputMode: mode, ...describeQR({ frames: [address] }) };
    const key = { tag: 303, value: publicNode(account, chain, fingerprint) };
    const wrap = (tag, value) => ({ tag, value });
    const output = profile === 'native' ? wrap(404, key) : profile === 'taproot' ? wrap(409, key)
      : profile === 'nested' ? wrap(400, wrap(404, key)) : profile === 'legacy' ? wrap(403, key)
      : profile === 'multisig-native' ? wrap(401, key) : wrap(400, wrap(401, key));
    const qr = qrFromUR(new UR(writeCBOR(new Map([[1, fingerprint.readUInt32BE(0)], [2, [output]]])), 'crypto-account'), fragmentLength);
    return { ...qr, text: qr.frames.join('\n'), path, address, profile, outputMode: mode, ...describeQR(qr),
      note: cosigner ? 'Cosigner account key only. No threshold or complete wallet policy is included.' : 'Public account key. Receive and change addresses can be derived.' };
  }
  mode = mode || (chain === 'tron' ? 'address' : 'wallet');
  ensure(chain === 'tron' ? mode === 'address' : ['wallet', 'address'].includes(mode), 'Unsupported export mode');
  if (chain === 'solana') {
    profile = profile || 'standard'; ensure(Object.hasOwn(SOLANA_PROFILES, profile), 'Unsupported Solana profile');
    leaf = derivePublicKeyAt(cache, chain, SOLANA_PROFILES[profile]); account = leaf;
  } else {
    account = chain === 'evm' ? cache.evmAccountNode : cache.tronAccountNode;
    leaf = derivePublicKeyAt(cache, chain, account.originPath + '/0/' + index);
  }
  address = leaf.address; path = mode === 'wallet' && chain === 'evm' ? account.originPath : leaf.path;
  if (mode === 'address') return { type: 'address', frames: [address], text: address, address, path, profile: profile || 'standard', outputMode: mode, ...describeQR({ frames: [address] }) };
  const qr = chain === 'evm' ? qrFromUR(new UR(writeCBOR(publicNode(account, chain, fingerprint)), 'crypto-hdkey'), fragmentLength)
    : qrFromUR(new UR(writeCBOR(new Map([[1, fingerprint.readUInt32BE(0)], [2, [{ tag: 303, value: publicNode(leaf, chain, fingerprint, true) }]], [3, 'BitTool Signer'], [5, '1.0.0']])), 'crypto-multi-accounts'), fragmentLength);
  return { ...qr, text: qr.frames.join('\n'), address, path, profile: profile || 'standard', outputMode: mode, ...describeQR(qr) };
}
export const createPairing = createPublicPairing;

// ---------------------------------------------------------------------------
// BitTool Signer Wallet-Level QR Pairing v1 (docs/Wallet-Pairing-v1.md).
// One QR for all four chain families: `ur:bytes`, whose byte string is the
// canonical CBOR encoding of the logical object. Chain-specific exports above
// stay unchanged for third-party wallets.

export const WALLET_PAIRING_PROTOCOL = 'bittool-signer-wallet';
export const WALLET_PAIRING_VERSION = 1;

/** RFC 8949 §4.2.1 core deterministic encoding for the pairing object: definite
 * lengths, shortest-form integers, and map keys sorted by the bytewise order of
 * their encodings. Plain objects become text-keyed maps; `undefined` is omitted. */
export function canonicalCBOR(value) {
  const prepare = v => {
    if (Array.isArray(v)) return v.map(prepare);
    if (v && typeof v === 'object' && !Buffer.isBuffer(v)) {
      // Plain objects are always text-keyed maps here, even one with a "tag" key.
      ensure(!(v instanceof Map), 'Unsupported pairing value');
      const entries = Object.entries(v).filter(([, x]) => x !== undefined).map(([k, x]) => [k, prepare(x)]);
      entries.sort(([a], [b]) => Buffer.compare(writeCBOR(a), writeCBOR(b)));
      return new Map(entries);
    }
    ensure(typeof v === 'string' || typeof v === 'boolean' || (Number.isSafeInteger(v) && v >= 0), 'Unsupported pairing value');
    return v;
  };
  return writeCBOR(prepare(value));
}

/** The single-signature Bitcoin script types the pairing exports, in the order a
 * wallet should offer them: Native SegWit, Taproot, Nested SegWit and Legacy.
 * The two `m/48'` multisig profiles are deliberately left out — a multisig
 * wallet needs every cosigner key and a threshold, which the cosigner export
 * (Connect › Coin Level) carries instead. */
const PAIRING_BTC_SCRIPTS = Object.freeze([
  ['native', 'p2wpkh'], ['taproot', 'p2tr'], ['nested', 'p2sh-p2wpkh'], ['legacy', 'p2pkh'],
]);

/** The logical wallet-level pairing object for one wallet's validated public index.
 * BitTool Signer exports one form, in the draft's `full` layout: an account-level
 * xpub for each of the four single-sig Bitcoin script types, for EVM and for TRON,
 * and the three Solana addresses (Ed25519 derivation is hardened, so Solana has no
 * xpub and each profile has to be sent as its own address). */
export function walletPairingObject(cache) {
  const btcNodes = PAIRING_BTC_SCRIPTS.map(([profile, script]) => {
    const node = cache.bitcoinPublicNodes.find(item => item.scriptProfile === profile);
    ensure(node, 'Missing Bitcoin account for ' + profile);
    return { node, script };
  });
  for (const [chain, node] of [...btcNodes.map(({ node }) => ['bitcoin', node]),
                               ['evm', cache.evmAccountNode], ['tron', cache.tronAccountNode]])
    derivePublicKeyAt(cache, chain, node.originPath + '/0/0'); // verifies each node against its xpub
  // One entry per Solana profile, because the three paths give three different
  // addresses and a watch wallet cannot derive one from another.
  const sol = Object.entries(SOLANA_PROFILES).map(([profile, path], index) =>
    ({ index, profile, path, address: derivePublicKeyAt(cache, 'solana', path).address }));
  const accounts = [
    ...btcNodes.map(({ node, script }) =>
      ({ chain: 'btc', accountPath: node.originPath, script, xpub: node.xpub, derive: { receive: '0/*', change: '1/*' } })),
    { chain: 'evm', accountPath: cache.evmAccountNode.originPath, xpub: cache.evmAccountNode.xpub, derive: '0/*' },
    { chain: 'tron', accountPath: cache.tronAccountNode.originPath, xpub: cache.tronAccountNode.xpub, derive: '0/*' },
    { chain: 'sol', profile: 'bip44-solana', accounts: sol },
  ];
  // masterFingerprint is an additive v1 field (parsers ignore unknown fields): it lets a
  // watch wallet put BitTool Signer's fingerprint into PSBT and sign-request derivation data.
  return { protocol: WALLET_PAIRING_PROTOCOL, version: WALLET_PAIRING_VERSION, mode: 'full', network: 'mainnet',
    masterFingerprint: cache.masterFingerprint.toLowerCase(), accounts };
}

/** The fragment size for the pairing's animated QR. Four Bitcoin xpubs, EVM,
 * TRON and three Solana addresses no longer fit one comfortably scanned code,
 * so the payload is split into a multi-part `ur:bytes` sequence the receiving
 * wallet reassembles. 400 bytes keeps each frame well inside an easy QR
 * version, and the ceiling guarantees at least two frames for any payload. */
const WALLET_PAIRING_FRAGMENT = 400;

export function createWalletPairing({ publicIndex, mode = 'full' }) {
  ensure(mode === 'full', 'Unsupported wallet pairing mode');
  const cache = validatePublicIndex(publicIndex), object = walletPairingObject(cache);
  const payload = canonicalCBOR(object);
  // Animated, so the old one-QR ceiling no longer applies; this one only keeps
  // the frame count and the scan time sane.
  ensure(payload.length <= 4096, 'Wallet pairing payload is too large');
  const fragment = Math.min(WALLET_PAIRING_FRAGMENT, Math.ceil(payload.length / 2));
  const qr = qrFromUR(new UR(writeCBOR(payload), 'bytes'), fragment);
  ensure(qr.frames.length >= 2, 'Wallet pairing QR must be animated');
  // Every exported account gets a first address to check: four Bitcoin script
  // types, EVM, TRON and the three Solana profiles. `profile` names which one,
  // so the interface can label rows that share a chain.
  const first = (chain, profile, path) => ({ chain, profile, path,
    address: derivePublicKeyAt(cache, chain === 'btc' ? 'bitcoin' : chain === 'sol' ? 'solana' : chain, path).address });
  const verify = [
    ...PAIRING_BTC_SCRIPTS.map(([profile]) =>
      first('btc', profile, cache.bitcoinPublicNodes.find(node => node.scriptProfile === profile).originPath + '/0/0')),
    first('evm', 'standard', "m/44'/60'/0'/0/0"), first('tron', 'standard', "m/44'/195'/0'/0/0"),
    ...Object.entries(SOLANA_PROFILES).map(([profile, path]) => first('sol', profile, path)),
  ];
  return { type: 'bytes', frames: qr.frames, text: qr.frames.join('\n'), mode: 'full', payload: object, payloadBytes: payload.length,
    verify };
}

/** A CBOR tag read by the canonical parser (kept distinct from maps with a "tag" key). */
class CBORTag { constructor(tag, value) { this.tag = tag; this.value = value; } }

/** Parses one CBOR item and requires RFC 8949 §4.2.1 deterministic encoding:
 * shortest-form heads, definite lengths and map keys in strictly increasing
 * bytewise order of their encodings (which also rejects duplicate keys). Every
 * major type is read, so unknown fields of any type can be ignored; floating
 * point values are read but their shortest-form rule is not checked. */
function parseCanonicalCBOR(bytes) {
  const buffer = Buffer.from(bytes), notCanonical = 'Wallet pairing payload is not canonical CBOR';
  let p = 0, nodes = 0;
  const need = n => ensure(p + n <= buffer.length, 'Truncated wallet pairing CBOR');
  const head = () => {
    need(1); const byte = buffer[p++], major = byte >> 5, info = byte & 31; let value;
    if (info < 24) value = info;
    else if (info === 24) { need(1); value = buffer[p]; p += 1; ensure(major === 7 ? value >= 32 : value >= 24, notCanonical); }
    else if (info === 25) { need(2); value = buffer.readUInt16BE(p); p += 2; ensure(major === 7 || value >= 256, notCanonical); }
    else if (info === 26) { need(4); value = buffer.readUInt32BE(p); p += 4; ensure(major === 7 || value >= 65536, notCanonical); }
    else if (info === 27) { need(8); value = buffer.readBigUInt64BE(p); p += 8; ensure(major === 7 || value >= 0x100000000n, notCanonical); if (major !== 7 && value <= BigInt(Number.MAX_SAFE_INTEGER)) value = Number(value); }
    else fail(notCanonical); // reserved values and indefinite lengths
    return { major, info, value };
  };
  const length = value => { ensure(typeof value === 'number' && value <= buffer.length, 'Invalid wallet pairing CBOR length'); return value; };
  const half = bits => { const e = (bits >> 10) & 31, m = bits & 1023, sign = bits & 0x8000 ? -1 : 1;
    return e === 0 ? sign * m * 2 ** -24 : e === 31 ? (m ? NaN : sign * Infinity) : sign * (1 + m / 1024) * 2 ** (e - 15); };
  const item = depth => {
    ensure(depth <= 24 && ++nodes <= 20000, 'Wallet pairing CBOR is too complex');
    const start = p, { major, info, value } = head();
    switch (major) {
      case 0: return value;
      case 1: return typeof value === 'bigint' ? -1n - value : -1 - value;
      case 2: { const n = length(value); need(n); const out = Buffer.from(buffer.subarray(p, p + n)); p += n; return out; }
      case 3: { const n = length(value); need(n); const raw = buffer.subarray(p, p + n); p += n; const text = raw.toString('utf8');
        ensure(Buffer.from(text, 'utf8').equals(raw), 'Invalid UTF-8 in wallet pairing'); return text; }
      case 4: return Array.from({ length: length(value) }, () => item(depth + 1));
      case 5: {
        const map = new Map(); let previous;
        for (let i = 0, n = length(value); i < n; i++) {
          const keyStart = p, key = item(depth + 1), encodedKey = buffer.subarray(keyStart, p);
          ensure(!previous || Buffer.compare(previous, encodedKey) < 0, notCanonical); previous = encodedKey;
          map.set(key, item(depth + 1));
        }
        return map;
      }
      case 6: return new CBORTag(value, item(depth + 1));
      default:
        if (info === 20) return false; if (info === 21) return true; if (info === 22) return null; if (info === 23) return undefined;
        if (info === 25) return half(value);
        if (info === 26) { const b = Buffer.alloc(4); b.writeUInt32BE(value); return b.readFloatBE(0); }
        if (info === 27) { const b = Buffer.alloc(8); b.writeBigUInt64BE(value); return b.readDoubleBE(0); }
        void start; return new CBORTag('simple', value);
    }
  };
  const value = item(0);
  ensure(p === buffer.length, 'Trailing bytes after wallet pairing CBOR');
  return value;
}

/** Test/developer decoder: exact v1 checks, unknown fields (of any type) ignored,
 * other versions refused, non-canonical encodings refused. */
export function decodeWalletPairing({ frames }) {
  const decoder = new URDecoder(); frames.forEach(frame => decoder.receivePart(frame));
  ensure(decoder.isComplete() && decoder.isSuccess(), 'Incomplete wallet pairing QR');
  const ur = decoder.resultUR(); ensure(ur.type === 'bytes', 'Not a ur:bytes wallet pairing');
  const outer = parseCanonicalCBOR(ur.cbor); ensure(Buffer.isBuffer(outer), 'ur:bytes must hold a byte string');
  // Text-keyed maps become objects; other keys and unknown values are kept only where unknown fields may be.
  const toObject = v => v instanceof Map
    ? Object.fromEntries([...v].filter(([k]) => typeof k === 'string').map(([k, x]) => [k, toObject(x)]))
    : Array.isArray(v) ? v.map(toObject) : v;
  const object = toObject(parseCanonicalCBOR(outer));
  ensure(object && typeof object === 'object' && !Array.isArray(object) && !Buffer.isBuffer(object), 'Wallet pairing is not a map');
  ensure(object.protocol === WALLET_PAIRING_PROTOCOL, 'Not a BitTool Signer wallet pairing');
  ensure(object.version === WALLET_PAIRING_VERSION, 'Unsupported wallet pairing version');
  ensure(object.mode === 'simple' || object.mode === 'full', 'Unsupported wallet pairing mode');
  ensure(Array.isArray(object.accounts), 'Wallet pairing has no accounts');
  return object;
}
