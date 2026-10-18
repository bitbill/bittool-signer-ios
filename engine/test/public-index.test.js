import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {createHmac,createPrivateKey,createPublicKey} from 'node:crypto';
import {mnemonicToSeedSync} from '@scure/bip39';
import {HDKey} from '@scure/bip32';
import {HDNodeWallet,verifyMessage,getBytes,keccak256,recoverAddress} from 'ethers';
import {ed25519} from '@noble/curves/ed25519.js';
import {base58} from '@scure/base';
import {URDecoder} from '@ngraveio/bc-ur';
import {CryptoAccount,CryptoHDKey,CryptoMultiAccounts,extend} from '@keystonehq/bc-ur-registry';
import {Transaction,p2wpkh,p2wsh,p2ms} from '@scure/btc-signer';
import {RawPSBTV0} from '@scure/btc-signer/psbt.js';
import {derivePublicIndex,derivePublicAddresses,derivePublicKeyAt,BITCOIN_PROFILES} from '../src/public-index.js';
import {resolveSigningPlan,signPlanTask} from '../src/resolver.js';
import {createPublicPairing,decodeQR,encodeQR,encodeResponse,validateRequestTransport} from '../protocols.js';
import {bytesToHex,hexToBytes,toBase64,fromBase64,requestHash,concat,short} from '../src/util.js';

const MN='abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const MN2='legal winner thank year wave sausage worth useful legal winner thank yellow';
const A=derivePublicIndex({mnemonic:MN}),B=derivePublicIndex({mnemonic:MN2});
const wallets=[{localWalletId:'a',publicIndex:A},{localWalletId:'b',publicIndex:B}];
const clone=value=>JSON.parse(JSON.stringify(value));
const ur=frames=>{const decoder=new URDecoder();frames.forEach(frame=>decoder.receivePart(frame));assert.ok(decoder.isComplete());return decoder.resultUR();};
const pub=(index,chain,path)=>derivePublicKeyAt(index,chain,path);
const evm=(index=0)=>pub(A,'evm',"m/44'/60'/0'/0/"+index);
const message=key=>({chain:'evm',kind:'personal',message:'0x68656c6c6f',address:key.address});

test('public index contains precisely registered public trees and stable seed/passphrase identity',()=>{
  assert.deepEqual(A.bitcoinPublicNodes.map(n=>n.originPath),Object.values(BITCOIN_PROFILES));
  assert.equal(A.tronAddressIndex.length,100);assert.equal(A.solanaPublicKeys.length,3);
  // Vector for the BitTool-Signer/WalletKeyId/v1 domain separator.
  assert.equal(A.walletKeyId,'99d5d3536665b81e0e99ccbd2219e090c6efe01f9966e9e9a7419c23d6d80f96');
  assert.equal(derivePublicIndex({mnemonic:MN}).walletKeyId,A.walletKeyId);
  assert.notEqual(derivePublicIndex({mnemonic:MN,passphrase:'different seed'}).walletKeyId,A.walletKeyId);
  const serialized=JSON.stringify(A);for(const forbidden of ['xprv','mnemonic','privateKey','password','seed'])assert.equal(serialized.includes(forbidden),false);
  for(const node of [...A.bitcoinPublicNodes,A.evmAccountNode,A.tronAccountNode])assert.ok(node.depth>=3&&node.publicKey.length===66&&node.chainCode.length===64);
});

