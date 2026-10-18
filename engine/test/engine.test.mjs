import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { execute, dispatch } from '../src/index.js';
import { withSeed, withKey, PATHS, deriveAccounts } from '../src/keys.js';
import { concat, utf8, bytesToHex, hexToBytes, toBase64, short, fromBase64 } from '../src/util.js';
import { Transaction as BitcoinTx, p2wpkh, p2wsh, p2ms, p2tr, p2pkh } from '@scure/btc-signer';
import { secp256k1, schnorr } from '@noble/curves/secp256k1.js';
import { ed25519 } from '@noble/curves/ed25519.js';
import { sha256 } from '@noble/hashes/sha2.js';
import { base58, base58check } from '@scure/base';
import { Transaction, verifyMessage, verifyTypedData, Interface, TypedDataEncoder, getBytes, recoverAddress } from 'ethers';
const MN='abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const MN2='legal winner thank year wave sausage worth useful legal winner thank yellow';
const accounts=deriveAccounts({mnemonic:MN}).accounts;
const req=(operation,more)=>execute({operation,...more});
const sign=(request,more={})=>req('sign',{request,mnemonic:MN,...more});
const review=request=>req('review',{request});
const fails=(f,code)=>assert.throws(f,e=>e.code===code,`Expected ${code}`);
const u32=n=>{const b=new Uint8Array(4);new DataView(b.buffer).setUint32(0,n,true);return b;};
const u64=n=>{const b=new Uint8Array(8);new DataView(b.buffer).setBigUint64(0,BigInt(n),true);return b;};
function nodeInfo(mn=MN,path=PATHS.bitcoin){return withSeed(mn,'',(_s,root)=>{const node=root.derive(path);return {publicKey:node.publicKey,privateKey:node.privateKey,fingerprint:root.fingerprint,path:path.split('/').slice(1).map(x=>Number(x.replace("'",''))+(x.endsWith("'")?0x80000000:0))};});}
function btcRequest({multisig=false,taproot=false,witnessOnly=false,sighash=undefined,version=0}={}){
 const a=nodeInfo(MN,taproot?"m/86'/0'/0'/0/0":PATHS.bitcoin),b=nodeInfo(MN2);
 const payment=multisig?p2wsh(p2ms(2,[a.publicKey,b.publicKey])):taproot?p2tr(a.publicKey.slice(1)):p2wpkh(a.publicKey);
 const prev=new BitcoinTx();prev.addOutput({script:payment.script,amount:100000n});prev.addInput({txid:new Uint8Array(32),index:0});
 const tx=new BitcoinTx({PSBTVersion:version});let input={txid:prev.id,index:0,witnessUtxo:{script:payment.script,amount:100000n}};
 if(!witnessOnly)input.nonWitnessUtxo=prev.unsignedTx;
 if(multisig)input.witnessScript=payment.witnessScript;
 if(taproot){input.tapInternalKey=a.publicKey.slice(1);input.tapBip32Derivation=[[a.publicKey.slice(1),{hashes:[],der:{fingerprint:a.fingerprint,path:a.path}}]];}
 else input.bip32Derivation=[[a.publicKey,{fingerprint:a.fingerprint,path:a.path}],...(multisig?[[b.publicKey,{fingerprint:b.fingerprint,path:b.path}]]:[])];
 if(sighash!==undefined)input.sighashType=sighash;
 tx.addInput(input);tx.addOutput({script:p2wpkh(b.publicKey).script,amount:90000n});
 return {request:{chain:'bitcoin',psbt:toBase64(tx.toPSBT()),network:'mainnet'},tx,a,b,payment};
}
const simpleEVM=()=>({chain:'evm',kind:'transaction',transaction:{type:2,chainId:1,nonce:7,to:'0x000000000000000000000000000000000000dead',value:'1000000000000000',gasLimit:'21000',maxFeePerGas:'30000000000',maxPriorityFeePerGas:'1000000000'}});
function pbVar(n){n=BigInt(n);const b=[];do{const v=Number(n&127n);n>>=7n;b.push(v|(n?128:0));}while(n);return new Uint8Array(b);}
const pbN=(k,n)=>concat(pbVar(k*8),pbVar(n));const pbB=(k,b)=>concat(pbVar(k*8+2),pbVar(b.length),b);
function tronRequest({permission=0,amount=1000000,owner=accounts[2].address,contractType=1,contractValue,signatures=[]}={}){
 const address=base58check(sha256).decode(owner),to=base58check(sha256).decode('TJRabPrwbZy45sbavfcjinPJC18kjpRTv8');
 const value=contractValue??concat(pbB(1,address),pbB(2,to),pbN(3,amount));
 const name=contractType===46?'AccountPermissionUpdateContract':'TransferContract';
 const any=concat(pbB(1,utf8('type.googleapis.com/protocol.'+name)),pbB(2,value));
 const contract=concat(pbN(1,contractType),pbB(2,any),...(permission?[pbN(5,permission)]:[]));
 const raw=concat(pbB(1,new Uint8Array([0,1])),pbB(4,new Uint8Array(8)),pbN(8,1800000060000),pbB(11,contract),pbN(14,1800000000000));
 return {chain:'tron',kind:'transaction',transaction:{raw_data_hex:bytesToHex(raw),txID:bytesToHex(sha256(raw)),signature:signatures}};
}
function solRequest({version='legacy',alt=false,unknown=false,multisig=false}={}){
 const pub=base58.decode(accounts[3].address),other=ed25519.getPublicKey(new Uint8Array(32).fill(7)),recipient=new Uint8Array(32).fill(4),system=new Uint8Array(32);
 const keys=multisig?[other,pub,recipient,system]:[pub,recipient,system];
 const header=new Uint8Array([multisig?2:1,0,1]);
 const instruction=concat(new Uint8Array([keys.length-1]),short(2),new Uint8Array(multisig?[1,2]:[0,1]),short(12),u32(2),u64(123456789));
 if(unknown)keys[keys.length-1]=new Uint8Array(32).fill(99);
 const msg=concat(...(version==='v0'?[new Uint8Array([128])]:[]),header,short(keys.length),...keys,new Uint8Array(32).fill(5),short(1),instruction,...(version==='v0'?[short(alt?1:0)]:[]));
 const request={chain:'solana',kind:'transaction',message:toBase64(msg)};
 if(multisig)request.signatures=[toBase64(ed25519.sign(msg,new Uint8Array(32).fill(7))),null];
 return request;
}

