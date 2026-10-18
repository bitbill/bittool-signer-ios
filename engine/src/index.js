import './polyfills.js';
import { mnemonic, validateMnemonic, deriveAccounts, deriveBitcoinCosigner, withSeed, fpHex, wordlist } from './keys.js';
import { parseEVM, signEVM } from './evm.js';
import { validateBitcoinPolicy } from './bitcoin-policy.js';
import { parseBitcoin, signBitcoin } from './bitcoin.js';
import { parseTron, signTron } from './tron.js';
import { parseSolana, signSolana } from './solana.js';
import { decodeQR, decodePayload, parseProtocolJSON, encodeQR, encodeResponse, createPairing, createPublicPairing, createWalletPairing, ProtocolError, QRCollector } from '../protocols.js';
import { check, EngineError, requestHash } from './util.js';
import { derivePublicIndex, derivePublicAddresses } from './public-index.js';
import { resolveSigningPlan, signPlanTask } from './resolver.js';
const PARSERS={bitcoin:parseBitcoin,evm:parseEVM,tron:parseTron,solana:parseSolana};
const SIGNERS={bitcoin:signBitcoin,evm:signEVM,tron:signTron,solana:signSolana};
export function capabilities(){return {
  version:'1.0.0',offline:true,chains:['bitcoin','evm','tron','solana'],
  protocols:['crypto-psbt','eth-sign-request/eth-signature','sol-sign-request/sol-signature','tron-sign-request/tron-signature','BBQR PSBT'],
  authorization:'Public-index resolution with fixed, independently authorized wallet tasks',
  bitcoin:{supported:['PSBT v0/v2','P2PKH','P2WPKH','P2SH-P2WPKH','P2SH/P2SH-P2WSH/P2WSH multisig','Taproot key-path','Taproot c0 CHECKSIGADD/CHECKSIGVERIFY multisig leaves'],policy:['Legacy/SegWit v0 require full previous transactions; all-Taproot accepts witness UTXOs','ALL/DEFAULT sighash only','All outputs shown; no inferred change','Global/input/output metadata and existing signatures preserved'],rejected:['MuSig2','Unknown Taproot leaf policies','Unknown output scripts']},
  evm:{supported:['Legacy/EIP-2930/EIP-1559','personal_sign arbitrary bytes','EIP-712','SafeTx CALL/DELEGATECALL','Safe MultiSend and permission methods','ERC20/ERC721/ERC1155 transfers and approvals','ERC1155 single and batch transfers','EIP-2612/DAI Permit','Permit2 Single/Batch/TransferFrom/BatchTransferFrom','Seaport 1.5/1.6 orders and bulk orders','LooksRare v2 maker and batch orders','Blur blind Merkle-root orders (shown as opaque)'],networks:[1,56,42161,8453,10,137,100,43114],riskGated:['Unknown calldata and contract deployment: opaque','Custom typed data: partially decoded','Delegatecall, batch, permit and permission operations: high risk','NFT marketplace orders and collection-wide approvals: high risk','ERC20/ERC721 shared selectors on unregistered contracts: shown as NFT or token'],rejected:['Unsupported chain IDs','EIP-7702','Blob transactions','eth_sign raw hash']},
  tron:{supported:['TRX transfer','TRC20/TRC721/TRC1155 ABI calls (NFT displays with Base58 contracts)','AccountPermissionUpdate','Incremental multisig signatures','Personal messages using the TronWeb length-prefixed standard','Stake 2.0/resource contract types 54–59'],rejected:['Unknown protobuf fields/contracts','Unlabelled raw hash signing','TRC10 calls'],offlineLimits:['Network identity and current permission membership cannot be verified']},
  solana:{supported:['Legacy/v0 static keys','Three registered Ed25519 preset paths','System transfers, create, nonce, assign and allocate','SPL Token transfers/approvals/mint/burn/close/setAuthority/syncNative','Associated token account, compute budget and memo','Stake delegate/split/withdraw/deactivate','Required signer slots including non-fee-payer/read-only signers','Message signatures'],riskGated:['Unknown programs: opaque','Token-2022 extensions: partially decoded','Squads approve/reject/cancel proposal references: partially decoded'],rejected:['Address lookup tables','Malformed messages and invalid signer slots']},
  releaseQualification:'Protocol unit tests do not establish third-party wallet end-to-end certification or a security audit.'
};}
function requestValid(request){check(request&&typeof request==='object'&&!Array.isArray(request)&&Object.hasOwn(PARSERS,request.chain),'REQUEST','Unsupported or missing chain.');requestHash(request);return request;}
export function review(request){return PARSERS[requestValid(request).chain](request).review;}
export function sign({request,mnemonic,passphrase,reviewedHash}){
  requestValid(request);if(reviewedHash!==undefined)check(reviewedHash===requestHash(request),'INTEGRITY','The request changed after review. Review the transaction again.');
  return withSeed(mnemonic,passphrase,(seed,root)=>{if(request.masterFingerprint!==undefined)check(request.masterFingerprint.toLowerCase()===fpHex(root.fingerprint),'FINGERPRINT','Signing request belongs to a different wallet.');return SIGNERS[request.chain](request,seed,root);});
}
// A scan session lives only in the host's dedicated per-scan context. It holds
// public QR frames, never secrets, and is discarded with that context.
let scanSession;
function scanBegin(){scanSession=new QRCollector();return {started:true};}
function scanAdd({frame}){check(scanSession,'SCAN','No scan session is active.');return scanSession.add(frame);}
export function execute(input){check(input&&typeof input==='object','REQUEST','Expected a JSON operation.');switch(input.operation){case 'mnemonic':return mnemonic(input.entropy);case 'validateMnemonic':return validateMnemonic(input.mnemonic);case 'wordlist':return {words:wordlist};case 'derivePublicIndex':case 'deriveWalletPublic':return derivePublicIndex(input);case 'derivePublicAddresses':return derivePublicAddresses(input);case 'createPublicPairing':return createPublicPairing(input);case 'createWalletPairing':return createWalletPairing(input);case 'resolveSigningPlan':return resolveSigningPlan(input);case 'signPlanTask':return signPlanTask(input);case 'deriveAccounts':return deriveAccounts(input);case 'deriveBitcoinCosigner':return deriveBitcoinCosigner(input);case 'validateBitcoinPolicy':return validateBitcoinPolicy(input);case 'review':return review(input.request);case 'sign':return sign(input);case 'capabilities':return capabilities();case 'decodeQR':return decodeQR(input);case 'scanBegin':return scanBegin();case 'scanAdd':return scanAdd(input);case 'decodePayload':return decodePayload(input);case 'encodeQR':return encodeQR(input);case 'encodeResponse':return encodeResponse(input);case 'createPairing':return createPairing(input);default:throw new EngineError('OPERATION','Unsupported engine operation.');}}
export function dispatch(json){try{check(typeof json==='string'&&json.length<=1048576,'LIMIT','Request exceeds one megabyte.');const result=execute(parseProtocolJSON(json,1048576));return JSON.stringify({ok:true,result});}catch(error){const controlled=error instanceof EngineError||error instanceof ProtocolError;return JSON.stringify({ok:false,error:{code:controlled?error.code:'INVALID_REQUEST',message:controlled?error.message:'The payload is malformed, unsupported or inconsistent. No signature was produced.'}});}}
