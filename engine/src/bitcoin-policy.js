/** Restricted, public-only BIP380/BIP383 descriptors. Checksum algorithm follows
 * Bitcoin BIP380 (Pieter Wuille, Ava Chow; BSD-2-Clause). No private-key grammar.
 */
import { HDKey } from '@scure/bip32';
import { p2ms,p2wsh,p2sh,NETWORK,TEST_NETWORK } from '@scure/btc-signer';
import { sha256 } from '@noble/hashes/sha2.js';
import { check, bytesToHex, utf8, equal } from './util.js';
const INPUT="0123456789()[],'/*abcdefgh@:$%{}IJKLMNOPQRSTUVWXYZ&+-.;<=>?!^_|~ijklmnopqrstuvwxyzABCDEFGH`#\"\\ ";
const OUTPUT='qpzry9x8gf2tvdw0s3jn54khce6mua7l';
const GENERATORS=[0xf5dee51989n,0xa9fdca3312n,0x1bab10e32dn,0x3706b1677an,0x644d626ffdn];
export function descriptorChecksum(body){
 const symbols=[],groups=[];for(const char of body){const v=INPUT.indexOf(char);check(v>=0,'DESCRIPTOR','Invalid descriptor character.');symbols.push(v&31);groups.push(v>>5);if(groups.length===3){symbols.push(groups[0]*9+groups[1]*3+groups[2]);groups.length=0;}}
 if(groups.length===1)symbols.push(groups[0]);else if(groups.length===2)symbols.push(groups[0]*3+groups[1]);
 let checksum=1n;for(const value of [...symbols,0,0,0,0,0,0,0,0]){const top=checksum>>35n;checksum=((checksum&0x7ffffffffn)<<5n)^BigInt(value);for(let i=0;i<5;i++)if((top>>BigInt(i))&1n)checksum^=GENERATORS[i];}checksum^=1n;
 let out='';for(let i=0;i<8;i++)out+=OUTPUT[Number((checksum>>BigInt(5*(7-i)))&31n)];return out;
}
export function parseBitcoinPolicy(descriptor){
 check(typeof descriptor==='string'&&descriptor.length<=16384,'DESCRIPTOR','Invalid or oversized descriptor.');
 const parts=descriptor.split('#');check(parts.length===2&&parts[1]===descriptorChecksum(parts[0]),'DESCRIPTOR','Missing or incorrect descriptor checksum.');
 const body=parts[0],nested=body.startsWith('sh(wsh(');
 check(body.startsWith(nested?'sh(wsh(':'wsh(')&&body.endsWith(nested?'))':')'),'DESCRIPTOR','Unsupported descriptor wrapper.');
 const inner=body.slice(nested?7:4,nested?-2:-1);const outer=/^(sortedmulti|multi)\(([1-9][0-9]*),([^()]+)\)$/.exec(inner);
 check(outer,'DESCRIPTOR','Only wsh(multi/sortedmulti) and sh(wsh(multi/sortedmulti)) descriptors are supported.');
 const threshold=Number(outer[2]),entries=outer[3].split(',');check(entries.length>=2&&entries.length<=20&&threshold<=entries.length,'POLICY','Invalid multisig threshold.');
 const keys=entries.map(entry=>{
   const match=/^\[([0-9a-fA-F]{8})((?:\/[0-9]+['h]?)*)\]((?:xpub|tpub)[1-9A-HJ-NP-Za-km-z]+)\/(0|1|<0;1>)\/\*$/.exec(entry);check(match,'DESCRIPTOR','Every cosigner needs an origin, public xpub, receive/change branch and unhardened wildcard.');
   const network=match[3].startsWith('tpub')?'testnet':'mainnet';
   const node=HDKey.fromExtendedKey(match[3],network==='testnet'?{public:0x043587cf,private:0x04358394}:undefined);
   const origin='m'+match[2].replace(/h/g,"'");const components=origin.split('/').slice(1);check(node.depth===components.length,'POLICY','Cosigner origin depth does not match xpub.');
   const path=components.map(c=>{const n=Number(c.replace("'",''));check(Number.isSafeInteger(n)&&n>=0&&n<2147483648,'PATH','Invalid cosigner origin.');return n+(c.endsWith("'")?2147483648:0);});
   if(path.length)check(node.index===path.at(-1),'POLICY','Cosigner origin child does not match xpub.');
   return {fingerprint:match[1].toLowerCase(),origin,path,xpub:match[3],node,network,branch:match[4]};
 });
 check(new Set(keys.map(k=>bytesToHex(k.node.publicKey)+bytesToHex(k.node.chainCode))).size===keys.length,'POLICY','Duplicate cosigner extended key.');
 check(keys.every(k=>k.network===keys[0].network&&k.branch===keys[0].branch),'POLICY','Cosigners must share network and branch shape.');
 return {descriptor,id:bytesToHex(sha256(utf8(descriptor))),threshold,sorted:outer[1]==='sortedmulti',nested,network:keys[0].network,keys};
}
export function policyPayment(policy,branch,index){
 check([0,1].includes(branch)&&Number.isInteger(index)&&index>=0&&index<2147483648,'PATH','Invalid descriptor address index.');
 check(policy.keys.every(k=>k.branch==='<0;1>'||Number(k.branch)===branch),'POLICY','Descriptor does not cover this branch.');
 const network=policy.network==='testnet'?TEST_NETWORK:NETWORK;
 const publicKeys=policy.keys.map(k=>k.node.deriveChild(branch).deriveChild(index).publicKey);
 if(policy.sorted)publicKeys.sort((a,b)=>bytesToHex(a).localeCompare(bytesToHex(b)));
 const witness=p2wsh(p2ms(policy.threshold,publicKeys),network);return policy.nested?p2sh(witness,network):witness;
}
export function validateBitcoinPolicy({descriptor}){const p=parseBitcoinPolicy(descriptor);const branches=p.keys[0].branch==='<0;1>'?[0,1]:[Number(p.keys[0].branch)];return {id:p.id,descriptor:p.descriptor,network:p.network,threshold:p.threshold,total:p.keys.length,scriptType:p.nested?'P2SH-P2WSH':'P2WSH',sorted:p.sorted,cosigners:p.keys.map(({fingerprint,origin,xpub})=>({fingerprint,origin,xpub})),samples:branches.flatMap(branch=>[0,1].map(index=>({branch,index,address:policyPayment(p,branch,index).address}))),notice:'This validates descriptor structure and derived addresses. It does not register or authenticate the policy. Independently verify every cosigner and threshold.'};}
