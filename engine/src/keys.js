import { entropyToMnemonic, validateMnemonic as bip39Validate, mnemonicToSeedSync } from '@scure/bip39';
import { wordlist } from '@scure/bip39/wordlists/english.js';
import { HDKey } from '@scure/bip32';
import { hmac } from '@noble/hashes/hmac.js';
import { sha256, sha512 } from '@noble/hashes/sha2.js';
import { ed25519 } from '@noble/curves/ed25519.js';
import { base58, base58check } from '@scure/base';
import { p2wpkh, p2pkh, p2tr, p2sh } from '@scure/btc-signer';
import { computeAddress } from 'ethers/transaction';
import { hexToBytes, bytesToHex, check, utf8, concat } from './util.js';
export { wordlist };
export const PATHS = {bitcoin:"m/84'/0'/0'/0/0",evm:"m/44'/60'/0'/0/0",tron:"m/44'/195'/0'/0/0",solana:"m/44'/501'/0'/0'"};
export const fpHex = n => n.toString(16).padStart(8,'0');
export function normalizeMnemonic(mnemonic) { check(typeof mnemonic === 'string' && mnemonic.length <= 512,'MNEMONIC','Invalid recovery phrase.'); return mnemonic.normalize('NFKD').trim().toLowerCase().replace(/\s+/g,' '); }
export function validateMnemonic(mnemonic) { try { return {valid:bip39Validate(normalizeMnemonic(mnemonic),wordlist)}; }catch{return {valid:false};} }
export function mnemonic(entropy) { const b=hexToBytes(entropy,32);check([16,20,24,28,32].includes(b.length),'ENTROPY','Entropy must contain 128–256 bits in 32-bit steps.');return {mnemonic:entropyToMnemonic(b,wordlist),wordCount:b.length*3/4}; }
export function withSeed(mnemonic,passphrase,fn) {
  const m=normalizeMnemonic(mnemonic);check(bip39Validate(m,wordlist),'MNEMONIC','Recovery phrase has invalid words or checksum.');
  check(typeof (passphrase??'') === 'string' && (passphrase??'').length <= 1024,'PASSPHRASE','BIP39 passphrase is too long.');
  const seed=mnemonicToSeedSync(m,passphrase??''); const root=HDKey.fromMasterSeed(seed);
  try{return fn(seed,root);}finally{seed.fill(0);root.wipePrivateData();}
}
/** The host may supply the 64-byte BIP39 seed it derived natively (PBKDF2-HMAC-SHA512,
 * 2048 rounds) instead of the phrase; interpreted JavaScript PBKDF2 is very slow on iOS.
 * Every signing path still re-derives and checks keys against the fixed plan. */
