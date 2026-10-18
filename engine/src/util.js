import { hex, base64 } from '@scure/base';
import { sha256 } from '@noble/hashes/sha2.js';
export class EngineError extends Error { constructor(code, message) { super(message); this.code = code; } }
export function fail(code, message) { throw new EngineError(code, message); }
export function check(ok, code, message) { if (!ok) fail(code, message); }
export const bytesToHex = (b) => hex.encode(b);
export function hexToBytes(s, max = 262144) {
  check(typeof s === 'string', 'ENCODING', 'Expected hexadecimal text.');
  const v = s.startsWith('0x') ? s.slice(2) : s;
  check(v.length <= max * 2 && v.length % 2 === 0 && /^[0-9a-f]*$/i.test(v), 'ENCODING', 'Invalid or oversized hexadecimal data.');
  return hex.decode(v);
}
export function fromBase64(s, max = 262144) {
  check(typeof s === 'string' && s.length <= Math.ceil(max / 3) * 4 && /^[A-Za-z0-9+/]*={0,2}$/.test(s), 'ENCODING', 'Invalid or oversized base64 data.');
  try { const bytes = base64.decode(s); check(bytes.length <= max, 'LIMIT', 'Payload is too large.'); return bytes; } catch { fail('ENCODING', 'Invalid base64 data.'); }
}
export const toBase64 = (b) => base64.encode(b);
export const utf8 = (s) => new TextEncoder().encode(s);
export function text(b) { try { return new TextDecoder('utf-8', { fatal: true }).decode(b); } catch { fail('ENCODING', 'Invalid UTF-8 text.'); } }
export function concat(...arrays) { const out = new Uint8Array(arrays.reduce((n, a) => n + a.length, 0)); let pos = 0; for (const a of arrays) { out.set(a, pos); pos += a.length; } return out; }
export function equal(a,b) { if (a.length !== b.length) return false; let diff = 0; for (let i=0;i<a.length;i++) diff |= a[i]^b[i]; return diff === 0; }
export function stable(value, depth = 0) {
  check(depth < 32, 'LIMIT', 'Request nesting is too deep.');
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return JSON.stringify(value);
  if (typeof value === 'number') { check(Number.isSafeInteger(value), 'PRECISION', 'Use decimal strings for amounts larger than safe integers.'); return JSON.stringify(value); }
  if (Array.isArray(value)) return '[' + value.map(x => stable(x, depth+1)).join(',') + ']';
  check(value && typeof value === 'object' && (Object.getPrototypeOf(value) === Object.prototype || Object.getPrototypeOf(value) === null), 'REQUEST', 'Expected a plain JSON object.');
  return '{' + Object.keys(value).sort().map(k => JSON.stringify(k)+':'+stable(value[k],depth+1)).join(',') + '}';
}
export const requestHash = (request) => bytesToHex(sha256(utf8(stable(request))));
export const field = (label, value) => ({label, value: String(value)});
export function reviewResult(request, title, summary, fields, warnings = [], details = {}) {
  return { chain:request.chain, title, summary, fields, warnings, requestHash:requestHash(request), canSign:true,
    decodeStatus:'fullyDecoded',riskLevel:warnings.length?'warning':'normal',...details };
}
export function uint(value, max = (1n << 256n)-1n) {
  check((typeof value === 'number' && Number.isSafeInteger(value)) || (typeof value === 'string' && /^(?:0x[0-9a-f]+|[0-9]+)$/i.test(value)) || typeof value === 'bigint', 'INTEGER', 'Expected an unsigned integer.');
  const n = BigInt(value); check(n >= 0n && n <= max, 'INTEGER', 'Integer is outside the supported range.'); return n;
}
export function decimal(value, decimals) { const n = BigInt(value), d = 10n ** BigInt(decimals); const fraction = (n % d).toString().padStart(decimals, '0').replace(/0+$/,''); return (n/d).toString() + (fraction ? '.'+fraction : ''); }
export class Reader {
  constructor(bytes) { this.bytes = bytes; this.pos=0; }
  take(n) { check(Number.isSafeInteger(n) && n >= 0 && this.pos+n <= this.bytes.length, 'TRUNCATED', 'Truncated transaction.'); const b=this.bytes.slice(this.pos,this.pos+n);this.pos+=n;return b; }
  u8() { return this.take(1)[0]; }
  u32() { const b=this.take(4);return new DataView(b.buffer,b.byteOffset,4).getUint32(0,true); }
  u64() { const b=this.take(8); let n=0n; for(let i=7;i>=0;i--) n=(n<<8n)+BigInt(b[i]); return n; }
  short() { let n=0, shift=0; for(let i=0;i<3;i++){const b=this.u8();check(i<2||b<4,'ENCODING','Invalid compact length.'); n|=(b&127)<<shift;if(!(b&128)){check(i===0||b!==0,'ENCODING','Non-canonical compact length.');return n;}shift+=7;} fail('ENCODING','Invalid compact length.'); }
  end() { check(this.pos === this.bytes.length,'ENCODING','Trailing transaction bytes.'); }
}
export function short(n) { const a=[]; do { let b=n&127;n>>>=7;a.push(b|(n?128:0)); }while(n);return new Uint8Array(a); }