test('public address derivation matches published BIP86 vector and independent ethers HD derivation',()=>{
  const tap=derivePublicAddresses({publicIndex:A,chain:'bitcoin',profile:'taproot',count:2}).addresses;
  assert.equal(tap[0].address,'bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr');
  assert.equal(tap[0].publicKey.slice(2),'cc8a4bc64d897bddc5fbc2f670f7a8ba0b386779106cf1223c6fc5d7cd6fc115');
  assert.equal(tap[1].address,'bc1p4qhjn9zdvkux4e44uhx8tc55attvtyu358kutcqkudyccelu0was9fqzwh');
  for(const i of [0,8,99]){const key=evm(i),independent=HDNodeWallet.fromPhrase(MN,undefined,key.path);assert.equal(key.address,independent.address);assert.equal('0x'+key.publicKey,independent.publicKey);}
  const change=pub(A,'bitcoin',"m/86'/0'/0'/1/0");assert.equal(change.address,'bc1p3qkhfews2uk44qtvauqyr2ttdsw7svhkl9nkm9s9c3x4ax5h60wqwruhk7');
  assert.equal(A.tronAddressIndex[99].publicKey,HDNodeWallet.fromPhrase(MN,undefined,"m/44'/195'/0'/0/99").publicKey.slice(2));
  // TRON browsing is not capped at the 100 cached addresses: any non-hardened index derives from the account xpub.
  const tronPage=derivePublicAddresses({publicIndex:A,chain:'tron',start:99,count:20});
  assert.equal(tronPage.addresses.length,20);assert.equal(tronPage.hasMore,true);assert.equal(tronPage.nextIndex,119);
  assert.equal(tronPage.addresses[0].address,A.tronAddressIndex[99].address);
  for(const i of [100,4096,2147483647]){const key=pub(A,'tron',"m/44'/195'/0'/0/"+i);assert.equal('0x'+key.publicKey,HDNodeWallet.fromPhrase(MN,undefined,key.path).publicKey);}
  const lastPage=derivePublicAddresses({publicIndex:A,chain:'tron',start:2147483646,count:2});
  assert.equal(lastPage.addresses.length,2);assert.equal(lastPage.hasMore,false);
  assert.throws(()=>pub(A,'tron',"m/44'/195'/0'/0/2147483648"),/range/);
  assert.throws(()=>pub(A,'tron',"m/44'/195'/0'/1/0"),/range/);
  assert.throws(()=>derivePublicAddresses({publicIndex:A,chain:'bitcoin',profile:'multisig-native'}),/cosigner/);
  assert.throws(()=>derivePublicAddresses({publicIndex:A,chain:'evm',count:101}),/Invalid address page/);
  assert.throws(()=>pub(A,'evm',"m/44'/60'/1'/0/0"),/outside/);
  assert.throws(()=>pub(A,'evm',"m/44'/60'/0'/0/1'"),/non-hardened/);
  const changed=clone(A),wrongAccount=HDKey.fromMasterSeed(mnemonicToSeedSync(MN)).derive("m/44'/60'/1'");
  Object.assign(changed.evmAccountNode,{xpub:wrongAccount.publicExtendedKey,publicKey:bytesToHex(wrongAccount.publicKey),chainCode:bytesToHex(wrongAccount.chainCode),parentFingerprint:wrongAccount.parentFingerprint.toString(16).padStart(8,'0')});
  wrongAccount.wipePrivateData();
  assert.throws(()=>pub(changed,'evm',"m/44'/60'/0'/0/0"),/metadata does not match/);
});

test('all three Solana presets match independent Node crypto SLIP0010 implementation',()=>{
  const seed=mnemonicToSeedSync(MN),hmac=(key,data)=>createHmac('sha512',key).update(data).digest();
  for(const item of A.solanaPublicKeys){
    let I=hmac('ed25519 seed',seed);
    for(const part of item.path.split('/').slice(1)){const index=Buffer.alloc(4);index.writeUInt32BE(Number(part.slice(0,-1))+0x80000000);I=hmac(I.subarray(32),Buffer.concat([Buffer.from([0]),I.subarray(0,32),index]));}
    const privateDER=Buffer.concat([Buffer.from('302e020100300506032b657004220420','hex'),I.subarray(0,32)]);
    const key=createPrivateKey({key:privateDER,format:'der',type:'pkcs8'}),publicDER=createPublicKey(key).export({format:'der',type:'spki'});
    assert.equal(publicDER.subarray(-32).toString('hex'),item.publicKey);assert.equal(base58.encode(publicDER.subarray(-32)),item.address);
  }
  assert.deepEqual(A.solanaPublicKeys.map(k=>k.path),["m/44'/501'/0'/0'","m/44'/501'/0'","m/44'/501'"]);
});