test('BIP39 entropy/checksum and four chain known address vectors',()=>{
 assert.equal(req('mnemonic',{entropy:'00'.repeat(16)}).mnemonic,MN);
 assert.equal(req('validateMnemonic',{mnemonic:MN}).valid,true);
 assert.equal(req('validateMnemonic',{mnemonic:MN.replace('about','abandon')}).valid,false);
 assert.deepEqual(accounts.map(x=>x.address),['bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu','0x9858EfFD232B4033E47d90003D41EC34EcaEda94','TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdH','HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk']);
 assert.equal(req('deriveAccounts',{mnemonic:MN}).fingerprint,'73c5da0a');
 assert.notDeepEqual(req('deriveAccounts',{mnemonic:MN,passphrase:'TREZOR'}).accounts.map(x=>x.address),accounts.map(x=>x.address));
 assert.ok(!JSON.stringify(accounts).includes('private'));
});
test('BIP39 official NFKD passphrase handling',()=>{assert.deepEqual(req('deriveAccounts',{mnemonic:MN,passphrase:'é'}),req('deriveAccounts',{mnemonic:MN,passphrase:'e\u0301'}));});
test('EVM EIP1559 signs and independently verifies curve signature',()=>{
 const request=simpleEVM(),out=sign(request),tx=Transaction.from(out.serializedTransaction);
 assert.equal(tx.from,accounts[1].address);assert.equal(tx.nonce,7);assert.equal(tx.value,1000000000000000n);
 assert.ok(secp256k1.verify(getBytes(tx.signature.r+tx.signature.s.slice(2)),getBytes(tx.unsignedHash),hexToBytes(accounts[1].publicKey),{prehash:false}));
 assert.equal(review(request).requestHash,out.requestHash);
});
test('EVM legacy signature preserves large EIP155 v',()=>{const request=simpleEVM();request.transaction={chainId:42161,type:0,nonce:0,gasLimit:'21000',gasPrice:'1',to:request.transaction.to,value:'1'};const out=sign(request);assert.ok(BigInt(out.signatureV)>255n);assert.equal(Transaction.from(out.serializedTransaction).chainId,42161n);});
test('EVM personal and EIP712 known Mail hash',()=>{
 const request={chain:'evm',kind:'personal',message:bytesToHex(utf8('Hello BitTool Signer'))};const out=sign(request);assert.equal(verifyMessage(utf8('Hello BitTool Signer'),'0x'+out.signature),accounts[1].address);
 const typedData={types:{Person:[{name:'name',type:'string'},{name:'wallet',type:'address'}],Mail:[{name:'from',type:'Person'},{name:'to',type:'Person'},{name:'contents',type:'string'}]},primaryType:'Mail',domain:{name:'Ether Mail',version:'1',chainId:1,verifyingContract:'0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC'},message:{from:{name:'Cow',wallet:'0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826'},to:{name:'Bob',wallet:'0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB'},contents:'Hello, Bob!'}};
 const signed=sign({chain:'evm',kind:'typedData',typedData});assert.equal(signed.digest,'0xbe609aee343fb3c4b28e1df9e632fca64fcfaede20f02e86244efddf30957bd2');assert.equal(verifyTypedData(typedData.domain,typedData.types,typedData.message,'0x'+signed.signature),accounts[1].address);
});
test('EVM raw token/NFT units are decoded without trusting symbols',()=>{
 const abi=new Interface(['function approve(address spender,uint256 amount)','function safeTransferFrom(address from,address to,uint256 tokenId)']);
 const request=simpleEVM();request.transaction.data=abi.encodeFunctionData('approve',[request.transaction.to,(1n<<256n)-1n]);
 assert.ok(review(request).warnings.some(w=>w.includes('UNLIMITED')));assert.ok(sign(request).signature);
 request.transaction.data=abi.encodeFunctionData('safeTransferFrom',[accounts[1].address,request.transaction.to,42]);assert.ok(review(request).fields.some(f=>f.value==='42'));
});
test('EVM rejects chain confusion, wrong signer and tampering; opaque calldata has explicit risk',()=>{
 const r=simpleEVM();fails(()=>sign({...r,chainId:56}),'CHAIN_ID');fails(()=>sign({...r,address:r.transaction.to}),'SIGNER');
 assert.equal(review({...r,transaction:{...r.transaction,data:'0x12345678'}}).decodeStatus,'opaque');assert.equal(review({...r,transaction:{...r.transaction,data:'0x12345678'}}).riskLevel,'high');
 fails(()=>sign(r,{reviewedHash:'00'.repeat(32)}),'INTEGRITY');fails(()=>sign({...r,masterFingerprint:'00000000'}),'FINGERPRINT');
 fails(()=>sign({...r,transaction:{...r.transaction,chainId:0}}),'CHAIN_ID');
});
test('Bitcoin PSBT v0/v2 preserve unsigned transaction and verify ECDSA',()=>{
 for(const version of [0,2]){const {request,a,tx,payment}=btcRequest({version});const out=sign(request),signed=BitcoinTx.fromPSBT(fromBase64(out.psbt));
 assert.deepEqual(signed.unsignedTx,tx.unsignedTx);assert.equal(out.signedInputs,1);
 const rawSig=signed.getInput(0).partialSig[0][1];const der=secp256k1.Signature.fromBytes(rawSig.slice(0,-1),'der').toBytes('compact');
 const hash=signed.preimageWitnessV0(0,p2pkh(a.publicKey).script,1,100000n);assert.ok(secp256k1.verify(der,hash,a.publicKey,{prehash:false}));signed.finalize();assert.ok(signed.extract().length>0);
 }
});
test('Bitcoin multisig incrementally preserves other cosigner signature',()=>{
 const {request,b}=btcRequest({multisig:true});const first=sign(request);const tx1=BitcoinTx.fromPSBT(fromBase64(first.psbt));const sig1=tx1.getInput(0).partialSig[0][1];
 const second=sign({...request,psbt:first.psbt},{mnemonic:MN2});const tx2=BitcoinTx.fromPSBT(fromBase64(second.psbt));assert.equal(tx2.getInput(0).partialSig.length,2);assert.ok(tx2.getInput(0).partialSig.some(p=>bytesToHex(p[1])===bytesToHex(sig1)));tx2.finalize();assert.ok(tx2.extract().length>0);
});
test('Bitcoin Taproot key path signs and finalizes',()=>{const {request}=btcRequest({taproot:true});const out=sign(request);const tx=BitcoinTx.fromPSBT(fromBase64(out.psbt));assert.equal(tx.getInput(0).tapKeySig.length,64);tx.finalize();assert.ok(tx.extract().length>0);});
test('Bitcoin refuses forged fee context and weak sighash',()=>{fails(()=>review(btcRequest({witnessOnly:true}).request),'PREVOUT');fails(()=>review(btcRequest({sighash:0x81}).request),'SIGHASH');const r=btcRequest().request;fails(()=>sign({...r,network:'testnet'}),'NETWORK');});
test('TRON txID and signature are bound to protobuf bytes',()=>{const request=tronRequest();const out=sign(request);assert.equal(out.txID,request.transaction.txID);assert.equal(out.signedTransaction.raw_data.contract[0].parameter.value.amount,1000000);const sig=hexToBytes(out.signature);assert.ok(secp256k1.verify(sig.slice(0,64),hexToBytes(out.txID),hexToBytes(accounts[2].publicKey),{prehash:false}));assert.ok(review(request).fields.some(f=>f.label==='Amount (TRX)'&&f.value==='1'));});
test('TRON refuses txID/JSON mismatch and preserves multisig',()=>{
 const r=tronRequest();fails(()=>sign({...r,transaction:{...r.transaction,txID:'00'.repeat(32)}}),'INTEGRITY');
 const out=sign(r);const manipulated=structuredClone(out.signedTransaction);manipulated.raw_data.contract[0].parameter.value.amount=2000000;fails(()=>sign({...r,transaction:manipulated}),'INTEGRITY');
 const multi=tronRequest({permission:2});const first=sign(multi);const second=sign({...multi,transaction:first.signedTransaction},{mnemonic:MN2});assert.equal(second.signedTransaction.signature.length,2);assert.equal(second.signedTransaction.signature[0],first.signature);
 fails(()=>sign({...multi,transaction:first.signedTransaction}),'SIGNATURE');
});
test('TRON AccountPermissionUpdate displays threshold and keys from bytes',()=>{
 const addr=base58check(sha256).decode(accounts[2].address);const key=concat(pbB(1,addr),pbN(2,1));const perm=concat(pbB(3,utf8('owner')),pbN(4,1),pbB(7,key));const value=concat(pbB(1,addr),pbB(2,perm));
 const r=tronRequest({contractType:46,contractValue:value});assert.ok(review(r).warnings.some(w=>w.includes('HIGH RISK')));assert.ok(sign(r).signature);
});
test('Solana legacy/v0 signatures verify and preserve exact message',()=>{
 for(const version of ['legacy','v0']){const r=solRequest({version});const out=sign(r);assert.ok(ed25519.verify(hexToBytes(out.signature),fromBase64(r.message),base58.decode(accounts[3].address)));assert.ok(fromBase64(out.serializedTransaction).length>fromBase64(r.message).length);}
});
test('Solana multisig adds correct slot and preserves other signer',()=>{
 const r=solRequest({multisig:true});const out=sign(r);assert.equal(out.signerIndex,1);assert.equal(out.signatures[0],r.signatures[0]);assert.equal(out.signatures.length,2);
});
test('Solana refuses ALT, bad signatures and wrong signer; unknown programs are marked high risk',()=>{
 fails(()=>review(solRequest({version:'v0',alt:true})),'LOOKUP_TABLE');assert.equal(review(solRequest({unknown:true})).riskLevel,'high');assert.equal(review(solRequest({unknown:true})).decodeStatus,'opaque');
 const r=solRequest();fails(()=>sign({...r,address:base58.encode(new Uint8Array(32))}),'SIGNER');fails(()=>review({...r,signatures:[toBase64(new Uint8Array(64).fill(1))]}),'SIGNATURE');
});
test('dispatch rejects oversized/malformed input without reflecting secrets',()=>{const r=JSON.parse(dispatch('{"operation":"sign","mnemonic":"SECRET","request":{}}'));assert.equal(r.ok,false);assert.ok(!JSON.stringify(r).includes('SECRET'));assert.equal(JSON.parse(dispatch('x'.repeat(1048577))).error.code,'LIMIT');});
test('browser bundle operates in a JavaScriptCore-like isolated environment',()=>{
 let source;try{source=readFileSync(new URL('../../BitToolSigner/Resources/signer.js',import.meta.url),'utf8');}catch{return;}
 const context=vm.createContext({});vm.runInContext(source,context,{timeout:20000});
 const result=JSON.parse(context.BitToolSignerEngine.dispatch(JSON.stringify({operation:'deriveAccounts',mnemonic:MN})));
 assert.equal(result.ok,true);assert.equal(result.result.accounts[1].address,accounts[1].address);assert.equal(vm.runInContext('typeof fetch',context),'undefined');
 const signed=JSON.parse(context.BitToolSignerEngine.dispatch(JSON.stringify({operation:'sign',mnemonic:MN,request:simpleEVM()})));assert.equal(signed.ok,true);
});
export {MN,accounts,btcRequest,tronRequest,solRequest,simpleEVM};