export function withSeedInput({mnemonic,passphrase,seed},fn) {
  if(seed===undefined)return withSeed(mnemonic,passphrase,fn);
  check(mnemonic===undefined&&passphrase===undefined,'SEED','Provide either a seed or a recovery phrase, not both.');
  check(typeof seed==='string'&&/^[0-9a-f]{128}$/i.test(seed),'SEED','Invalid wallet seed.');
  const bytes=hexToBytes(seed,64),root=HDKey.fromMasterSeed(bytes);
  try{return fn(bytes,root);}finally{bytes.fill(0);root.wipePrivateData();}
}
export function validatePath(path,chain) {
  check(typeof path === 'string' && (chain==='solana'?/^m(?:\/[0-9]+'){2,4}$/:/^m(?:\/[0-9]+'?){3,6}$/).test(path),'PATH','Unsupported derivation path.');
  const c=path.split('/').slice(1).map(x=>({h:x.endsWith("'"),n:Number(x.replace("'",''))}));
  check(c.every(x=>Number.isSafeInteger(x.n)&&x.n<2147483648),'PATH','Derivation index is too large.');
  if(chain==='bitcoin') check([44,49,84,86,48].includes(c[0].n)&&c[0].h&&[0,1].includes(c[1].n)&&c[1].h&&c[2].h,'PATH','Expected a Bitcoin BIP44/49/84/86/48 path.');
  else {const coin={evm:60,tron:195,solana:501}[chain];check(c[0].n===44&&c[0].h&&c[1].n===coin&&c[1].h&&(chain==='solana'||c[2]?.h),'PATH','The derivation path belongs to a different chain.');if(chain==='solana')check(c.every(x=>x.h),'PATH','Ed25519 paths must be fully hardened.');}
  return c;
}
export function solanaKey(seed,path) {
  const parts=validatePath(path,'solana');let I=hmac(sha512,utf8('ed25519 seed'),seed);
  try { for(const c of parts){const index=new Uint8Array(4);new DataView(index.buffer).setUint32(0,c.n+2147483648);const next=hmac(sha512,I.slice(32),concat(new Uint8Array([0]),I.slice(0,32),index));I.fill(0);I=next;}return I.slice(0,32);}finally{I.fill(0);}
}
export function tronAddress(publicKey) { const evm=computeAddress('0x'+bytesToHex(publicKey));return base58check(sha256).encode(concat(new Uint8Array([0x41]),hexToBytes(evm))); }
export function withKey(seed,root,chain,path,fn){validatePath(path,chain);if(chain==='solana'){const key=solanaKey(seed,path);try{return fn(key,ed25519.getPublicKey(key));}finally{key.fill(0);}}const node=root.derive(path);try{return fn(node.privateKey,node.publicKey);}finally{node.wipePrivateData();}}
export function deriveAccounts({mnemonic,passphrase,index=0}) {
  check(Number.isInteger(index)&&index>=0&&index<2147483648,'INDEX','Invalid account index.');
  return withSeed(mnemonic,passphrase,(seed,root)=>{
    const fingerprint=fpHex(root.fingerprint);const accounts=[];
    for(const chain of ['bitcoin','evm','tron','solana']){
      const path=chain==='solana'?`m/44'/501'/${index}'/0'`:PATHS[chain].slice(0,-1)+index;
      const accountPath=chain==='solana'?path:path.split('/').slice(0,4).join('/');
      const account=withKey(seed,root,chain,path,(key,pub)=>({chain,name:({bitcoin:'Bitcoin',evm:'Ethereum / EVM',tron:'TRON',solana:'Solana'})[chain],address:chain==='bitcoin'?p2wpkh(pub).address:chain==='evm'?computeAddress('0x'+bytesToHex(pub)):chain==='tron'?tronAddress(pub):base58.encode(pub),path,publicKey:bytesToHex(pub),masterFingerprint:fingerprint}));
      if(chain!=='solana'){const node=root.derive(accountPath);try{Object.assign(account,{xpub:node.publicExtendedKey,accountPublicKey:bytesToHex(node.publicKey),accountPath,chainCode:bytesToHex(node.chainCode),parentFingerprint:fpHex(node.parentFingerprint)});}finally{node.wipePrivateData();}}
      accounts.push(account);
    }
    return {fingerprint,masterFingerprint:fingerprint,accounts};
  });
}

export function deriveBitcoinCosigner({mnemonic,passphrase,account=0,network='mainnet',scriptType='native'}) {
  check(Number.isInteger(account)&&account>=0&&account<2147483648,'INDEX','Invalid Bitcoin account.');
  check(['mainnet','testnet'].includes(network)&&['native','nested'].includes(scriptType),'NETWORK','Unsupported cosigner profile.');
  return withSeed(mnemonic,passphrase,(seed,root)=>{
    const accountPath=`m/48'/${network==='testnet'?1:0}'/${account}'/${scriptType==='nested'?1:2}'`;
    const node=root.derive(accountPath);
    try {
      const publicNode=network==='testnet'?new HDKey({publicKey:node.publicKey,chainCode:node.chainCode,depth:node.depth,index:node.index,parentFingerprint:node.parentFingerprint,versions:{public:0x043587cf,private:0x04358394}}):node;
      return {chain:'bitcoin',name:'Bitcoin multisig cosigner',isCosigner:true,address:'',path:accountPath,accountPath,network,scriptType,masterFingerprint:fpHex(root.fingerprint),xpub:publicNode.publicExtendedKey,publicKey:bytesToHex(node.publicKey),chainCode:bytesToHex(node.chainCode),parentFingerprint:fpHex(node.parentFingerprint),note:'Public cosigner key only. The complete multisig descriptor, threshold and all cosigners are required to construct wallet addresses.'};
    }finally{node.wipePrivateData();}
  });
}