test('Bitcoin exports the account xpub (the only crypto-account form wallets import) or the first address',()=>{
  for(const [profile,expressions] of [['native',['wpkh']],['nested',['sh','wpkh']],['legacy',['pkh']]]){
    const node=A.bitcoinPublicNodes.find(n=>n.scriptProfile===profile);
    const accountQR=createPublicPairing({publicIndex:A,chain:'bitcoin',profile,outputMode:'accountXpub'});
    const output=CryptoAccount.fromCBOR(ur(accountQR.frames).cbor).getOutputDescriptors()[0],hd=output.getHDKey();
    assert.deepEqual(output.getScriptExpressions().map(x=>x.getExpression()),expressions);
    assert.equal(hd.getBip32Key(),node.xpub);assert.equal(hd.getChildren(),undefined);assert.equal(hd.getOrigin().getPath(),node.originPath.slice(2));
    assert.ok(hd.getChainCode(),'An account key always carries its chain code.');
    // Account XPUB is the default: it is what Sparrow, BlueWallet and other HD watch-only wallets import.
    assert.deepEqual(createPublicPairing({publicIndex:A,chain:'bitcoin',profile}).frames,accountQR.frames);assert.equal(createPublicPairing({publicIndex:A,chain:'bitcoin',profile}).outputMode,'accountXpub');
    const leaf=pub(A,'bitcoin',node.originPath+'/0/0');assert.equal(accountQR.address,leaf.address);
    const addressQR=createPublicPairing({publicIndex:A,chain:'bitcoin',profile,outputMode:'address'});assert.deepEqual(addressQR.frames,[leaf.address]);assert.equal(addressQR.text,leaf.address);
    // A crypto-account holding only a leaf key (no chain code) breaks the standard and every wallet's parser.
    assert.throws(()=>createPublicPairing({publicIndex:A,chain:'bitcoin',profile,outputMode:'publicKey'}),/Unsupported Bitcoin export mode/);
  }
  // Independent registry CBOR parser confirms standard BCR-2020-010 tag 409;
  // this old registry release has no named Taproot ScriptExpression wrapper.
  extend.cbor.patchTags([409]);
  const tapNode=A.bitcoinPublicNodes.find(n=>n.scriptProfile==='taproot');
  const tap=createPublicPairing({publicIndex:A,chain:'bitcoin',profile:'taproot'}),decoded=extend.decodeToDataItem(ur(tap.frames).cbor).getData();
  assert.equal(decoded[2][0].getTag(),409);assert.equal(decoded[2][0].getData().getTag(),303);
  assert.equal(decoded[2][0].getData().getData()[3].toString('hex'),tapNode.publicKey);
  assert.equal(decoded[2][0].getData().getData()[4].toString('hex'),tapNode.chainCode);
  assert.equal(tap.address,'bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr');
  for(const profile of ['multisig-native','multisig-nested']){
    const qr=createPublicPairing({publicIndex:A,chain:'bitcoin',profile}),output=CryptoAccount.fromCBOR(ur(qr.frames).cbor).getOutputDescriptors()[0];
    assert.equal(output.getHDKey().getBip32Key(),A.bitcoinPublicNodes.find(n=>n.scriptProfile===profile).xpub);
    assert.equal(output.getMultiKey(),undefined);assert.equal(qr.address,'');assert.equal(qr.outputMode,'accountXpub');
    assert.throws(()=>createPublicPairing({publicIndex:A,chain:'bitcoin',profile,outputMode:'address'}),/Unsupported/);
  }
  assert.throws(()=>createPublicPairing({publicIndex:A,chain:'bitcoin',profile:'sparrow'}),/Unsupported/);
});

