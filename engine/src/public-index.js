import { HDKey } from '@scure/bip32';
import { sha256 } from '@noble/hashes/sha2.js';
import { ed25519 } from '@noble/curves/ed25519.js';
import { base58 } from '@scure/base';
import { p2wpkh, p2pkh, p2sh, p2tr } from '@scure/btc-signer';
import { computeAddress } from 'ethers/transaction';
import { withSeedInput, solanaKey, tronAddress, fpHex } from './keys.js';
import { check, bytesToHex, hexToBytes, concat, utf8 } from './util.js';

export const BITCOIN_PROFILES = Object.freeze({
  native: "m/84'/0'/0'", taproot: "m/86'/0'/0'", nested: "m/49'/0'/0'", legacy: "m/44'/0'/0'",
  'multisig-native': "m/48'/0'/0'/2'", 'multisig-nested': "m/48'/0'/0'/1'",
});
export const SOLANA_PROFILES = Object.freeze({standard:"m/44'/501'/0'/0'",trust:"m/44'/501'/0'",legacy:"m/44'/501'"});
const PUBLIC_INDEX_VERSION = 1;
const EVM_ORIGIN="m/44'/60'/0'", TRON_ORIGIN="m/44'/195'/0'";
export function seedWalletKeyId(root) { return bytesToHex(sha256(concat(utf8('BitTool-Signer/WalletKeyId/v1'),root.publicKey,root.chainCode))); }
function accountNode(root,chain,originPath,scriptProfile) {
  const node=root.derive(originPath);
  try { return {chain,originPath,accountPath:originPath,path:originPath,xpub:node.publicExtendedKey,publicKey:bytesToHex(node.publicKey),compressedPublicKey:bytesToHex(node.publicKey),chainCode:bytesToHex(node.chainCode),parentFingerprint:fpHex(node.parentFingerprint),depth:node.depth,scriptProfile,children:chain==='bitcoin'?['0/*','1/*']:['0/*'],masterFingerprint:fpHex(root.fingerprint)}; }
  finally { node.wipePrivateData(); }
}
export function derivePublicIndex({mnemonic,passphrase,seed}) {
  return withSeedInput({mnemonic,passphrase,seed},publicIndexFromSeed);
}
export function publicIndexFromSeed(seed,root) {
    const index={version:PUBLIC_INDEX_VERSION,walletKeyId:seedWalletKeyId(root),masterFingerprint:fpHex(root.fingerprint),bitcoinPublicNodes:Object.entries(BITCOIN_PROFILES).map(([profile,path])=>accountNode(root,'bitcoin',path,profile)),evmAccountNode:accountNode(root,'evm',EVM_ORIGIN,'standard'),tronAccountNode:accountNode(root,'tron',TRON_ORIGIN,'standard'),tronAddressIndex:[],solanaPublicKeys:[]};
    index.evmDefaultAddress=derivePublicKeyAt(index,'evm',EVM_ORIGIN+'/0/0');
    index.tronAddressIndex=Array.from({length:100},(_,i)=>derivePublicKeyAt(index,'tron',TRON_ORIGIN+'/0/'+i));
    index.solanaPublicKeys=Object.entries(SOLANA_PROFILES).map(([profile,path])=>{
      const key=solanaKey(seed,path);try {const pub=ed25519.getPublicKey(key);return {chain:'solana',profile,path,index:0,publicKey:bytesToHex(pub),address:base58.encode(pub),masterFingerprint:index.masterFingerprint};}finally{key.fill(0);}
    });
    return index;
}
function validSolanaKey(item) {
  try { const key=hexToBytes(item.publicKey);return key.length===32&&ed25519.Point.fromBytes(key).isSmallOrder()===false&&base58.encode(key)===item.address; } catch { return false; }
}
export function validatePublicIndex(index) {
  check(index&&index.version===PUBLIC_INDEX_VERSION&&/^[0-9a-f]{64}$/i.test(index.walletKeyId)&&/^[0-9a-f]{8}$/i.test(index.masterFingerprint),'PUBLIC_INDEX','Wallet setup required');
  check(Array.isArray(index.bitcoinPublicNodes)&&index.bitcoinPublicNodes.length===6&&Array.isArray(index.solanaPublicKeys)&&index.solanaPublicKeys.length===3&&Array.isArray(index.tronAddressIndex)&&index.tronAddressIndex.length===100,'PUBLIC_INDEX','Wallet setup required');
  check(Object.entries(BITCOIN_PROFILES).every(([profile,path])=>index.bitcoinPublicNodes.filter(n=>n.scriptProfile===profile&&n.originPath===path).length===1),'PUBLIC_INDEX','Invalid Bitcoin public index');
  check(index.evmAccountNode?.originPath===EVM_ORIGIN&&index.tronAccountNode?.originPath===TRON_ORIGIN,'PUBLIC_INDEX','Invalid public account origin');
  check(index.tronAddressIndex.every((item,i)=>item.index===i&&item.path===TRON_ORIGIN+'/0/'+i&&/^(02|03)[0-9a-f]{64}$/i.test(item.publicKey)&&typeof item.address==='string'),'PUBLIC_INDEX','Invalid TRON address index');
  check(Object.entries(SOLANA_PROFILES).every(([profile,path])=>index.solanaPublicKeys.filter(n=>n.profile===profile&&n.path===path).length===1),'PUBLIC_INDEX','Invalid Solana public index');
  check(index.solanaPublicKeys.every(n=>n.index===0&&validSolanaKey(n)),'PUBLIC_INDEX','Invalid Solana preset key');
  // Three different paths give three different keys: a repeated key means a corrupt or forged index.
  check(new Set(index.solanaPublicKeys.map(n=>n.publicKey.toLowerCase())).size===index.solanaPublicKeys.length,'PUBLIC_INDEX','Duplicate Solana public key');
  return index;
}
// Parsing an xpub (point decompression) and deriving its branch dominate public
// derivation cost. Both are cached per exact public node for this context only.
const nodeCache=new Map(),branchCache=new Map();
function remember(cache,key,make){let value=cache.get(key);if(!value){value=make();cache.set(key,value);if(cache.size>64)cache.delete(cache.keys().next().value);}return value;}
function verifiedNode(node,origin) {
  check(node?.originPath===origin&&node.accountPath===origin&&typeof node.xpub==='string'&&node.xpub.startsWith('xpub'),'PUBLIC_INDEX','Invalid registered public node');
  const key=[origin,node.xpub,node.publicKey,node.chainCode,node.parentFingerprint,node.depth].join('|');
  return remember(nodeCache,key,()=>{
    const hd=HDKey.fromExtendedKey(node.xpub);
    const components=origin.split('/'),childIndex=Number(components.at(-1).replace("'",''))+0x80000000;
    check(!hd.privateKey&&hd.depth===components.length-1&&hd.depth===node.depth&&hd.index===childIndex&&bytesToHex(hd.publicKey)===node.publicKey&&bytesToHex(hd.chainCode)===node.chainCode&&fpHex(hd.parentFingerprint)===node.parentFingerprint,'PUBLIC_INDEX','Public node metadata does not match its extended key');
    return {hd,key};
  });
}
function branchNode(node,origin,branch){const {hd,key}=verifiedNode(node,origin);return remember(branchCache,key+'/'+branch,()=>hd.deriveChild(branch));}
export function publicAddress(chain,profile,publicKey) {
  if(chain==='evm')return computeAddress('0x'+bytesToHex(publicKey));
  if(chain==='tron')return tronAddress(publicKey);
  if(chain==='solana')return base58.encode(publicKey);
  if(profile==='native')return p2wpkh(publicKey).address;
  if(profile==='nested')return p2sh(p2wpkh(publicKey)).address;
  if(profile==='legacy')return p2pkh(publicKey).address;
  if(profile==='taproot')return p2tr(publicKey.slice(1)).address;
  return ''; // A cosigner alone has no multisig receive address.
}
export function derivePublicKeyAt(index,chain,path) {
  check(index&&typeof path==='string'&&path.length<=100,'PATH','Invalid public derivation path');
  if(chain==='solana'){
    const item=index.solanaPublicKeys.find(item=>item.path===path&&SOLANA_PROFILES[item.profile]===path);
    check(item,'PATH','Path is not a registered Solana key');
    check(validSolanaKey(item),'PUBLIC_INDEX','Invalid cached Solana public key');
    return {...item};
  }
  const nodes=chain==='bitcoin'?index.bitcoinPublicNodes:chain==='evm'?[index.evmAccountNode]:chain==='tron'?[index.tronAccountNode]:[];
  const node=nodes.find(node=>path.startsWith(node.originPath+'/'));
  check(node,'PATH','Path is outside registered public accounts');
  const origin=chain==='bitcoin'?BITCOIN_PROFILES[node.scriptProfile]:chain==='evm'?EVM_ORIGIN:TRON_ORIGIN;
  const suffix=path.slice(node.originPath.length+1),match=/^([01])\/(0|[1-9][0-9]*)$/.exec(suffix);
  check(match,'PATH','Only registered non-hardened address paths are supported');
  const branch=Number(match[1]),i=Number(match[2]);
  check(Number.isSafeInteger(i)&&i<0x80000000&&(chain==='bitcoin'||branch===0),'PATH','Address index is outside the supported range');
  const hd=branchNode(node,origin,branch).deriveChild(i),key=hd.publicKey;
  return {chain,profile:node.scriptProfile,path,index:i,branch,publicKey:bytesToHex(key),address:publicAddress(chain,node.scriptProfile,key),masterFingerprint:index.masterFingerprint};
}
export function derivePublicAddresses({publicIndex,chain,profile,start=0,count=20}) {
  const index=validatePublicIndex(publicIndex);
  check(Number.isInteger(start)&&start>=0&&Number.isInteger(count)&&count>=1&&count<=100&&start+count<=0x80000000,'INDEX','Invalid address page');
  if(chain==='solana'){
    const list=profile?[index.solanaPublicKeys.find(x=>x.profile===profile)]:index.solanaPublicKeys;
    check(list.every(Boolean),'PROFILE','Unsupported Solana profile');
    return {addresses:list.map(x=>derivePublicKeyAt(index,'solana',x.path)),hasMore:false};
  }
  check(['bitcoin','evm','tron'].includes(chain),'CHAIN','Unsupported address chain');
  profile=profile??'native';
  check(chain!=='bitcoin'||Object.hasOwn(BITCOIN_PROFILES,profile)&&!profile.startsWith('multisig-'),'PROFILE','A cosigner key cannot define a multisig receive address');
  const end=Math.min(start+count,0x80000000),origin=chain==='bitcoin'?BITCOIN_PROFILES[profile]:chain==='evm'?EVM_ORIGIN:TRON_ORIGIN;
  return {addresses:Array.from({length:end-start},(_,i)=>derivePublicKeyAt(index,chain,origin+'/0/'+(start+i))),hasMore:end<0x80000000,nextIndex:end};
}
