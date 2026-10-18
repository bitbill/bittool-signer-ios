import { Transaction, computeAddress, recoverAddress } from 'ethers/transaction';
import { SigningKey } from 'ethers/crypto';
import { TypedDataEncoder, hashMessage } from 'ethers/hash';
import { Interface } from 'ethers/abi';
import { getAddress } from 'ethers/address';
import { keccak256 } from 'ethers/crypto';
import { concat as hexConcat, toUtf8String } from 'ethers/utils';
import { lookupToken, evmNetwork } from './token-registry.js';
import { describeContract } from './known-contracts.js';
import { check, fail, field, reviewResult, hexToBytes, bytesToHex, uint, decimal, stable, equal, Reader } from './util.js';
import { PATHS, withKey } from './keys.js';
import { tokenIdText, tokenIdHex, tokenIdFields, quantityText, shortAddress, indexWarning, reviewNftOrder, opaqueRootWarning, marketplaceRequest } from './nft-orders.js';

const ABI = new Interface([
  'function transfer(address to,uint256 amount)',
  'function approve(address spender,uint256 amount)',
  'function transferFrom(address from,address to,uint256 amount)',
  'function safeTransferFrom(address from,address to,uint256 tokenId)',
  'function safeTransferFrom(address from,address to,uint256 tokenId,bytes data)',
  'function setApprovalForAll(address operator,bool approved)',
  'function safeTransferFrom(address from,address to,uint256 id,uint256 amount,bytes data)',
  'function safeBatchTransferFrom(address from,address to,uint256[] ids,uint256[] amounts,bytes data)',
  'function multiSend(bytes transactions)',
  'function enableModule(address module)',
  'function disableModule(address prevModule,address module)',
  'function addOwnerWithThreshold(address owner,uint256 threshold)',
  'function removeOwner(address prevOwner,address owner,uint256 threshold)',
  'function swapOwner(address prevOwner,address oldOwner,address newOwner)',
  'function changeThreshold(uint256 threshold)',
  'function setGuard(address guard)',
  'function setFallbackHandler(address handler)',
  'function execTransaction(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,bytes signatures)'
]);
const SAFE_TYPES = [['to','address'],['value','uint256'],['data','bytes'],['operation','uint8'],['safeTxGas','uint256'],['baseGas','uint256'],['gasPrice','uint256'],['gasToken','address'],['refundReceiver','address'],['nonce','uint256']];
const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000';
const MAX_UINT256 = (1n << 256n) - 1n;
// Maximum network fee (native units) above which a transaction is flagged. Normal
// transfers and swaps stay well below these; they catch fat-finger or hostile gas.
const HIGH_FEE = { '1': 5n * 10n ** 16n, '10': 5n * 10n ** 16n, '42161': 5n * 10n ** 16n, '8453': 5n * 10n ** 16n,
  '56': 5n * 10n ** 16n, '137': 20n * 10n ** 18n, '100': 5n * 10n ** 18n, '43114': 10n ** 18n };

const nativeAmount = (network, wei) => decimal(wei, 18) + ' ' + network.symbol;
const display = (action, extra = {}) => Object.fromEntries(Object.entries({ action, ...extra })
  .filter(([, v]) => v !== undefined && v !== null && v !== '' && !(Array.isArray(v) && !v.length)));

/** Labels decodeCall gives the called contract's row; TRON replaces that row with its own Base58 'Contract' field. */
export const CONTRACT_FIELD_LABELS = ['Recipient / contract', 'NFT contract', 'ERC-1155 contract', 'Collection contract', 'Contract (NFT or token)'];
const GENERIC_CALL_WARNING = 'Contract identity, current permissions and on-chain state are not verified offline.';
const NFT_METHODS = new Set(['approve', 'transferFrom', 'safeTransferFrom', 'setApprovalForAll', 'safeBatchTransferFrom']);
// ENS on Ethereum mainnet only (docs.ens.domains/learn/deployments). Detail text only: the name is never guessed.
const ENS_CONTRACTS = {
  '0x57f1887a8bf19b14fc0df6fd9b2acc9af147ea85': 'ENS .eth registrar (ERC-721). The token ID is keccak256 of the name label; the name itself is not in this request and cannot be shown offline.',
  '0xd4416b13d2b3a9abae7acd5d6c2bbdbe25686401': 'ENS NameWrapper (ERC-1155). The token ID is the namehash of the wrapped name; the name itself is not in this request and cannot be shown offline.',
};
const RISK_ORDER = { high: 0, warning: 1, normal: 2 };
/** Raw-unit text for a value that may be an ERC-20 amount; only very long values are abbreviated. */
const rawUnits = n => n.toString().length >= 25 ? quantityText(n) : n.toString();

/** Adds Safe refund fields and warnings shared by SafeTx typed data and execTransaction calldata. */
function safeRefund(fields, warnings, { safeTxGas, baseGas, gasPrice, gasToken, refundReceiver }, context) {
  const token = getAddress(gasToken), receiver = getAddress(refundReceiver), fmt = context.formatAddress ?? (x => x);
  fields.push(field('Safe transaction gas', safeTxGas), field('Refund base gas', baseGas), field('Refund gas price', gasPrice),
    field('Refund token', token === ZERO_ADDRESS ? 'Native currency' : fmt(token)),
    field('Refund receiver', receiver === ZERO_ADDRESS ? 'Transaction submitter' : fmt(receiver)));
  if (gasPrice > 0n) {
    const known = token === ZERO_ADDRESS ? undefined : lookupToken('evm', context.chainId, token);
    warnings.push(`HIGH RISK: This Safe transaction pays a gas refund of up to (gas used + ${baseGas}) × ${gasPrice} ${token === ZERO_ADDRESS ? 'wei' : known ? `raw units of ${known.symbol}` : 'raw units of token ' + fmt(token)} to ${receiver === ZERO_ADDRESS ? 'whoever submits it' : fmt(receiver)}. Only approve refunds you expect.`);
    return true;
  }
  return false;
}