test('EIP712 Safe owner signature binds CALL fields, marks delegatecall high risk and rejects unsigned extras',()=>{
 const types={SafeTx:[['to','address'],['value','uint256'],['data','bytes'],['operation','uint8'],['safeTxGas','uint256'],['baseGas','uint256'],['gasPrice','uint256'],['gasToken','address'],['refundReceiver','address'],['nonce','uint256']].map(([name,type])=>({name,type}))};
 const zero='0x0000000000000000000000000000000000000000';const typedData={domain:{chainId:1,verifyingContract:'0x000000000000000000000000000000000000dead'},primaryType:'SafeTx',types,message:{to:accounts[1].address,value:'10',data:'0x',operation:0,safeTxGas:0,baseGas:0,gasPrice:0,gasToken:zero,refundReceiver:zero,nonce:1}};
 const r={chain:'evm',kind:'typedData',typedData};assert.ok(sign(r).signature);fails(()=>sign({...r,chainId:56}),'CHAIN_ID');
 assert.equal(review({...r,typedData:{...typedData,message:{...typedData.message,operation:1}}}).riskLevel,'high');assert.ok(review({...r,typedData:{...typedData,message:{...typedData.message,operation:1}}}).warnings.some(w=>w.includes('DELEGATECALL')));
 fails(()=>sign({...r,typedData:{...typedData,message:{...typedData.message,humanDescription:'This is not actually signed'}}}),'TYPED_DATA');
});
test('all-Taproot witness-only PSBT is accepted because its signature commits every amount',()=>{
 const {request,a,payment}=btcRequest({taproot:true,witnessOnly:true});const out=sign(request);const tx=BitcoinTx.fromPSBT(fromBase64(out.psbt));
 const sig=tx.getInput(0).tapKeySig;const digest=tx.preimageWitnessV1(0,[payment.script],0,[100000n]);assert.ok(schnorr.verify(sig,digest,payment.script.slice(2)));
 const forgedDigest=tx.preimageWitnessV1(0,[payment.script],0,[100001n]);assert.equal(schnorr.verify(sig,forgedDigest,payment.script.slice(2)),false);
});
test('Solana message signing rejects legacy header bytes and requires recognizable text',()=>{
 for(const n of [9,10,13,0x80]){const r={chain:'solana',kind:'message',address:accounts[3].address,message:toBase64(new Uint8Array([n,65,66]))};fails(()=>sign(r),'MESSAGE');}
 const r={chain:'solana',kind:'message',address:accounts[3].address,message:toBase64(utf8('Sign in to bittool-signer.io'))};assert.ok(ed25519.verify(hexToBytes(sign(r).signature),fromBase64(r.message),base58.decode(accounts[3].address)));
});
test('strict dispatch rejects duplicate keys and unsafe numeric payloads before signing',()=>{
 assert.equal(JSON.parse(dispatch('{"operation":"capabilities","operation":"wordlist"}')).ok,false);
 assert.equal(JSON.parse(dispatch('{"operation":"deriveAccounts","index":9007199254740993}')).ok,false);
});
test('BIP380 checksum known vector and BIP48 complete multisig policy derivation',async()=>{
 const {descriptorChecksum}=await import('../src/bitcoin-policy.js');assert.equal(descriptorChecksum('raw(deadbeef)'),'89f8spxm');
 const a=req('deriveBitcoinCosigner',{mnemonic:MN}),b=req('deriveBitcoinCosigner',{mnemonic:MN2});
 const key=x=>`[${x.masterFingerprint}/${x.accountPath.slice(2)}]${x.xpub}/<0;1>/*`;
 const body=`wsh(sortedmulti(2,${key(a)},${key(b)}))`;const descriptor=body+'#'+descriptorChecksum(body);
 const policy=req('validateBitcoinPolicy',{descriptor});assert.equal(policy.threshold,2);assert.equal(policy.total,2);assert.equal(policy.samples.length,4);assert.ok(policy.samples.every(x=>x.address.startsWith('bc1q')));
 fails(()=>req('validateBitcoinPolicy',{descriptor:descriptor.slice(0,-1)+'x'}),'DESCRIPTOR');
 const duplicate=`wsh(sortedmulti(2,${key(a)},${key(a)}))`;fails(()=>req('validateBitcoinPolicy',{descriptor:duplicate+'#'+descriptorChecksum(duplicate)}),'POLICY');
});

