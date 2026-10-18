import { Transaction, NETWORK, getInputType, OutScript, p2tr } from '@scure/btc-signer';
import { getPrevOut } from '@scure/btc-signer/transaction.js';
import { tapLeafHash } from '@scure/btc-signer/payment.js';
import { hash160, taprootTweakPrivKey, tagSchnorr, compareBytes } from '@scure/btc-signer/utils.js';
import { secp256k1, schnorr } from '@noble/curves/secp256k1.js';
import { sha256 } from '@noble/hashes/sha2.js';
import { randomBytes } from '@noble/hashes/utils.js';
import { check, field, reviewResult, fromBase64, toBase64, bytesToHex, hexToBytes, decimal, equal, concat } from './util.js';
import { validatePath } from './keys.js';

/** A fee this large is worth a second look whatever the payment is: 0.01 BTC. */
const HIGH_FEE_ABSOLUTE=1000000n;
/** The share test below ignores fees under 0.0001 BTC: on a small payment a
 * few thousand satoshis is simply what the network costs, and warning there
 * only teaches people to tick the box without reading. */
const HIGH_FEE_FLOOR=10000n;
const pathText=path=>'m/'+path.map(i=>(i&0x7fffffff)+(i>=0x80000000?"'":'')).join('/');
const xOnly=pub=>pub.length===33?pub.slice(1):pub;
function leaves(input) {
  return (input.tapLeafScript??[]).map(([control,encoded])=>{
    const version=encoded.at(-1),script=encoded.slice(0,-1),policy=OutScript.decode(script);
    check(version===0xc0,'UNSUPPORTED','Unsupported signing protocol: unknown Taproot leaf version.');
    check(['tr_ns','tr_ms'].includes(policy.type),'UNSUPPORTED','Unsupported signing protocol: only CHECKSIG/CHECKSIGVERIFY and CHECKSIGADD threshold leaves are supported.');
    check(policy.pubkeys.length<=20&&new Set(policy.pubkeys.map(bytesToHex)).size===policy.pubkeys.length,'POLICY','Taproot leaves require 1–20 distinct public keys.');
    const hash=tapLeafHash(script,version);let root=hash;
    for(const sibling of control.merklePath)root=compareBytes(sibling,root)<0?tagSchnorr('TapBranch',sibling,root):tagSchnorr('TapBranch',root,sibling);
    return {hash,script,version,policy,root};
  });
}
function signatureDigest(parsed,index,sighash,leaf) {
  const input=parsed.tx.getInput(index),type=getInputType(input);
  if(type.txType==='taproot')return parsed.tx.preimageWitnessV1(index,parsed.prevouts.map(p=>p.script),sighash,parsed.prevouts.map(p=>p.amount),undefined,leaf?.script,leaf?.version);
  const script=type.last.type==='wpkh'?OutScript.encode({type:'pkh',hash:type.last.hash}):type.lastScript;
  return type.txType==='legacy'?parsed.tx.preimageLegacy(index,script,sighash):parsed.tx.preimageWitnessV0(index,script,sighash,parsed.prevouts[index].amount);
}
/** Headline for the payment. Outputs proven to return to a signing wallet can be
 * excluded by the resolver (`change`); nothing is excluded based on PSBT labels. */
/** The summary for a Bitcoin transaction. Value sent to an unspendable data
 * output is destroyed, so it is never folded into "payments" and never left out
 * of the headline: a burn is the one outcome that cannot be undone, and it must
 * not be able to read as a consolidation. Every satoshi is accounted for as
 * payment, change, burn or fee. */