test('EVM exports only its account, SOL only the selected preset, TRON only one raw address',()=>{
  const eth=createPublicPairing({publicIndex:A,chain:'evm'}),node=CryptoHDKey.fromCBOR(ur(eth.frames).cbor);
  assert.equal(node.getBip32Key(),A.evmAccountNode.xpub);assert.equal(node.getChildren().getPath(),'0/*');
  for(const item of A.solanaPublicKeys){const qr=createPublicPairing({publicIndex:A,chain:'solana',profile:item.profile}),keys=CryptoMultiAccounts.fromCBOR(ur(qr.frames).cbor).getKeys();assert.equal(keys.length,1);assert.equal(keys[0].getKey().toString('hex'),item.publicKey);assert.equal(qr.address,item.address);}
  for(const i of [0,99]){const qr=createPublicPairing({publicIndex:A,chain:'tron',index:i});assert.deepEqual(qr.frames,[A.tronAddressIndex[i].address]);assert.equal(qr.text,qr.frames[0]);}
  for(const i of [100,123456,2147483647]){const qr=createPublicPairing({publicIndex:A,chain:'tron',index:i});assert.equal(qr.path,"m/44'/195'/0'/0/"+i);assert.deepEqual(qr.frames,[pub(A,'tron',qr.path).address]);}
  for(const i of [-1,1.5,2147483648])assert.throws(()=>createPublicPairing({publicIndex:A,chain:'tron',index:i}),/index/);
  assert.throws(()=>createPublicPairing({publicIndex:A,chain:'evm',index:1,outputMode:'address'}),/index/);
});

test('public EVM resolver supports paths, limited fallback, collisions, missing metadata and duplicate identities',()=>{
  assert.equal(resolveSigningPlan({request:{chain:'evm',kind:'personal',message:'0x6869',publicKey:evm(0).publicKey.slice(2)},wallets}).status,'invalid');
  assert.equal(resolveSigningPlan({request:{chain:'evm',kind:'personal',message:'0x6869',publicKey:evm(0).publicKey},wallets}).status,'ready');
  assert.equal(resolveSigningPlan({request:message(evm(0)),wallets}).tasks[0].localWalletId,'a');
  assert.equal(resolveSigningPlan({request:message(evm(8)),wallets}).status,'noMatch');
  const request={...message(evm(8)),path:evm(8).path,masterFingerprint:A.masterFingerprint};
  assert.equal(resolveSigningPlan({request,wallets:[...wallets].reverse()}).tasks[0].paths[0],evm(8).path);
  assert.equal(resolveSigningPlan({request:{...request,address:evm(0).address},wallets}).status,'noMatch');
  assert.equal(resolveSigningPlan({request:{chain:'evm',kind:'personal',message:'0x6869',path:evm(0).path},wallets}).status,'missingSigner');
  const metadata={chain:'evm',kind:'personal',message:'0x6869',path:evm(0).path,masterFingerprint:A.masterFingerprint};
  assert.equal(resolveSigningPlan({request:metadata,wallets}).status,'ready');
  const collision=clone(B);collision.masterFingerprint=A.masterFingerprint;
  assert.equal(resolveSigningPlan({request:metadata,wallets:[wallets[0],{localWalletId:'collision',publicIndex:collision}]}).status,'ambiguous');
  assert.equal(resolveSigningPlan({request:message(evm(0)),wallets:[wallets[0],{localWalletId:'duplicate',publicIndex:A}]}).status,'ambiguous');
  assert.equal(resolveSigningPlan({request:message(evm(0)),wallets:[{localWalletId:'old',publicMetadataStatus:'needsCompletion'}]}).status,'setupRequired');
});