test('TRON TRC20 transfer decodes protobuf contract address, recipient and raw units',()=>{
 const owner=base58check(sha256).decode(accounts[2].address);const token=base58check(sha256).decode('TJRabPrwbZy45sbavfcjinPJC18kjpRTv8');
 const abi=new Interface(['function transfer(address to,uint256 amount)']);const data=hexToBytes(abi.encodeFunctionData('transfer',[accounts[1].address,1234567]));
 const value=concat(pbB(1,owner),pbB(2,token),pbB(4,data));const any=concat(pbB(1,utf8('type.googleapis.com/protocol.TriggerSmartContract')),pbB(2,value));const contract=concat(pbN(1,31),pbB(2,any));
 const raw=concat(pbB(1,new Uint8Array([0,1])),pbB(4,new Uint8Array(8)),pbN(8,1800000060000),pbB(11,contract),pbN(14,1800000000000),pbN(18,100000000));
 const request={chain:'tron',kind:'transaction',transaction:{raw_data_hex:bytesToHex(raw)}};
 const out=sign(request);assert.equal(out.signedTransaction.raw_data.contract[0].type,'TriggerSmartContract');assert.ok(review(request).fields.some(f=>f.value==='1234567'));assert.ok(review(request).fields.some(f=>f.label==='Contract'&&f.value==='TJRabPrwbZy45sbavfcjinPJC18kjpRTv8'));
});
test('Solana SPL checked token and NFT transfers decode mint and raw amount',()=>{
 const pub=base58.decode(accounts[3].address),source=new Uint8Array(32).fill(1),mint=new Uint8Array(32).fill(2),destination=new Uint8Array(32).fill(3),program=base58.decode('TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA');
 const keys=[pub,source,destination,mint,program];
 for(const [amount,decimals] of [[5000000,6],[1,0]]){
  const data=concat(new Uint8Array([12]),u64(amount),new Uint8Array([decimals]));const ix=concat(new Uint8Array([4]),short(4),new Uint8Array([1,3,2,0]),short(data.length),data);
  const message=concat(new Uint8Array([1,0,2]),short(keys.length),...keys,new Uint8Array(32).fill(5),short(1),ix);const r={chain:'solana',kind:'transaction',message:toBase64(message)};
  assert.ok(review(r).fields.some(f=>f.label.includes('Mint')&&f.value===base58.encode(mint)));assert.ok(review(r).fields.some(f=>f.label.includes('Raw amount')&&f.value===String(amount)));assert.ok(ed25519.verify(hexToBytes(sign(r).signature),message,pub));
 }
});