export function bitcoinDisplay(outputs,fee,change=new Set()) {
  const burned=outputs.filter(o=>o.data).reduce((n,o)=>n+o.amount,0n);
  const payments=outputs.filter(o=>!o.data&&!change.has(o.index));
  const total=payments.reduce((n,o)=>n+o.amount,0n);
  const base={action:'Send',fee:decimal(fee,8)+' BTC'};
  const burn=decimal(burned,8);
  // A burn leads the summary whatever else the transaction does.
  if(burned>0n) {
    const rest=payments.length?` · ${payments.length===1?decimal(total,8)+' BTC to '+payments[0].address:`${payments.length} recipients · ${decimal(total,8)} BTC`}`:'';
    const {note:_dropped,...noNote}=base;
    return {...noNote,action:'Burn',amount:burn,symbol:'BTC',
      headline:`Destroys ${burn} BTC in an unspendable output${rest}`};
  }
  if(payments.length===1)return {...base,amount:decimal(payments[0].amount,8),symbol:'BTC',counterpartyLabel:'To',counterparty:payments[0].address,...(change.size?{note:'Change returns to your wallet'}:{})};
  if(payments.length===0)return {...base,action:'Consolidate',headline:change.size?'All outputs return to your wallet':'Data output only'};
  return {...base,headline:`${payments.length} recipients · ${decimal(total,8)} BTC`,...(change.size?{note:'Change returns to your wallet'}:{})};
}
export function bitcoinKeyMatchesInput(parsed,inputIndex,publicKey,leafHashes) {
  const pub=typeof publicKey==='string'?hexToBytes(publicKey,33):publicKey;
  if(!Number.isInteger(inputIndex)||inputIndex<0||inputIndex>=parsed.tx.inputsLength)return false;
  const input=parsed.tx.getInput(inputIndex),type=getInputType(input);
  if(type.txType==='taproot') {
    const x=xOnly(pub);if(x.length!==32)return false;
    const scripts=parsed.leaves[inputIndex];
    if(Array.isArray(leafHashes)&&leafHashes.length===0)return !!(input.tapInternalKey&&equal(input.tapInternalKey,x))||equal(p2tr(x).script,parsed.prevouts[inputIndex].script);
    if(leafHashes?.length)return leafHashes.every(h=>scripts.some(l=>bytesToHex(l.hash)===h&&l.policy.pubkeys.some(k=>equal(k,x))));
    if(input.tapInternalKey&&equal(input.tapInternalKey,x))return true;
    if(scripts.some(l=>l.policy.pubkeys.some(k=>equal(k,x))))return true;
    return equal(p2tr(x).script,parsed.prevouts[inputIndex].script);
  }
  if(pub.length!==33)return false;
  if(['pkh','wpkh'].includes(type.last.type))return equal(hash160(pub),type.last.hash);
  if(type.last.type==='ms')return type.last.pubkeys.some(k=>equal(k,pub));
  return false;
}
function verifySignatures(parsed,index) {
  const input=parsed.tx.getInput(index),type=getInputType(input);
  for(const [pub,sig] of input.partialSig??[]) {
    check(type.txType!=='taproot'&&sig.at(-1)===1&&bitcoinKeyMatchesInput(parsed,index,pub),'SIGNATURE','Existing Bitcoin signature has an unsupported sighash or unrelated key.');
    check(secp256k1.verify(sig.slice(0,-1),signatureDigest(parsed,index,1),pub,{prehash:false,format:'der',lowS:true}),'SIGNATURE','Existing Bitcoin signature is invalid.');
  }
  if(input.tapKeySig) {
    const sig=input.tapKeySig,sighash=sig.length===64?0:sig.at(-1);
    check(type.txType==='taproot'&&[0,1].includes(sighash),'SIGHASH','Unsupported existing Taproot signature sighash.');
    check(schnorr.verify(sig.slice(0,64),signatureDigest(parsed,index,sighash),parsed.prevouts[index].script.slice(2)),'SIGNATURE','Existing Taproot key-path signature is invalid.');
  }
  for(const [{pubKey,leafHash},sig] of input.tapScriptSig??[]) {
    const leaf=parsed.leaves[index].find(l=>equal(l.hash,leafHash));
    const sighash=sig.length===64?0:sig.at(-1);
    check(leaf&&[0,1].includes(sighash)&&leaf.policy.pubkeys.some(k=>equal(k,pubKey)),'SIGNATURE','Existing Taproot signature does not match a supported committed leaf.');
    check(schnorr.verify(sig.slice(0,64),signatureDigest(parsed,index,sighash,leaf),pubKey),'SIGNATURE','Existing Taproot script signature is invalid.');
  }
}
export function parseBitcoin(request) {
  check(!request.network||request.network==='mainnet','NETWORK','Unsupported network');
  // scure's "ignore" retains unknown/proprietary fields; "strip" deletes them.
  const tx=Transaction.fromPSBT(fromBase64(request.psbt,262144),{strictPrevoutValidation:false,unknown:'ignore',proprietary:'ignore'});
  check(tx.inputsLength>0&&tx.inputsLength<=100&&tx.outputsLength>0&&tx.outputsLength<=100,'LIMIT','Bitcoin transaction must have 1–100 inputs and outputs.');
  const parsed={tx,prevouts:[],leaves:[],selectors:[],inputs:[],outputs:[],signingBytesDigest:bytesToHex(sha256(tx.unsignedTx))};
  const fields=[field('Network','Bitcoin'),field('Network context',request.network?'Mainnet selected by request; broadcast network is not encoded by the transaction':'Network context not included'),field('Inputs',tx.inputsLength),field('Locktime',tx.lockTime)];
  const warnings=['Every output is shown. Change ownership and the intended multisig policy are not inferred from untrusted PSBT labels.'];
  let inputTotal=0n,outputTotal=0n,witnessOnly=false;const outpoints=new Set(),inputTypes=[];
  for(let i=0;i<tx.inputsLength;i++) {
    const input=tx.getInput(i),outpoint=bytesToHex(input.txid)+':'+input.index,type=getInputType(input);
    check(!outpoints.has(outpoint),'OUTPOINT','Duplicate Bitcoin input outpoint.');outpoints.add(outpoint);
    check(input.sighashType!==0||type.txType==='taproot','SIGHASH','SIGHASH_DEFAULT is valid only for Taproot.');
    check([0,1].includes(type.sighash),'SIGHASH','Only SIGHASH_ALL or Taproot SIGHASH_DEFAULT is accepted.');
    check(['pkh','wpkh','ms','tr'].includes(type.last.type),'UNSUPPORTED','Unsupported signing protocol: unknown Bitcoin input script.');
    if(type.last.type==='ms')check(new Set(type.last.pubkeys.map(bytesToHex)).size===type.last.pubkeys.length,'POLICY','Duplicate multisig public key.');
    if(!input.nonWitnessUtxo){witnessOnly=true;check(type.txType==='taproot','PREVOUT','Full previous transactions (nonWitnessUtxo) are required for legacy and SegWit v0 inputs to prevent repeated-signing fee attacks.');}
    inputTypes.push(type.txType);const prev=getPrevOut(input);parsed.prevouts.push(prev);inputTotal+=prev.amount;
    check(prev.amount>=0n&&prev.amount<=2100000000000000n,'AMOUNT','Invalid Bitcoin input amount.');
    const tapLeaves=leaves(input);parsed.leaves.push(tapLeaves);
    const derivations=type.txType==='taproot'?(input.tapBip32Derivation??[]).map(([pub,d])=>({pub,der:d.der,hashes:d.hashes})):(input.bip32Derivation??[]).map(([pub,der])=>({pub,der}));
    for(const d of derivations)parsed.selectors.push({inputIndex:i,path:pathText(d.der.path),masterFingerprint:d.der.fingerprint.toString(16).padStart(8,'0'),publicKey:bytesToHex(d.pub),...(d.hashes?{leafHashes:d.hashes.map(bytesToHex)}:{})});
    parsed.inputs.push({inputIndex:i,scriptType:type.type,finalized:!!(input.finalScriptSig||input.finalScriptWitness),hasDerivations:derivations.length>0,taproot:type.txType==='taproot'});
    fields.push(field(`Input ${i+1}`,`${type.type}; ${decimal(prev.amount,8)} BTC; ${outpoint}`),field(`Input ${i+1} sighash`,type.sighash===0?'DEFAULT':'ALL'));
    if(type.last.type==='ms')fields.push(field(`Input ${i+1} multisig`,`${type.last.m} of ${type.last.pubkeys.length}\n`+type.last.pubkeys.map(bytesToHex).join('\n')));
    for(const leaf of tapLeaves)fields.push(field(`Input ${i+1} Taproot leaf`,`${leaf.policy.m??leaf.policy.pubkeys.length} of ${leaf.policy.pubkeys.length}; ${leaf.policy.type==='tr_ms'?'CHECKSIGADD':'CHECKSIG/CHECKSIGVERIFY'}\nLeaf ${bytesToHex(leaf.hash)}\n`+leaf.policy.pubkeys.map(bytesToHex).join('\n')));
  }
  if(witnessOnly){check(inputTypes.every(t=>t==='taproot'),'PREVOUT','Witness-only amounts are accepted only in all-Taproot transactions, whose signatures bind all input amounts.');warnings.push('Input amounts are supplied by the coordinator. Taproot ALL/DEFAULT commits every input amount; incorrect values invalidate the signature.');}
  for(let i=0;i<tx.inputsLength;i++)verifySignatures(parsed,i);
  for(let i=0;i<tx.outputsLength;i++) {
    const output=tx.getOutput(i);check(output.amount>=0n&&output.amount<=2100000000000000n,'AMOUNT','Invalid Bitcoin output amount.');
    let address;try{address=tx.getOutputAddress(i,NETWORK);}catch{}
    const data=!address;
    if(data){check(output.script[0]===0x6a&&output.script.length<=83,'UNSUPPORTED','Unsupported Bitcoin output script.');address='OP_RETURN '+bytesToHex(output.script);
      // A zero-value OP_RETURN only carries data. One that carries value
      // destroys it permanently, which no other output in Bitcoin does.
      if(output.amount>0n)warnings.push(`HIGH RISK: Output ${i+1} permanently destroys ${decimal(output.amount,8)} BTC. It pays to an unspendable OP_RETURN data output, and no one can ever spend it.`);
      else warnings.push('The transaction includes an unspendable data output.');}
    parsed.outputs.push({index:i,amount:output.amount,address,data});
    outputTotal+=output.amount;fields.push(field(`Output ${i+1}`,`${decimal(output.amount,8)} BTC\n${address}`));
  }
  const fee=inputTotal-outputTotal;check(fee>=0n&&inputTotal<=2100000000000000n,'FEE','Bitcoin output total exceeds verified inputs.');
  fields.push(field('Total output',decimal(outputTotal,8)+' BTC'),field('Network fee',decimal(fee,8)+' BTC'));
  // Large outright, or eating more than half of what is being sent.
  if(fee>HIGH_FEE_ABSOLUTE||(fee>HIGH_FEE_FLOOR&&fee*2n>outputTotal))warnings.push('HIGH FEE: Fee exceeds 0.01 BTC, or it is more than half the amount being sent. Verify it carefully.');
  parsed.fee=fee;
  parsed.review=reviewResult(request,'Sign Bitcoin transaction',`Send ${decimal(outputTotal,8)} BTC`,fields,warnings,{riskLevel:warnings.some(w=>w.startsWith('HIGH'))?'high':'warning',network:{name:'Bitcoin',symbol:'BTC'},display:bitcoinDisplay(parsed.outputs,fee)});
  return parsed;
}
/** Developer summary of PSBT bytes for the response payload view. Field names are
 * Bitcoin Core `decodepsbt` names; amounts are integer satoshis (`value_sat`) so no
 * float rounding can appear. Only transaction identity and signature records are
 * summarized; every other PSBT field stays in the full PSBT shown beside it. */