export function decodeCall(to, data, value = 0n, depth = 0, context = {}) {
  check(depth < 5, 'LIMIT', 'Nested calls are too deep.');
  const network = context.network;
  // Address values and addresses in text use the chain's own format: TRON passes
  // a Base58 formatter, so only real address fields are ever converted.
  const fmt = context.formatAddress ?? (x => x);
  const fields = [field('Recipient / contract', to ? fmt(to) : 'Contract deployment'), field('Native amount (wei)', value)];
  if (network && value > 0n) fields.push(field(`Native amount (${network.symbol})`, decimal(value, 18)));
  const warnings = [];
  const raw = hexToBytes(data || '0x', 65536);
  const withValue = (base) => value > 0n && network ? { ...base, amount: decimal(value, 18), symbol: network.symbol } : base;
  if (!raw.length && to) {
    return { title: 'Native transfer', fields, warnings, decodeStatus: 'fullyDecoded', riskLevel: 'normal',
      display: network ? display('Send', { amount: decimal(value, 18), symbol: network.symbol, counterpartyLabel: 'To', counterparty: getAddress(to) }) : display('Send') };
  }
  if (!to) {
    return { title: 'Deploy contract', fields: [...fields, field('Deployment bytecode', data)],
      warnings: ['HIGH RISK: Deployment bytecode is opaque; runtime behavior and resulting permissions are not decoded.'],
      decodeStatus: 'opaque', riskLevel: 'high', display: display('Deploy Contract', withValue({})) };
  }
  let parsed;
  if (raw.length >= 4) try { parsed = ABI.parseTransaction({ data, value }); } catch { fail('CALLDATA', 'Malformed contract call.'); }
  const contract = getAddress(to);
  if (!parsed) {
    return { title: 'Unknown contract call', counterparty: { address: contract, role: 'contract' },
      fields: [...fields, field('Function selector', data.slice(0, 10)), field('Exact calldata', data)],
      warnings: ['HIGH RISK: This contract method is not decoded. The contract may move assets or change permissions.'],
      decodeStatus: 'opaque', riskLevel: 'high',
      display: display('Contract Interaction', withValue({ headline: 'Method ' + data.slice(0, 10), counterpartyLabel: 'Contract', counterparty: contract })) };
  }
  check(ABI.encodeFunctionData(parsed.fragment, parsed.args).toLowerCase() === data.toLowerCase(), 'CALLDATA', 'Contract call uses a non-canonical or trailing encoding.');
  const a = parsed.args, fn = parsed.name;
  let riskLevel = 'normal', decodeStatus = 'fullyDecoded', asset, callDisplay, title, summary;
  // The address this request puts in someone's hands: for an approval that is
  // the spender, otherwise the contract being called.
  let counterparty = { address: contract, role: 'contract' };
  const short = x => shortAddress(fmt(x));
  const contractLabel = label => { fields[0] = field(label, fmt(to)); };
  fields.push(field('Method', parsed.signature), field('Exact calldata', data));
  warnings.push(GENERIC_CALL_WARNING);
  const token = (amount) => {
    const address = context.assetAddress ?? to;
    asset = lookupToken(context.chainFamily ?? 'evm', context.chainId, address, amount);
    if (asset) fields.push(field('Asset', asset.name + ' (' + asset.symbol + ')'), field('Amount (' + asset.symbol + ')', asset.displayAmount), field('Decimals (local registry)', asset.decimals));
    else { warnings.push('Unknown token contract: display raw units and the full contract address; token metadata is unavailable offline.'); riskLevel = riskLevel === 'high' ? 'high' : 'warning'; }
    return asset;
  };
  const amountDisplay = (amount, known) => known ? { amount: known.displayAmount, symbol: known.symbol } : { amount: String(amount), symbol: 'raw units' };
  if (fn === 'transfer') {
    fields.push(field('Recipient', fmt(a[0])), field('Token amount (raw units)', a[1]));
    const known = token(a[1]);
    callDisplay = display('Send', { ...amountDisplay(a[1], known), counterpartyLabel: 'To', counterparty: getAddress(a[0]) });
  } else if (fn === 'approve') {
    const spender = getAddress(a[0]), id = a[1];
    if (spender !== ZERO_ADDRESS) counterparty = { address: spender, role: 'spender' };
    fields.push(field('Spender', fmt(spender)), field('Allowance / NFT token ID', id));
    riskLevel = 'high';
    const known = token(id);
    const unlimited = id === MAX_UINT256;
    if (known) {
      // Registry tokens are fungible ERC-20s: unchanged allowance display, including revoke for 0.
      warnings.push('This authorizes another address to spend assets. Unknown ERC20 allowance and ERC721 token approval share this selector.');
      if (unlimited) warnings.push('UNLIMITED spending approval.');
      callDisplay = display(id === 0n ? 'Revoke Approval' : 'Approve Spending',
        unlimited ? { amount: 'Unlimited', symbol: known.symbol, counterpartyLabel: 'Spender', counterparty: spender }
          : { ...amountDisplay(id, known), counterpartyLabel: 'Spender', counterparty: spender });
    } else {
      // ERC-20 and ERC-721 share this selector; on ERC-721, approve(X, 0) grants token #0.
      contractLabel('Contract (NFT or token)');
      fields.push(field('Token ID (hex)', tokenIdHex(id)));
      const nft = { assetKind: 'nftOrToken', assetContract: contract, assetContractLabel: 'Contract (NFT or token)', tokenId: id.toString() };
      if (spender === ZERO_ADDRESS) {
        riskLevel = 'warning'; title = 'Clear NFT approval';
        fields.push(field('Interpretation', `ERC-721: clears the approved address for token ${tokenIdText(id)} (the zero address means no approved address). ERC-20: an allowance of ${id} raw units for the zero address, which many ERC-20 implementations reject. The contract type cannot be confirmed offline.`));
        warnings.push(`If this is an ERC-721 contract, this clears the approval for token ${tokenIdText(id)}. Many ERC-20 implementations reject a zero spender.`);
        callDisplay = display('Clear NFT Approval (if ERC-721)', { headline: 'NFT ' + tokenIdText(id), ...nft });
        summary = `Clear NFT approval ${tokenIdText(id)} (${short(contract)})`;
      } else {
        title = 'Approve NFT or token';
        warnings.push('This authorizes another address to spend assets. Unknown ERC20 allowance and ERC721 token approval share this selector.');
        if (unlimited) warnings.push('UNLIMITED spending approval.');
        fields.push(field('Interpretation', `ERC-721: approves ${fmt(spender)} to transfer token ${tokenIdText(id)}. ERC-20: ${id === 0n ? `sets the allowance for ${fmt(spender)} to 0 (a revoke)` : `an allowance of ${id} raw units for ${fmt(spender)}`}. The contract type cannot be confirmed offline.`));
        callDisplay = display('Approve (NFT or token)', { ...(unlimited ? { amount: 'Unlimited', symbol: 'tokens' } : {}),
          headline: `NFT ${tokenIdText(id)} — or ${unlimited ? 'unlimited' : rawUnits(id)} raw token units if this is an ERC-20`, counterpartyLabel: 'Spender', counterparty: spender, ...nft });
        summary = `Approve NFT ${tokenIdText(id)} or ${unlimited ? 'unlimited' : rawUnits(id)} raw units to ${short(spender)} (${short(contract)})`;
      }
    }
  } else if (fn === 'transferFrom') {
    const from = getAddress(a[0]), recipient = getAddress(a[1]), id = a[2];
    fields.push(field('Asset owner', fmt(from)), field('Recipient', fmt(recipient)), field('Amount / NFT token ID', id));
    const known = token(id);
    if (known) callDisplay = display('Transfer', { amount: known.displayAmount, symbol: known.symbol, counterpartyLabel: 'To', counterparty: recipient });
    else {
      title = 'Transfer asset (type unconfirmed)';
      contractLabel('Contract (NFT or token)');
      fields.push(field('Token ID (hex)', tokenIdHex(id)), field('Interpretation', `ERC-721: moves token ${tokenIdText(id)} from ${fmt(from)} to ${fmt(recipient)}. ERC-20: moves ${id} raw units from ${fmt(from)} to ${fmt(recipient)}. The contract type cannot be confirmed offline.`));
      callDisplay = display('Transfer (NFT or token)', { headline: `NFT ${tokenIdText(id)} — or ${rawUnits(id)} raw units if ERC-20`, counterpartyLabel: 'To', counterparty: recipient,
        assetKind: 'nftOrToken', assetContract: contract, assetContractLabel: 'Contract (NFT or token)', tokenId: id.toString() });
      summary = `Transfer NFT ${tokenIdText(id)} or ${rawUnits(id)} raw units to ${short(recipient)} (${short(contract)})`;
    }
  } else if (fn === 'safeTransferFrom' && parsed.fragment.inputs.length < 5) {
    // ERC-721 safeTransferFrom exists only on NFTs.
    const recipient = getAddress(a[1]), id = a[2];
    contractLabel('NFT contract');
    fields.push(field('Asset owner', fmt(a[0])), field('Recipient', fmt(recipient)), ...tokenIdFields(id));
    if (parsed.fragment.inputs.length === 4 && a[3] !== '0x') fields.push(field('Receiver callback bytes', a[3]));
    title = 'Transfer NFT';
    callDisplay = display('Send NFT', { headline: 'NFT ' + tokenIdText(id), counterpartyLabel: 'To', counterparty: recipient,
      assetKind: 'nft', assetContract: contract, assetContractLabel: 'NFT contract (not verified)', tokenId: id.toString() });
    summary = `Send NFT ${tokenIdText(id)} (${short(contract)})`;
  } else if (fn === 'safeTransferFrom') {
    // ERC-1155 single transfer: quantities are whole units; IDs may be fungible.
    const recipient = getAddress(a[1]), id = a[2], quantity = a[3];
    contractLabel('ERC-1155 contract');
    fields.push(field('Asset owner', fmt(a[0])), field('Recipient', fmt(recipient)), ...tokenIdFields(id), field('Quantity', quantity));
    if (a[4] !== '0x') fields.push(field('Receiver callback bytes', a[4]));
    if (quantity === 0n) warnings.push('The quantity is 0, so this transfer moves nothing.');
    title = 'Transfer ERC-1155 token';
    const headline = `${quantityText(quantity)} × ${tokenIdText(id)}`;
    callDisplay = display('Send ERC-1155 Token', { headline, counterpartyLabel: 'To', counterparty: recipient,
      assetKind: 'multiToken', assetContract: contract, assetContractLabel: 'ERC-1155 contract (not verified)', tokenId: id.toString() });
    summary = `Send ${headline} (${short(contract)})`;
  } else if (fn === 'setApprovalForAll') {
    if (a[1]) counterparty = { address: getAddress(a[0]), role: 'operator' };
    const operator = getAddress(a[0]);
    contractLabel('Collection contract');
    fields.push(field('Operator', fmt(operator)), field('Approve all assets', a[1] ? 'YES' : 'Revoke'));
    riskLevel = a[1] ? 'high' : 'warning';
    const nft = { counterpartyLabel: 'Operator', counterparty: operator, assetKind: 'nft', assetContract: contract, assetContractLabel: 'NFT contract (not verified)' };
    if (a[1]) {
      warnings.push(`HIGH RISK: ${fmt(operator)} will be able to transfer every token held by this account in contract ${fmt(contract)} (ERC-721 or ERC-1155), including ones received later, until the approval is revoked.`);
      callDisplay = display('Approve All NFTs', { headline: `All your NFTs in ${short(contract)}`, ...nft });
      summary = `Approve all NFTs in ${short(contract)} to ${short(operator)}`;
    } else {
      title = 'Revoke collection operator';
      callDisplay = display('Revoke NFT Approval', { headline: `Operator for all NFTs in ${short(contract)}`, ...nft });
      summary = `Revoke NFT operator ${short(operator)} for ${short(contract)}`;
    }
  } else if (fn === 'safeBatchTransferFrom') {
    const ids = a[2], quantities = a[3], recipient = getAddress(a[1]);
    check(ids.length === quantities.length && ids.length <= 32, 'LIMIT', 'Invalid or oversized token batch.');
    contractLabel('ERC-1155 contract');
    const totals = new Map();
    ids.forEach((id, i) => { const t = totals.get(id) ?? { id, count: 0, quantity: 0n }; t.count++; t.quantity += quantities[i]; totals.set(id, t); });
    const total = quantities.reduce((n, q) => n + q, 0n);
    fields.push(field('Asset owner', fmt(a[0])), field('Recipient', fmt(recipient)),
      field('Items', ids.map((id, i) => `#${id} × ${quantities[i]}`).join('\n') || 'None'),
      field('Distinct token IDs', totals.size), field('Total quantity', total));
    if (a[4] !== '0x') fields.push(field('Receiver callback bytes', a[4]));
    if (!ids.length) warnings.push('This batch contains no items.');
    for (const t of totals.values()) if (t.count > 1) warnings.push(`Token ${tokenIdText(t.id)} appears ${t.count} times in this batch; its total quantity is ${t.quantity}.`);
    const zero = ids.map((id, i) => quantities[i] === 0n ? `${i + 1} (${tokenIdText(id)})` : undefined).filter(Boolean);
    if (zero.length) warnings.push(`Item${zero.length === 1 ? '' : 's'} ${zero.join(', ')} ${zero.length === 1 ? 'has' : 'have'} quantity 0.`);
    title = 'Transfer ERC-1155 batch';
    const distinct = [...totals.keys()];
    const headline = `${ids.length} item${ids.length === 1 ? '' : 's'}${distinct.length ? ` · IDs ${distinct.slice(0, 2).map(tokenIdText).join(', ')}${distinct.length > 2 ? ` (+${distinct.length - 2} more)` : ''}` : ''}`;
    callDisplay = display('Send ERC-1155 Batch', { headline, counterpartyLabel: 'To', counterparty: recipient,
      assetKind: 'multiToken', assetContract: contract, assetContractLabel: 'ERC-1155 contract (not verified)', tokenId: distinct.length === 1 ? distinct[0].toString() : undefined });
    summary = `Send ERC-1155 batch: ${headline} (${short(contract)})`;
  } else if (fn === 'execTransaction') {
    check(a[3] === 0n || a[3] === 1n, 'CALLDATA', 'Invalid Safe operation.');
    fields.push(field('Safe operation', a[3] ? 'DELEGATECALL' : 'CALL'), field('Existing signatures', a[9]));
    const refund = safeRefund(fields, warnings, { safeTxGas: a[4], baseGas: a[5], gasPrice: a[6], gasToken: a[7], refundReceiver: a[8] }, context);
    const inner = decodeCall(a[0], a[2], a[1], depth + 1, context);
    fields.push(...inner.fields.map(f => field('Safe: ' + f.label, f.value)));
    warnings.push(...inner.warnings, 'Safe owners and threshold are not independently verified offline.');
    asset = inner.asset; decodeStatus = inner.decodeStatus;
    riskLevel = a[3] || refund ? 'high' : inner.riskLevel;
    if (a[3]) warnings.push('HIGH RISK: DELEGATECALL executes in the Safe account context and may change owners, modules or storage.');
    callDisplay = { ...inner.display, action: 'Safe: ' + (inner.display?.action ?? inner.title) };
    if (inner.summary) summary = 'Safe: ' + inner.summary;
  } else if (fn === 'multiSend') {
    const reader = new Reader(hexToBytes(a[0], 65536));
    let count = 0, moved = 0n; riskLevel = 'high';
    const calls = [];
    while (reader.pos < reader.bytes.length) {
      check(++count <= 32, 'LIMIT', 'MultiSend contains too many calls.');
      const op = reader.u8(); check(op <= 1, 'CALLDATA', 'Invalid MultiSend operation.');
      const destination = getAddress('0x' + bytesToHex(reader.take(20)));
      const innerValue = BigInt('0x' + bytesToHex(reader.take(32)));
      const length = BigInt('0x' + bytesToHex(reader.take(32)));
      check(length <= 65536n, 'LIMIT', 'MultiSend calldata is too large.');
      const innerData = '0x' + bytesToHex(reader.take(Number(length)));
      const inner = decodeCall(destination, innerData, op ? 0n : innerValue, depth + 1, context);
      if (op) {
        // MultiSend hands no value to a delegatecall. Showing the encoded
        // number as an amount paid would misstate what the batch does.
        if (innerValue > 0n) {
          fields.push(field(`Call ${count} ignored value`, `${innerValue} wei encoded on a DELEGATECALL, which transfers nothing`));
          warnings.push(`Call ${count} encodes a value of ${innerValue} wei on a DELEGATECALL. MultiSend does not transfer it; it is not part of the amount shown.`);
        }
      } else moved += innerValue;
      calls.push({ index: count, inner, risk: op ? 'high' : inner.riskLevel, moves: op ? 0n : innerValue });
      fields.push(field(`Call ${count} operation`, op ? 'DELEGATECALL' : 'CALL'), ...inner.fields.map(f => field(`Call ${count}: ${f.label}`, f.value)));
      // Call-specific warnings are indexed; the shared generic notice is kept once.
      warnings.push(...inner.warnings.map(w => w === GENERIC_CALL_WARNING ? w : indexWarning(w, `Call ${count}`)));
      if (inner.decodeStatus !== 'fullyDecoded') decodeStatus = 'partiallyDecoded';
      if (op) warnings.push(`HIGH RISK: Call ${count} uses DELEGATECALL.`);
    }
    check(count > 0, 'CALLDATA', 'Empty MultiSend batch.');
    warnings.push('MultiSend target code and the current Safe policy are unverified offline.');
    // Headline lists the riskiest calls first (stable within the same risk).
    const describe = ({ inner }) => {
      const d = inner.display ?? {}, detail = d.headline ?? (d.amount !== undefined ? `${d.amount} ${d.symbol}` : undefined);
      return detail ? `${d.action ?? inner.title} (${detail})` : d.action ?? inner.title;
    };
    const ordered = [...calls].sort((p, q) => (RISK_ORDER[p.risk] ?? 0) - (RISK_ORDER[q.risk] ?? 0) || p.index - q.index);
    // A call that spends native value is always described, whatever its risk
    // rank: truncating the list must never be what hides a transfer.
    const spending = ordered.filter(c => c.moves > 0n);
    const shown = [...new Set([...spending, ...ordered])].slice(0, Math.max(3, spending.length));
    const omitted = count - shown.length;
    const headline = `${count} call${count === 1 ? '' : 's'}: ${shown.map(describe).join('; ')}${omitted > 0 ? ` (+${omitted} more)` : ''}`;
    // `moved` is what the batch forwards internally; `value` is what this
    // wallet actually pays to the batch contract. When both exist they are
    // shown separately — the amount is always what leaves the wallet.
    const inner = moved > 0n && network ? `${decimal(moved, 18)} ${network.symbol} forwarded inside the batch` : undefined;
    callDisplay = value > 0n && network
      ? display('Batch Transaction', { amount: decimal(value, 18), symbol: network.symbol,
                                       headline: [`${headline}`, inner].filter(Boolean).join(' · ') })
      : display('Batch Transaction', { headline, ...(inner ? { amount: decimal(moved, 18), symbol: network.symbol } : {}) });
    summary = `Batch: ${headline}`;
    if (value > 0n && network) {
      // The batch contract keeps whatever the inner calls do not forward, and
      // MultiSend has no refund path.
      const unspent = value - moved;
      warnings.push(`This pays ${nativeAmount(network, value)} to the batch contract${moved > 0n ? `, of which ${nativeAmount(network, moved)} is forwarded by the calls below` : ''}.`);
      if (unspent > 0n) warnings.push(`HIGH RISK: ${nativeAmount(network, unspent)} is sent to the batch contract but not forwarded by any call in it. A batch contract has no refund path, so that amount stays there and anyone able to call the contract may be able to take it.`);
      summary += ` (pays ${nativeAmount(network, value)})`;
    }
  } else {
    parsed.fragment.inputs.forEach((input, i) => fields.push(field(input.name, input.type === 'address' ? fmt(a[i]) : a[i])));
    riskLevel = 'high';
    warnings.push('HIGH RISK: This changes Safe account ownership, threshold, modules, guard or fallback handler.');
  }
  const titles = { transfer: 'Transfer tokens', approve: 'Approve token spending', transferFrom: 'Transfer assets', safeTransferFrom: 'Transfer NFT', setApprovalForAll: 'Authorize collection spending', safeBatchTransferFrom: 'Transfer NFT batch', execTransaction: 'Execute Safe transaction', multiSend: 'Execute transaction batch', enableModule: 'Enable Safe module', disableModule: 'Disable Safe module', addOwnerWithThreshold: 'Add Safe owner', removeOwner: 'Remove Safe owner', swapOwner: 'Replace Safe owner', changeThreshold: 'Change Safe threshold', setGuard: 'Set Safe guard', setFallbackHandler: 'Set Safe fallback handler' };
  title ??= titles[fn] ?? fn;
  callDisplay ??= display(title, { counterpartyLabel: 'Contract', counterparty: contract });
  const ens = ENS_CONTRACTS[contract.toLowerCase()];
  if (ens && NFT_METHODS.has(fn) && context.chainId === '1' && (context.chainFamily ?? 'evm') === 'evm') fields.push(field('Known contract (Ethereum)', ens));
  if (value > 0n && network && fn !== 'multiSend') {
    // Native value sent with a contract call always leads the summary.
    warnings.push(`This call also sends ${nativeAmount(network, value)} to the contract.`);
    riskLevel = 'high';
    const { assetKind, assetContract, assetContractLabel, tokenId } = callDisplay;
    if (assetContract === contract) {
      // NFT call: keep the recipient / operator / spender; the called contract is
      // already the asset contract, whose caption says it receives the native value.
      callDisplay = { ...callDisplay, amount: decimal(value, 18), symbol: network.symbol,
        assetContractLabel: `${assetContractLabel ?? 'Contract'} · receives the ${nativeAmount(network, value)}` };
    } else callDisplay = display(callDisplay.action, { amount: decimal(value, 18), symbol: network.symbol, headline: callDisplay.amount ? `${callDisplay.amount} ${callDisplay.symbol}` : callDisplay.headline, counterpartyLabel: 'Contract', counterparty: contract,
      assetKind, assetContract, assetContractLabel, tokenId });
    if (summary) summary += ` (also sends ${nativeAmount(network, value)})`;
  }
  return { title, fields, warnings: [...new Set(warnings)], decodeStatus, riskLevel, display: callDisplay, counterparty,
    ...(summary ? { summary } : {}), ...(asset ? { asset } : {}) };
}

