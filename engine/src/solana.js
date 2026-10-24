import { ed25519 } from '@noble/curves/ed25519.js';
import { sha256 } from '@noble/hashes/sha2.js';
import { base58 } from '@scure/base';
import { check, fail, field, reviewResult, fromBase64, toBase64, bytesToHex, Reader, concat, short, decimal, text, utf8, equal, hexToBytes } from './util.js';
import { describeContract } from './known-contracts.js';
import { lookupToken } from './token-registry.js';
import { PATHS, withKey } from './keys.js';
const SYSTEM='11111111111111111111111111111111';
const TOKEN='TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA';
const TOKEN2022='TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb';
const ATA='ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL';
const COMPUTE='ComputeBudget111111111111111111111111111111';
const STAKE='Stake11111111111111111111111111111111111111';
const SQUADS='SQDS4ep65T869zMMBKyuUq6aD6EgTu8psMjkvj52pCf';
const MEMO='MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr';
// Metaplex programs and their fixed accounts (declare_id! / IDL metadata.address in the official repositories).
const TOKEN_METADATA='metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s';
const BUBBLEGUM='BGUMAp9Gq7iTEuizy4pqaxsTyUCBK68MDfK752saRPUY';
const CORE='CoREENxT6tW1HoK8ypY1SxRMZTcVPm7R94rH4PZNhX7d';
const SYSVAR_INSTRUCTIONS='Sysvar1nstructions1111111111111111111111111';
const AUTH_RULES='auth9SigNpDKz4sJJ1DfCTuZrZNSAgh9sFD3rboVmgg';
const SPL_NOOP='noopb9bkMVfRPU8AsbpTUg8AQkHtKwMYZiFUjNRtMmV',SPL_COMPRESSION='cmtDvXumGCrqC1Age74AVPhSRVXJMd8PJS91L8KbNCK';
const MPL_NOOP='mnoopTCrg4p8ry25e4bcWA9XZjbNjMTfgYVGGEdRsf3',MPL_COMPRESSION='mcmt6YrQEMKw8Mw43FmpRLmf7BqRnFMKmAcbxE3xkAW';
const BUBBLEGUM_TRANSFER_V2_FEE=6000n; // state/collect.rs TRANSFER_V2_FEE_LAMPORTS, paid by the payer to the tree config
// Named only: these programs are never decoded, their instructions stay opaque and HIGH RISK.
const MARKETPLACES=Object.freeze({'M2mx93ekt1fmXSVkTrUL9xVFHkmME8HTUi5Cyc5aF7K':'Magic Eden M2','mmm3XBJg5gk8XJxEKBvdgptZz6SgK4tXvn36sodowMc':'Magic Eden MMM','TCMPhJdwDryooaGtiocG1u3xcYbRpiJzb283XfCZsDp':'Tensor Marketplace','TSWAPaqyCSx2KABk68Shruf4rp7CxcNi8hAsbdwmHbN':'Tensor Swap','TAMM6ub33ij1mbetoMyVBLeKY5iP41i4UPUJQGkhfsg':'Tensor AMM','hausS13jsjafwWwGqZTUQRmWyvyxn9EQpqMwV1PBBmk':'Metaplex Auction House'});
const NFT_PROGRAMS=Object.freeze({[TOKEN_METADATA]:'Metaplex Token Metadata',[BUBBLEGUM]:'Metaplex Bubblegum',[CORE]:'Metaplex Core'});
// Programs this file decodes instruction by instruction. Their own Action
// field says more than a library name would, so the library is not consulted.
const DECODED_PROGRAMS=new Set([SYSTEM,TOKEN,TOKEN2022,ATA,COMPUTE,MEMO,STAKE,SQUADS]);
// Instruction names by u8 discriminant (idls/token_metadata.json, idls/mpl_core.json) and Anchor sighash (bubblegum lib.rs).
const TM_NAMES='CreateMetadataAccount UpdateMetadataAccount DeprecatedCreateMasterEdition DeprecatedMintNewEditionFromMasterEditionViaPrintingToken UpdatePrimarySaleHappenedViaToken DeprecatedSetReservationList DeprecatedCreateReservationList SignMetadata DeprecatedMintPrintingTokensViaToken DeprecatedMintPrintingTokens CreateMasterEdition MintNewEditionFromMasterEditionViaToken ConvertMasterEditionV1ToV2 MintNewEditionFromMasterEditionViaVaultProxy PuffMetadata UpdateMetadataAccountV2 CreateMetadataAccountV2 CreateMasterEditionV3 VerifyCollection Utilize ApproveUseAuthority RevokeUseAuthority UnverifyCollection ApproveCollectionAuthority RevokeCollectionAuthority SetAndVerifyCollection FreezeDelegatedAccount ThawDelegatedAccount RemoveCreatorVerification BurnNft VerifySizedCollectionItem UnverifySizedCollectionItem SetAndVerifySizedCollectionItem CreateMetadataAccountV3 SetCollectionSize SetTokenStandard BubblegumSetCollectionSize BurnEditionNft CreateEscrowAccount CloseEscrowAccount TransferOutOfEscrow Burn Create Mint Delegate Revoke Lock Unlock Migrate Transfer Update Use Verify Unverify Collect Print Resize CloseAccounts'.split(' ');
const CORE_NAMES='CreateV1 CreateCollectionV1 AddPluginV1 AddCollectionPluginV1 RemovePluginV1 RemoveCollectionPluginV1 UpdatePluginV1 UpdateCollectionPluginV1 ApprovePluginAuthorityV1 ApproveCollectionPluginAuthorityV1 RevokePluginAuthorityV1 RevokeCollectionPluginAuthorityV1 BurnV1 BurnCollectionV1 TransferV1 UpdateV1 UpdateCollectionV1 CompressV1 DecompressV1 Collect CreateV2 CreateCollectionV2 AddExternalPluginAdapterV1 AddCollectionExternalPluginAdapterV1 RemoveExternalPluginAdapterV1 RemoveCollectionExternalPluginAdapterV1 UpdateExternalPluginAdapterV1 UpdateCollectionExternalPluginAdapterV1 WriteExternalPluginAdapterDataV1 WriteCollectionExternalPluginAdapterDataV1 UpdateV2 ExecuteV1 UpdateCollectionInfoV1 AddCollectionsToGroupV1 RemoveCollectionsFromGroupV1 AddAssetsToGroupV1 RemoveAssetsFromGroupV1 AddGroupsToGroupV1 RemoveGroupsFromGroupV1 CreateGroupV1 CloseGroupV1 UpdateGroupV1'.split(' ');
const BUBBLEGUM_NAMES='burn burn_v2 cancel_redeem close_tree_v2 collect_v2 compress create_tree create_tree_v2 decompress_v1 delegate delegate_and_freeze_v2 delegate_v2 freeze_v2 mint_to_collection_v1 mint_v1 mint_v2 redeem set_and_verify_collection set_collection_v2 set_decompressable_state set_decompressible_state set_non_transferable_v2 set_tree_delegate thaw_and_revoke_v2 thaw_v2 transfer transfer_v2 unverify_collection unverify_creator unverify_creator_v2 update_asset_data_v2 update_metadata update_metadata_v2 verify_collection verify_creator verify_creator_v2'.split(' ');
const anchor=(name)=>sha256(utf8('global:'+name)).slice(0,8);
const BG_TRANSFER=anchor('transfer'),BG_TRANSFER_V2=anchor('transfer_v2'),BG_DELEGATE=anchor('delegate'),BG_DELEGATE_V2=anchor('delegate_v2');
let bubblegumSighashes;
const bubblegumName=(data)=>{if(data.length<8)return undefined;bubblegumSighashes??=BUBBLEGUM_NAMES.map(n=>[n,anchor(n)]);return bubblegumSighashes.find(([,d])=>equal(d,data.slice(0,8)))?.[0];};
const OPAQUE_NAMED_WARNINGS=Object.freeze({AddPluginV1:'HIGH RISK: Adding a plugin can create a transfer, burn or freeze delegate or change royalties on this Core asset.',ApprovePluginAuthorityV1:'HIGH RISK: This can give another address authority over a plugin on this Core asset, such as a transfer, burn or freeze delegate.',BurnV1:'HIGH RISK: This burns a Core asset. Burning is irreversible.',burn:'HIGH RISK: This burns a compressed NFT. Burning is irreversible.',burn_v2:'HIGH RISK: This burns a compressed NFT. Burning is irreversible.',BurnEditionNft:'HIGH RISK: This burns a print-edition NFT. Burning is irreversible.'});
// Token Metadata DelegateArgs and RevokeArgs are separate enums with different variant orders.
const DELEGATE_ARGS='CollectionV1 SaleV1 TransferV1 DataV1 UtilityV1 StakingV1 StandardV1 LockedTransferV1 ProgrammableConfigV1 AuthorityItemV1 DataItemV1 CollectionItemV1 ProgrammableConfigItemV1 PrintDelegateV1'.split(' ');
const REVOKE_ARGS='CollectionV1 SaleV1 TransferV1 DataV1 UtilityV1 StakingV1 StandardV1 LockedTransferV1 ProgrammableConfigV1 MigrationV1 AuthorityItemV1 DataItemV1 CollectionItemV1 ProgrammableConfigItemV1 PrintDelegateV1'.split(' ');
// Token delegate roles that Token Metadata accepts only for programmable NFTs (delegate.rs/revoke.rs: every other
// standard requires StandardV1). StandardV1, metadata and holder delegates never read the edition account, so only
// the role, not a supplied edition, can prove an NFT.
const PNFT_ONLY_ROLES=new Set(['SaleV1','TransferV1','LockedTransferV1','UtilityV1','StakingV1','MigrationV1']);
const AMOUNT_ROLES=new Set(['SaleV1','TransferV1','UtilityV1','StakingV1','StandardV1','LockedTransferV1']);
// Token delegate powers per https://metaplex.com/docs/token-metadata/delegates; every other variant is a metadata delegate.
// transfer.rs handles a LockedTransfer delegate as a Transfer delegate: the locked address is stored but never enforced.
const DELEGATE_POWERS=Object.freeze({SaleV1:'can transfer this NFT without asking you again',TransferV1:'can transfer this NFT without asking you again',LockedTransferV1:'can lock this NFT and transfer it to any address without asking you again (the locked address in the arguments is not enforced by Token Metadata)',StandardV1:'can transfer, burn and lock up to the delegated amount of this token without asking you again',UtilityV1:'can burn and lock this NFT without asking you again',StakingV1:'can lock this NFT so it cannot be transferred until the delegate unlocks it'});
const NAME_ONLY='HIGH RISK: Only the instruction type and key accounts are decoded. Its arguments and on-chain effects cannot be fully verified offline.';
const CNFT_WARNINGS=['The NFT’s name, image and collection are committed only as hashes and cannot be displayed offline. Compare the asset ID with an independent source.','If the Merkle proof is stale the transaction fails; it cannot affect any asset other than the asset ID shown.'];
const NETWORK={name:'Solana',symbol:'SOL'};
const HIGH_PRIORITY_FEE=10000000n; // 0.01 SOL
const pubkey=(address)=>base58.decode(address);
function pda(seeds,program){const id=pubkey(program);for(let i=255;i>=0;i--){const h=sha256(concat(...seeds,new Uint8Array([i]),id,utf8('ProgramDerivedAddress')));try{ed25519.Point.fromBytes(h);continue;}catch{return base58.encode(h);}}fail('ADDRESS','Unable to derive program address.');}
function ataAddress(owner,token,mint){return pda([pubkey(owner),pubkey(token),pubkey(mint)],ATA);}
const tmPda=(mint,...seeds)=>pda([utf8('metadata'),pubkey(TOKEN_METADATA),pubkey(mint),...seeds],TOKEN_METADATA);
const notSupplied=(account,placeholder)=>account===placeholder?'Not supplied':account;
function nftResult(){const o={fields:[],warnings:[],movements:[],riskLevel:'normal',decodeStatus:'fullyDecoded',extra:{}};
  o.add=(...pairs)=>{for(let i=0;i<pairs.length;i+=2)o.fields.push(field(pairs[i],pairs[i+1]));};
  o.high=(warning)=>{o.riskLevel='high';o.warnings.push(warning);};o.partial=()=>{o.decodeStatus='partiallyDecoded';};return o;}