test('signing plan binds immutable QR bytes, key identity, task contents and exact nonzero EVM path',()=>{
  const request={...message(evm(8)),path:evm(8).path},plan=resolveSigningPlan({request,wallets});assert.equal(plan.status,'ready');
  const out=signPlanTask({request,plan,taskId:plan.tasks[0].id,mnemonic:MN});assert.equal(verifyMessage(getBytes(request.message),'0x'+out.signature),evm(8).address);
  assert.throws(()=>signPlanTask({request,plan,taskId:plan.tasks[0].id,mnemonic:MN2}),/decrypted wallet/);
  assert.throws(()=>signPlanTask({request:{...request,message:'0x686a'},plan,taskId:plan.tasks[0].id,mnemonic:MN}),/changed/);
  const altered=clone(plan);altered.tasks[0].targets[0].path=evm(0).path;assert.throws(()=>signPlanTask({request,plan:altered,taskId:plan.tasks[0].id,mnemonic:MN}),/changed/);
  const {planHash,...body}=altered;altered.planHash=requestHash(body);assert.throws(()=>signPlanTask({request,plan:altered,taskId:plan.tasks[0].id,mnemonic:MN}),/targets/);
  const fixture=JSON.parse(fs.readFileSync(new URL('./fixtures/evm-public-ui.json',import.meta.url)));
  const qr=decodeQR({frames:fixture.frames}).request;validateRequestTransport(qr);assert.equal(resolveSigningPlan({request:qr,wallets}).status,'ready');
  assert.throws(()=>validateRequestTransport({...qr,message:'0x00'}),/original QR/);
});

function bitcoinRequest(entries,{derivations=true,multisig=false}={}){
  const tx=new Transaction(),all=entries.map(({cache,path})=>pub(cache,'bitcoin',path));
  const groups=multisig?[all]:all.map(item=>[item]);
  groups.forEach((keys,i)=>{
    const payment=multisig?p2wsh(p2ms(2,keys.map(item=>hexToBytes(item.publicKey)))):p2wpkh(hexToBytes(keys[0].publicKey));
    const prev=new Transaction();prev.addInput({txid:new Uint8Array(32).fill(i+1),index:0});prev.addOutput({script:payment.script,amount:100000n});
    const input={txid:prev.id,index:0,nonWitnessUtxo:prev.unsignedTx,witnessUtxo:{script:payment.script,amount:100000n},...(multisig?{witnessScript:payment.witnessScript}:{})};
    if(derivations)input.bip32Derivation=keys.map(item=>[hexToBytes(item.publicKey),{fingerprint:parseInt(item.masterFingerprint,16),path:item.path.split('/').slice(1).map(x=>Number(x.replace("'",''))+(x.endsWith("'")?0x80000000:0))}]);
    tx.addInput(input);tx.addOutput({script:p2wpkh(hexToBytes(all[0].publicKey)).script,amount:90000n});
  });
  return {chain:'bitcoin',psbt:toBase64(tx.toPSBT())};
}

test('PSBT public matching fixes two wallet tasks, preserves partial signatures, and never scans beyond zero fallback',()=>{
  const request=bitcoinRequest([{cache:A,path:"m/84'/0'/0'/0/8"},{cache:A,path:"m/84'/0'/0'/1/3"},{cache:B,path:"m/84'/0'/0'/0/0"}]);
  const plan=resolveSigningPlan({request,wallets});assert.equal(plan.status,'ready');assert.equal(plan.tasks.length,2);assert.deepEqual(plan.tasks[0].inputs,[0,1]);
  const first=signPlanTask({request,plan,taskId:plan.tasks[0].id,mnemonic:MN});
  const second=signPlanTask({request,plan,taskId:plan.tasks[1].id,mnemonic:MN2,previousResult:first});
  const tx=Transaction.fromPSBT(fromBase64(second.psbt));assert.equal(tx.getInput(0).partialSig.length,1);assert.equal(tx.getInput(2).partialSig.length,1);tx.finalize();assert.ok(tx.extract().length>0);
  assert.equal(second.requestHash,plan.requestHash);assert.deepEqual(second.completedTaskIds,plan.tasks.map(t=>t.id));
  for(const index of [0,1]){
    const fallback=bitcoinRequest([{cache:A,path:"m/84'/0'/0'/0/"+index}],{derivations:false});
    const match=resolveSigningPlan({request:fallback,wallets});assert.equal(match.status,index===0?'ready':'noMatch');
  }
  const multisig=bitcoinRequest([{cache:A,path:"m/48'/0'/0'/2'/0/0"},{cache:B,path:"m/48'/0'/0'/2'/0/0"}],{derivations:false,multisig:true});
  const decoded=decodeQR({frames:encodeQR({type:'crypto-psbt',payload:multisig.psbt,encoding:'base64'}).frames}).request;
  const multiPlan=resolveSigningPlan({request:decoded,wallets});assert.equal(multiPlan.tasks.length,2);
  const a=signPlanTask({request:decoded,plan:multiPlan,taskId:multiPlan.tasks[0].id,mnemonic:MN});
  const b=signPlanTask({request:decoded,plan:multiPlan,taskId:multiPlan.tasks[1].id,mnemonic:MN2,previousResult:a});
  const final=decodeQR({frames:encodeResponse({request:decoded,result:b}).frames}).request;
  const full=Transaction.fromPSBT(fromBase64(final.psbt));assert.equal(full.getInput(0).partialSig.length,2);full.finalize();assert.ok(full.extract().length>0);
});

