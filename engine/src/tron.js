import { keccak_256 } from '@noble/hashes/sha3.js';
import { sha256 } from '@noble/hashes/sha2.js';
import { secp256k1 } from '@noble/curves/secp256k1.js';
import { base58check } from '@scure/base';
import { check, fail, field, reviewResult, hexToBytes, bytesToHex, text, Reader, uint, concat, stable, decimal, utf8, equal } from './util.js';
import { PATHS, withKey, tronAddress } from './keys.js';
import { decodeCall, CONTRACT_FIELD_LABELS } from './evm.js';
import { describeContract } from './known-contracts.js';
const B58=base58check(sha256);
const NETWORK={name:'TRON',symbol:'TRX'};
const HIGH_FEE_LIMIT=1000000000n; // 1,000 TRX of energy fees
const toTron=v=>typeof v==='string'&&/^0x[0-9a-f]{40}$/i.test(v)?B58.encode(concat(new Uint8Array([0x41]),hexToBytes(v))):v;
function varint(r){let n=0n;for(let i=0;i<10;i++){const b=r.u8();check(i<9||b<2,'PROTOBUF','Protobuf integer overflow.');n|=BigInt(b&127)<<BigInt(i*7);if(!(b&128)){check(i===0||b!==0,'PROTOBUF','Non-canonical protobuf integer.');return n;}}fail('PROTOBUF','Invalid protobuf varint.');}
function proto(bytes,schema){const r=new Reader(bytes),out={};while(r.pos<bytes.length){const tagValue=varint(r);check(tagValue>0n&&tagValue<=0xffffffffn,'PROTOBUF','Invalid protobuf field tag.');const tag=Number(tagValue);const key=tag>>>3,wire=tag&7;const type=schema[key];check(type,'UNSUPPORTED','Unknown TRON protobuf field; signing is disabled.');check(wire===(type[0]==='b'?2:0),'PROTOBUF','Unexpected protobuf wire type.');check(type.endsWith('*')||out[key]===undefined,'PROTOBUF','Duplicate protobuf field.');const value=wire===2?r.take(Number(varint(r))):varint(r);if(type.endsWith('*'))(out[key]??=[]).push(value);else out[key]=value;}return out;}
const bv=(o,k)=>o[k]??new Uint8Array();const nv=(o,k)=>o[k]??0n;const number=n=>n<=BigInt(Number.MAX_SAFE_INTEGER)?Number(n):n.toString();
function addr(bytes){check(bytes.length===21&&bytes[0]===0x41,'ADDRESS','Invalid TRON address in transaction.');return B58.encode(bytes);}
function jaddr(bytes){addr(bytes);return bytesToHex(bytes);}
function normalizeAddress(value){if(typeof value==='string'&&/^41[0-9a-f]{40}$/i.test(value))return value.toLowerCase();try{return bytesToHex(B58.decode(value));}catch{fail('ADDRESS','Invalid TRON address.');}}
function normalizeJSON(value,key=''){
  if(key==='resource'&&['BANDWIDTH','ENERGY'].includes(value))return value==='ENERGY'?'1':'0';
  if(Array.isArray(value))return value.map(x=>normalizeJSON(x));
  if(value&&typeof value==='object'){const o={};for(const k of Object.keys(value)){const v=value[k];if(v===0||v==='0'||v===''||(Array.isArray(v)&&v.length===0))continue;o[k]=normalizeJSON(v,k);}return o;}
  if(/address$/.test(key))return normalizeAddress(value);
  if(typeof value==='number'||(typeof value==='string'&&/^(?:0|[1-9][0-9]*)$/.test(value)))return uint(value,(1n<<63n)-1n).toString();
  if(['ref_block_bytes','ref_block_hash','data','operations'].includes(key)&&typeof value==='string')return value.toLowerCase();return value;
}
function permission(bytes,expectedType){const p=proto(bytes,{1:'n',2:'n',3:'b',4:'n',5:'n',6:'b',7:'b*'});check(nv(p,1)===BigInt(expectedType),'PERMISSION','Permission type does not match its position.');const keys=(p[7]??[]).map(b=>{const k=proto(b,{1:'b',2:'n'});check(nv(k,2)>0n&&nv(k,2)<=(1n<<63n)-1n,'PERMISSION','Invalid key weight.');return {address:jaddr(bv(k,1)),weight:number(nv(k,2))};});check(keys.length>0&&keys.length<=32&&new Set(keys.map(k=>k.address)).size===keys.length,'PERMISSION','Invalid or duplicate permission keys.');const threshold=nv(p,4);check(threshold>0n&&threshold<=(1n<<63n)-1n&&threshold<=keys.reduce((n,k)=>n+BigInt(k.weight),0n),'PERMISSION','Invalid permission threshold.');check(nv(p,5)===0n,'PERMISSION','Unsupported permission parent.');if(expectedType===2)check(bv(p,6).length===32,'PERMISSION','Active permissions require a 32-byte operation mask.');const out={type:expectedType,id:number(nv(p,2)),permission_name:text(bv(p,3)),threshold:number(threshold),keys};if(p[6])out.operations=bytesToHex(p[6]);return out;}
export function parseTron(request){
  let counterparty;
  check(!request.network||request.network==='mainnet','NETWORK','Unsupported network');
  if(request.kind==='message') {
    check(typeof request.message==='string'&&(!request.encoding||['hex','utf8'].includes(request.encoding)),'MESSAGE','Invalid TRON personal message encoding.');
    const message=request.encoding==='utf8'?utf8(request.message):hexToBytes(request.message,8192);
    check(message.length>0&&message.length<=8192,'MESSAGE','TRON personal messages must contain 1–8192 bytes.');
    // TronWeb signMessageV2/hashMessage: prefix + decimal byte length, keccak256.
    const digest=keccak_256(concat(utf8('\x19TRON Signed Message:\n'),utf8(String(message.length)),message));
    let decoded;try{decoded=text(message);}catch{}
    const printable=decoded!==undefined&&!/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(decoded);
    return {digest,signingBytesDigest:bytesToHex(digest),signerSelectors:{path:request.path,masterFingerprint:request.masterFingerprint,address:request.address},review:reviewResult(request,'Sign TRON message','TRON personal signature',[...(request.address?[field('Requested signer',request.address)]:[]),field('Message',printable?JSON.stringify(decoded):'Non-text message; review exact bytes.'),field('Exact bytes',bytesToHex(message)),field('Network context','Network context not included')],['A personal signature may authorize logins, orders or other asset actions. Verify the full message and origin.'],{riskLevel:'high',decodeStatus:printable?'fullyDecoded':'opaque',network:NETWORK,display:{action:'Sign Message',headline:printable?decoded.slice(0,280):message.length+' bytes of binary data'}})};
  }
  check(request.kind==='transaction','UNSUPPORTED','Unsupported TRON signing protocol.');
  const tx=request.transaction;check(tx&&typeof tx==='object','TRANSACTION','Missing TRON transaction.');
  const raw=hexToBytes(tx.raw_data_hex,65536);check(raw.length>0,'TRANSACTION','Missing TRON raw_data_hex.');const digest=sha256(raw),txID=bytesToHex(digest);
  if(tx.txID)check(tx.txID.toLowerCase()===txID,'INTEGRITY','TRON txID does not match raw_data_hex.');
  const r=proto(raw,{1:'b',3:'n',4:'b',8:'n',10:'b',11:'b*',14:'n',18:'n'});
  check(bv(r,1).length===2&&bv(r,4).length===8,'TRANSACTION','Invalid TRON reference block.');
  check(nv(r,8)>nv(r,14)&&nv(r,14)>0n&&nv(r,8)<=BigInt(Number.MAX_SAFE_INTEGER),'TRANSACTION','Invalid TRON timestamp or expiration.');
  check(r[11]?.length===1,'UNSUPPORTED','Exactly one TRON contract is supported per transaction.');
  check(nv(r,18)<=(1n<<63n)-1n,'FEE','Invalid TRON fee limit.');
  const c=proto(r[11][0],{1:'n',2:'b',5:'n'});const permissionId=nv(c,5);check(permissionId!==1n&&permissionId<=2147483647n,'PERMISSION','Invalid or witness-only permission ID.');
  const any=proto(bv(c,2),{1:'b',2:'b'});const type=Number(nv(c,1));let typeName,value,title,owner,asset,summary,decodeStatus='fullyDecoded',riskLevel='warning',display;const fields=[field('Network','TRON'),field('Network context','Network context not included in raw transaction bytes'),field('Derivation path',request.path??'Provided by matched signing plan'),...(request.address?[field('Requested signer',request.address)]:[])],warnings=['TRON chain identity and current account permissions cannot be verified from transaction bytes offline. Verify the intended network in the hot wallet.'];
  if(type===1){typeName='TransferContract';const v=proto(bv(any,2),{1:'b',2:'b',3:'n'});owner=addr(bv(v,1));check(nv(v,3)>0n&&nv(v,3)<=(1n<<63n)-1n,'AMOUNT','Invalid TRX transfer amount.');value={owner_address:jaddr(bv(v,1)),to_address:jaddr(bv(v,2)),amount:number(nv(v,3))};title='TRX transfer';fields.push(field('Recipient',addr(bv(v,2))),field('Amount (TRX)',decimal(nv(v,3),6)));display={action:'Send',amount:decimal(nv(v,3),6),symbol:'TRX',counterpartyLabel:'To',counterparty:addr(bv(v,2))};}
  else if(type===31){typeName='TriggerSmartContract';const v=proto(bv(any,2),{1:'b',2:'b',3:'n',4:'b',5:'n',6:'n'});owner=addr(bv(v,1));check(nv(v,5)===0n&&nv(v,6)===0n,'UNSUPPORTED','TRC10 value in a smart contract call is unsupported.');check(nv(r,18)>0n,'FEE','TRON contract calls require an explicit fee limit.');check(nv(v,3)<=(1n<<63n)-1n,'AMOUNT','Invalid TRX call value.');const call=decodeCall('0x'+bytesToHex(bv(v,2).slice(1)),'0x'+bytesToHex(bv(v,4)),nv(v,3),0,{chainFamily:'tron',assetAddress:addr(bv(v,2)),formatAddress:toTron});value={owner_address:jaddr(bv(v,1)),contract_address:jaddr(bv(v,2)),data:bytesToHex(bv(v,4))};if(v[3])value.call_value=number(v[3]);if(v[5])value.call_token_value=number(v[5]);if(v[6])value.token_id=number(v[6]);title='TRON '+call.title;counterparty=call.counterparty?.role==='spender'||call.counterparty?.role==='operator'?{address:toTron(call.counterparty.address),role:call.counterparty.role}:{address:addr(bv(v,2)),role:'contract'};fields.push(field('Contract',addr(bv(v,2))),field('Attached TRX',decimal(nv(v,3),6)));fields.push(...call.fields.filter(f=>![...CONTRACT_FIELD_LABELS,'Native amount (wei)'].includes(f.label)));warnings.push(...call.warnings);asset=call.asset;decodeStatus=call.decodeStatus;riskLevel=call.riskLevel;if(call.summary)summary='TRON '+call.summary;
    display={...call.display,counterparty:toTron(call.display?.counterparty)};if(!display.counterparty)delete display.counterparty;if(display.assetContract)display.assetContract=toTron(display.assetContract);
    // The called contract is the counterparty unless the NFT asset box already shows it (as on EVM).
    if((display.counterpartyLabel==='Contract'||!display.counterparty)&&!(!display.counterparty&&display.assetContract===addr(bv(v,2))))Object.assign(display,{counterpartyLabel:'Contract',counterparty:addr(bv(v,2))});
    // decodeCall formats address fields as Base58 itself (formatAddress), so bytes values are never mistaken for addresses.
    if(nv(v,3)>0n){const trx=decimal(nv(v,3),6);warnings.push('This call also sends '+trx+' TRX to the contract.');riskLevel='high';
      // NFT call: keep the recipient / operator / spender; the asset contract's caption says it receives the TRX.
      if(display.assetContract&&display.assetContract===addr(bv(v,2)))display={...display,amount:trx,symbol:'TRX',assetContractLabel:(display.assetContractLabel??'Contract')+' · receives the '+trx+' TRX'};
      else{const nft=Object.fromEntries(['assetKind','assetContract','assetContractLabel','tokenId'].filter(k=>display[k]!==undefined).map(k=>[k,display[k]]));display={action:display.action,amount:trx,symbol:'TRX',headline:display.amount?display.amount+' '+display.symbol:display.headline,counterpartyLabel:'Contract',counterparty:addr(bv(v,2)),...nft};}
      if(summary)summary+=' (also sends '+trx+' TRX)';}}
  else if(type===46){typeName='AccountPermissionUpdateContract';const v=proto(bv(any,2),{1:'b',2:'b',3:'b',4:'b*'});owner=addr(bv(v,1));check(v[2],'PERMISSION','New owner permission is required.');value={owner_address:jaddr(bv(v,1)),owner:permission(v[2],0),actives:(v[4]??[]).map(b=>permission(b,2))};if(v[3])value.witness=permission(v[3],1);check(value.actives.length<=8,'PERMISSION','Too many active permissions.');check(permissionId===0n,'PERMISSION','Account permission updates must use the current owner permission (ID 0).');title='Update account permissions';for(const [label,perm] of [['Owner',value.owner],...value.actives.map((p,i)=>['Active '+(i+1),p]),...(value.witness?[['Witness',value.witness]]:[])]){fields.push(field('New '+label+' threshold',perm.threshold),field('New '+label+' permission ID',perm.id),field('New '+label+' members',perm.keys.map(k=>addr(hexToBytes(k.address))+' — weight '+k.weight).join('\n')));if(perm.operations)fields.push(field('New '+label+' allowed operations (bit mask)',perm.operations));}warnings.push('New permission members shown here are the replacement configuration, not evidence of current signing authority.');fields.push(field('New permission configuration',JSON.stringify(value,null,2)));warnings.push('HIGH RISK: This replaces account owners and spending permissions. Incorrect keys or thresholds can permanently lock funds.');display={action:'Update Permissions',headline:'Owner threshold '+value.owner.threshold+' · '+value.owner.keys.length+' key'+(value.owner.keys.length===1?'':'s')};}
  else if([54,55,56,57,58,59].includes(type)) {
    // tronprotocol/protocol core/contract/balance_contract.proto, Stake 2.0.
    const schemas={54:{1:'b',2:'n',3:'n'},55:{1:'b',2:'n',3:'n'},56:{1:'b'},57:{1:'b',2:'n',3:'n',4:'b',5:'n',6:'n'},58:{1:'b',2:'n',3:'n',4:'b'},59:{1:'b'}};
    const names={54:'FreezeBalanceV2Contract',55:'UnfreezeBalanceV2Contract',56:'WithdrawExpireUnfreezeContract',57:'DelegateResourceContract',58:'UnDelegateResourceContract',59:'CancelAllUnfreezeV2Contract'};
    const v=proto(bv(any,2),schemas[type]);owner=addr(bv(v,1));value={owner_address:jaddr(bv(v,1))};typeName=names[type];title=typeName.replace(/Contract$/,'');
    if([54,55].includes(type)){const amount=nv(v,2);check(amount>0n&&amount<=(1n<<63n)-1n,'AMOUNT','Invalid resource balance.');check(nv(v,3)<=1n,'RESOURCE','Unsupported resource type.');value[type===54?'frozen_balance':'unfreeze_balance']=number(amount);value.resource=number(nv(v,3));fields.push(field('Resource',nv(v,3)?'Energy':'Bandwidth'),field('Amount (TRX)',decimal(amount,6)));}
    if(type===57||type===58){check(nv(v,2)<=1n&&nv(v,3)>0n&&nv(v,3)<=(1n<<63n)-1n,'RESOURCE','Invalid resource delegation.');value.resource=number(nv(v,2));value.balance=number(nv(v,3));value.receiver_address=jaddr(bv(v,4));fields.push(field('Resource',nv(v,2)?'Energy':'Bandwidth'),field('Receiver',addr(bv(v,4))),field('Delegated balance (TRX)',decimal(nv(v,3),6)));if(type===57){check(nv(v,5)<=1n&&nv(v,6)<=(1n<<63n)-1n,'RESOURCE','Invalid delegation lock.');if(v[5])value.lock=!!nv(v,5);if(v[6])value.lock_period=number(nv(v,6));fields.push(field('Locked',nv(v,5)?'Yes':'No'),field('Lock period (blocks)',nv(v,6)));}}
    warnings.push('Available staked resources, pending unfreezes and delegation state cannot be verified offline.');
    const staked=value.frozen_balance??value.unfreeze_balance??value.balance;
    display={action:title.replace(/([a-z])([A-Z])/g,'$1 $2').replace(/ V2$/,''),...(staked!==undefined?{amount:decimal(BigInt(staked),6),symbol:'TRX'}:{}),...(value.receiver_address?{counterpartyLabel:'Receiver',counterparty:addr(hexToBytes(value.receiver_address))}:{})};
  }
  else fail('UNSUPPORTED','Unsupported TRON contract type. Its signed structure cannot be safely parsed.');
  check(text(bv(any,1))==='type.googleapis.com/protocol.'+typeName,'INTEGRITY','TRON contract type URL does not match the contract type.');
  const rawJSON={ref_block_bytes:bytesToHex(r[1]),ref_block_hash:bytesToHex(r[4]),expiration:number(r[8]),contract:[{parameter:{value,type_url:text(any[1])},type:typeName}],timestamp:number(r[14])};
  if(r[3])rawJSON.ref_block_num=number(r[3]);if(r[10])rawJSON.data=bytesToHex(r[10]);if(r[18])rawJSON.fee_limit=number(r[18]);if(permissionId)rawJSON.contract[0].Permission_id=number(permissionId);
  if(tx.raw_data)check(stable(normalizeJSON(tx.raw_data))===stable(normalizeJSON(rawJSON)),'INTEGRITY','TRON raw_data JSON differs from the signed protobuf bytes.');
  const signatures=tx.signature??[];check(Array.isArray(signatures)&&signatures.length<=32,'SIGNATURE','Invalid signature array.');
  const existingSigners=signatures.map(s=>{const b=hexToBytes(s,65);check(b.length===65&&b[64]<2,'SIGNATURE','Invalid existing TRON signature.');try{const pub=secp256k1.recoverPublicKey(concat(b.slice(64),b.slice(0,64)),digest,{prehash:false});check(secp256k1.verify(b.slice(0,64),digest,pub,{prehash:false,lowS:true}),'SIGNATURE','Invalid TRON signature.');return tronAddress(pub);}catch{fail('SIGNATURE','Existing TRON signature cannot be verified.');}});
  check(new Set(existingSigners).size===existingSigners.length,'SIGNATURE','Duplicate TRON signer.');
  if(nv(r,18)>HIGH_FEE_LIMIT){warnings.unshift('HIGH FEE: This transaction allows up to '+decimal(nv(r,18),6)+' TRX in energy fees. Check the fee limit in your other wallet.');riskLevel='high';}
  // The only fee figure a TRON transaction carries is fee_limit, and it caps
  // energy for contract execution alone. Bandwidth, account creation and
  // operation fees are charged separately, from resources and chain parameters
  // that cannot be read offline, so no total can be promised here.
  warnings.push(nv(r,18)>0n
    ?'The fee limit caps only the energy this transaction may burn. Bandwidth and any operation fee are charged on top of it, from account resources and chain parameters that cannot be read offline, so the total fee is not known here.'
    :'This transaction sets no fee limit. Bandwidth and any operation fee are still charged, from account resources and chain parameters that cannot be read offline, so the total fee is not known here.');
  fields.unshift(field('Account',owner),field('Permission ID',permissionId));fields.push(field('Maximum energy fee (TRX)',decimal(nv(r,18),6)),field('Expiration (UTC)',new Date(Number(r[8])).toISOString()),field('Transaction ID',txID));if(r[10])fields.push(field('Memo (hex)',bytesToHex(r[10])));if(existingSigners.length)fields.push(field('Existing signers',existingSigners.join('\n')));if(permissionId===0n)warnings.push('Owner permission ID 0 may use weighted multisig members. Current membership, weights and threshold are unverified offline.');if(permissionId)warnings.push('Multisig member weights and whether the selected permission is current are unverified offline. This adds one signature only.');
  if(permissionId===0n&&request.address&&normalizeAddress(request.address)!==normalizeAddress(owner))warnings.push('Owner permission (ID 0): the requested signer differs from the account address. Current owner membership, weights and threshold are unverified offline. This adds one member signature only; the coordinator must verify membership and sufficient total weight before broadcast.');
  const contract=counterparty?describeContract('tron',undefined,counterparty.address,counterparty.role):undefined;
  if(contract?.known)fields.push(field(contract.role==='spender'?'Spender (known contract)':'Contract (known)',`${contract.name} — ${contract.protocol} · ${contract.category}`));
  else if(contract&&['spender','operator'].includes(contract.role))warnings.push('The spender is not in the bundled list of known public contracts. It may be new, or it may be an imitation. Check the address against the project\u2019s own documentation before signing.');
  else if(contract)warnings.push('This contract is not in the bundled list of known public contracts. That is normal for a new or private deployment; check the address against the project\u2019s own documentation.');
  return {digest,txID,owner,permissionId,rawJSON,existingSigners,signatures,signingBytesDigest:txID,signerSelectors:{path:request.path,masterFingerprint:request.masterFingerprint,address:request.address,operatedAccountAddress:owner,permissionId:permissionId.toString()},review:reviewResult(request,title,asset?`${title}: ${asset.displayAmount} ${asset.symbol}`:summary?summary:fields.find(f=>f.label==='Amount (TRX)')?`${fields.find(f=>f.label==='Amount (TRX)').value} TRX`:title,fields,warnings,{decodeStatus,riskLevel:type===46||warnings.some(w=>/approval|authoriz|HIGH RISK|HIGH FEE/i.test(w))?'high':riskLevel,network:NETWORK,display:{...(display??{action:title}),...(nv(r,18)>0n?{fee:decimal(nv(r,18),6)+' TRX',feeKind:'energyBudget'}:{})},...(contract?{contract}:{}),...(asset?{asset}:{})})};
}
export function signTron(request,seed,root,task) {
  const p=parseTron(request),target=task?.targets?.[0];
  if(task)check(task.targets?.length===1,'SIGNER','A TRON task requires one signer.');
  const path=target?.path??request.path??PATHS.tron;
  return withKey(seed,root,'tron',path,(key,pub)=>{
    const address=tronAddress(pub);
    if(target?.publicKey)check(equal(pub,hexToBytes(target.publicKey,33)),'SIGNER','TRON task public key differs from the decrypted wallet.');
    for(const expected of [request.address,target?.address].filter(Boolean))check(normalizeAddress(expected)===normalizeAddress(address),'SIGNER','Requested TRON signer does not match this wallet.');
    if(request.kind==='transaction') {
      // Owner permission ID 0 may contain weighted members unlike owner_address.
      // A resolved immutable task identifies a member without rewriting the request.
      if(p.permissionId===0n&&address!==p.owner)check(!!request.address||!!target,'SIGNER','Owner multisig requires an explicit matched signer.');
      check(!p.existingSigners.includes(address),'SIGNATURE','This wallet has already signed the transaction.');
    }
    const sig=secp256k1.sign(p.digest,key,{prehash:false,lowS:true,format:'recovered'});
    const signature=bytesToHex(concat(sig.slice(1),sig.slice(0,1)));
    check(tronAddress(secp256k1.recoverPublicKey(sig,p.digest,{prehash:false}))===address&&secp256k1.verify(sig.slice(1),p.digest,pub,{prehash:false,lowS:true}),'SIGNATURE','Signature verification failed.');
    const result={chain:'tron',requestHash:p.review.requestHash,address,signature,digest:bytesToHex(p.digest),signatureV:String(27+sig[0])};
    if(request.kind==='transaction')Object.assign(result,{txID:p.txID,signedTransaction:{visible:false,txID:p.txID,raw_data:p.rawJSON,raw_data_hex:request.transaction.raw_data_hex.toLowerCase().replace(/^0x/,''),signature:[...p.signatures,signature]}});
    return result;
  });
}