// ---------------------------------------------------------------------------
// EIP-712. Every value is checked against its declared type and the digest is
// computed from the normalised values; displayed values are those same values.

const DOMAIN_TYPES = { name: 'string', version: 'string', chainId: 'uint256', verifyingContract: 'address', salt: 'bytes32' };
const DOMAIN_ORDER = ['name', 'version', 'chainId', 'verifyingContract', 'salt'];

function normalizeAtomic(type, value) {
  if (type === 'bool') { check(typeof value === 'boolean', 'TYPED_DATA', 'Typed bool values must be true or false.'); return value; }
  if (type === 'string') { check(typeof value === 'string' && value.length <= 65536, 'TYPED_DATA', 'Invalid typed string.'); return value; }
  if (type === 'address') {
    check(typeof value === 'string' && /^0x[0-9a-fA-F]{40}$/.test(value), 'TYPED_DATA', 'Typed addresses must be 0x-prefixed 20-byte hex.');
    try { return getAddress(value); } catch { fail('TYPED_DATA', 'Typed address has an invalid checksum.'); }
  }
  if (type === 'bytes') {
    check(typeof value === 'string' && /^0x(?:[0-9a-fA-F]{2}){0,65536}$/.test(value), 'TYPED_DATA', 'Typed bytes must be 0x-prefixed hex.');
    return value.toLowerCase();
  }
  let match = /^bytes([1-9][0-9]?)$/.exec(type);
  if (match) {
    const size = Number(match[1]); check(size <= 32, 'TYPED_DATA', 'Unsupported fixed bytes type.');
    check(typeof value === 'string' && new RegExp(`^0x[0-9a-fA-F]{${size * 2}}$`).test(value), 'TYPED_DATA', `Typed ${type} must be exactly ${size} bytes.`);
    return value.toLowerCase();
  }
  match = /^(u?)int([1-9][0-9]{0,2})$/.exec(type);
  if (match) {
    const bits = Number(match[2]); check(bits % 8 === 0 && bits <= 256, 'TYPED_DATA', 'Unsupported integer type.');
    let n;
    if (typeof value === 'number') { check(Number.isSafeInteger(value), 'TYPED_DATA', 'Use strings for large typed integers.'); n = BigInt(value); }
    else if (typeof value === 'string' && /^-?(0|[1-9][0-9]*)$/.test(value)) n = BigInt(value);
    else if (typeof value === 'string' && /^0x[0-9a-fA-F]{1,64}$/.test(value)) n = BigInt(value);
    else fail('TYPED_DATA', 'Typed integers must be decimal strings, 0x hex strings or safe integers.');
    const unsigned = match[1] === 'u', limit = 1n << BigInt(unsigned ? bits : bits - 1);
    check(unsigned ? n >= 0n && n < limit : n >= -limit && n < limit, 'TYPED_DATA', `Typed value is outside the ${type} range.`);
    return n;
  }
  fail('TYPED_DATA', 'Unsupported typed data type: ' + String(type).slice(0, 40));
}