test('TRON public reference request and response match the pinned upstream wire fixture',()=>{
  const fixture=JSON.parse(fs.readFileSync(new URL('./fixtures/keystone-tron-public.json',import.meta.url)));
  const {request}=decodeQR({frames:[fixture.requestUR]});assert.equal(request.chain,'tron');assert.equal(request.kind,'transaction');assert.equal(request.transaction.raw_data_hex,fixture.rawDataHex);assert.equal(request.transport.requestId,fixture.requestId);
  const response=encodeQR({type:'tron-signature',payload:fixture.signatureHex,requestId:fixture.requestId,fragmentLength:800});assert.equal(response.frames[0].toLowerCase(),fixture.signatureUR);
  assert.throws(()=>encodeQR({type:'tron-signature',payload:'aa'.repeat(64),requestId:fixture.requestId}),/signature size/);
});

test('Solana message matching handles optional address and exact presets; transaction signer slots are required',()=>{
  for(const key of A.solanaPublicKeys){
    const request={chain:'solana',kind:'message',message:toBase64(new TextEncoder().encode('Public Solana fixture')),path:key.path,masterFingerprint:A.masterFingerprint};
    const plan=resolveSigningPlan({request,wallets});assert.equal(plan.status,'ready');assert.equal(plan.tasks[0].paths[0],key.path);
    const result=signPlanTask({request,plan,taskId:plan.tasks[0].id,mnemonic:MN});assert.ok(ed25519.verify(hexToBytes(result.signature),fromBase64(request.message),hexToBytes(key.publicKey)));
    assert.equal(resolveSigningPlan({request:{...request,path:undefined,address:key.address,masterFingerprint:undefined},wallets}).status,'invalid'); // JSON callers must omit absent keys.
    const withoutPath={chain:'solana',kind:'message',message:request.message,address:key.address};assert.equal(resolveSigningPlan({request:withoutPath,wallets}).status,'ready');
  }
  const signer=A.solanaPublicKeys[0],recipient=A.solanaPublicKeys[1],other=ed25519.getPublicKey(new Uint8Array(32).fill(7));
  const keys=[other,hexToBytes(signer.publicKey),hexToBytes(recipient.publicKey),new Uint8Array(32)];
  const instruction=concat(new Uint8Array([3]),short(2),new Uint8Array([0,2]),short(12),new Uint8Array([2,0,0,0,1,0,0,0,0,0,0,0]));
  for(const version of ['legacy','v0']){
    const bytes=concat(...(version==='v0'?[new Uint8Array([128])]:[]),new Uint8Array([2,1,1]),short(4),...keys,new Uint8Array(32).fill(9),short(1),instruction,...(version==='v0'?[short(0)]:[]));
    const request={chain:'solana',kind:'transaction',message:toBase64(bytes),address:signer.address,signatures:[toBase64(ed25519.sign(bytes,new Uint8Array(32).fill(7))),null]};
    const plan=resolveSigningPlan({request,wallets});assert.equal(plan.status,'ready');assert.equal(plan.tasks[0].targets[0].signerSlot,1);
    const result=signPlanTask({request,plan,taskId:plan.tasks[0].id,mnemonic:MN});assert.equal(result.signatures[0],request.signatures[0]);assert.ok(ed25519.verify(fromBase64(result.signatures[1]),bytes,hexToBytes(signer.publicKey)));
    assert.equal(resolveSigningPlan({request:{...request,address:recipient.address},wallets}).status,'noMatch');
  }
});