export function psbtSummary(bytes) {
  const tx=Transaction.fromPSBT(bytes,{strictPrevoutValidation:false,unknown:'ignore',proprietary:'ignore'});
  const hex=bytesToHex,sats=n=>n<=BigInt(Number.MAX_SAFE_INTEGER)?Number(n):n.toString(),vin=[],vout=[],inputs=[];
  for(let i=0;i<tx.inputsLength;i++){
    const input=tx.getInput(i),view={};
    vin.push({txid:hex(input.txid),vout:input.index,sequence:input.sequence});
    if(input.partialSig?.length)view.partial_signatures=Object.fromEntries(input.partialSig.map(([pub,sig])=>[hex(pub),hex(sig)]));
    if(input.tapKeySig)view.taproot_key_path_sig=hex(input.tapKeySig);
    if(input.tapScriptSig?.length)view.taproot_script_path_sigs=input.tapScriptSig.map(([{pubKey,leafHash},sig])=>({pubkey:hex(pubKey),leaf_hash:hex(leafHash),sig:hex(sig)}));
    if(input.finalScriptSig?.length)view.final_scriptSig={hex:hex(input.finalScriptSig)};
    if(input.finalScriptWitness?.length)view.final_scriptwitness=input.finalScriptWitness.map(hex);
    inputs.push(view);
  }
  for(let i=0;i<tx.outputsLength;i++){
    const output=tx.getOutput(i);let address;try{address=tx.getOutputAddress(i,NETWORK);}catch{}
    vout.push({n:i,value_sat:sats(output.amount),scriptPubKey:{hex:hex(output.script),...(address?{address}:{})}});
  }
  // The unsigned transaction's txid (as decodepsbt reports it), even when some
  // inputs are already finalized.
  const txid=hex(sha256(sha256(tx.unsignedTx)).reverse());
  return {psbt_version:tx.opts.PSBTVersion??0,tx:{txid,version:tx.version,locktime:tx.lockTime,vin,vout},inputs};
}
export function signBitcoin(request,seed,root,task) {
  const p=parseBitcoin(request),before=p.tx.unsignedTx;
  const targets=task?.targets??p.selectors.filter(s=>s.masterFingerprint===root.fingerprint.toString(16).padStart(8,'0'));
  check(Array.isArray(targets)&&targets.length>0&&targets.length<=200,'SIGNER','No unsigned input belongs to this wallet. Correct derivation metadata or a matched signing task is required.');
  const signed=new Set();
  for(const target of targets) {
    const i=target.inputIndex;check(Number.isInteger(i)&&i>=0&&i<p.tx.inputsLength,'SIGNER','Invalid signing input index.');
    const input=p.tx.getInput(i);if(input.finalScriptSig||input.finalScriptWitness)continue;
    const path=validatePath(target.path,'bitcoin');check(path[1].n===0,'NETWORK','Unsupported network');
    const node=root.derive(target.path);
    try {
      const pub=node.publicKey,expected=hexToBytes(target.publicKey,33);
      check(equal(expected,expected.length===32?xOnly(pub):pub),'SIGNER','Signing task public key does not match the decrypted wallet.');
      check(bitcoinKeyMatchesInput(p,i,pub,target.leafHashes),'SIGNER','Signing key does not satisfy the committed input script.');
      const type=getInputType(input),sighash=type.sighash;
      if(type.txType==='taproot') {
        const x=xOnly(pub),matchingLeaves=p.leaves[i].filter(l=>l.policy.pubkeys.some(k=>equal(k,x))&&(!target.leafHashes?.length||target.leafHashes.includes(bytesToHex(l.hash))));
        const keyPath=(!target.leafHashes?.length)&&((input.tapInternalKey&&equal(input.tapInternalKey,x))||equal(p2tr(x).script,p.prevouts[i].script));
        if(keyPath) {
          check(!input.tapKeySig,'SIGNATURE','Taproot key-path signature already exists.');
          const tweaked=taprootTweakPrivKey(node.privateKey,input.tapMerkleRoot??p.leaves[i][0]?.root??new Uint8Array());
          try {const signature=schnorr.sign(signatureDigest(p,i,sighash),tweaked,randomBytes(32));p.tx.updateInput(i,{tapKeySig:concat(signature,...(sighash?[new Uint8Array([sighash])]:[]))},true);}finally{tweaked.fill(0);}
        } else {
          check(!Array.isArray(target.leafHashes)||target.leafHashes.length>0,'SIGNER','An empty Taproot leaf-hash list identifies key-path signing only.');
          check(matchingLeaves.length>0,'SIGNER','No supported Taproot leaf belongs to this signing task.');
          for(const leaf of matchingLeaves) {
            check(!(input.tapScriptSig??[]).some(([k])=>equal(k.pubKey,x)&&equal(k.leafHash,leaf.hash)),'SIGNATURE','This Taproot leaf already has the signer signature.');
            const signature=schnorr.sign(signatureDigest(p,i,sighash,leaf),node.privateKey,randomBytes(32));
            p.tx.updateInput(i,{tapScriptSig:[[{pubKey:x,leafHash:leaf.hash},concat(signature,...(sighash?[new Uint8Array([sighash])]:[]))]]},true);
          }
        }
      } else {
        check(!(input.partialSig??[]).some(([key])=>equal(key,pub)),'SIGNATURE','This input already has the signer signature.');
        check(p.tx.signIdx(node.privateKey,i,[0,1],new Uint8Array(32)),'SIGNATURE','Bitcoin signing failed.');
      }
      verifySignatures(p,i);signed.add(i);
    } finally {node.wipePrivateData();}
  }
  check(signed.size>0,'SIGNER','No unsigned input belongs to this signing task.');
  check(equal(before,p.tx.unsignedTx),'INTEGRITY','Bitcoin transaction changed while signing.');
  return {chain:'bitcoin',requestHash:p.review.requestHash,psbt:toBase64(p.tx.toPSBT()),signedInputs:signed.size,signedInputIndexes:[...signed]};
}