/**
 * Normalises a typed value against its declared type. Every declared field is
 * required. Undeclared keys are not part of the signed data: in strict mode they
 * are refused; otherwise they are stripped (never displayed, never hashed) and
 * their paths recorded in `extras` so the review can say they were ignored.
 */
function normalizeTyped(types, type, value, depth = 0, extras = { strict: true, paths: [], count: 0 }, path = '') {
  check(depth < 20, 'LIMIT', 'Typed value nesting is too deep.');
  const array = /^(.*)\[([0-9]*)\]$/.exec(type);
  if (array) {
    check(Array.isArray(value) && value.length <= 128 && (!array[2] || value.length === Number(array[2])), 'TYPED_DATA', 'Invalid typed array length.');
    return value.map((item, i) => normalizeTyped(types, array[1], item, depth + 1, extras, `${path}[${i}]`));
  }
  if (types[type]) {
    check(value && typeof value === 'object' && !Array.isArray(value), 'TYPED_DATA', 'Expected a typed struct.');
    const definition = types[type], names = definition.map(f => f.name);
    check(names.every(n => Object.hasOwn(value, n)), 'TYPED_DATA', 'Typed message has extra unsigned or missing fields.');
    const undeclared = Object.keys(value).filter(k => !names.includes(k));
    if (undeclared.length) {
      check(!extras.strict, 'TYPED_DATA', 'Typed message has extra unsigned or missing fields.');
      extras.count += undeclared.length;
      for (const k of undeclared) if (extras.paths.length < 5) extras.paths.push(path ? `${path}.${k}` : k);
    }
    return Object.fromEntries(definition.map(f => [f.name, normalizeTyped(types, f.type, value[f.name], depth + 1, extras, path ? `${path}.${f.name}` : f.name)]));
  }
  return normalizeAtomic(type, value);
}