// Metaplex Token Metadata. Omitted optional accounts are passed as the program ID itself.
function tmTransfer(a,data,signers){
  const TM=TOKEN_METADATA;
  // [49][TransferArgs::V1 = 0][amount u64][Option<AuthorizationData>]; exactly 17 accounts.
  if(a.length!==17||data.length<11||data[1]!==0||data[10]>1||(data[10]===0)!==(data.length===11))return;
  const [token,owner,destination,destinationOwner,mint,metadata,edition,ownerRecord,destinationRecord,authority,payer,system,sysvar,tokenProgram,ataProgram,rulesProgram,rules]=a;
  if(system!==SYSTEM||sysvar!==SYSVAR_INSTRUCTIONS||![TOKEN,TOKEN2022].includes(tokenProgram)||ataProgram!==ATA||![AUTH_RULES,TM].includes(rulesProgram)||(rulesProgram===TM&&rules!==TM))return;
  if([token,owner,destination,destinationOwner,mint,metadata,authority,payer].includes(TM))return;
  // Clients always pass these PDAs; Token Metadata only creates its accounts there, so anything else is refused.
  check(metadata===tmPda(mint),'INSTRUCTION','Metaplex metadata account does not match the mint.');
  const editionPda=tmPda(mint,utf8('edition'));
  check(edition===TM||edition===editionPda,'INSTRUCTION','Metaplex edition account does not match the mint.');
  check(ownerRecord===TM||ownerRecord===tmPda(mint,utf8('token_record'),pubkey(token)),'INSTRUCTION','Metaplex token record does not match the source token account.');
  check(destinationRecord===TM||destinationRecord===tmPda(mint,utf8('token_record'),pubkey(destination)),'INSTRUCTION','Metaplex token record does not match the destination token account.');
  const amount=new Reader(data.slice(2,10)).u64(),o=nftResult();
  // Transfer falls through to transfer_checked for fungible standards, and decimals are not in the instruction.
  // Only a supplied edition PDA (which the program requires to be owned by Token Metadata) proves an NFT.
  const nft=edition===editionPda&&amount===1n,unit=amount===1n?'raw unit':'raw units',headline=nft?'1 NFT':`${amount} ${unit}`,action=nft?'Send NFT':'Send Metaplex token';
  o.add('Action',action,'Mint',mint,'Raw amount',amount,
    'Asset type',nft?'NFT: the edition account for this mint is supplied, and Token Metadata requires it to be a Metaplex edition':edition===editionPda?'Metaplex edition supplied, but the amount is not 1':'Not proven to be an NFT: no edition account is supplied, so this may be a fungible Metaplex token',
    'From wallet (token owner)',owner,'Source token account',token,'To wallet',destinationOwner,'Destination token account',destination,
    'Destination account type',destination===ataAddress(destinationOwner,tokenProgram,mint)?'Associated token account of the recipient wallet':'Not the recipient wallet’s associated token account; it must already exist and be owned by the recipient',
    'Transfer authority',authority,'Payer',payer,'Token program',tokenProgram,'Edition account',notSupplied(edition,TM),'Token records supplied',ownerRecord!==TM||destinationRecord!==TM?'Yes':'No');
  if(rules!==TM)o.add('Rule set',rules);
  o.movements.push({amount:nft?'1':String(amount),symbol:nft?'NFT':unit,to:destinationOwner,label:'To'});
  o.extra.display={action,headline,summary:headline,assetKind:nft?'nft':'nftOrToken',assetContract:mint,assetContractLabel:'Mint'};
  o.extra.nftTransfer={destination,owner:destinationOwner,mint,tokenProgram};
  o.warnings.push('NFT name, image and collection are not in the transaction and cannot be verified offline. Compare the mint address with an independent source.');
  if(!nft)o.warnings.push('Decimals are not included in this instruction, so the amount is shown in raw units. Without the edition account this may be a fungible token rather than an NFT.');
  if(authority!==owner)o.high('HIGH RISK: The transfer authority '+authority+' is not the token owner '+owner+'. This transfer is authorised as a delegate of that wallet (for example a sale, transfer, locked-transfer, standard or migration delegate), not by the owner.');
  if(!signers.has(authority))o.warnings.push('The transfer authority does not sign this transaction, so the transfer will fail on-chain.');
  if(rules!==TM)o.warnings.push('A royalty/transfer rule set will be evaluated on-chain and cannot be checked offline.');
  if(tokenProgram===TOKEN2022){o.high('Token-2022 mint extensions and transfer hooks cannot be verified offline.');o.partial();}
  if(data[10]===1){o.add('Authorization data (not decoded)',bytesToHex(data.slice(11)));o.warnings.push('Authorization rule payload is not decoded.');o.partial();}
  return o;
}
// DelegateArgs::<variant> after [44][variant]: amount u64 (token roles), locked_address (LockedTransferV1), then
// Option<AuthorizationData> for every variant except StandardV1. Anything that is not exactly this shape stays opaque.
function delegateArgs(variant,data){
  const out={};let p=2;
  if(AMOUNT_ROLES.has(variant)){if(data.length<p+8)return;out.amount=new Reader(data.slice(p,p+8)).u64();p+=8;}
  if(variant==='LockedTransferV1'){if(data.length<p+32)return;out.lockedAddress=base58.encode(data.slice(p,p+32));p+=32;}
  if(variant==='StandardV1')return data.length===p?out:undefined;
  if(data.length<=p||data[p]>1||(data[p]===0)!==(data.length===p+1))return;
  if(data[p]===1)out.authData=data.slice(p+1);
  return out;
}
function tmDelegate(a,data,revoke){
  const TM=TOKEN_METADATA,variant=(revoke?REVOKE_ARGS:DELEGATE_ARGS)[data[1]];
  if(!variant||a.length!==14)return;
  const args=revoke?(data.length===2?{}:undefined):delegateArgs(variant,data);if(!args)return;
  const [,delegate,metadata,,,mint,token,authority,payer,system,sysvar,tokenProgram,rulesProgram]=a;
  if(system!==SYSTEM||sysvar!==SYSVAR_INSTRUCTIONS||![TOKEN,TOKEN2022,TM].includes(tokenProgram)||![AUTH_RULES,TM].includes(rulesProgram))return;
  if([delegate,metadata,mint,authority,payer].includes(TM)||metadata!==tmPda(mint))return;
  const nft=PNFT_ONLY_ROLES.has(variant),o=nftResult();
  o.add('Action',(revoke?'Revoke':'Approve')+(nft?' NFT ':' Metaplex ')+variant+' delegate','Delegate type',variant,
    'Asset type',nft?'Programmable NFT: Token Metadata accepts this delegate type only for programmable NFTs':'Not proven to be an NFT: Token Metadata does not require an NFT for this delegate type',
    'Delegate',delegate,'Mint',mint,'Token account',notSupplied(token,TM),'Authority (owner or update authority)',authority,'Payer',payer);
  if(args.amount!==undefined)o.add('Delegated amount (raw units)',args.amount);
  if(args.lockedAddress)o.add('Locked address (stored, not enforced)',args.lockedAddress);
  if(args.authData){o.add('Authorization data (not decoded)',bytesToHex(args.authData));o.warnings.push('Authorization rule payload is not decoded.');}
  if(!revoke)o.high('HIGH RISK: The delegate '+delegate+' '+(DELEGATE_POWERS[variant]??'gains '+variant+' authority over this asset’s metadata, collection or configuration')+'.');
  o.high(NAME_ONLY);o.partial();
  o.extra.display={assetKind:nft?'nft':'nftOrToken',assetContract:mint,assetContractLabel:'Mint'};
  return o;
}
function tmLock(a,data,unlock){
  const TM=TOKEN_METADATA;
  // [46|47][LockArgs/UnlockArgs::V1 = 0][Option<AuthorizationData>]; accounts: authority, tokenOwner?, token, mint, metadata, edition?, tokenRecord?, payer, system, sysvar, splToken?, rulesProgram?, rules?
  if(a.length!==13||data.length<3||data[1]!==0||data[2]>1||(data[2]===0)!==(data.length===3))return;
  const [authority,tokenOwner,token,mint,metadata,edition,,payer,system,sysvar,tokenProgram,rulesProgram]=a;
  if(system!==SYSTEM||sysvar!==SYSVAR_INSTRUCTIONS||![TOKEN,TOKEN2022,TM].includes(tokenProgram)||![AUTH_RULES,TM].includes(rulesProgram))return;
  if([authority,token,mint,metadata,payer].includes(TM)||metadata!==tmPda(mint))return;
  // Without an edition, a non-programmable token takes the fungible path (the mint freeze authority freezes it).
  const nft=edition===tmPda(mint,utf8('edition')),o=nftResult();
  o.add('Action',(unlock?'Unlock ':'Lock ')+(nft?'NFT':'Metaplex token'),'Mint',mint,'Token account',token,'Token owner',notSupplied(tokenOwner,TM),'Authority (delegate or freeze authority)',authority,'Payer',payer);
  if(data[2]===1)o.add('Authorization data (not decoded)',bytesToHex(data.slice(3)));
  if(!unlock)o.high('HIGH RISK: Locking freezes this token so its owner cannot transfer, sell or burn it until the locking authority unlocks it.');
  o.high(NAME_ONLY);o.partial();
  o.extra.display={assetKind:nft?'nft':'nftOrToken',assetContract:mint,assetContractLabel:'Mint'};
  return o;
}
function tmBurn(a,data){
  const TM=TOKEN_METADATA;
  // [41][BurnArgs::V1 = 0][amount u64]; accounts: authority, collectionMetadata?, metadata, edition?, mint, token, masterEdition?, masterEditionMint?, masterEditionToken?, editionMarker?, tokenRecord?, system, sysvar, splToken
  if(a.length!==14||data.length!==10||data[1]!==0)return;
  const [authority,collectionMetadata,metadata,edition,mint,token,,,,,,system,sysvar,tokenProgram]=a;
  if(system!==SYSTEM||sysvar!==SYSVAR_INSTRUCTIONS||![TOKEN,TOKEN2022].includes(tokenProgram))return;
  if([authority,metadata,mint,token].includes(TM)||metadata!==tmPda(mint))return;
  const nft=edition===tmPda(mint,utf8('edition')),o=nftResult();
  o.add('Action',nft?'Burn NFT (irreversible)':'Burn Metaplex token (irreversible)','Mint',mint,'Token account',token,'Raw amount',new Reader(data.slice(2)).u64(),'Authority (owner or delegate)',authority,'Edition account',notSupplied(edition,TM),'Collection metadata',notSupplied(collectionMetadata,TM));
  o.high('HIGH RISK: Burning permanently destroys this asset. This cannot be undone.');o.high(NAME_ONLY);o.partial();
  // Destruction is an economic effect, not just a field: without this the
  // headline aggregator cannot see the burn and a dust transfer beside it
  // becomes the whole summary. Metaplex carries no decimals, so a non-NFT
  // amount stays in raw units rather than being given invented ones.
  const burned=new Reader(data.slice(2)).u64();
  if(nft||burned>0n)o.movements.push({amount:nft?'1':String(burned),symbol:nft?'NFT':burned===1n?'raw unit':'raw units',
    to:mint,label:'Mint',destroys:true,raw:nft?1n:burned,scale:0});
  o.extra.display={assetKind:nft?'nft':'nftOrToken',assetContract:mint,assetContractLabel:'Mint'};
  return o;
}
function tmBurnNft(a,data){
  // Legacy [29]; accounts: metadata, owner, mint, tokenAccount, masterEdition, splToken, collectionMetadata (omitted when absent).
  if(data.length!==1||(a.length!==6&&a.length!==7))return;
  const [metadata,owner,mint,token,masterEdition,tokenProgram,collectionMetadata]=a;
  if(tokenProgram!==TOKEN||metadata!==tmPda(mint)||masterEdition!==tmPda(mint,utf8('edition')))return;
  const o=nftResult();
  o.add('Action','Burn NFT (irreversible)','Mint',mint,'Owner',owner,'Token account',token,'Master edition',masterEdition);if(collectionMetadata)o.add('Collection metadata',collectionMetadata);
  o.high('HIGH RISK: Burning permanently destroys this asset. This cannot be undone.');o.high(NAME_ONLY);o.partial();
  o.movements.push({amount:'1',symbol:'NFT',to:mint,label:'Mint',destroys:true,raw:1n,scale:0});
  o.extra.display={assetKind:'nft',assetContract:mint,assetContractLabel:'Mint'};
  return o;
}
function decodeTokenMetadata(a,data,signers){
  switch(data[0]){case 49:return tmTransfer(a,data,signers);case 44:return tmDelegate(a,data,false);case 45:return tmDelegate(a,data,true);case 46:return tmLock(a,data,false);case 47:return tmLock(a,data,true);case 41:return tmBurn(a,data);case 29:return tmBurnNft(a,data);default:return undefined;}
}
// Metaplex Bubblegum (Anchor). Data: sighash(8) root[32] data_hash[32] creator_hash[32] ...options nonce u64 index u32.
function bubblegumArgs(data,optionSizes){
  try{const r=new Reader(data);r.take(8);const out={root:r.take(32),dataHash:r.take(32),creatorHash:r.take(32),options:[]};
    for(const size of optionSizes){const tag=r.u8();if(tag>1)return undefined;out.options.push(tag?r.take(size):undefined);}
    out.nonceBytes=r.take(8);out.nonce=new Reader(out.nonceBytes).u64();out.index=r.u32();r.end();return out;}catch{return undefined;}
}
const treeConfigMatches=(config,tree)=>config===pda([pubkey(tree)],BUBBLEGUM);
const assetId=(tree,nonceBytes)=>pda([utf8('asset'),pubkey(tree),nonceBytes],BUBBLEGUM);
function leafFields(o,args,tree,config,proof){o.add('Merkle tree',tree,'Tree config',config,'Leaf index',args.index,'Nonce',args.nonce,'Proof accounts',proof.length,'Merkle root',bytesToHex(args.root),'Data hash',bytesToHex(args.dataHash),'Creator hash',bytesToHex(args.creatorHash));}
function compressedSend(o,id,to){o.movements.push({amount:'1',symbol:'NFT',to,label:'To'});o.extra.display={action:'Send compressed NFT',headline:'1 NFT',summary:'Send compressed NFT',assetKind:'nft',assetContract:id,assetContractLabel:'Asset ID'};o.warnings.push(...CNFT_WARNINGS);}
function bgTransfer(a,data,signers){
  const args=bubblegumArgs(data,[]);if(!args||a.length<8)return;
  const [config,leafOwner,leafDelegate,newOwner,tree,noop,compression,system]=a,proof=a.slice(8);
  if(noop!==SPL_NOOP||compression!==SPL_COMPRESSION||system!==SYSTEM||[leafOwner,leafDelegate,newOwner,tree].includes(BUBBLEGUM)||!treeConfigMatches(config,tree))return;
  const id=assetId(tree,args.nonceBytes),o=nftResult();
  o.add('Action','Send compressed NFT','Asset ID (derived from tree and nonce)',id,'From (leaf owner)',leafOwner);if(leafDelegate!==leafOwner)o.add('Leaf delegate',leafDelegate);
  o.add('New owner',newOwner);leafFields(o,args,tree,config,proof);compressedSend(o,id,newOwner);
  // transfer_v1 requires leaf_owner.is_signer || leaf_delegate.is_signer.
  if(!signers.has(leafOwner)&&!signers.has(leafDelegate))o.warnings.push('Neither the leaf owner nor the leaf delegate signs this transaction, so the transfer will fail on-chain.');
  else if(!signers.has(leafOwner))o.high('HIGH RISK: You are transferring an NFT owned by '+leafOwner+' as its delegate.');
  return o;
}
function bgTransferV2(a,data,signers){
  const args=bubblegumArgs(data,[32,1]);if(!args||a.length<11)return;
  const [config,payer,authorityAccount,leafOwner,delegateAccount,newOwner,tree,collectionAccount,noop,compression,system]=a,proof=a.slice(11);
  if(noop!==MPL_NOOP||compression!==MPL_COMPRESSION||system!==SYSTEM||[payer,leafOwner,newOwner,tree].includes(BUBBLEGUM)||!treeConfigMatches(config,tree))return;
  // Anchor reads the program ID as an omitted optional account; the program defaults authority to payer and delegate to owner.
  const authority=authorityAccount===BUBBLEGUM?payer:authorityAccount,leafDelegate=delegateAccount===BUBBLEGUM?leafOwner:delegateAccount,collection=collectionAccount===BUBBLEGUM?undefined:collectionAccount;
  const [assetDataHash,flags]=args.options,id=assetId(tree,args.nonceBytes),o=nftResult();
  o.add('Action','Send compressed NFT','Asset ID (derived from tree and nonce)',id,'From (leaf owner)',leafOwner);if(leafDelegate!==leafOwner)o.add('Leaf delegate',leafDelegate);
  o.add('New owner',newOwner,'Signing authority',authority,'Payer',payer,'Core collection',collection??'Not supplied');leafFields(o,args,tree,config,proof);
  // The fee is a detail, not a movement: a second movement would replace the NFT headline.
  o.add('Asset data hash',assetDataHash?bytesToHex(assetDataHash):'Not supplied (default)','Flags',flags?flags[0]:'Not supplied (default)','Bubblegum transfer fee (SOL)',decimal(BUBBLEGUM_TRANSFER_V2_FEE,9),'Transfer fee recipient (tree config)',config);
  compressedSend(o,id,newOwner);
  if(!signers.has(payer)||!signers.has(authority))o.warnings.push('The payer or signing authority does not sign this transaction, so the transfer will fail on-chain.');
  if(authority!==leafOwner)o.high('HIGH RISK: The signing authority '+authority+' is not the NFT owner '+leafOwner+'. You are transferring it as its delegate or as the collection’s permanent transfer delegate.');
  if(collection)o.warnings.push('Collection plugins (permanent transfer delegate, royalties, freeze) are evaluated on-chain and cannot be checked offline.');
  return o;
}
function compressedDelegate({args,config,tree,proof,leafOwner,previousDelegate,newDelegate,payer,signed,canFreeze=false,extraFields=[]}){
  const id=assetId(tree,args.nonceBytes),o=nftResult(),clear=newDelegate===leafOwner;
  o.add('Action',clear?'Remove compressed-NFT delegate':'Approve compressed-NFT delegate','Asset ID (derived from tree and nonce)',id,'Leaf owner',leafOwner,'Previous delegate',previousDelegate,'New delegate',newDelegate);
  if(payer)o.add('Payer',payer);leafFields(o,args,tree,config,proof);o.add(...extraFields);o.warnings.push(...CNFT_WARNINGS);
  if(!signed)o.warnings.push('The leaf owner'+(payer?' or payer':'')+' does not sign this transaction, so it will fail on-chain.');
  // V2 trees also let the leaf delegate freeze_v2 the asset; delegate_v2 fails on a frozen leaf (asset_validate_delegate).
  if(!clear)o.high('HIGH RISK: The new delegate '+newDelegate+(canFreeze?' can transfer, burn or freeze':' can transfer or burn')+' this compressed NFT without asking you again, until the delegate is changed or the NFT is transferred.'+(canFreeze?' While it is frozen, you cannot transfer it or change the delegate.':''));
  o.extra.display={assetKind:'nft',assetContract:id,assetContractLabel:'Asset ID'};
  return o;
}
function bgDelegate(a,data,signers){
  const args=bubblegumArgs(data,[]);if(!args||a.length<8)return;
  const [config,leafOwner,previousDelegate,newDelegate,tree,noop,compression,system]=a;
  if(noop!==SPL_NOOP||compression!==SPL_COMPRESSION||system!==SYSTEM||[leafOwner,previousDelegate,newDelegate,tree].includes(BUBBLEGUM)||!treeConfigMatches(config,tree))return;
  return compressedDelegate({args,config,tree,proof:a.slice(8),leafOwner,previousDelegate,newDelegate,signed:signers.has(leafOwner)});
}
function bgDelegateV2(a,data,signers){
  const args=bubblegumArgs(data,[32,32,1]);if(!args||a.length<9)return;
  const [config,payer,ownerAccount,previousAccount,newDelegate,tree,noop,compression,system]=a;
  if(noop!==MPL_NOOP||compression!==MPL_COMPRESSION||system!==SYSTEM||[payer,newDelegate,tree].includes(BUBBLEGUM)||!treeConfigMatches(config,tree))return;
  const leafOwner=ownerAccount===BUBBLEGUM?payer:ownerAccount,previousDelegate=previousAccount===BUBBLEGUM?leafOwner:previousAccount,[collectionHash,assetDataHash,flags]=args.options;
  return compressedDelegate({args,config,tree,proof:a.slice(9),leafOwner,previousDelegate,newDelegate,payer,signed:signers.has(payer)&&signers.has(leafOwner),canFreeze:true,
    extraFields:['Collection hash',collectionHash?bytesToHex(collectionHash):'Not supplied (default)','Asset data hash',assetDataHash?bytesToHex(assetDataHash):'Not supplied (default)','Flags',flags?flags[0]:'Not supplied (default)']});
}
function decodeBubblegum(a,data,signers){
  if(data.length<8)return undefined;const sighash=data.slice(0,8);
  if(equal(sighash,BG_TRANSFER))return bgTransfer(a,data,signers);
  if(equal(sighash,BG_TRANSFER_V2))return bgTransferV2(a,data,signers);
  if(equal(sighash,BG_DELEGATE))return bgDelegate(a,data,signers);
  if(equal(sighash,BG_DELEGATE_V2))return bgDelegateV2(a,data,signers);
  return undefined;
}
// Metaplex Core TransferV1: exactly [14, None]. A compression-proof variant stays opaque as a fail-closed choice.
function decodeCore(a,data,signers){
  if(data.length!==2||data[0]!==14||data[1]!==0||a.length<7)return;
  const [asset,collection,payer,authorityAccount,newOwner,system,logWrapper]=a,extras=a.slice(7);
  if(![SYSTEM,CORE].includes(system)||![SPL_NOOP,CORE].includes(logWrapper)||[asset,payer,newOwner].includes(CORE))return;
  const authority=authorityAccount===CORE?payer:authorityAccount,o=nftResult();
  o.add('Action','Send Core NFT','Asset ID',asset,'Collection',notSupplied(collection,CORE),'Signing authority',authority,'Payer',payer,'New owner',newOwner);
  if(extras.length)o.add('Additional accounts (plugin adapters)',extras.join('\n'));
  o.movements.push({amount:'1',symbol:'NFT',to:newOwner,label:'To'});
  o.extra.display={action:'Send Core NFT',headline:'1 NFT',summary:'Send Core NFT',assetKind:'nft',assetContract:asset,assetContractLabel:'Asset ID'};
  o.warnings.push('The asset’s current owner is not included in the transaction. The signing authority must be the owner or an approved transfer delegate; if this is not your NFT, you are acting as a delegate.','Core plugins (royalties, freeze, permanent transfer delegate, oracle) can block or alter this transfer and cannot be checked offline.','NFT name, image and collection are not in the transaction and cannot be verified offline. Compare the asset ID with an independent source.');
  if(!signers.has(payer)||!signers.has(authority))o.warnings.push('The payer or signing authority does not sign this transaction, so the transfer will fail on-chain.');
  if(extras.length){o.high('HIGH RISK: Additional accounts are passed to Core plugin adapters (for example lifecycle hooks or oracles). Their programs are not decoded and cannot be checked offline.');o.partial();}
  return o;
}
function instruction(program,a,data,signers){
  const r=new Reader(data),fields=[field('Program',program)],warnings=[],movements=[],extra={};let asset,riskLevel='normal',decodeStatus='fullyDecoded';
  const programName=MARKETPLACES[program]??NFT_PROGRAMS[program];if(programName)fields.push(field('Program name',programName));
  // The bundled library names programs this file does not decode itself; a
  // program it does decode is already named by its own Action field. The
  // library identifies a deployment and nothing else, so an unlisted program
  // adds no warning here: whether the instruction was decoded carries that.
  else if(!DECODED_PROGRAMS.has(program)){const known=describeContract('solana',undefined,program,'contract');
    if(known?.known)fields.push(field('Program (known)',known.name+' — '+known.protocol+' · '+known.category));}
  const opaque=(name)=>{if(name)fields.push(field('Instruction',name+' (not decoded)'));fields.push(field('Accounts',a.join('\n')),field('Exact instruction bytes',bytesToHex(data)));
    const market=MARKETPLACES[program];if(market){extra.marketplace=market;warnings.push('HIGH RISK: This '+market+' NFT marketplace instruction (list, delist, buy, sell, bid or pool deposit) is not decoded. It may move your NFT into marketplace escrow, give the marketplace a sale delegate, or spend SOL. Only sign if you started exactly this action on '+market+'.');}
    else warnings.push('HIGH RISK: This instruction is not semantically decoded and may transfer assets or change permissions.');
    if(name&&OPAQUE_NAMED_WARNINGS[name])warnings.push(OPAQUE_NAMED_WARNINGS[name]);
    if(programName)extra.named=true;r.pos=data.length;decodeStatus='opaque';riskLevel='high';};
  const count=(n)=>check(a.length===n,'INSTRUCTION','Unexpected number of instruction accounts.');
  const tokenCount=(n,unbounded=false)=>check(a.length>=n&&(unbounded||a.length<=n+11),'INSTRUCTION','Invalid token signer accounts.');
  if(program===SYSTEM){const opcode=r.u32();if(opcode===2){count(2);const lamports=r.u64();fields.push(field('Action','Transfer SOL'),field('Source',a[0]),field('Recipient',a[1]),field('Amount (SOL)',decimal(lamports,9)));movements.push({amount:decimal(lamports,9),symbol:'SOL',to:a[1],label:'To'});}
    else if(opcode===0){count(2);const lamports=r.u64(),space=r.u64(),owner=base58.encode(r.take(32));fields.push(field('Action','Create account'),field('Payer',a[0]),field('New account',a[1]),field('Funding (SOL)',decimal(lamports,9)),field('Allocated bytes',space),field('Account owner program',owner));
      if(lamports>0n)movements.push({amount:decimal(lamports,9),symbol:'SOL',to:a[1],label:'New account'});
      if(![SYSTEM,TOKEN,TOKEN2022,STAKE].includes(owner)){riskLevel='high';warnings.push('HIGH RISK: This funds a new account controlled by program '+owner+'. That program, not you, will control the '+decimal(lamports,9)+' SOL.');}}
    else if(opcode===4){count(3);fields.push(field('Action','Advance durable nonce'),field('Nonce account',a[0]),field('Nonce authority',a[2]));}
    else if(opcode===1){count(1);fields.push(field('Action','Assign account owner program'),field('Account',a[0]),field('New owner program',base58.encode(r.take(32))));riskLevel='high';warnings.push('HIGH RISK: The new program may control this account.');}
    else if(opcode===8){count(1);fields.push(field('Action','Allocate account storage'),field('Account',a[0]),field('Bytes',r.u64()));}
    else opaque();
  }else if(program===TOKEN||program===TOKEN2022){
    const opcode=r.u8();if([3,4,7,8,12,13,14,15].includes(opcode)){
      const amount=r.u64(),checked=opcode>=12,decimals=checked?r.u8():null;
      const action=({3:'Transfer tokens',4:'Approve delegate',7:'Mint tokens',8:'Burn tokens',12:'Send tokens',13:'Approve checked delegate',14:'Mint checked tokens',15:'Burn checked tokens'})[opcode];
      const transfer=opcode===3||opcode===12,approve=opcode===4||opcode===13;
      // Token-2022 transferChecked may carry transfer-hook accounts beyond the 11 multisig signers.
      const hooked=program===TOKEN2022&&opcode===12;
      const needed=(checked&&(transfer||approve))?4:3;tokenCount(needed,hooked);
      fields.push(field('Action',action),field('Raw amount',amount));if(checked)fields.push(field('Decimals bound by instruction',decimals),field('Display amount',decimal(amount,decimals)));
      if(transfer||approve){fields.push(field('Source token account',a[0]));if(checked)fields.push(field('Mint',a[1]));fields.push(field(approve?'Delegate':'Destination token account',a[checked?2:1]),field('Owner / authority',a[checked?3:2]));}
      else fields.push(field(opcode===7||opcode===14?'Mint':'Token account',a[0]),field(opcode===7||opcode===14?'Destination token account':'Mint',a[1]),field('Authority',a[2]));
      if(approve){riskLevel='high';warnings.push('Token delegation authorizes another address to spend these assets.');}
      const burn=(opcode===8||opcode===15)&&amount>0n;
      const mint=(checked&&(transfer||approve))?a[1]:([7,14].includes(opcode)?a[0]:([8,15].includes(opcode)?a[1]:undefined));
      if(mint){asset=lookupToken('solana',undefined,mint,amount,program);if(asset){if(checked)check(asset.decimals===decimals,'TOKEN_METADATA','Instruction decimals disagree with the local registry for this mint.');fields.push(field('Asset',asset.name+' ('+asset.symbol+')'),field('Amount ('+asset.symbol+')',asset.displayAmount));}}
      else warnings.push('Mint is not included in this unchecked instruction. Token-account addresses cannot establish asset identity or decimals offline.');
      if(burn){
        const shown=asset?asset.displayAmount:checked?decimal(amount,decimals):String(amount);
        const unit=asset?asset.symbol:checked?(shown==='1'?'token':'tokens'):(amount===1n?'raw unit':'raw units');
        movements.push({amount:shown,symbol:unit,to:a[1],label:'Mint',destroys:true,
          raw:amount,scale:asset?asset.decimals:checked?decimals:0});
        riskLevel='high';
        warnings.push(`HIGH RISK: This permanently destroys ${shown} ${unit}. Burning cannot be undone.`);
      }
      if(transfer){const destination=a[checked?2:1],shown=asset?asset.displayAmount:checked?decimal(amount,decimals):String(amount);
        const movement={amount:shown,symbol:asset?asset.symbol:checked?(shown==='1'?'token':'tokens'):(amount===1n?'raw unit':'raw units'),to:destination,label:'To token account'};
        movements.push(movement);extra.transfer={checked,program,mint:checked?a[1]:undefined,destination,movement};
        // 1 unit of an unregistered 0-decimal mint is the NFT pattern, but 0-decimal fungible and semi-fungible tokens match it too.
        if(checked&&!asset&&decimals===0&&amount===1n){
          fields.push(field('Asset type','1 unit of a 0-decimal token: the usual NFT pattern, but supply, edition and collection are not verified offline'));
          warnings.push('This looks like an NFT (1 unit, 0 decimals), but 0-decimal fungible tokens match the same pattern. NFT name, image, collection and verified status are not in the transaction and cannot be checked offline. Compare the mint address with an independent source.');
          extra.display={action:'Send Token (likely NFT)',headline:'1 token (0 decimals)',summary:'1 token (0 decimals)',assetKind:'nftOrToken',assetContract:a[1],assetContractLabel:'Mint'};}}
      warnings.push('Token-account owners, mint metadata and decimals are not independently fetched or verified offline.');
      if(a.length>needed&&hooked){
        // Multisig signers follow the authority, but only a non-signing authority can be a multisig: when the authority
        // signs, leading signer extras are hook accounts (often the owner or payer). Token-2022 locates hook accounts by
        // key, so the trailing [hook program, validation PDA] pair only shows which hook the transaction supplies accounts for.
        const extras=a.slice(needed);let s=0;if(!signers.has(a[3]))while(s<extras.length&&signers.has(extras[s]))s++;const rest=extras.slice(s);
        if(s)fields.push(field('Multisig signers',extras.slice(0,s).join('\n')));
        const hook=rest.length>=2?rest[rest.length-2]:undefined;
        if(hook&&rest[rest.length-1]===pda([utf8('extra-account-metas'),pubkey(a[1])],hook)){
          fields.push(field('Transfer hook program (supplied)',hook),field('Hook validation account',rest[rest.length-1]));if(rest.length>2)fields.push(field('Hook extra accounts',rest.slice(0,-2).join('\n')));
          warnings.push('HIGH RISK: This transfer supplies accounts for transfer-hook program '+hook+'. The mint’s actual transfer hook is on-chain state and cannot be verified offline; whichever hook the mint configures will run with the accounts listed.');}
        else if(rest.length)fields.push(field('Unclassified extra accounts',rest.join('\n')));}
      else if(a.length>needed)fields.push(field(program===TOKEN2022?'Additional authority / extension accounts':'Multisig signers',a.slice(needed).join('\n')));
    }else if(opcode===5){tokenCount(2);fields.push(field('Action','Revoke token delegate'),field('Token account',a[0]),field('Authority',a[1]));if(a.length>2)fields.push(field(program===TOKEN2022?'Additional authority / extension accounts':'Multisig signers',a.slice(2).join('\n')));}
    else if(opcode===9){tokenCount(3);fields.push(field('Action','Close token account'),field('Token account',a[0]),field('Rent recipient',a[1]),field('Authority',a[2]));warnings.push('Closing this token account sends all of its remaining SOL to the specified recipient. For a wrapped SOL account this is the entire wrapped balance, not just rent.');movements.push({amount:'All remaining',symbol:'SOL',to:a[1],label:'To'});if(a.length>3)fields.push(field(program===TOKEN2022?'Additional authority / extension accounts':'Multisig signers',a.slice(3).join('\n')));}
    else if(opcode===6){tokenCount(2);const type=r.u8(),flag=r.u8();check(type<=3&&flag<=1,'INSTRUCTION','Unsupported token authority change.');fields.push(field('Action','Change token authority'),field('Account / mint',a[0]),field('Current authority',a[1]),field('Authority type',['Mint tokens','Freeze accounts','Account owner','Close account'][type]),field('New authority',flag?base58.encode(r.take(32)):'None (revoked)'));riskLevel='high';warnings.push('HIGH RISK: This changes control of the token account or mint; revoking an authority may be irreversible.');if(a.length>2)fields.push(field('Additional authority accounts',a.slice(2).join('\n')));}
    else if(opcode===17){count(1);fields.push(field('Action','Sync wrapped SOL balance'),field('Token account',a[0]));}
    else opaque();
    if(program===TOKEN2022){warnings.push('Token-2022 mint extensions and transfer hooks cannot be verified offline.');riskLevel='high';decodeStatus=decodeStatus==='opaque'?'opaque':'partiallyDecoded';}
  }else if(program===ATA){check(a.length===6||a.length===7,'INSTRUCTION','Invalid associated token account instruction.');const opcode=data.length?r.u8():0;check([0,1].includes(opcode),'UNSUPPORTED','Unsupported associated token account instruction.');check(a[4]===SYSTEM&&[TOKEN,TOKEN2022].includes(a[5]),'INSTRUCTION','Unexpected associated account programs.');check(ataAddress(a[2],a[5],a[3])===a[1],'ADDRESS','Associated token address does not match owner and mint.');fields.push(field('Action',opcode?'Create token account if absent':'Create token account'),field('Rent payer',a[0]),field('Token account',a[1]),field('Owner',a[2]),field('Mint',a[3]));
    // Both Create and CreateIdempotent fail unless the account at a[1] is owned by a[2] for mint a[3].
    extra.ata={ata:a[1],owner:a[2],mint:a[3],tokenProgram:a[5]};}
  else if(program===COMPUTE){count(0);const opcode=r.u8();if(opcode===2){const units=r.u32();check(units>0&&units<=1400000,'FEE','Invalid compute unit limit.');fields.push(field('Compute unit limit',units));}else if(opcode===3)fields.push(field('Compute unit price (micro-lamports)',r.u64()));else fail('UNSUPPORTED','Unsupported compute budget instruction.');}
  else if(program===MEMO){check(data.length<=512,'LIMIT','Memo is too large.');fields.push(field('Memo',JSON.stringify(text(data))));r.pos=data.length;}
  else if(program===STAKE){const opcode=r.u32();fields.push(field('Stake accounts',a.join('\n')));if(opcode===2){check(a.length>=3&&a.length<=6,'INSTRUCTION','Invalid stake delegate accounts.');fields.push(field('Action','Delegate stake'),field('Stake account',a[0]),field('Validator vote account',a[1]));}else if(opcode===3){count(3);fields.push(field('Action','Split stake'),field('Source stake',a[0]),field('Destination stake',a[1]),field('Amount (SOL)',decimal(r.u64(),9)));}else if(opcode===4){check(a.length>=3&&a.length<=6,'INSTRUCTION','Invalid stake withdrawal accounts.');const lamports=r.u64();fields.push(field('Action','Withdraw stake'),field('Stake account',a[0]),field('Recipient',a[1]),field('Amount (SOL)',decimal(lamports,9)));movements.push({amount:decimal(lamports,9),symbol:'SOL',to:a[1],label:'To'});riskLevel='high';}else if(opcode===5){check(a.length===2||a.length===3,'INSTRUCTION','Invalid deactivate accounts.');fields.push(field('Action','Deactivate stake'),field('Stake account',a[0]));}else opaque();warnings.push('Stake authorities, lockups, balances and validator status cannot be verified offline.');}
  else if(program===SQUADS){const discriminator=r.take(8),name=['proposal_approve','proposal_reject','proposal_cancel'].find(n=>equal(discriminator,sha256(utf8('global:'+n)).slice(0,8)));if(name){count(3);const option=r.u8();check(option<=1,'INSTRUCTION','Invalid Squads memo option.');if(option){const length=r.u32();check(length<=512,'LIMIT','Squads memo is too large.');fields.push(field('Memo',JSON.stringify(text(r.take(length)))));}fields.push(field('Action',name.replaceAll('_',' ')),field('Multisig account',a[0]),field('Current voting member',a[1]),field('Referenced proposal',a[2]));warnings.push('HIGH RISK: Only a proposal reference is signed. Proposal transfer contents, existing members, permissions and threshold are NOT included and cannot be verified offline.');decodeStatus='partiallyDecoded';riskLevel='high';}else opaque();}
  else if(NFT_PROGRAMS[program]){
    const out=program===TOKEN_METADATA?decodeTokenMetadata(a,data,signers):program===BUBBLEGUM?decodeBubblegum(a,data,signers):decodeCore(a,data,signers);
    if(out){fields.push(...out.fields);warnings.push(...out.warnings);movements.push(...out.movements);riskLevel=out.riskLevel;decodeStatus=out.decodeStatus;Object.assign(extra,out.extra);r.pos=data.length;}
    else opaque(program===TOKEN_METADATA?TM_NAMES[data[0]]:program===CORE?CORE_NAMES[data[0]]:bubblegumName(data));}
  else opaque();
  r.end();return {fields,warnings,decodeStatus,riskLevel,movements,...extra,...(asset?{asset}:{})};
}
export function parseSolana(request){
  check(!request.network||['mainnet','mainnet-beta'].includes(request.network),'NETWORK','Unsupported network');
  const bytes=fromBase64(request.message,1232);
  if(request.kind==='message'){
    // Solana Ed25519 has no mandatory domain prefix: reject anything that could be a wire transaction.
    check(bytes.length>0&&bytes.length<=1024,'MESSAGE','Solana messages must be 1–1024 bytes.');
    check(bytes[0]>=0x20&&bytes[0]!==0x80,'MESSAGE','Solana message prefix could represent a transaction header.');
    // A legacy message with >=32 required signers cannot fit in 1024 bytes.
    // Current v0 starts 0x80; valid UTF-8 multibyte starts cannot encode that header.
    const message=text(bytes);check(!/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/.test(message),'MESSAGE','Control bytes are not allowed in signed Solana messages.');
    return {bytes,signingBytesDigest:bytesToHex(sha256(bytes)),review:reviewResult(request,'Sign Solana message','Ed25519 message signature',[...(request.address?[field('Requested signer',request.address)]:[]),field('Message',JSON.stringify(message)),field('Exact bytes',bytesToHex(bytes))],['Solana signs exact message bytes without a mandatory domain prefix. Only sign a message you recognize.'],{network:NETWORK,display:{action:'Sign Message',headline:message.slice(0,280)}})};
  }
  check(request.kind==='transaction','UNSUPPORTED','Unsupported Solana request kind.');
  const r=new Reader(bytes);let version='legacy';let required=r.u8();if(required&128){check(required===128,'UNSUPPORTED','Only legacy and version 0 Solana messages are supported.');version='v0';required=r.u8();}
  const readonlySigned=r.u8(),readonlyUnsigned=r.u8(),keyCount=r.short();check(required>0&&required<=keyCount&&readonlySigned<required&&readonlyUnsigned<=keyCount-required&&keyCount<=256,'MESSAGE','Invalid Solana message header.');
  const keys=Array.from({length:keyCount},()=>base58.encode(r.take(32)));check(new Set(keys).size===keys.length,'MESSAGE','Duplicate static Solana account keys.');const blockhash=base58.encode(r.take(32));const n=r.short();check(n>0&&n<=64,'LIMIT','Solana requires 1–64 instructions.');
  const instructions=[];for(let i=0;i<n;i++){const programIndex=r.u8();const count=r.short();const indexes=Array.from(r.take(count));const data=r.take(r.short());instructions.push({programIndex,indexes,data});}
  if(version==='v0'){const lookups=r.short();check(lookups===0,'LOOKUP_TABLE','Address lookup tables require independently trusted account data and are refused offline. Export a transaction with static account keys.');}r.end();
  const fields=[field('Network','Solana'),field('Network context','Network context not included in message bytes'),field('Derivation path',request.path??'Provided by matched signing plan'),field('Message version',version),field('Fee payer',keys[0]),field('Recent blockhash / durable nonce',blockhash),field('Required signers',keys.slice(0,required).join('\n'))];const warnings=['Blockhash freshness, network identity, account state and base network fee cannot be verified offline.'];
  let decodeStatus='fullyDecoded',riskLevel='warning';const assets=[],movements=[],actions=[],decoded=[],signers=new Set(keys.slice(0,required));const seenCompute=new Set();let computeLimit=BigInt(Math.min(1400000,n*200000)),computePrice=0n;
  instructions.forEach((ix,i)=>{check(ix.programIndex<keys.length&&ix.indexes.every(k=>k<keys.length),'MESSAGE','Instruction refers to an unresolved account.');check(ix.programIndex>=required,'MESSAGE','Program account cannot be a required signer.');const program=keys[ix.programIndex],accounts=ix.indexes.map(k=>keys[k]);const d=instruction(program,accounts,ix.data,signers);Object.assign(d,{program,accounts,bytes:ix.data,notes:[]});decoded.push(d);
    if(program===SYSTEM&&i===0&&ix.data.length>=4&&new DataView(ix.data.buffer,ix.data.byteOffset,4).getUint32(0,true)===4)d.notes.push('This transaction uses a durable nonce, so it does not expire. It can be submitted until the nonce account advances.');
    if(program===COMPUTE){check(!seenCompute.has(ix.data[0]),'FEE','Duplicate compute budget instruction.');seenCompute.add(ix.data[0]);const dr=new Reader(ix.data);const op=dr.u8();if(op===2)computeLimit=BigInt(dr.u32());if(op===3)computePrice=dr.u64();}});
  // Token recipients: a same-transaction ATA Create/CreateIdempotent (j < i) fails unless the destination is owned by
  // that wallet for that mint, so the wallet is proven at instruction j. It is trusted only when nothing between j and i
  // can re-own or close the account and no opaque instruction (which could CPI anything) is present.
  const anyOpaque=decoded.some(d=>d.decodeStatus==='opaque'),folded=new Set();
  const ataBefore=(i,account)=>{for(let j=i-1;j>=0;j--)if(decoded[j].ata?.ata===account)return j;return -1;};
  decoded.forEach((d,i)=>{
    if(d.nftTransfer){const t=d.nftTransfer,j=ataBefore(i,t.destination),x=decoded[j]?.ata;if(x&&x.owner===t.owner&&x.mint===t.mint&&x.tokenProgram===t.tokenProgram)folded.add(j);}
    if(!d.transfer)return;const t=d.transfer,j=ataBefore(i,t.destination),x=decoded[j]?.ata;
    const reowned=x&&decoded.slice(j+1,i).some(k=>[TOKEN,TOKEN2022].includes(k.program)&&[6,9].includes(k.bytes[0])&&k.accounts[0]===t.destination);
    if(t.checked&&x&&!anyOpaque&&!reowned&&x.mint===t.mint&&x.tokenProgram===t.program){t.movement.to=x.owner;t.movement.label='To';d.fields.push(field('Recipient wallet (owner of destination token account)',x.owner));folded.add(j);}
    else d.warnings.push('The recipient wallet is not included in this transaction, only its token account. Make sure the destination token account belongs to the intended recipient.');});
  decoded.forEach((d,i)=>{fields.push(...d.fields.map(f=>field(`Instruction ${i+1} · ${f.label}`,f.value)));warnings.push(...d.warnings,...d.notes);if(d.riskLevel==='high')riskLevel='high';if(d.decodeStatus!=='fullyDecoded')decodeStatus='partiallyDecoded';if(d.asset)assets.push(d.asset);for(const m of d.movements)movements.push({...m,source:i});const action=d.fields.find(f=>f.label==='Action')?.value;if(action&&d.program!==COMPUTE&&!folded.has(i))actions.push({action,source:i});});
  // A recognised NFT or marketplace program that is not decoded makes the transaction "not decoded" when nothing else is.
  const substantive=decoded.filter((d,i)=>!folded.has(i)&&d.program!==COMPUTE&&d.program!==MEMO);
  if(substantive.length&&substantive.every(d=>d.decodeStatus==='opaque'))decodeStatus='opaque';
  const priorityFee=(computeLimit*computePrice+999999n)/1000000n,baseFee=5000n*BigInt(required);
  fields.push(field('Base network fee (SOL)',decimal(baseFee,9)),field('Maximum priority fee (SOL)',decimal(priorityFee,9)));
  if(priorityFee>HIGH_PRIORITY_FEE){warnings.unshift('HIGH FEE: This transaction allows up to '+decimal(priorityFee,9)+' SOL in priority fees. Check the fee settings in your other wallet.');riskLevel='high';}
  check(short(required).length+required*64+bytes.length<=1232,'LIMIT','Serialized Solana transaction exceeds the network packet limit.');
  const signatures=request.signatures??Array(required).fill(null);check(Array.isArray(signatures)&&signatures.length===required,'SIGNATURE','Solana signature slot count differs from the message header.');
  signatures.forEach((s,i)=>{if(s===null||s==='')return;const sig=fromBase64(s,64);check(sig.length===64,'SIGNATURE','Invalid Solana signature size.');if(sig.every(b=>b===0))return;check(ed25519.verify(sig,bytes,base58.decode(keys[i])),'SIGNATURE','Existing Solana signature is invalid for its signer slot.');});
  // A single headline amount is shown only when exactly one value movement exists;
  // otherwise every transfer is listed in the details and the headline says how many.
  // NFT flows carry a headline instead of an amount, plus the mint or asset ID to compare.
  const burns=movements.filter(m=>m.destroys);
  const single=movements.length===1?movements[0]:undefined,hint=single?decoded[single.source].display:undefined,lone=actions.length===1?actions[0]:undefined;
  const rest=movements.length-burns.length;
  // Burns of one mint add up; burns of different mints do not, and a transfer
  // beside them is a separate effect again. A single headline amount is shown
  // only when one total describes the whole transaction — otherwise the first
  // burn, which may be a dust amount, would stand in for everything.
  const burnGroups=[];
  for(const burn of burns){
    const key=burn.to+'/'+burn.symbol+'/'+burn.scale;
    const group=burnGroups.find(g=>g.key===key);
    if(group){group.raw+=burn.raw;group.count++;}
    else burnGroups.push({key,raw:burn.raw,scale:burn.scale,symbol:burn.symbol,to:burn.to,count:1});
  }
  const burnTotal=g=>decimal(g.raw,g.scale)+' '+g.symbol;
  const whole=burnGroups.length===1&&!rest?burnGroups[0]:undefined;
  const burnDisplay=burns.length?{action:'Burn',...(whole?{amount:decimal(whole.raw,whole.scale),symbol:whole.symbol}:{}),
    headline:(whole?`Destroys ${burnTotal(whole)}`+(whole.count>1?` in ${whole.count} burns`:'')
      :`Destroys ${burnGroups.slice(0,3).map(burnTotal).join(' + ')}`+(burnGroups.length>3?` (+${burnGroups.length-3} more assets)`:''))
      +(rest?` · ${rest} other transfer${rest>1?'s':''} below`:''),
    counterpartyLabel:'Mint',counterparty:burnGroups.length===1?burnGroups[0].to:undefined}:undefined;
  if(burnDisplay&&!burnDisplay.counterparty)delete burnDisplay.counterparty;
  const display=burnDisplay??(single&&hint?{action:lone?hint.action:'Sign Transaction',headline:hint.headline,counterpartyLabel:single.label,counterparty:single.to}
    :single?{action:lone?lone.action:'Sign Transaction',amount:single.amount,symbol:single.symbol,counterpartyLabel:single.label,counterparty:single.to}
    :movements.length>1?{action:'Sign Transaction',headline:movements.length+' transfers · review each below'}
    :{action:lone?lone.action:'Sign Transaction',headline:actions.length>1?actions.length+' instructions':undefined});
  const assetHint=hint??(!movements.length&&lone?decoded[lone.source].display:undefined);
  if(assetHint?.assetKind)Object.assign(display,{assetKind:assetHint.assetKind,assetContract:assetHint.assetContract,assetContractLabel:assetHint.assetContractLabel});
  const markets=[...new Set(decoded.map(d=>d.marketplace).filter(Boolean))];
  if(markets.length){display.action='NFT marketplace action';if(!hint&&movements.length<=1)display.headline=markets.join(' + ')+' · not decoded';}
  if(!display.headline)delete display.headline;display.fee=decimal(baseFee+priorityFee,9)+' SOL max';
  const summary=burns.length?`Burn ${burnGroups.slice(0,3).map(burnTotal).join(' + ')}`+(burnGroups.length>3?` and ${burnGroups.length-3} more assets`:'')+(rest?` and ${rest} transfer${rest>1?'s':''}`:''):markets.length&&!movements.length?'NFT marketplace action (not decoded)':single?(hint?.summary??`${single.amount} ${single.symbol}`):movements.length>1?`${movements.length} transfers`:instructions.length===1?(actions[0]?.action??'1 instruction'):`${instructions.length} instructions`;
  const title=instructions.length===1&&actions[0]?.action==='proposal approve'?'Approve a multisig proposal':'Sign Solana transaction';
  const asset=single&&assets.length===1&&single.symbol===assets[0].symbol?assets[0]:undefined;
  return {bytes,keys,required,signatures,signingBytesDigest:bytesToHex(sha256(bytes)),review:reviewResult(request,title,summary,fields,[...new Set(warnings)],{decodeStatus,riskLevel,network:NETWORK,display,...(asset?{asset}:{})})};
}
export function signSolana(request,seed,root,task){const p=parseSolana(request),target=task?.targets?.[0],path=target?.path??request.path??PATHS.solana;if(task)check(task.targets?.length===1,'SIGNER','A Solana task requires one signer.');return withKey(seed,root,'solana',path,(key,pub)=>{const address=base58.encode(pub);if(target?.publicKey)check(equal(pub,hexToBytes(target.publicKey,32)),'SIGNER','Solana task key differs from the decrypted wallet.');if(target?.address)check(address===target.address,'SIGNER','Solana task address mismatch.');if(request.address)check(address===request.address,'SIGNER','Requested Solana signer does not match this wallet.');const slot=p.keys?p.keys.slice(0,p.required).indexOf(address):-1;if(p.keys){check(slot>=0,'SIGNER','This wallet is not a required signer in the transaction.');if(target)check(target.signerSlot===slot,'SIGNER','Solana signer slot differs from the signing task.');}const sig=ed25519.sign(p.bytes,key);check(ed25519.verify(sig,p.bytes,pub),'SIGNATURE','Signature verification failed.');const result={chain:'solana',requestHash:p.review.requestHash,address,publicKey:bytesToHex(pub),signature:bytesToHex(sig)};if(p.keys){const signatures=p.signatures.map(s=>s?fromBase64(s,64):new Uint8Array(64));check(signatures[slot].every(b=>b===0),'SIGNATURE','This Solana signer slot is already populated.');signatures[slot]=sig;result.signatures=signatures.map(toBase64);result.serializedTransaction=toBase64(concat(short(p.required),...signatures,p.bytes));result.signerIndex=slot;}return result;});}
