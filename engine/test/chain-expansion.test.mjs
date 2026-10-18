import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync,existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { Transaction,p2pkh,p2wpkh,p2sh,p2wsh,p2ms,p2tr,p2tr_ms,p2tr_ns } from '@scure/btc-signer';
import { RawPSBTV0,RawPSBTV2 } from '@scure/btc-signer/psbt.js';
import { tapLeafHash } from '@scure/btc-signer/payment.js';
import { secp256k1,schnorr } from '@noble/curves/secp256k1.js';
import { ed25519 } from '@noble/curves/ed25519.js';
import { sha256 } from '@noble/hashes/sha2.js';
import { base58 } from '@scure/base';
import { Interface,hashMessage,keccak256,concat as ethConcat,toUtf8Bytes,verifyTypedData } from 'ethers';
import { withSeed,withKey,deriveAccounts,PATHS } from '../src/keys.js';
import { signBitcoin,parseBitcoin,bitcoinKeyMatchesInput } from '../src/bitcoin.js';
import { parseEVM,signEVM } from '../src/evm.js';
import { parseTron,signTron } from '../src/tron.js';
import { parseSolana,signSolana } from '../src/solana.js';
import { lookupToken } from '../src/token-registry.js';
import { bytesToHex,hexToBytes,toBase64,fromBase64,concat,utf8,short } from '../src/util.js';
const MN='abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const OTHER='legal winner thank year wave sausage worth useful legal winner thank yellow';
const node=(path,mn=MN)=>withSeed(mn,'',(seed,root)=>withKey(seed,root,'bitcoin',path,(priv,pub)=>({priv:priv.slice(),pub:pub.slice(),fingerprint:root.fingerprint,path:path.split('/').slice(1).map(x=>Number(x.replace("'",''))+(x.endsWith("'")?2**31:0))})));
const run=(f,r,task,mn=MN)=>withSeed(mn,'',(seed,root)=>f(r,seed,root,task));
const path="m/84'/0'/0'/0/0",a=node(path),b=node(path,OTHER);
function psbt(payment,{tap=false,version=0,keys=[a],inputCount=1}={}){
 const prev=new Transaction();prev.addInput({txid:new Uint8Array(32),index:0});for(let i=0;i<inputCount;i++)prev.addOutput({script:payment.script,amount:100000n});
 const tx=new Transaction({PSBTVersion:version,unknown:'ignore',proprietary:'ignore'});
 for(let i=0;i<inputCount;i++){
  const input={txid:prev.id,index:i,nonWitnessUtxo:prev.unsignedTx,witnessUtxo:{script:payment.script,amount:100000n}};
  for(const key of ['redeemScript','witnessScript','tapInternalKey','tapMerkleRoot','tapLeafScript'])if(payment[key])input[key]=payment[key];
  if(tap)input.tapBip32Derivation=keys.map(k=>[k.pub.slice(1),{der:{fingerprint:k.fingerprint,path:k.path},hashes:payment.tapLeafScript?.map(([,s])=>tapLeafHash(s.slice(0,-1),s.at(-1)))??[]}]);
  else input.bip32Derivation=keys.map(k=>[k.pub,{fingerprint:k.fingerprint,path:k.path}]);
  tx.addInput(input);
 }
 tx.addOutput({script:p2wpkh(b.pub).script,amount:BigInt(inputCount)*100000n-1000n});
 return {tx,request:{chain:'bitcoin',psbt:toBase64(tx.toPSBT()),network:'mainnet'}};
}
test('Bitcoin seven mainstream script forms sign v0/v2 and independently finalize',()=>{
 const forms=[p2pkh(a.pub),p2sh(p2wpkh(a.pub)),p2wpkh(a.pub),p2tr(a.pub.slice(1)),p2sh(p2ms(2,[a.pub,b.pub])),p2sh(p2wsh(p2ms(2,[a.pub,b.pub]))),p2wsh(p2ms(2,[a.pub,b.pub]))];
 for(const version of [0,2])for(const [index,payment] of forms.entries()){
  const {request,tx}=psbt(payment,{tap:index===3,version,keys:index>=4?[a,b]:[a]});
  let result=run(signBitcoin,request);if(index>=4)result=run(signBitcoin,{...request,psbt:result.psbt},undefined,OTHER);
  const signed=Transaction.fromPSBT(fromBase64(result.psbt));assert.deepEqual(signed.unsignedTx,tx.unsignedTx);signed.finalize();assert.ok(signed.extract().length>100);
 }
});
test('Bitcoin CHECKSIGADD and CHECKSIGVERIFY leaves produce verifiable script-path signatures',()=>{
 for(const script of [p2tr_ms(2,[a.pub.slice(1),b.pub.slice(1)]),p2tr_ns(2,[a.pub.slice(1),b.pub.slice(1)])[0]]){
  const payment=p2tr(undefined,script),{request}=psbt(payment,{tap:true,keys:[a,b]});
  const parsed=parseBitcoin(request);assert.ok(bitcoinKeyMatchesInput(parsed,0,bytesToHex(a.pub),[bytesToHex(parsed.leaves[0][0].hash)]));
  const first=run(signBitcoin,request),one=Transaction.fromPSBT(fromBase64(first.psbt));assert.equal(one.getInput(0).tapScriptSig.length,1);assert.equal(one.getInput(0).tapKeySig,undefined);
  const [entry,sig]=one.getInput(0).tapScriptSig[0],leaf=parsed.leaves[0][0];
  const digest=one.preimageWitnessV1(0,[payment.script],0,[100000n],undefined,leaf.script,0xc0);assert.ok(schnorr.verify(sig,digest,entry.pubKey));
  const second=run(signBitcoin,{...request,psbt:first.psbt},undefined,OTHER),two=Transaction.fromPSBT(fromBase64(second.psbt));assert.deepEqual(two.getInput(0).tapScriptSig[0],one.getInput(0).tapScriptSig[0]);two.finalize();assert.ok(two.extract().length>100);
 }
});
test('Bitcoin task signs only selected input/key and preserves all unknown PSBT maps',()=>{
 for(const version of [0,2]){
  const {request,tx}=psbt(p2wpkh(a.pub),{inputCount:2,version});const coder=version?RawPSBTV2:RawPSBTV0,wire=coder.decode(fromBase64(request.psbt));
  const unknown=[[{type:222,key:new Uint8Array([1,2])},new Uint8Array([3,4,5])]];wire.global.unknown=unknown;wire.inputs[0].unknown=unknown;wire.outputs[0].unknown=unknown;
  request.psbt=toBase64(coder.encode(wire));const result=run(signBitcoin,request,{targets:[{inputIndex:1,path,publicKey:bytesToHex(a.pub)}]});const signed=Transaction.fromPSBT(fromBase64(result.psbt));
  assert.equal(signed.getInput(0).partialSig,undefined);assert.equal(signed.getInput(1).partialSig.length,1);assert.deepEqual(signed.unsignedTx,tx.unsignedTx);
  const actual=coder.decode(fromBase64(result.psbt));assert.deepEqual(actual.global.unknown,unknown);assert.deepEqual(actual.inputs[0].unknown,unknown);assert.deepEqual(actual.outputs[0].unknown,unknown);
 }
});
test('Bitcoin rejects wrong script selector, altered control block and forged existing cosignature',()=>{
 const {request,tx}=psbt(p2wpkh(a.pub));assert.throws(()=>run(signBitcoin,request,{targets:[{inputIndex:0,path,publicKey:bytesToHex(b.pub)}]}),e=>e.code==='SIGNER');
 tx.updateInput(0,{partialSig:[[a.pub,concat(secp256k1.sign(new Uint8Array(32),a.priv,{prehash:false,format:'der'}),new Uint8Array([1]))]]});assert.throws(()=>parseBitcoin({...request,psbt:toBase64(tx.toPSBT())}),e=>e.code==='SIGNATURE');
 const tapped=psbt(p2tr(undefined,p2tr_ms(1,[a.pub.slice(1),b.pub.slice(1)])),{tap:true});const wire=RawPSBTV0.decode(fromBase64(tapped.request.psbt));wire.inputs[0].tapLeafScript[0][0].version^=1;assert.throws(()=>parseBitcoin({...tapped.request,psbt:toBase64(RawPSBTV0.encode(wire))}));
});
const account=deriveAccounts({mnemonic:MN}).accounts;
const evmRequest=data=>({chain:'evm',kind:'transaction',address:account[1].address,transaction:{type:2,chainId:1,nonce:0,to:'0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',data,value:'0',gasLimit:'100000',maxFeePerGas:'2',maxPriorityFeePerGas:'1'}});
test('EVM exact local registry formats integers without losing precision and unknown calls remain high risk',()=>{
 const abi=new Interface(['function transfer(address to,uint256 amount)']);const r=evmRequest(abi.encodeFunctionData('transfer',[account[1].address,'9007199254740993123']));const review=parseEVM(r).review;
 assert.equal(review.asset.symbol,'USDC');assert.equal(review.asset.displayAmount,'9007199254740.993123');assert.equal(review.asset.assetAddress,r.transaction.to.toLowerCase());
 const opaque=parseEVM(evmRequest('0x12345678')).review;assert.equal(opaque.decodeStatus,'opaque');assert.equal(opaque.riskLevel,'high');assert.ok(opaque.fields.some(f=>f.value==='0x12345678'));
 assert.throws(()=>parseEVM({...r,transaction:{...r.transaction,chainId:11155111}}),e=>e.code==='NETWORK');assert.throws(()=>parseEVM(evmRequest('0xa9059cbb')),e=>e.code==='CALLDATA');
});
test('EIP712 Permit2 fields and absent signed chain context are explicit; task identity is rechecked',()=>{
 const typedData={domain:{name:'Permit2',chainId:1,verifyingContract:'0x000000000022D473030F116dDEE9F6B43aC78BA3'},primaryType:'PermitSingle',types:{PermitDetails:[['token','address'],['amount','uint160'],['expiration','uint48'],['nonce','uint48']].map(([name,type])=>({name,type})),PermitSingle:[['details','PermitDetails'],['spender','address'],['sigDeadline','uint256']].map(([name,type])=>({name,type}))},message:{details:{token:'0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',amount:String((1n<<160n)-1n),expiration:1900000000,nonce:42},spender:account[1].address,sigDeadline:1900000000}};
 const request={chain:'evm',kind:'typedData',typedData},review=parseEVM(request).review;assert.equal(review.asset.symbol,'USDC');assert.equal(review.riskLevel,'high');assert.ok(review.warnings.some(w=>w.includes('UNLIMITED')));
 const out=run(signEVM,request,{targets:[{path:PATHS.evm,publicKey:account[1].publicKey,address:account[1].address}]});assert.equal(verifyTypedData(typedData.domain,typedData.types,typedData.message,'0x'+out.signature),account[1].address);
 const noChain=structuredClone(request);delete noChain.typedData.domain.chainId;assert.ok(parseEVM(noChain).review.warnings.some(w=>w.includes('Network context not included')));assert.equal(parseEVM(noChain).review.asset,undefined);
 assert.throws(()=>run(signEVM,request,{targets:[{path:PATHS.evm,publicKey:bytesToHex(a.pub)}]}),e=>e.code==='SIGNER');
});
test('Safe MultiSend decodes inner calls and surfaces delegatecall/ownership risk',()=>{
 const abi=new Interface(['function multiSend(bytes transactions)','function enableModule(address module)']);const data=abi.encodeFunctionData('enableModule',[account[1].address]);
 const packed='0x01'+account[1].address.slice(2)+'0'.repeat(64)+(BigInt((data.length-2)/2)).toString(16).padStart(64,'0')+data.slice(2);
 const r=evmRequest(abi.encodeFunctionData('multiSend',[packed]));const review=parseEVM(r).review;assert.equal(review.riskLevel,'high');assert.ok(review.fields.some(f=>f.value==='DELEGATECALL'));assert.ok(review.fields.some(f=>f.value.includes('enableModule')));
 const malformed=evmRequest(abi.encodeFunctionData('multiSend',[packed.slice(0,-2)]));assert.throws(()=>parseEVM(malformed),e=>e.code==='TRUNCATED');
});
test('TRON personal message uses TronWeb prefix and byte length, independently verified',()=>{
 const message='BitTool Signer 🔐',request={chain:'tron',kind:'message',encoding:'utf8',message};const parsed=parseTron(request),out=run(signTron,request,{targets:[{path:PATHS.tron,publicKey:account[2].publicKey,address:account[2].address}]});
 const expected=keccak256(ethConcat([toUtf8Bytes('\x19TRON Signed Message:\n'),toUtf8Bytes(String(toUtf8Bytes(message).length)),toUtf8Bytes(message)]));assert.equal('0x'+bytesToHex(parsed.digest),expected);assert.notEqual(expected,hashMessage(message));assert.ok(secp256k1.verify(hexToBytes(out.signature).slice(0,64),hexToBytes(expected),hexToBytes(account[2].publicKey),{prehash:false}));assert.ok(hexToBytes(out.signature)[64]<2);assert.equal(out.signedTransaction,undefined);
});
const u32=n=>{const b=new Uint8Array(4);new DataView(b.buffer).setUint32(0,n,true);return b;};
const u64=n=>{const b=new Uint8Array(8);new DataView(b.buffer).setBigUint64(0,BigInt(n),true);return b;};
function sol(program,accounts,data,{readonly=false}={}){const signer=base58.decode(account[3].address),other=ed25519.getPublicKey(new Uint8Array(32).fill(9)),keys=[other,signer,...accounts.map(x=>base58.decode(x)),base58.decode(program)];const message=concat(new Uint8Array([2,readonly?1:0,1]),short(keys.length),...keys,new Uint8Array(32).fill(8),short(1),new Uint8Array([keys.length-1]),short(accounts.length+1),new Uint8Array([...accounts.map((_,i)=>i+2),1]),short(data.length),data);return {chain:'solana',kind:'transaction',message:toBase64(message),signatures:[toBase64(ed25519.sign(message,new Uint8Array(32).fill(9))),null]};}
test('Solana signs read-only non-feepayer slot; selected slot mismatch is refused',()=>{
 const r=sol('MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr',[],utf8('Approve sign-in'),{readonly:true});const target={path:PATHS.solana,publicKey:account[3].publicKey,address:account[3].address,signerSlot:1};const out=run(signSolana,r,{targets:[target]});assert.equal(out.signerIndex,1);assert.equal(out.signatures[0],r.signatures[0]);assert.ok(ed25519.verify(hexToBytes(out.signature),fromBase64(r.message),base58.decode(account[3].address)));assert.throws(()=>run(signSolana,r,{targets:[{...target,signerSlot:0}]}),e=>e.code==='SIGNER');
});
test('Solana unchecked token transfer never infers mint from token-account address',()=>{
 const source=base58.encode(new Uint8Array(32).fill(2)),dest=base58.encode(new Uint8Array(32).fill(3));const r=sol('TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA',[source,dest],concat(new Uint8Array([3]),u64(9007199254740993n)));const review=parseSolana(r).review;assert.equal(review.asset,undefined);assert.ok(review.warnings.some(w=>w.includes('Mint is not included')));assert.ok(review.fields.some(f=>f.value==='9007199254740993'));
});
test('Squads proposal-only approvals explicitly disclose unavailable proposal contents',()=>{
 const multisig=base58.encode(new Uint8Array(32).fill(2)),proposal=base58.encode(new Uint8Array(32).fill(3));
 // Actual account order is multisig/member/proposal, not this helper's default appended authority.
 const r=sol('SQDS4ep65T869zMMBKyuUq6aD6EgTu8psMjkvj52pCf',[multisig,proposal],concat(sha256(utf8('global:proposal_approve')).slice(0,8),new Uint8Array([0])));const bytes=fromBase64(r.message),offset=3+1+5*32+32+1+1+1;bytes.set([2,1,3],offset);r.message=toBase64(bytes);r.signatures=[toBase64(ed25519.sign(bytes,new Uint8Array(32).fill(9))),null];const review=parseSolana(r).review;assert.equal(review.decodeStatus,'partiallyDecoded');assert.equal(review.riskLevel,'high');assert.ok(review.fields.some(f=>f.label.includes('Referenced proposal')&&f.value===proposal));assert.ok(review.warnings.some(w=>w.includes('NOT included')));
});
test('Offline registry has unique exact identities, on-chain decimals and packed icons that match their hashes',async()=>{
 const read=name=>readFileSync(new URL(name,import.meta.url),'utf8');
 const registry=JSON.parse(read('../data/token-registry.merged.json'));
 assert.equal(registry.schemaVersion,2);assert.match(registry.registryVersion,/^\d{4}-\d{2}-\d{2}\.\d+$/);
 assert.ok(Array.isArray(registry.sources)&&registry.sources.length>0);assert.ok(registry.selection.includes('not an endorsement'));
 assert.ok(registry.coinmarketcap.note.includes('Decimals are never taken from here'));
 // The app copy drops build provenance; the engine copy is columnar. Both must say exactly what the merged file says.
 const APP=['chainFamily','chainId','assetAddress','name','symbol','decimals','icon','tokenProgram','rank','cmcId','metadataSource'];
 const app=JSON.parse(read('../../BitToolSigner/Resources/token-registry.json'));
 assert.deepEqual(app.assets,registry.assets.map(a=>Object.fromEntries(APP.filter(k=>k in a).map(k=>[k,a[k]]))),'bundled registry must be the exact projection of the merged registry');
 assert.deepEqual({...app,assets:0},{...registry,assets:0},'bundled registry must keep the merged header');
 const compact=JSON.parse(read('../data/token-registry.engine.json'));
 assert.equal(compact.registryVersion,registry.registryVersion);
 assert.equal(compact.assetCount,registry.assets.length);
 assert.deepEqual(compact.assets.split('\n'),registry.assets.map(a=>[compact.networks.findIndex(([f,c])=>f===a.chainFamily&&(c??undefined)===a.chainId),
  a.assetAddress,a.name,a.symbol,a.decimals,a.icon,a.tokenProgram?compact.programs.indexOf(a.tokenProgram):-1].join('\t')),'engine registry must be the exact projection of the merged registry');
 // Icons: one packed file, addressed by content hash, so shared artwork is stored once.
 const index=JSON.parse(read('../../BitToolSigner/Resources/TokenIcons.index.json'));
 const pack=readFileSync(new URL('../../BitToolSigner/Resources/TokenIcons.pack',import.meta.url));
 let cursor=0;
 for(const [name,[offset,length]] of Object.entries(index).sort((x,y)=>x[1][0]-y[1][0])){
  assert.equal(offset,cursor,'icon pack must have no gaps or overlaps at '+name);cursor+=length;
  const bytes=pack.subarray(offset,offset+length);
  assert.equal(createHash('sha256').update(bytes).digest('hex').slice(0,16),name,'icon id must be its content hash');
  assert.deepEqual([...bytes.subarray(0,8)],[137,80,78,71,13,10,26,10],name+' must be a PNG');
  assert.ok(bytes.readUInt32BE(16)<=128&&bytes.readUInt32BE(20)<=128,name+' must be at most 128px');
 }
 assert.equal(cursor,pack.length,'icon pack must contain nothing but indexed icons');
 const {base58check}=await import('@scure/base');const tron=base58check(sha256);
 const PROGRAMS=new Set(['TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA','TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb']);
 const networks=new Map(registry.networks.map(n=>[n.chainFamily+':'+(n.chainId??''),n]));
 const ids=new Set(),counts={},symbols={},used=new Set();let collisions=0;
 for(const a of registry.assets){
  const key=[a.chainFamily,a.chainId??'',a.assetAddress].join(':');
  const network=networks.get(a.chainFamily+':'+(a.chainId??''));assert.ok(network,'unexpected network '+key);
  if(a.chainFamily==='evm'){assert.match(a.assetAddress,/^0x[0-9a-f]{40}$/);assert.equal(typeof a.chainId,'string');}
  else{assert.equal(a.chainId,undefined);if(a.chainFamily==='tron'){assert.match(a.assetAddress,/^T[1-9A-HJ-NP-Za-km-z]{33}$/);assert.equal(tron.decode(a.assetAddress)[0],0x41);}else assert.equal(base58.decode(a.assetAddress).length,32);}
  assert.ok(!ids.has(key),'duplicate identity '+key);ids.add(key);
  assert.ok(Number.isInteger(a.decimals)&&a.decimals>=0&&a.decimals<=30,key);
  for(const f of ['name','symbol','icon','metadataSource','iconSource','iconSha256'])assert.ok(typeof a[f]==='string'&&a[f].length>0,key+' '+f);
  assert.ok(!/\p{Extended_Pictographic}/u.test(a.name+a.symbol),key+' name/symbol must not contain emoji');
  assert.ok(![...a.name+a.symbol].some(c=>/\p{C}/u.test(c)),key+' name/symbol must not contain control characters');
  assert.match(a.iconSource,/^(https:\/\/|token_)/);
  assert.equal(a.iconSha256.slice(0,16),a.icon,key+' icon id must match its hash');
  assert.ok(index[a.icon],key+' icon must be in the pack');used.add(a.icon);
  // Decimals are always read from the chain, never from a listing.
  assert.equal(a.verification.onchainDecimals,true,key);
  if(a.metadataSource==='coinmarketcap'){
   assert.ok(Number.isInteger(a.cmcId),key);assert.equal(a.verifiedAt,registry.coinmarketcap.fetchedAt,key);
   assert.ok(['onchain','coinmarketcap'].includes(a.verification.symbolSource),key);
   if(a.verification.symbolSource==='onchain')assert.equal(a.symbol,a.verification.onchainSymbol,key+' must show the symbol the contract reports');
   else assert.equal(a.symbol,a.verification.coinmarketcapSymbol,key);
  }else{
   assert.match(a.metadataSource,/^https:\/\//);assert.equal(a.verifiedAt,registry.collectedAt,key);
   assert.equal(a.verification.coingecko,true,key);assert.equal(a.cmcId,undefined,key);
  }
  const found=lookupToken(a.chainFamily,a.chainId,a.assetAddress);assert.equal(found.symbol,a.symbol);assert.equal(found.decimals,a.decimals);assert.equal(found.icon,a.icon);
  if(a.chainFamily==='solana'){assert.ok(PROGRAMS.has(a.tokenProgram),key+' tokenProgram');assert.equal(lookupToken('solana',undefined,a.assetAddress,1n,a.tokenProgram).symbol,a.symbol);const other=[...PROGRAMS].find(p=>p!==a.tokenProgram);assert.equal(lookupToken('solana',undefined,a.assetAddress,1n,other),undefined);}
  else assert.equal(a.tokenProgram,undefined);
  counts[network.key]=(counts[network.key]??0)+1;
  // Tickers are not identities: same-network collisions exist on chain and are
  // tolerated, as long as no two curated records claim one and they stay rare.
  const sym=a.symbol.toUpperCase(),seen=(symbols[network.key]??={});
  if(seen[sym]){collisions++;assert.ok(seen[sym].metadataSource==='coinmarketcap'||a.metadataSource==='coinmarketcap',network.key+' duplicate curated symbol '+a.symbol);}
  seen[sym]=a;
 }
 assert.ok(collisions<=60,'unexpected number of symbol collisions: '+collisions);
 assert.equal(used.size,Object.keys(index).length,'every packed icon must be used');
 assert.deepEqual(Object.keys(counts).sort(),Object.keys(registry.counts).sort());
 for(const network of registry.networks){
  assert.equal(registry.counts[network.key].included,counts[network.key],network.key);
  assert.equal(network.tokens,counts[network.key],network.key);
  assert.equal(registry.counts[network.key].curated+registry.counts[network.key].coinmarketcap,counts[network.key],network.key);
  assert.ok(typeof network.name==='string'&&/^[A-Z]{2,5}|xDAI$/.test(network.nativeSymbol),network.key);
 }
 assert.ok(registry.assets.length>3000,'expanded registry should cover thousands of tokens');
 const wsol=lookupToken('solana',undefined,'So11111111111111111111111111111111111111112');assert.equal(wsol.decimals,9);
 assert.equal(lookupToken('evm','1','0xA0B86991C6218B36C1D19D4A2E9EB0CE3606EB48').symbol,'USDC');
 assert.equal(lookupToken('evm','56','0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48'),undefined);
 // USDT is one image on Ethereum and TRON; bridged deployments keep the symbol the contract reports.
 assert.equal(lookupToken('evm','1','0xdac17f958d2ee523a2206206994597c13d831ec7').icon,lookupToken('tron',undefined,'TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t').icon);
 assert.equal(lookupToken('evm','43114','0x5947bb275c521040051d82396192181b413227a3').symbol,'LINK.e');
 assert.equal(lookupToken('evm','137','0x0000000000000000000000000000000000001010').decimals,18);
});
const varint=n=>{n=BigInt(n);const bytes=[];do{bytes.push(Number(n&127n));n>>=7n;if(n)bytes[bytes.length-1]|=128;}while(n);return new Uint8Array(bytes);};
const pbN=(k,n)=>concat(varint(k*8),varint(n)),pbB=(k,v)=>concat(varint(k*8+2),varint(v.length),v);
function tronContract(type,name,value){const c=concat(pbN(1,type),pbB(2,concat(pbB(1,utf8('type.googleapis.com/protocol.'+name)),pbB(2,value))));return {chain:'tron',kind:'transaction',transaction:{raw_data_hex:bytesToHex(concat(pbB(1,new Uint8Array([0,1])),pbB(4,new Uint8Array(8)),pbN(8,1800000060000),pbB(11,c),pbN(14,1800000000000)))}};}
test('TRON Stake2 resource delegation parses signed protobuf units, recipient and lock',async()=>{
 const {base58check}=await import('@scure/base');const decode=base58check(sha256).decode;
 const value=concat(pbB(1,decode(account[2].address)),pbN(2,1),pbN(3,1000000),pbB(4,decode('TJRabPrwbZy45sbavfcjinPJC18kjpRTv8')),pbN(5,1),pbN(6,86400));const r=tronContract(57,'DelegateResourceContract',value);const review=parseTron(r).review;assert.ok(review.fields.some(f=>f.label==='Resource'&&f.value==='Energy'));assert.ok(review.fields.some(f=>f.label==='Delegated balance (TRX)'&&f.value==='1'));assert.ok(review.fields.some(f=>f.label==='Lock period (blocks)'&&f.value==='86400'));const out=run(signTron,r);assert.equal(out.signedTransaction.raw_data_hex,r.transaction.raw_data_hex);assert.equal(out.signedTransaction.raw_data.contract[0].parameter.value.lock,true);
 const json=structuredClone(out.signedTransaction);json.raw_data.contract[0].parameter.value.resource='ENERGY';assert.equal(parseTron({...r,transaction:json}).txID,out.txID);
});
test('TRON owner member can use verified task identity without optional request address',async()=>{
 const {base58check}=await import('@scure/base');const decode=base58check(sha256).decode;const owner='TJRabPrwbZy45sbavfcjinPJC18kjpRTv8';const r=tronContract(1,'TransferContract',concat(pbB(1,decode(owner)),pbB(2,decode(account[2].address)),pbN(3,1)));
 assert.throws(()=>run(signTron,r),e=>e.code==='SIGNER');const out=run(signTron,r,{targets:[{path:PATHS.tron,publicKey:account[2].publicKey,address:account[2].address}]});assert.equal(out.address,account[2].address);assert.equal(out.signedTransaction.raw_data.contract[0].parameter.value.owner_address,bytesToHex(decode(owner)));assert.equal(r.address,undefined);assert.ok(parseTron(r).review.warnings.some(w=>w.includes('Current membership, weights and threshold')));
});
test('All chain review entry points reject explicit unsupported networks',()=>{
 for(const [fn,request] of [[parseEVM,evmRequest('0x')],[parseTron,{chain:'tron',kind:'message',message:'00'}],[parseSolana,{chain:'solana',kind:'message',message:toBase64(utf8('hello'))}],[parseBitcoin,psbt(p2wpkh(a.pub)).request]])assert.throws(()=>fn({...request,network:'devnet'}),e=>e.code==='NETWORK');
});
test('Custom Permit schemas stay partial and never invent token allowance interpretations',()=>{
 const r={chain:'evm',kind:'typedData',typedData:{domain:{name:'Custom',chainId:1},primaryType:'Permit',types:{Permit:[{name:'token',type:'string'},{name:'amount',type:'string'}]},message:{token:'not an address',amount:'not a quantity'}}};const review=parseEVM(r).review;assert.equal(review.decodeStatus,'partiallyDecoded');assert.equal(review.riskLevel,'high');assert.equal(review.asset,undefined);assert.ok(review.fields.some(f=>f.label==='Signed values'&&f.value.includes('not a quantity')));
});
test('Reviewed EVM networks beyond token registry remain usable with accurate native tickers',()=>{
 for(const [chainId,symbol] of [[10,'ETH'],[137,'POL'],[100,'xDAI'],[43114,'AVAX']]){const r=evmRequest('0x');r.transaction.chainId=chainId;r.transaction.value='1234500000000000000';const review=parseEVM(r).review;assert.equal(review.summary,'1.2345 '+symbol);assert.ok(run(signEVM,r).serializedTransaction);}
});

test('Solana recognizes Unicode messages without permitting transaction header reinterpretation',()=>{
 const message=utf8('确认登录 BitTool Signer 🔐');const request={chain:'solana',kind:'message',message:toBase64(message)};const out=run(signSolana,request,{targets:[{path:PATHS.solana,publicKey:account[3].publicKey}]});assert.ok(ed25519.verify(hexToBytes(out.signature),message,base58.decode(account[3].address)));
 for(const first of [1,9,10,13,31,128])assert.throws(()=>parseSolana({...request,message:toBase64(new Uint8Array([first,65]))}),e=>e.code==='MESSAGE');
});
test('EVM conflicting unsigned network hints cannot override missing signed domain context',()=>{
 const r={chain:'evm',kind:'personal',chainId:1,transport:{chainId:56},message:bytesToHex(utf8('hello'))};assert.throws(()=>parseEVM(r),e=>e.code==='CHAIN_ID');
});