/** JSON-safe copy of normalised typed values (integers as decimal strings). */
const displayTyped = v => typeof v === 'bigint' ? v.toString() : Array.isArray(v) ? v.map(displayTyped)
  : v && typeof v === 'object' ? Object.fromEntries(Object.entries(v).map(([k, x]) => [k, displayTyped(x)])) : v;

function reachableTypes(types, primary) {
  const seen = new Set(), stack = [primary];
  while (stack.length) {
    const name = stack.pop();
    if (seen.has(name) || !types[name]) continue;
    seen.add(name);
    for (const f of types[name]) stack.push(f.type.replace(/(\[[0-9]*\])+$/, ''));
  }
  return seen;
}

function prepareTypedData(t) {
  check(t && typeof t === 'object' && t.domain && typeof t.domain === 'object' && t.types && typeof t.types === 'object' && t.message && typeof t.primaryType === 'string', 'TYPED_DATA', 'Incomplete EIP-712 request.');
  check(Object.keys(t.types).length <= 32, 'LIMIT', 'Too many EIP-712 types.');
  for (const [name, definition] of Object.entries(t.types)) {
    check(/^[A-Za-z_$][A-Za-z0-9_$]*$/.test(name) && Array.isArray(definition) && definition.length <= 64, 'TYPED_DATA', 'Invalid EIP-712 type definition.');
    check(definition.every(f => f && typeof f.name === 'string' && typeof f.type === 'string' && f.name.length <= 64 && f.type.length <= 96), 'TYPED_DATA', 'Invalid EIP-712 field definition.');
    check(new Set(definition.map(f => f.name)).size === definition.length, 'TYPED_DATA', 'Duplicate EIP-712 field name.');
  }
  check(t.primaryType !== 'EIP712Domain' && t.types[t.primaryType], 'TYPED_DATA', 'EIP-712 primary type is not defined.');
  // Types unreachable from the primary type do not affect the digest (as in wallets
  // that implement eth_signTypedData_v4); they are dropped rather than rejected.
  const reachable = reachableTypes(t.types, t.primaryType);
  const types = Object.fromEntries(Object.entries(t.types).filter(([name]) => name !== 'EIP712Domain' && reachable.has(name)));
  const encoder = TypedDataEncoder.from(types);
  check(encoder.primaryType === t.primaryType, 'TYPED_DATA', 'EIP-712 primary type is inconsistent.');
  // Domain: known fields only, each strictly typed. A declared EIP712Domain
  // must describe exactly the present fields; its order defines the separator.
  const keys = Object.keys(t.domain);
  check(keys.every(k => Object.hasOwn(DOMAIN_TYPES, k)), 'TYPED_DATA', 'Unsupported EIP-712 domain field.');
  const domain = Object.fromEntries(keys.map(k => [k, normalizeAtomic(DOMAIN_TYPES[k], t.domain[k])]));
  let domainType = DOMAIN_ORDER.filter(k => keys.includes(k)).map(name => ({ name, type: DOMAIN_TYPES[name] }));
  if (t.types.EIP712Domain) {
    const declared = t.types.EIP712Domain;
    check(declared.length === keys.length && declared.every(f => DOMAIN_TYPES[f.name] === f.type && keys.includes(f.name)), 'TYPED_DATA', 'The declared EIP-712 domain type does not match the domain values.');
    domainType = declared.map(({ name, type }) => ({ name, type }));
  }
  // Undeclared keys are refused (e.g. a Safe transaction's unsigned human
  // description), except on recognised marketplace request shapes, whose SDK
  // payloads may carry them; there they are stripped and reported.
  const extras = { strict: !marketplaceRequest(t.primaryType, domain), paths: [], count: 0 };
  const message = normalizeTyped(types, t.primaryType, t.message, 0, extras);
  const separator = TypedDataEncoder.hashStruct('EIP712Domain', { EIP712Domain: domainType }, domain);
  const digest = keccak256(hexConcat(['0x1901', separator, encoder.hash(message)]));
  return { types, domain, message, digest, displayDomain: displayTyped(domain), displayMessage: displayTyped(message),
    domainFields: domainType.map(f => f.name), extras };
}

/** What the review says about the address a request hands assets or authority
 * to. A hit means the deployment is published by the project itself, not that
 * this particular request is safe; a miss is worth a second look, so it becomes
 * a warning. A contract that is a token in the bundled registry is not treated
 * as unknown: the registry already identified it. */