test('TRON matches the 100 cached addresses without a path, any index with a path, and signs with TIP191 bytes',()=>{
  for(const index of [0,99]){
    const key=A.tronAddressIndex[index],request={chain:'tron',kind:'message',message:'68656c6c6f',messageStandard:'TIP191',address:key.address};
    const plan=resolveSigningPlan({request,wallets});assert.equal(plan.status,'ready');assert.equal(plan.tasks[0].paths[0],key.path);
    const result=signPlanTask({request,plan,taskId:plan.tasks[0].id,mnemonic:MN});
    const digest=keccak256(Buffer.concat([Buffer.from('\x19TRON Signed Message:\n5'),Buffer.from('hello')]));
    assert.equal(recoverAddress(digest,'0x'+result.signature),HDNodeWallet.fromPhrase(MN,undefined,key.path).address);
  }
  const ownerOnly={chain:'tron',kind:'message',message:'68656c6c6f',operatedAccountAddress:A.tronAddressIndex[0].address};
  assert.equal(resolveSigningPlan({request:ownerOnly,wallets}).status,'missingSigner');
  // A path (always present in tron-sign-request) reaches indexes beyond the cached 0–99.
  for(const index of [100,50000]){
    const path="m/44'/195'/0'/0/"+index,request={chain:'tron',kind:'message',message:'68656c6c6f',messageStandard:'TIP191',path,masterFingerprint:A.masterFingerprint};
    const plan=resolveSigningPlan({request,wallets});assert.equal(plan.status,'ready');assert.equal(plan.tasks[0].paths[0],path);
    const result=signPlanTask({request,plan,taskId:plan.tasks[0].id,mnemonic:MN});
    const digest=keccak256(Buffer.concat([Buffer.from('\x19TRON Signed Message:\n5'),Buffer.from('hello')]));
    assert.equal(recoverAddress(digest,'0x'+result.signature),HDNodeWallet.fromPhrase(MN,undefined,path).address);
    const withAddress={...request,address:pub(A,'tron',path).address};assert.equal(resolveSigningPlan({request:withAddress,wallets}).status,'ready');
  }
  // Address-only requests are still matched against the cached indexes only.
  assert.equal(resolveSigningPlan({request:{chain:'tron',kind:'message',message:'68656c6c6f',address:pub(A,'tron',"m/44'/195'/0'/0/100").address},wallets}).status,'noMatch');
  const request={chain:'tron',kind:'message',message:'68656c6c6f',path:"m/44'/195'/0'/0/100",masterFingerprint:A.masterFingerprint};
  const conflicting={...request,path:A.tronAddressIndex[99].path,address:A.tronAddressIndex[0].address};assert.equal(resolveSigningPlan({request:conflicting,wallets}).status,'noMatch');
  assert.equal(resolveSigningPlan({request:{...request,path:"m/44'/195'/0'/1/100"},wallets}).status,'noMatch');
});

test('PSBT plan rejects tampered accumulation and limits absent derivation cosigners to explicit scripts',()=>{
  const request=bitcoinRequest([{cache:A,path:"m/84'/0'/0'/0/0"},{cache:B,path:"m/84'/0'/0'/0/0"}]);
  const plan=resolveSigningPlan({request,wallets}),first=signPlanTask({request,plan,taskId:plan.tasks[0].id,mnemonic:MN});
  const second=()=>signPlanTask({request,plan,taskId:plan.tasks[1].id,mnemonic:MN2,previousResult:first});
  const changed=RawPSBTV0.decode(fromBase64(first.psbt));delete changed.inputs[1].bip32Derivation;first.psbt=toBase64(RawPSBTV0.encode(changed));
  assert.throws(second,/metadata/);
  const cosignerAsSingle=bitcoinRequest([{cache:A,path:"m/48'/0'/0'/2'/0/0"}],{derivations:false});assert.equal(resolveSigningPlan({request:cosignerAsSingle,wallets}).status,'noMatch');
});
