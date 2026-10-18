import { base58, base58check } from '@scure/base';
import { sha256 } from '@noble/hashes/sha2.js';
import { getAddress } from 'ethers/address';
import { RawPSBTV0, RawPSBTV2 } from '@scure/btc-signer/psbt.js';
import { parseBitcoin, signBitcoin, bitcoinKeyMatchesInput, bitcoinDisplay, highFeeWarning } from './bitcoin.js';
import { p2wpkh, p2pkh, p2sh, p2tr } from '@scure/btc-signer';
import { parseEVM, signEVM } from './evm.js';
import { parseSolana, signSolana } from './solana.js';
import { parseTron, signTron } from './tron.js';
import { validatePublicIndex, derivePublicKeyAt, BITCOIN_PROFILES, publicIndexFromSeed, seedWalletKeyId } from './public-index.js';
import { withSeedInput, withKey } from './keys.js';
import { validateRequestTransport, ProtocolError } from '../protocols.js';
import { check, EngineError, requestHash, stable, bytesToHex, hexToBytes, equal, utf8, fromBase64, field, decimal } from './util.js';

const PARSERS={bitcoin:parseBitcoin,evm:parseEVM,solana:parseSolana,tron:parseTron};
const SIGNERS={bitcoin:signBitcoin,evm:signEVM,solana:signSolana,tron:signTron};
const MESSAGES={noMatch:'No matching wallet',missingSigner:'Missing signer information',ambiguous:'Ambiguous wallet match',setupRequired:'Wallet setup required',invalid:'Invalid signing request'};
const failure=(status,message=MESSAGES[status])=>({version:1,status,message,tasks:[]});
function normalizeAddress(chain,value) {
  check(typeof value==='string','SIGNER','Invalid signer address');
  if(chain==='evm')return getAddress(value).toLowerCase();
  if(chain==='solana'){check(base58.decode(value).length===32,'SIGNER','Invalid Solana signer address');return value;}
  if(chain==='tron'){
    if(/^(?:0x)?41[0-9a-f]{40}$/i.test(value))return base58check(sha256).encode(hexToBytes(value));
    const raw=base58check(sha256).decode(value);check(raw.length===21&&raw[0]===0x41,'SIGNER','Invalid TRON signer address');return value;
  }
  return value;
}
function samePublicKey(a,b) {
  a=a.toLowerCase().replace(/^0x/,'');b=b.toLowerCase().replace(/^0x/,'');
  return a===b||(a.length===64&&b.length===66&&a===b.slice(2));
}
function publicAt(wallet,chain,path) {
  try{return derivePublicKeyAt(wallet.publicIndex,chain,path);}catch(error){if(error instanceof EngineError&&error.code==='PATH')return undefined;throw error;}
}
function identityMatches(request,key,index) {
  if(request.masterFingerprint!==undefined&&request.masterFingerprint.toLowerCase()!==index.masterFingerprint.toLowerCase())return false;
  if(request.publicKey!==undefined&&!samePublicKey(request.publicKey,key.publicKey))return false;
  if(request.address!==undefined&&normalizeAddress(request.chain,request.address)!==normalizeAddress(request.chain,key.address))return false;
  return true;
}
function unsignedBitcoinTarget(parsed,target) {
  const input=parsed.tx.getInput(target.inputIndex),pub=target.publicKey.toLowerCase();
  if(input.finalScriptSig||input.finalScriptWitness)return undefined;
  if((input.partialSig??[]).some(([key])=>bytesToHex(key)===pub))return undefined;
  if(parsed.inputs[target.inputIndex].taproot){
    const x=pub.length===66?pub.slice(2):pub;
    if(target.leafHashes?.length){
      const remaining=target.leafHashes.filter(hash=>!(input.tapScriptSig??[]).some(([key])=>bytesToHex(key.pubKey)===x&&bytesToHex(key.leafHash)===hash));
      if(!remaining.length)return undefined;
      return {...target,leafHashes:remaining};
    }
    if(input.tapKeySig)return undefined;
  }
  return target;
}
function bitcoinMatches(request,parsed,wallets) {
  const found=[];
  for(const wallet of wallets){
    const targets=[];
    for(const selector of parsed.selectors){
      if(selector.masterFingerprint.toLowerCase()!==wallet.publicIndex.masterFingerprint.toLowerCase())continue;
      const key=publicAt(wallet,'bitcoin',selector.path);
      if(!key||!samePublicKey(selector.publicKey,key.publicKey)||!bitcoinKeyMatchesInput(parsed,selector.inputIndex,key.publicKey,selector.leafHashes))continue;
      const target=unsignedBitcoinTarget(parsed,{...key,inputIndex:selector.inputIndex,...(selector.leafHashes?{leafHashes:selector.leafHashes}:{})});
      if(target)targets.push(target);
    }
    for(const input of parsed.inputs.filter(input=>!input.hasDerivations&&!input.finalized)){
      for(const origin of Object.values(BITCOIN_PROFILES)){
        const key=publicAt(wallet,'bitcoin',origin+'/0/0');
        if(origin.startsWith("m/48'")&&!input.scriptType.endsWith('-ms')&&!(input.taproot&&parsed.leaves[input.inputIndex].some(leaf=>leaf.policy.pubkeys.some(pub=>bytesToHex(pub)===key.publicKey.slice(2)))))continue;
        if(!bitcoinKeyMatchesInput(parsed,input.inputIndex,key.publicKey))continue;
        const wire=parsed.tx.getInput(input.inputIndex),x=key.publicKey.slice(2);
        const leafHashes=input.taproot&&(!wire.tapInternalKey||bytesToHex(wire.tapInternalKey)!==x)
          ?parsed.leaves[input.inputIndex].filter(leaf=>leaf.policy.pubkeys.some(pub=>bytesToHex(pub)===x)).map(leaf=>bytesToHex(leaf.hash)):[];
        const target=unsignedBitcoinTarget(parsed,{...key,inputIndex:input.inputIndex,...(leafHashes.length?{leafHashes}:{})});
        if(target)targets.push(target);
      }
    }
    const unique=[...new Map(targets.map(target=>[`${target.inputIndex}:${target.path}:${target.publicKey}`,target])).values()];
    if(unique.length)found.push({wallet,targets:unique});
  }
  return found;
}
function singleMatches(request,parsed,wallets) {
  const hasIdentity=request.address!==undefined||request.publicKey!==undefined||request.masterFingerprint!==undefined;
  if(!hasIdentity||(!request.path&&request.address===undefined&&request.publicKey===undefined))return {failure:failure('missingSigner')};
  const found=[];
  for(const wallet of wallets){
    let keys=[];
    if(request.path){const key=publicAt(wallet,request.chain,request.path);if(key)keys=[key];}
    else if(request.chain==='evm')keys=[derivePublicKeyAt(wallet.publicIndex,'evm',"m/44'/60'/0'/0/0")];
    else if(request.chain==='tron')keys=wallet.publicIndex.tronAddressIndex.filter(item=>identityMatches(request,item,wallet.publicIndex)).map(item=>{
      const key=derivePublicKeyAt(wallet.publicIndex,'tron',item.path);
      check(key.publicKey===item.publicKey&&key.address===item.address,'PUBLIC_INDEX','Cached TRON address does not match its public node');return key;
    });
    else if(request.chain==='solana')keys=wallet.publicIndex.solanaPublicKeys.map(item=>derivePublicKeyAt(wallet.publicIndex,'solana',item.path));
    for(const key of keys){
      if(!identityMatches(request,key,wallet.publicIndex))continue;
      const target={...key};
      if(request.chain==='solana'&&parsed.keys){
        const slot=parsed.keys.slice(0,parsed.required).indexOf(key.address);if(slot<0)continue;
        if(parsed.signatures?.[slot]&&fromBase64(parsed.signatures[slot],64).some(byte=>byte!==0))continue;
        target.signerSlot=slot;
      }
      if(request.chain==='tron'&&parsed.existingSigners?.includes(key.address))continue;
      found.push({wallet,targets:[target]});
    }
  }
  return {found};
}
const pathText=path=>'m/'+path.map(i=>(i&0x7fffffff)+(i>=0x80000000?"'":'')).join('/');
function singleSigScript(profile,publicKey){
  if(profile==='native')return p2wpkh(publicKey).script;
  if(profile==='nested')return p2sh(p2wpkh(publicKey)).script;
  if(profile==='legacy')return p2pkh(publicKey).script;
  if(profile==='taproot')return p2tr(publicKey.slice(1)).script;
  return undefined;
}
/** Outputs whose script is re-derived from a signing wallet's registered single-sig
 * public keys. PSBT derivation data only nominates candidates; the output script
 * must equal the script built from our own key, so labels alone prove nothing. */