function counterpartyNotice(chainFamily, chainId, counterparty, warnings) {
  if (!counterparty?.address) return undefined;
  const described = describeContract(chainFamily, chainId, counterparty.address, counterparty.role);
  if (described.known) return described;
  const token = lookupToken(chainFamily, chainId, counterparty.address);
  if (token) return { ...described, token: `${token.name} (${token.symbol})` };
  // An unlisted address is not suspicious by itself: most contracts, and every
  // Safe, are deployed by their own users. It is worth saying out loud when
  // something is being authorized to spend, which is where an imitation hurts.
  const what = counterparty.role === 'spender' ? 'The spender'
    : counterparty.role === 'operator' ? 'The operator' : undefined;
  if (what) warnings.push(`${what} is not in the bundled list of known public contracts, and is not a token this app recognizes. It may be new, or it may be an imitation. Check the address against the project's own documentation before signing.`);
  else warnings.push('This contract is not in the bundled list of known public contracts. That is normal for a new or private deployment; check the address against the project\u2019s own documentation.');
  return described;
}

function typedDataReview(request, common) {
  const t = request.typedData;
  const prepared = prepareTypedData(t);
  const { types, domain } = prepared, m = prepared.message;
  let network;
  if (domain.chainId !== undefined) {
    network = evmNetwork(domain.chainId);
    for (const id of [request.chainId, request.transport?.chainId].filter(v => v !== undefined))
      check(domain.chainId === uint(id), 'CHAIN_ID', 'EIP-712 chain ID does not match the signing request.');
  } else {
    for (const id of [request.chainId, request.transport?.chainId].filter(v => v !== undefined)) evmNetwork(uint(id));
  }
  const warnings = ['The verifying contract, domain name and current chain state are not verified offline.'];
  if (!network) warnings.push('Network context not included in the signed domain; this signature may be reusable on other networks.');
  if (!domain.verifyingContract) warnings.push('No verifying contract is bound by the signed domain.');
  // The counterparty of typed data is whoever it authorizes: the spender where
  // the message names one, otherwise the contract that will verify it.
  // Only a named spender or operator counts: `to` in a SafeTx is the inner call
  // target, not an address being authorized to spend.
  const spender = ['spender', 'operator'].map(key => m?.[key] ?? m?.details?.[key])
    .find(value => typeof value === 'string' && /^0x[0-9a-fA-F]{40}$/.test(value));
  const counterparty = spender ? { address: getAddress(spender), role: 'spender' }
    : domain.verifyingContract ? { address: getAddress(domain.verifyingContract), role: 'contract' } : undefined;
  const fields = [...common, field('Network', network?.name ?? 'Network context not included'), field('Primary type', t.primaryType),
    field('Domain', stable(prepared.displayDomain)), field('Field definitions', stable(types)), field('Signed values', stable(prepared.displayMessage))];
  if (prepared.extras.count) {
    // Key names are request text, not signed data: only the count is a warning;
    // the (sanitised, quoted) paths are a detail field.
    const names = prepared.extras.paths.map(p => JSON.stringify(p.replace(/[^A-Za-z0-9_$.[\]-]/g, '?').slice(0, 48)));
    warnings.push(`The request included ${prepared.extras.count} field(s) that are not part of the signed data. They were ignored and are not shown as signed values.`);
    fields.push(field('Ignored request keys', names.join('\n') + (prepared.extras.count > names.length ? `\n(+${prepared.extras.count - names.length} more)` : '')));
  }
  let riskLevel = 'high', decodeStatus = 'fullyDecoded', asset, typedDisplay, order, innerSummary;
  const canonical = (type, list) => JSON.stringify(types[type]?.map(f => [f.name, f.type])) === JSON.stringify(list);
  if (t.primaryType === 'SafeTx') {
    check(canonical('SafeTx', SAFE_TYPES), 'SAFE_SCHEMA', 'Unexpected SafeTx field definitions.');
    check(m.operation <= 1n, 'SAFE_SCHEMA', 'Invalid Safe operation.');
    fields.push(field('Safe address', domain.verifyingContract ?? 'Not included'), field('Safe operation', m.operation ? 'DELEGATECALL' : 'CALL'), field('Safe nonce', m.nonce));
    const context = { chainId: network?.chainId, network };
    const refund = safeRefund(fields, warnings, m, context);
    // Safe's Executor gives value to `call` only; `delegatecall` takes none, so
    // a value on a DELEGATECALL is never paid and must not be shown as the
    // amount. It is reported separately instead.
    const delegated = m.operation === 1n;
    const inner = decodeCall(m.to, m.data, delegated ? 0n : m.value, 0, context);
    if (delegated && m.value > 0n) {
      fields.push(field('Ignored delegatecall value', `${m.value} wei encoded on a DELEGATECALL, which transfers nothing`));
      warnings.push(`This Safe transaction encodes a value of ${m.value} wei on a DELEGATECALL. The Safe does not transfer it; it is not part of the amount shown.`);
    }
    fields.push(...inner.fields);
    warnings.push(...inner.warnings, 'This is one Safe owner signature. Current owner membership, threshold and nonce remain unverified offline.');
    asset = inner.asset; decodeStatus = inner.decodeStatus;
    riskLevel = m.operation || refund ? 'high' : inner.riskLevel;
    if (m.operation) warnings.push('HIGH RISK: DELEGATECALL executes using Safe account storage and may change permissions.');
    typedDisplay = { ...inner.display, action: 'Safe: ' + (inner.display?.action ?? inner.title) };
    innerSummary = inner.summary;
  } else if (/permit/i.test(t.primaryType)) {
    const permit2612 = canonical('Permit', [['owner','address'],['spender','address'],['value','uint256'],['nonce','uint256'],['deadline','uint256']]);
    const permitDai = canonical('Permit', [['holder','address'],['spender','address'],['nonce','uint256'],['expiry','uint256'],['allowed','bool']]);
    const permitDetails = canonical('PermitDetails', [['token','address'],['amount','uint160'],['expiration','uint48'],['nonce','uint48']]);
    const allowance2 = permitDetails && ((t.primaryType === 'PermitSingle' && canonical('PermitSingle', [['details','PermitDetails'],['spender','address'],['sigDeadline','uint256']]))
      || (t.primaryType === 'PermitBatch' && canonical('PermitBatch', [['details','PermitDetails[]'],['spender','address'],['sigDeadline','uint256']])));
    const permission2 = canonical('TokenPermissions', [['token','address'],['amount','uint256']]);
    const transfer2 = permission2 && ((t.primaryType === 'PermitTransferFrom' && canonical('PermitTransferFrom', [['permitted','TokenPermissions'],['spender','address'],['nonce','uint256'],['deadline','uint256']]))
      || (t.primaryType === 'PermitBatchTransferFrom' && canonical('PermitBatchTransferFrom', [['permitted','TokenPermissions[]'],['spender','address'],['nonce','uint256'],['deadline','uint256']])));
    const recognized = (t.primaryType === 'Permit' && (permit2612 || permitDai)) || allowance2 || transfer2;
    if (!recognized) { decodeStatus = 'partiallyDecoded'; warnings.push('This is a custom permit schema. Its complete signed fields are shown, but application-specific behavior is not fully decoded.'); }
    warnings.push('HIGH RISK: This permit authorizes token spending without another signature. Verify the spender, amount, expiry and nonce.');
    let unlimited = false, headlineAmount;
    if (recognized) {
      if (m.spender !== undefined) fields.push(field('Spender', m.spender));
      if (m.owner !== undefined) fields.push(field('Token owner', m.owner));
      if (m.holder !== undefined) fields.push(field('Token holder', m.holder));
      for (const name of ['nonce', 'deadline', 'sigDeadline', 'expiry']) if (m[name] !== undefined) fields.push(field(name, m[name]));
      // EIP-2612 / DAI Permit bind the token through the domain; Permit2 binds each token explicitly.
      if (m.value !== undefined && domain.verifyingContract) {
        fields.push(field('Allowance (raw units)', m.value));
        if (m.value === MAX_UINT256) { warnings.push('UNLIMITED spending approval.'); unlimited = true; }
        if (network) asset = lookupToken('evm', network.chainId, domain.verifyingContract, m.value);
        headlineAmount = m.value;
      }
      if (m.allowed !== undefined) {
        fields.push(field('Unlimited permit', m.allowed ? 'YES' : 'No (revokes allowance)'));
        if (m.allowed === true) { warnings.push('UNLIMITED spending approval.'); unlimited = true; }
        if (network) asset = lookupToken('evm', network.chainId, domain.verifyingContract);
      }
      const details = m.details ?? m.permitted;
      if (details) {
        const entries = Array.isArray(details) ? details : [details];
        check(entries.length <= 32, 'LIMIT', 'Too many Permit2 token allowances.');
        entries.forEach((d, i) => {
          fields.push(field(`Token ${i + 1}`, d.token), field(`Token ${i + 1} allowance (raw units)`, d.amount));
          for (const n of ['expiration', 'nonce']) if (d[n] !== undefined) fields.push(field(`Token ${i + 1} ${n}`, d[n]));
          if (d.amount === (1n << 160n) - 1n || d.amount === MAX_UINT256) { warnings.push('UNLIMITED spending approval.'); unlimited = true; }
          if (network && entries.length === 1) { asset = lookupToken('evm', network.chainId, d.token, d.amount); headlineAmount = d.amount; }
        });
      }
      if (asset?.displayAmount !== undefined) fields.push(field('Asset', asset.name + ' (' + asset.symbol + ')'), field('Allowance (' + asset.symbol + ')', asset.displayAmount));
    }
    const amount = unlimited ? 'Unlimited' : asset?.displayAmount ?? (headlineAmount !== undefined ? String(headlineAmount) : undefined);
    typedDisplay = display('Permit Spending', { amount, symbol: amount ? (asset?.symbol ?? (unlimited ? 'tokens' : 'raw units')) : undefined,
      headline: amount ? undefined : t.primaryType, counterpartyLabel: m.spender ? 'Spender' : undefined, counterparty: m.spender });
  } else if ((order = reviewNftOrder({ primaryType: t.primaryType, types, domain, domainFields: prepared.domainFields, message: m, network,
    signer: request.address ? getAddress(request.address) : undefined }))) {
    // Seaport / Blur / LooksRare orders recognised by exact types, domain and contract.
    fields.push(...order.fields);
    warnings.push(...order.warnings);
    decodeStatus = order.decodeStatus;
    typedDisplay = order.display;
  } else {
    decodeStatus = 'partiallyDecoded';
    const opaque = opaqueRootWarning(t.primaryType, types);
    if (opaque) warnings.push(opaque);
    warnings.push('The typed fields are decoded, but this application-specific authorization is not semantically understood. Review every signed field.');
    typedDisplay = display('Sign Typed Data', { headline: t.primaryType, counterpartyLabel: domain.verifyingContract ? 'Contract' : undefined, counterparty: domain.verifyingContract });
  }
  const title = order?.title ?? (t.primaryType === 'SafeTx' ? 'Approve a Safe transaction' : /permit/i.test(t.primaryType) ? 'Authorize token spending' : 'Sign typed data');
  const summary = order?.summary ?? (asset?.displayAmount !== undefined ? `${t.primaryType}: ${asset.displayAmount} ${asset.symbol}`
    : t.primaryType === 'SafeTx' ? (innerSummary ? `Safe owner approval: ${innerSummary}` : 'Safe owner approval') : 'EIP-712 structured signature');
  const contract = t.primaryType === 'SafeTx' && counterparty?.role === 'contract'
    ? undefined : counterpartyNotice('evm', network?.chainId, counterparty, warnings);
  if (contract?.known) fields.push(field(contract.role === 'spender' ? 'Spender (known contract)' : 'Verifying contract (known)',
    `${contract.name} — ${contract.protocol} · ${contract.category}${contract.everyChain ? ' (same address on every EVM network)' : ''}`));
  return { path: request.path ?? PATHS.evm, digest: prepared.digest, signingBytesDigest: prepared.digest.slice(2),
    review: reviewResult(request, title, summary, fields, warnings,
      { decodeStatus, riskLevel: contract && !contract.known && contract.role === 'spender' && riskLevel === 'normal' ? 'warning' : riskLevel, display: typedDisplay,
        ...(network ? { network: { chainId: network.chainId, name: network.name, symbol: network.symbol } } : {}),
        ...(contract ? { contract } : {}), ...(asset ? { asset } : {}) }) };
}