test('TRON owner permission signs explicit member identities and preserves independently verified cosignatures',()=>{
 const secondAccount=deriveAccounts({mnemonic:MN2}).accounts.find(a=>a.chain==='tron');
 const owner='TJRabPrwbZy45sbavfcjinPJC18kjpRTv8';
 const request=tronRequest({permission:0,owner});
 assert.notEqual(owner,accounts[2].address);assert.notEqual(owner,secondAccount.address);
 fails(()=>sign(request),'SIGNER');
 fails(()=>sign({...request,address:secondAccount.address}),'SIGNER');
 const firstRequest={...request,address:accounts[2].address};const firstReview=review(firstRequest);
 assert.ok(firstReview.warnings.some(w=>w.includes('Owner permission (ID 0)')&&w.includes('weights and threshold are unverified')));
 assert.ok(firstReview.fields.some(f=>f.label==='Account'&&f.value===owner));
 assert.ok(firstReview.fields.some(f=>f.label==='Requested signer'&&f.value===accounts[2].address));
 const first=sign(firstRequest,{reviewedHash:firstReview.requestHash});
 const secondRequest={...request,address:secondAccount.address,transaction:first.signedTransaction};
 const second=sign(secondRequest,{mnemonic:MN2});
 assert.equal(second.signedTransaction.raw_data_hex,request.transaction.raw_data_hex);
 assert.equal(second.txID,request.transaction.txID);
 assert.deepEqual(second.signedTransaction.signature,[first.signature,second.signature]);
 assert.equal(second.signedTransaction.raw_data.contract[0].Permission_id,undefined);
 const expected=[accounts[2],secondAccount];
 second.signedTransaction.signature.forEach((signature,index)=>{
   const expectedAddress='0x'+bytesToHex(base58check(sha256).decode(expected[index].address).slice(1));
   assert.equal(recoverAddress('0x'+second.txID,'0x'+signature).toLowerCase(),expectedAddress);
   assert.ok(secp256k1.verify(hexToBytes(signature).slice(0,64),hexToBytes(second.txID),hexToBytes(expected[index].publicKey),{prehash:false}));
 });
 fails(()=>sign({...request,transaction:first.signedTransaction},{mnemonic:MN2}),'SIGNER');
 fails(()=>sign({...firstRequest,transaction:first.signedTransaction}),'SIGNATURE');
});