function verifiedBitcoinChange(parsed,found){
  const change=new Map();
  for(let i=0;i<parsed.tx.outputsLength;i++){
    const output=parsed.tx.getOutput(i);
    const candidates=[...(output.bip32Derivation??[]).map(([pub,der])=>({pub,der})),...(output.tapBip32Derivation??[]).map(([pub,d])=>({pub,der:d.der}))];
    for(const {pub,der} of candidates){
      const fingerprint=der.fingerprint.toString(16).padStart(8,'0'),path=pathText(der.path);
      for(const {wallet} of found){
        if(fingerprint!==wallet.publicIndex.masterFingerprint.toLowerCase())continue;
        const key=publicAt(wallet,'bitcoin',path);
        if(!key||!samePublicKey(bytesToHex(pub),key.publicKey))continue;
        const script=singleSigScript(key.profile,hexToBytes(key.publicKey,33));
        if(script&&equal(script,output.script))change.set(i,{walletId:wallet.localWalletId,path});
      }
    }
  }
  return change;
}
function withVerifiedChange(parsed,found){
  const change=verifiedBitcoinChange(parsed,found);
  if(!change.size)return parsed.review;
  const fields=[...parsed.review.fields];
  for(const [index,{path}] of change){
    const at=fields.findIndex(f=>f.label===`Output ${index+1}`);
    fields.splice(at+1,0,field(`Output ${index+1} ownership`,`Returns to the signing wallet (verified from its public key, ${path})`));
  }
  const warnings=parsed.review.warnings.map(w=>w.startsWith('Every output is shown.')?'Every output is shown. Outputs marked as returning to your wallet were verified from the signing wallet’s own public keys.':w);
  // The fee rule compares the fee against what is actually being sent, which
  // is only known now: an output coming back to this wallet is not a payment,
  // and counting it would hide a fee that dwarfs the real one. Change only
  // shrinks the payment, so this can add the warning, never withdraw one.
  const payment=parsed.outputs.reduce((total,output)=>change.has(output.index)?total:total+output.amount,0n);
  const highFee=highFeeWarning(parsed.fee,payment);
  if(highFee&&!warnings.includes(highFee))warnings.push(highFee);
  const riskLevel=warnings.some(w=>w.startsWith('HIGH'))?'high':parsed.review.riskLevel;
  // The summary outlives the review: it is what the history and the signature
  // receipt show. Change is not money sent, so it is not in the figure either,
  // which is the same amount the card itself shows.
  const sent=parsed.outputs.reduce((total,output)=>output.data||change.has(output.index)?total:total+output.amount,0n);
  const summary=sent>0n?`Send ${decimal(sent,8)} BTC`:'Every output returns to your wallet';
  return {...parsed.review,fields,warnings,riskLevel,summary,display:bitcoinDisplay(parsed.outputs,parsed.fee,new Set(change.keys()))};
}
function digestOf(parsed,request){return parsed.signingBytesDigest||(typeof parsed.digest==='string'?parsed.digest.replace(/^0x/,''):parsed.digest?bytesToHex(parsed.digest):parsed.bytes?bytesToHex(sha256(parsed.bytes)):requestHash(request));}
export function resolveSigningPlan({request,wallets}) {
  try {
    check(request&&Object.hasOwn(PARSERS,request.chain),'REQUEST','Unsupported signing request');
    validateRequestTransport(request);
    check(Array.isArray(wallets)&&wallets.length<=100,'LIMIT','Invalid public wallet collection');
    check(new Set(wallets.map(wallet=>wallet.localWalletId)).size===wallets.length,'WALLET','Duplicate local wallet identifier');
    if(request.masterFingerprint!==undefined)check(typeof request.masterFingerprint==='string'&&/^[0-9a-f]{8}$/i.test(request.masterFingerprint),'SIGNER','Invalid master fingerprint');
    if(request.publicKey!==undefined){
      const keyPattern=request.chain==='solana'?/^(?:0x)?[0-9a-f]{64}$/i:request.chain==='bitcoin'?/^(?:0x)?(?:[0-9a-f]{64}|0[23][0-9a-f]{64})$/i:/^(?:0x)?0[23][0-9a-f]{64}$/i;
      check(typeof request.publicKey==='string'&&keyPattern.test(request.publicKey),'SIGNER','Invalid signer public key');
    }
    const ready=[],incomplete=[];
    for(const wallet of wallets){
      check(typeof wallet.localWalletId==='string'&&wallet.localWalletId.length>0&&wallet.localWalletId.length<=128,'WALLET','Invalid local wallet identifier');
      if(!wallet.publicIndex){incomplete.push(wallet);continue;}
      try{validatePublicIndex(wallet.publicIndex);ready.push(wallet);}catch{incomplete.push(wallet);}
    }
    const parsed=PARSERS[request.chain](request);let found;
    if(request.chain==='bitcoin')found=bitcoinMatches(request,parsed,ready);
    else {const match=singleMatches(request,parsed,ready);if(match.failure)return {...match.failure,review:parsed.review};found=match.found;}
    if(!found.length)return {...failure(incomplete.length?'setupRequired':'noMatch'),review:parsed.review};
    if(new Set(found.map(item=>item.wallet.publicIndex.walletKeyId)).size!==found.length||request.chain!=='bitcoin'&&found.length>1)return {...failure('ambiguous'),review:parsed.review};
    const hash=requestHash(request),signingBytesDigest=digestOf(parsed,request);
    const tasks=found.map(({wallet,targets})=>{
      targets.sort((a,b)=>(a.inputIndex??0)-(b.inputIndex??0)||(a.path>b.path?1:a.path<b.path?-1:0));
      const task={localWalletId:wallet.localWalletId,walletKeyId:wallet.publicIndex.walletKeyId,chain:request.chain,targets,paths:targets.map(t=>t.path),publicKeys:targets.map(t=>t.publicKey),addresses:targets.map(t=>t.address),inputs:[...new Set(targets.flatMap(t=>t.inputIndex===undefined?[]:[t.inputIndex]))],signatureAlgorithm:request.chain==='solana'?'Ed25519':request.chain==='bitcoin'?'ECDSA / BIP340':'ECDSA secp256k1',signingBytesDigest};
      return {id:requestHash({requestHash:hash,...task}),...task};
    }).sort((a,b)=>(a.localWalletId>b.localWalletId?1:a.localWalletId<b.localWalletId?-1:0));
    check(tasks.every(t=>t.targets.length<=200),'LIMIT','Too many signing targets');
    const originalPayloadBytes=request.transport?.payloadBytes||bytesToHex(utf8(stable(request)));
    const review=request.chain==='bitcoin'?withVerifiedChange(parsed,found):parsed.review;
    const plan={version:1,status:'ready',requestHash:hash,payloadDigest:bytesToHex(sha256(hexToBytes(originalPayloadBytes))),protocolProfile:request.transport?.type||'internal',originalPayloadBytes,signingBytesDigest,chain:request.chain,review,tasks};
    return {...plan,planHash:requestHash(plan)};
  }catch(error){return failure('invalid',error instanceof EngineError||error instanceof ProtocolError?error.message:'Invalid or unsupported signing request');}
}
const comparable=value=>{
  if(value===undefined)return null;
  if(value instanceof Uint8Array)return bytesToHex(value);
  if(typeof value==='bigint')return value.toString();
  if(Array.isArray(value))return value.map(comparable);
  if(value&&typeof value==='object')return Object.fromEntries(Object.entries(value).filter(([,item])=>item!==undefined).map(([key,item])=>[key,comparable(item)]));
  return value;
};
function accumulatedRequest(request,previousResult,plan,parsed) {
  if(!previousResult)return request;
  check(request.chain==='bitcoin'&&previousResult.requestHash===plan.requestHash&&previousResult.planHash===plan.planHash,'INTEGRITY','Previous signature does not belong to this signing plan');
  const next={...request,psbt:previousResult.psbt},candidate=parseBitcoin(next);
  check(equal(candidate.tx.unsignedTx,parsed.tx.unsignedTx),'INTEGRITY','Previous signature changed the transaction');
  const globals=psbt=>{const bytes=fromBase64(psbt);try{return RawPSBTV0.decode(bytes).global;}catch{return RawPSBTV2.decode(bytes).global;}};
  check(stable(comparable(globals(request.psbt)))===stable(comparable(globals(next.psbt))),'INTEGRITY','Previous signature changed PSBT global metadata');
  const clean=input=>Object.fromEntries(Object.entries(input).filter(([name])=>!['partialSig','tapKeySig','tapScriptSig'].includes(name)));
  for(let i=0;i<parsed.tx.inputsLength;i++){
    check(stable(comparable(clean(parsed.tx.getInput(i))))===stable(comparable(clean(candidate.tx.getInput(i)))),'INTEGRITY','Previous signature changed PSBT input metadata');
    for(const name of ['partialSig','tapScriptSig'])for(const item of parsed.tx.getInput(i)[name]??[])check((candidate.tx.getInput(i)[name]??[]).some(x=>stable(comparable(x))===stable(comparable(item))),'INTEGRITY','Previous signature dropped an existing signature');
    const existing=parsed.tx.getInput(i).tapKeySig;if(existing)check(candidate.tx.getInput(i).tapKeySig&&equal(existing,candidate.tx.getInput(i).tapKeySig),'INTEGRITY','Previous signature changed an existing signature');
  }
  for(let i=0;i<parsed.tx.outputsLength;i++)check(stable(comparable(parsed.tx.getOutput(i)))===stable(comparable(candidate.tx.getOutput(i))),'INTEGRITY','Previous signature changed PSBT output metadata');
  return next;
}
export function signPlanTask({request,plan,taskId,mnemonic,passphrase,seed,previousResult,riskAcknowledged=false}) {
  check(plan?.status==='ready'&&plan.version===1,'PLAN','A resolved signing plan is required');
  const {planHash,...body}=plan;
  check(planHash===requestHash(body)&&plan.requestHash===requestHash(request),'INTEGRITY','The request or signing plan changed after review');
  validateRequestTransport(request);
  check(Array.isArray(plan.tasks)&&plan.tasks.length>0&&plan.tasks.length<=100,'PLAN','Invalid signing tasks');
  const task=plan.tasks.find(item=>item.id===taskId);check(task,'PLAN','The signing task does not belong to this plan');
  const parsed=PARSERS[request.chain](request);check(digestOf(parsed,request)===plan.signingBytesDigest,'INTEGRITY','Signing bytes changed after review');
  if(['partiallyDecoded','opaque'].includes(parsed.review.decodeStatus))check(riskAcknowledged===true,'RISK','Confirm this request’s decoding risks before signing');
  const working=accumulatedRequest(request,previousResult,plan,parsed);
  return withSeedInput({mnemonic,passphrase,seed},(seedBytes,root)=>{
    check(seedWalletKeyId(root)===task.walletKeyId,'SIGNER','The decrypted wallet does not match the signing plan');
    const index=publicIndexFromSeed(seedBytes,root),resolved=resolveSigningPlan({request,wallets:[{localWalletId:task.localWalletId,publicIndex:index}]});
    check(resolved.status==='ready'&&resolved.tasks.length===1&&stable(resolved.tasks[0])===stable(task),'INTEGRITY','The signing targets do not match the request and decrypted wallet');
    for(const target of task.targets)withKey(seedBytes,root,request.chain,target.path,(_key,pub)=>check(samePublicKey(target.publicKey,bytesToHex(pub)),'SIGNER','Decrypted public key differs from the approved key'));
    const result=SIGNERS[request.chain](working,seedBytes,root,task);
    return {...result,requestHash:plan.requestHash,planHash,taskId,completedTaskIds:[...(previousResult?.completedTaskIds??[]),taskId]};
  });
}