export function parseEVM(request) {
  check(!request.network || request.network === 'mainnet', 'NETWORK', 'Unsupported network');
  for (const id of [request.chainId, request.transport?.chainId].filter(v => v !== undefined)) evmNetwork(uint(id));
  if (request.chainId !== undefined && request.transport?.chainId !== undefined) check(uint(request.chainId) === uint(request.transport.chainId), 'CHAIN_ID', 'Conflicting network context in the request and transport.');
  const path = request.path ?? PATHS.evm;
  const common = [field('Derivation path', request.path ?? 'Provided by matched signing plan')];
  if (request.address) common.push(field('Requested signer', getAddress(request.address)));
  if (request.kind === 'personal') {
    const message = hexToBytes(request.message, 8192);
    let text, decodeStatus = 'fullyDecoded';
    try { text = toUtf8String(message); } catch { decodeStatus = 'opaque'; }
    const printable = text !== undefined && !/[ --]/.test(text);
    if (!printable) decodeStatus = 'opaque';
    const contextNetwork = request.chainId !== undefined ? evmNetwork(uint(request.chainId)) : undefined;
    const warnings = ['Message signatures can authorize logins, orders or asset actions. Verify the entire message and origin.'];
    if (message.length === 32 && !printable) warnings.push('HIGH RISK: This 32-byte message looks like a hash. Signing a hash you cannot read can authorize anything.');
    return { path, digest: hashMessage(message), signingBytesDigest: hashMessage(message).slice(2),
      review: reviewResult(request, 'Sign Ethereum message', 'Personal signature (EIP-191)', [...common,
        field('Network context', contextNetwork ? contextNetwork.name + ' (request context only; not bound by personal message)' : 'Network context not included'),
        field('Message', printable ? JSON.stringify(text) : 'Non-text message; review exact bytes.'), field('Exact message bytes', '0x' + bytesToHex(message))],
        warnings, { decodeStatus, riskLevel: 'high', display: display('Sign Message', { headline: printable ? text.slice(0, 280) : `${message.length} bytes of binary data` }),
          ...(contextNetwork ? { network: { chainId: contextNetwork.chainId, name: contextNetwork.name, symbol: contextNetwork.symbol } } : {}) }) };
  }
  if (request.kind === 'typedData') return typedDataReview(request, common);
  check(request.kind === 'transaction', 'UNSUPPORTED', 'Unsupported EVM request kind.');
  const raw = request.transaction;
  check(raw && (typeof raw === 'string' || typeof raw === 'object'), 'TRANSACTION', 'Missing EVM transaction.');
  let unsigned = raw;
  if (typeof raw === 'object') {
    const allowed = ['type', 'to', 'nonce', 'gasLimit', 'gasPrice', 'maxPriorityFeePerGas', 'maxFeePerGas', 'data', 'value', 'chainId', 'accessList', 'from'];
    check(Object.keys(raw).every(k => allowed.includes(k)), 'TRANSACTION', 'Unsupported EVM transaction field.');
    check(raw.chainId !== undefined && raw.nonce !== undefined && raw.gasLimit !== undefined, 'TRANSACTION', 'Chain ID, nonce and gas limit are required.');
    // 'from' is not part of an unsigned transaction; when present (null means
    // absent, as in ethers) it is validated here, shown as the sender and checked
    // against the signing key. The key is always left out of hashing.
    if (raw.from != null) {
      check(typeof raw.from === 'string' && /^0x[0-9a-fA-F]{40}$/.test(raw.from), 'TRANSACTION', 'Invalid transaction sender.');
      try { getAddress(raw.from); } catch { fail('TRANSACTION', 'Transaction sender has an invalid checksum.'); }
    }
    const { from, ...rest } = raw;
    unsigned = rest;
  }
  const tx = Transaction.from(unsigned);
  check(!tx.signature, 'TRANSACTION', 'EVM transaction is already signed.');
  check([0, 1, 2].includes(tx.type ?? tx.inferType()), 'UNSUPPORTED', 'Only EVM legacy, EIP-2930 and EIP-1559 transactions are supported.');
  check(tx.chainId > 0n, 'CHAIN_ID', 'Unprotected or missing-chain-ID EVM transactions are refused.');
  const network = evmNetwork(tx.chainId);
  if (request.chainId !== undefined) check(tx.chainId === uint(request.chainId), 'CHAIN_ID', 'Chain ID does not match the signing request.');
  if (request.transport?.chainId !== undefined) check(tx.chainId === uint(request.transport.chainId), 'CHAIN_ID', 'Transport chain ID differs from the transaction.');
  check(tx.gasLimit > 0n, 'GAS', 'Gas limit must be positive.');
  const feePerGas = tx.maxFeePerGas ?? tx.gasPrice;
  check(feePerGas !== null && feePerGas >= 0n, 'GAS', 'Gas price is missing.');
  check(tx.maxPriorityFeePerGas === null || tx.maxPriorityFeePerGas <= feePerGas, 'GAS', 'Priority fee exceeds maximum fee.');
  const call = decodeCall(tx.to, tx.data, tx.value, 0, { chainId: network.chainId, network });
  const maxFee = tx.gasLimit * feePerGas;
  const fields = [...common, ...(typeof raw === 'object' && raw.from ? [field('Sender', getAddress(raw.from))] : []),
    field('Network', network.name), field('Chain ID', tx.chainId), field('Transaction type', tx.type ?? tx.inferType()), ...call.fields,
    field('Nonce', tx.nonce), field('Gas limit', tx.gasLimit), field('Maximum gas price (wei)', feePerGas),
    field('Maximum network fee (' + network.symbol + ')', decimal(maxFee, 18))];
  let riskLevel = call.riskLevel;
  if (['10', '42161', '8453'].includes(network.chainId)) call.warnings.push('Additional L1 data or rollup fees are not bound by gasLimit × gas price and cannot be calculated fully offline.');
  if (maxFee > (HIGH_FEE[network.chainId] ?? 5n * 10n ** 16n)) {
    call.warnings.unshift(`HIGH FEE: This transaction allows up to ${nativeAmount(network, maxFee)} in network fees. Check the gas settings in your other wallet.`);
    riskLevel = 'high';
  }
  if (tx.accessList?.length) fields.push(field('Access list', JSON.stringify(tx.accessList)));
  const contract = counterpartyNotice('evm', network.chainId, call.counterparty, call.warnings);
  if (contract?.known) fields.push(field(contract.role === 'spender' ? 'Spender (known contract)' : contract.role === 'operator' ? 'Operator (known contract)' : 'Contract (known)',
    `${contract.name} — ${contract.protocol} · ${contract.category}${contract.everyChain ? ' (same address on every EVM network)' : ''}`));
  if (contract && !contract.known && ['spender', 'operator'].includes(contract.role)) riskLevel = riskLevel === 'high' ? 'high' : 'warning';
  const rawAmount = call.fields.find(f => ['Token amount (raw units)', 'Allowance / NFT token ID', 'Amount / NFT token ID'].includes(f.label));
  const summary = call.asset ? `${call.title}: ${call.asset.displayAmount} ${call.asset.symbol}` : call.title === 'Native transfer' ? `${decimal(tx.value, 18)} ${network.symbol}`
    : call.summary ?? (rawAmount ? `${call.title}: ${rawAmount.value} raw units` : call.title);
  return { path, digest: tx.unsignedHash, signingBytesDigest: tx.unsignedHash.slice(2), tx,
    review: reviewResult(request, call.title, summary, fields, call.warnings, { decodeStatus: call.decodeStatus, riskLevel,
      display: { ...call.display, fee: decimal(maxFee, 18) + ' ' + network.symbol },
      network: { chainId: network.chainId, name: network.name, symbol: network.symbol },
      ...(contract ? { contract } : {}), ...(call.asset ? { asset: call.asset } : {}) }) };
}

/** Minimal big-endian bytes of a non-negative integer (at least one byte). */
function integerBytes(n) {
  let text = n.toString(16); if (text.length % 2) text = '0' + text;
  return hexToBytes(text);
}

export function signEVM(request, seed, root, task) {
  const parsed = parseEVM(request), target = task?.targets?.[0];
  if (task) check(task.targets?.length === 1, 'SIGNER', 'An EVM task requires one signer.');
  return withKey(seed, root, 'evm', target?.path ?? parsed.path, (key, pub) => {
    const address = computeAddress('0x' + bytesToHex(pub));
    if (target?.publicKey) check(equal(pub, hexToBytes(target.publicKey, 33)), 'SIGNER', 'EVM task key differs from the decrypted wallet.');
    if (target?.address) check(address === getAddress(target.address), 'SIGNER', 'EVM task address mismatch.');
    if (request.address) check(address === getAddress(request.address), 'SIGNER', 'Requested signer does not match this wallet.');
    if (typeof request.transaction === 'object' && request.transaction?.from) check(address === getAddress(request.transaction.from), 'SIGNER', 'Transaction sender does not match this wallet.');
    const signature = new SigningKey('0x' + bytesToHex(key)).sign(parsed.digest);
    check(recoverAddress(parsed.digest, signature) === address, 'SIGNATURE', 'Signature verification failed.');
    const rs = signature.r.slice(2) + signature.s.slice(2);
    const result = { chain: 'evm', requestHash: parsed.review.requestHash, address, signature: signature.serialized.slice(2), digest: parsed.digest };
    if (parsed.tx) {
      parsed.tx.signature = signature;
      result.serializedTransaction = parsed.tx.serialized;
      result.transactionHash = parsed.tx.hash;
      // The eth-signature v must be what the coordinator writes into the
      // transaction: EIP-155 v for legacy, y-parity for typed transactions.
      const v = parsed.tx.type === 0 ? parsed.tx.chainId * 2n + 35n + BigInt(signature.yParity) : BigInt(signature.yParity);
      result.signatureV = v.toString();
      result.qrSignature = rs + bytesToHex(integerBytes(v));
    } else {
      // Messages and typed data use v = 27 + y-parity (ethers' serialized form).
      result.qrSignature = result.signature;
    }
    return result;
  });
}
