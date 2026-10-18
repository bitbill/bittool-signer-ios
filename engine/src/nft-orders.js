// NFT display helpers and EIP-712 NFT marketplace orders (Seaport, Blur,
// LooksRare). Every protocol constant is pinned from the protocol's verified
// source; nothing is fetched at runtime. Recognition is exact (types, domain
// and verifying contract); anything else falls back to the generic typed-data
// review, which is always at least as cautious. Marketplace orders are always
// high risk because they move assets without another signature.
import { lookupToken } from './token-registry.js';
import { field, decimal } from './util.js';

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000';
const MAX_UINT256 = (1n << 256n) - 1n;
const MAX_LINES = 32;          // give/receive/others lines per display list
const MAX_ITEMISED = 32;       // orders of a bulk tree itemised as detail fields
const MAX_ORDER_WARNINGS = 24; // distinct per-order warnings listed for a bulk tree
const YEAR_9999 = 253402300799n; // engine policy: end times after 9999-12-31 never expire
const YEAR = 365n * 86400n;    // engine policy: validity windows over a year are flagged,
const DECADE = 10n * YEAR;     // and over ten years are flagged red
const DUST_DECIMALS = 4;       // engine policy: proceeds under 0.0001 of a whole unit are a very low price
const same = (a, b) => typeof a === 'string' && typeof b === 'string' && a.toLowerCase() === b.toLowerCase();
const plural = (n, word) => `${n} ${word}${n === 1n || n === 1 ? '' : 's'}`;

// ---------------------------------------------------------------------------
// Shared helpers (also used for EVM/TRON calldata in evm.js).

/** '#1234', or '#79233663…80642508 (77 digits)' for IDs of 13 or more digits. */
export function tokenIdText(id) {
  const s = BigInt(id).toString();
  return s.length >= 13 ? `#${s.slice(0, 8)}…${s.slice(-8)} (${s.length} digits)` : '#' + s;
}
export const tokenIdHex = id => '0x' + BigInt(id).toString(16).padStart(64, '0');
/** Full decimal and hex forms of a token ID as detail fields. */
export const tokenIdFields = (id, prefix = '') => [field(prefix + 'Token ID', BigInt(id).toString()), field(prefix + 'Token ID (hex)', tokenIdHex(id))];
/** Whole-number quantity; only very long values are abbreviated. */
export function quantityText(n) {
  const s = BigInt(n).toString();
  return s.length >= 25 ? `${s.slice(0, 8)}…${s.slice(-8)} (${s.length} digits)` : s;
}
export const shortAddress = a => typeof a === 'string' && a.length > 14 ? `${a.slice(0, 6)}…${a.slice(-4)}` : String(a);
const shortHex = h => `${h.slice(0, 10)}…${h.slice(-8)}`;
export function utcTime(seconds) {
  const t = BigInt(seconds);
  if (t === MAX_UINT256) return 'Never (maximum value)';
  if (t > 253402300799n) return `${t} (after year 9999)`;
  return new Date(Number(t) * 1000).toISOString().replace('T', ' ').replace('.000Z', ' UTC');
}
/**
 * Labels a nested warning ("Call 2", "Order 3") while keeping a severe prefix
 * (HIGH RISK / HIGH FEE / UNLIMITED) at the start so the UI still renders it red.
 */
export function indexWarning(warning, label) {
  const severe = /^(HIGH RISK:|HIGH FEE:)\s*/.exec(warning);
  if (severe) return `${severe[1]} ${label}: ${warning.slice(severe[0].length)}`;
  if (/^UNLIMITED/i.test(warning)) return `${warning.replace(/\.$/, '')} (${label}).`;
  return `${label}: ${warning}`;
}
export const capLines = lines => lines.length <= MAX_LINES ? lines : [...lines.slice(0, MAX_LINES - 1), `(+${lines.length - MAX_LINES + 1} more)`];
const display = (action, extra = {}) => Object.fromEntries(Object.entries({ action, ...extra })
  .filter(([, v]) => v !== undefined && v !== null && v !== '' && !(Array.isArray(v) && !v.length)));
const unique = list => [...new Set(list)];

/** Engine expiry policy shared by every marketplace order. */
function expiryWarnings(start, end) {
  if (end > YEAR_9999)
    return [`HIGH RISK: This order effectively never expires (end time ${end === MAX_UINT256 ? 'is the maximum possible value' : utcTime(end)}). It stays valid until you cancel it on-chain.`];
  if (start !== undefined && end <= start) return ['The order end time is not after its start time, so it cannot be filled.'];
  if (start !== undefined && end - start > DECADE)
    return [`HIGH RISK: This order stays valid for more than 10 years (until ${utcTime(end)}). It can be filled at any time until then unless you cancel it on-chain.`];
  if (start !== undefined && end - start > YEAR) return [`This order stays valid for more than a year (until ${utcTime(end)}).`];
  return [];
}

/**
 * Per-order warnings of a bulk tree: identical warnings are merged
 * ("Orders 1, 2, 3 (+597 more): …") and the list is capped, red ones first,
 * so a large hostile tree cannot flood the review.
 */
function orderWarnings(lists, many) {
  if (!many) return lists.flat();
  const groups = new Map();
  lists.forEach((list, i) => { for (const w of unique(list)) { const g = groups.get(w) ?? []; g.push(i + 1); groups.set(w, g); } });
  const label = orders => orders.length === 1 ? `Order ${orders[0]}`
    : orders.length === lists.length ? `All ${orders.length} orders`
      : `Orders ${orders.slice(0, 3).join(', ')}${orders.length > 3 ? ` (+${orders.length - 3} more)` : ''}`;
  const out = [...groups].map(([w, orders]) => indexWarning(w, label(orders)));
  if (out.length <= MAX_ORDER_WARNINGS) return out;
  const red = out.filter(isSevere), other = out.filter(w => !isSevere(w));
  const kept = [...red, ...other].slice(0, MAX_ORDER_WARNINGS - 1), dropped = out.length - kept.length;
  const droppedRed = red.length > kept.length;
  return [...kept, `${droppedRed ? 'HIGH RISK: ' : ''}${dropped} more order-specific warning${dropped === 1 ? ' is' : 's are'} not listed here. Review every order in the signed values.`];
}
const isSevere = w => /^(HIGH RISK|HIGH FEE|UNLIMITED)/i.test(w);
/** Raw amount below which a known currency's proceeds are a very low price, or undefined. */
const dustLimit = cur => cur.decimals !== undefined && cur.decimals >= DUST_DECIMALS ? 10n ** BigInt(cur.decimals - DUST_DECIMALS) : undefined;
const dustWarning = texts => `You receive only ${texts.join(' + ')} for the items you give. Check that this very low price is intended.`;

const sameFields = (defs, list) => Array.isArray(defs) && defs.length === list.length && defs.every((f, i) => f.name === list[i][0] && f.type === list[i][1]);
const onlyTypes = (types, names) => Object.keys(types).length === names.length && names.every(n => types[n]);
const DOMAIN_FIELDS = ['name', 'version', 'chainId', 'verifyingContract'];
function exactDomain(domain, domainFields, name, version, chainIds, contract) {
  return JSON.stringify(domainFields) === JSON.stringify(DOMAIN_FIELDS) && Object.keys(domain).length === 4
    && domain.name === name && domain.version === version && chainIds.includes(String(domain.chainId)) && same(domain.verifyingContract, contract);
}
/** Height h of a Merkle tree type `<leaf>[2]…[2] tree` (1 ≤ h ≤ max), or 0. */
function treeHeight(defs, leaf, max) {
  if (!Array.isArray(defs) || defs.length !== 1 || defs[0].name !== 'tree') return 0;
  const match = new RegExp(`^${leaf}((?:\\[2\\])+)$`).exec(defs[0].type);
  const h = match ? match[1].length / 3 : 0;
  return h >= 1 && h <= max ? h : 0;
}
const treeLeaves = (tree, h) => { let out = [tree]; for (let i = 0; i < h; i++) out = out.flat(1); return out; };

/** The local registry lists fungible tokens only; a hit means the contract is not an NFT collection. */
const fungibleToken = (token, ctx) => ctx.network ? lookupToken('evm', ctx.network.chainId, token) : undefined;
/**
 * HIGH RISK text for an NFT-typed item or order on a registry fungible token.
 * NFT transfers use transferFrom(from, to, id), the same selector as ERC-20,
 * so on an ERC-20 the "token ID" becomes an amount.
 */
function disguisedText(what, token, meta, erc721, effect) {
  return `HIGH RISK: ${what} is typed ${erc721 ? 'ERC-721' : 'ERC-1155'}, but ${token} is ${meta.symbol}, a fungible token in the local registry, not an NFT contract. ${effect}`;
}
/** Fungible currency of an order item: native coin or ERC-20 (registry or raw units). */
function currency(native, token, ctx) {
  if (native) {
    const symbol = ctx.network?.symbol;
    return { key: 'native', known: !!symbol, decimals: symbol ? 18 : undefined, symbol: symbol ?? 'wei', value: v => symbol ? decimal(v, 18) : String(v),
      text: v => symbol ? `${decimal(v, 18)} ${symbol}` : `${v} wei (native currency)` };
  }
  const meta = fungibleToken(token, ctx);
  if (meta) return { key: token.toLowerCase(), known: true, decimals: meta.decimals, symbol: meta.symbol, value: v => decimal(v, meta.decimals), text: v => `${decimal(v, meta.decimals)} ${meta.symbol}` };
  return { key: token.toLowerCase(), known: false, symbol: 'raw units', value: v => String(v), text: v => `${v} raw units of ${shortAddress(token)}` };
}
const rangeText = (fmt, start, end) => start === end ? fmt(start) : `${fmt(start)} → ${fmt(end)} (changes linearly over time)`;
const minOf = (a, b) => a < b ? a : b, maxOf = (a, b) => a > b ? a : b;

/** Summary of NFT items: the single item, or "<k> items · IDs #a, #b (+m more) · 0xColl…". */
function nftSummary(items) {
  if (!items.length) return undefined;
  if (items.length === 1) return items[0].text;
  const contracts = unique(items.map(i => i.token.toLowerCase()));
  const shown = items.slice(0, 2).map(i => i.short).join(', ');
  return `${items.length} items · IDs ${shown}${items.length > 2 ? ` (+${items.length - 2} more)` : ''}${contracts.length === 1 ? ' · ' + shortAddress(items[0].token) : ''}`;
}
/** A single-currency total (lower or upper bound for Dutch auctions), or undefined. */
function totalAmount(totals, bound) {
  if (totals.size !== 1) return undefined;
  const [t] = totals.values();
  const v = bound === 'min' ? minOf(t.start, t.end) : maxOf(t.start, t.end);
  return { amount: t.cur.value(v), symbol: t.cur.symbol, text: t.cur.text(v), key: t.cur.key, known: t.cur.known };
}
function addTotal(totals, cur, start, end) {
  const t = totals.get(cur.key) ?? { cur, start: 0n, end: 0n };
  t.start += start; t.end += end; totals.set(cur.key, t);
}
function commonContract(items) {
  const contracts = unique(items.map(i => i.token));
  return contracts.length === 1 && items.length ? contracts[0] : undefined;
}
function singleTokenId(items) {
  return items.length === 1 && items[0].id !== undefined ? items[0].id.toString() : undefined;
}

// ---------------------------------------------------------------------------
// Seaport 1.5 / 1.6 (ProjectOpenSea/seaport-core ConsiderationBase.sol; README deployments).

const SEAPORT = { '1.6': '0x0000000000000068F116a894984e2DB1123eB395', '1.5': '0x00000000000000ADc04C56Bf30aC9d3c0aAF14dC' };
// Seaport 1.5 and 1.6 are deployed at these addresses on all eight supported networks.
const SEAPORT_CHAINS = ['1', '56', '42161', '8453', '10', '137', '100', '43114'];
const OFFER_ITEM = [['itemType', 'uint8'], ['token', 'address'], ['identifierOrCriteria', 'uint256'], ['startAmount', 'uint256'], ['endAmount', 'uint256']];
const CONSIDERATION_ITEM = [...OFFER_ITEM, ['recipient', 'address']];
const ORDER_COMPONENTS = [['offerer', 'address'], ['zone', 'address'], ['offer', 'OfferItem[]'], ['consideration', 'ConsiderationItem[]'], ['orderType', 'uint8'],
  ['startTime', 'uint256'], ['endTime', 'uint256'], ['zoneHash', 'bytes32'], ['salt', 'uint256'], ['conduitKey', 'bytes32'], ['counter', 'uint256']];
const ITEM_TYPES = ['NATIVE', 'ERC20', 'ERC721', 'ERC1155', 'ERC721_WITH_CRITERIA', 'ERC1155_WITH_CRITERIA'];
const ORDER_TYPES = ['FULL_OPEN', 'PARTIAL_OPEN', 'FULL_RESTRICTED', 'PARTIAL_RESTRICTED', 'CONTRACT'];
// opensea-js (src/constants.ts, utils/chain.ts) uses these defaults on Ethereum,
// OP, Polygon, Base, Arbitrum and Avalanche. It does not support BNB Smart Chain
// or Gnosis, so no OpenSea label is shown there. Labels are detail text only.
const OPENSEA_CHAINS = ['1', '10', '137', '8453', '42161', '43114'];
const OPENSEA_FEE_RECIPIENT = '0x0000a26b00c1F0DF003000390027140000fAa719';
const OPENSEA_CONDUIT_KEY = '0x0000007b02230091a7ed01230072f7006a004d60a8d4e71d599b8104250f0000';
const OPENSEA_CONDUIT = '0x1E0049783F008A0085193E00003D00cd54003c71';
const OPENSEA_SIGNED_ZONE_V2 = '0x000056f7000000ece9003ca63978907a00ffd100';
const ZERO_BYTES32 = '0x' + '00'.repeat(32);

function seaportItem(item, ctx) {
  const n = item.itemType, token = item.token, id = item.identifierOrCriteria, start = item.startAmount, end = item.endAmount;
  const typeName = n <= 5n ? `${ITEM_TYPES[Number(n)]} (${n})` : `Unknown (${n})`;
  const base = { token, start, end, recipient: item.recipient };
  if (n > 5n) return { ...base, valid: false, nft: false, text: `Unknown item type ${n} · ${shortAddress(token)}`, short: '?',
    detail: `Type: ${typeName}\nContract: ${token}\nIdentifier or criteria: ${id}\nAmount: ${start === end ? start : `${start} → ${end}`}` };
  const type = Number(n);
  const rawRange = start === end ? `${start}` : `${start} → ${end}`;
  if (type <= 1) {
    const cur = currency(type === 0, token, ctx);
    // Seaport's ERC-20 path calls transferFrom(from, to, amount); on an ERC-721 contract that moves token #amount.
    const alt = type === 1 && !cur.known && start === end;
    return { ...base, valid: true, nft: false, cur,
      text: rangeText(cur.text, start, end) + (alt ? ` (or NFT ${tokenIdText(start)} if ${shortAddress(token)} is an ERC-721)` : ''),
      detail: `Type: ${typeName}\n${type === 0 ? 'Currency: native' : `Token: ${token}${cur.known ? '' : ' (not in the local registry)'}`}\nAmount: ${rangeText(cur.text, start, end)}${cur.known ? `\nRaw amount: ${rawRange}` : ''}`
        + (alt ? `\nInterpretation: if this contract is an ERC-721, the same transfer moves token ${tokenIdText(start)} instead. The contract type cannot be confirmed offline.` : '') };
  }
  const meta = fungibleToken(token, ctx);
  if (meta) {
    // An NFT-typed item on a registry ERC-20: never shown as an NFT.
    const erc721 = type === 2 || type === 4, sa = shortAddress(token);
    const effect = type === 2 ? `Seaport moves ERC-721 items with transferFrom, which on this token moves ${decimal(id, meta.decimals)} ${meta.symbol} (the "token ID" is the amount).`
      : type === 4 ? `Seaport moves ERC-721 items with transferFrom; the token ID is chosen when the order is filled${id === 0n ? ' (any ID is accepted)' : ''}, and on this token it is an amount of ${meta.symbol}.`
        : 'Seaport would call ERC-1155 transfer functions on it; the effect on this token cannot be predicted offline.';
    const text = type === 2 ? `${decimal(id, meta.decimals)} ${meta.symbol} (typed as NFT ${tokenIdText(id)}) · ${sa}`
      : type === 4 ? `${id === 0n ? 'ANY amount' : 'An amount'} of ${meta.symbol} (typed as an ERC-721 criteria item) · ${sa}`
        : `ERC-1155 item on ${meta.symbol}, a fungible token · ${sa}`;
    return { ...base, valid: true, nft: false, disguised: { meta, erc721, effect }, text, short: '?',
      detail: `Type: ${typeName}\nContract: ${token} (${meta.symbol}, a fungible token in the local registry)\nIdentifier or criteria: ${id}\nAmount: ${rawRange}` };
  }
  const qty = start === end ? quantityText(start) : `${quantityText(start)} → ${quantityText(end)}`;
  const one = start === 1n && end === 1n;
  const criteria = type >= 4, any = criteria && id === 0n;
  let text, short;
  if (type === 2) { text = `NFT ${tokenIdText(id)}${one ? '' : ' × ' + qty} · ${shortAddress(token)}`; short = tokenIdText(id); }
  else if (type === 3) { text = `${qty} × ${tokenIdText(id)} · ${shortAddress(token)}`; short = `${qty} × ${tokenIdText(id)}`; }
  else if (any) { text = `ANY ${qty} token${one ? '' : '(s)'} · ${shortAddress(token)}`; short = 'ANY'; }
  else { text = `${qty} token(s) matching criteria ${shortHex(tokenIdHex(id))} · ${shortAddress(token)}`; short = 'criteria set'; }
  const idLines = criteria ? (any ? 'Criteria: 0 (any token ID)' : `Criteria root: ${tokenIdHex(id)}`) : `Token ID: ${id}\nToken ID (hex): ${tokenIdHex(id)}`;
  return { ...base, valid: true, nft: true, criteria, any, id: criteria ? undefined : id, criteriaRoot: criteria ? id : undefined, qty, text, short,
    detail: `Type: ${typeName}\nContract: ${token}\n${idLines}\nAmount: ${qty}` };
}

function seaportOrder(o, ctx, prefix) {
  const fields = [], warnings = [];
  let partial = false;
  const offer = o.offer.map(i => seaportItem(i, ctx)), consideration = o.consideration.map(i => seaportItem(i, ctx));
  const mine = consideration.filter(i => same(i.recipient, o.offerer)), elsewhere = consideration.filter(i => !same(i.recipient, o.offerer));
  const recipientLabel = r => ctx.labels && same(r, OPENSEA_FEE_RECIPIENT) ? 'OpenSea fee recipient' : 'unrecognised recipient';
  fields.push(field(prefix + 'Offerer', o.offerer),
    field(prefix + 'Order type', o.orderType <= 4n ? `${ORDER_TYPES[Number(o.orderType)]} (${o.orderType})` : `Invalid (${o.orderType})`),
    field(prefix + 'Starts (UTC)', utcTime(o.startTime)), field(prefix + 'Expires (UTC)', utcTime(o.endTime)));
  offer.forEach((it, i) => fields.push(field(`${prefix}You give · Item ${i + 1}`, it.detail)));
  consideration.forEach((it, i) => {
    const toMe = same(it.recipient, o.offerer);
    fields.push(field(`${prefix}${toMe ? 'You receive' : 'Also paid'} · Item ${i + 1}`, `${it.detail}\nRecipient: ${it.recipient}${toMe ? ' (the offerer)' : ` (${recipientLabel(it.recipient)})`}`));
  });
  const restricted = o.orderType === 2n || o.orderType === 3n;
  const knownZone = ctx.labels && same(o.zone, OPENSEA_SIGNED_ZONE_V2);
  fields.push(field(prefix + 'Zone', `${o.zone}${knownZone ? ' (OpenSea Signed Zone v2)' : ''}${restricted ? '' : ' (not consulted for open orders)'}`),
    field(prefix + 'Zone hash', o.zoneHash),
    field(prefix + 'Conduit key', o.conduitKey === ZERO_BYTES32 ? `${o.conduitKey} (none: Seaport transfers the items itself)`
      : ctx.labels && o.conduitKey === OPENSEA_CONDUIT_KEY ? `${o.conduitKey} (OpenSea conduit ${OPENSEA_CONDUIT})` : `${o.conduitKey} (unrecognised conduit key)`),
    field(prefix + 'Counter', o.counter), field(prefix + 'Salt', o.salt));

  if (o.orderType === 4n) { warnings.push('HIGH RISK: Order type CONTRACT (4) is not valid for a signed order.'); partial = true; }
  else if (o.orderType > 4n) { warnings.push(`HIGH RISK: Invalid Seaport order type ${o.orderType}.`); partial = true; }
  if ([...offer, ...consideration].some(i => !i.valid)) { warnings.push('HIGH RISK: An item uses an unknown Seaport item type; it is not decoded.'); partial = true; }
  if ([...offer, ...consideration].some(i => i.cur && !i.cur.known)) {
    warnings.push('Unknown token contract: amounts are shown in raw units; token metadata is unavailable offline.'); partial = true;
  }
  if (restricted && !knownZone) { warnings.push(`This restricted order is validated by zone ${o.zone}, whose rules are not decoded.`); partial = true; }
  offer.forEach((it, i) => { if (it.disguised) warnings.push(disguisedText(`You give · Item ${i + 1}`, it.token, it.disguised.meta, it.disguised.erc721, it.disguised.effect)); });
  consideration.forEach((it, i) => {
    if (it.disguised) warnings.push(disguisedText(`${same(it.recipient, o.offerer) ? 'You receive' : 'Also paid'} · Item ${i + 1}`, it.token, it.disguised.meta, it.disguised.erc721, it.disguised.effect));
  });
  if ([...offer, ...consideration].some(i => i.disguised)) partial = true;

  // A listing gives only NFTs; an offer (bid) gives only currency. Disguised or unknown items make it 'mixed'.
  const offerNFT = offer.filter(i => i.nft);
  const kind = !offer.length ? (consideration.length ? 'mixed' : 'empty')
    : offerNFT.length === offer.length ? 'listing' : offer.every(i => i.cur) ? 'offer' : 'mixed';
  // An item counts as received only if its lower bound is positive: a Dutch
  // auction that decays to 0 can be filled for (almost) nothing.
  const received = mine.filter(i => i.valid && minOf(i.start, i.end) > 0n);
  const decaying = mine.filter(i => i.valid && minOf(i.start, i.end) === 0n && maxOf(i.start, i.end) > 0n);
  const receivedNFT = received.filter(i => i.nft);
  // Counts NFTs received as well as payment, so an offer (bid) that receives the NFT is never flagged.
  const nothing = offer.length > 0 && received.length === 0;
  if (nothing && decaying.length) {
    const atEnd = decaying.some(i => i.end === 0n);
    warnings.push(`HIGH RISK: What you receive ${atEnd ? 'falls to 0 by the end time' : 'is 0 at the start time'}, so this order can be filled for almost nothing.`);
  } else if (nothing) warnings.push('HIGH RISK: You receive nothing for the items you give.');

  const receiveTotals = new Map(), paidTotals = new Map(), giveTotals = new Map();
  for (const it of consideration) if (it.cur) { addTotal(paidTotals, it.cur, it.start, it.end); if (same(it.recipient, o.offerer)) addTotal(receiveTotals, it.cur, it.start, it.end); }
  for (const it of offer) if (it.cur) addTotal(giveTotals, it.cur, it.start, it.end);
  if (kind === 'listing' && !nothing) {
    // Share rule applies to listings only: in a bid the fees are paid from the bidder's own offer.
    for (const [key, all] of paidTotals) {
      const got = receiveTotals.get(key) ?? { start: 0n, end: 0n };
      if (got.start === 0n && got.end === 0n && receivedNFT.length) continue;
      if (got.start * 2n < all.start || got.end * 2n < all.end)
        warnings.push(`HIGH RISK: Most of the ${all.cur.symbol} payment goes to other addresses: you receive ${rangeText(all.cur.text, got.start, got.end)} of ${rangeText(all.cur.text, all.start, all.end)}.`);
    }
    // Dust price: every received currency is known and its lower bound is under the policy limit.
    const totals = [...receiveTotals.values()];
    if (!receivedNFT.length && totals.length && totals.every(t => { const limit = dustLimit(t.cur); return limit !== undefined && minOf(t.start, t.end) < limit; }))
      warnings.push(dustWarning(totals.map(t => t.cur.text(minOf(t.start, t.end)))));
  }
  for (const it of offerNFT) if (it.criteria) {
    if (it.any) warnings.push(`HIGH RISK: The buyer may choose ANY ${it.qty} token(s) of yours from ${it.token}.`);
    else { warnings.push(`HIGH RISK: The buyer may choose ${it.qty} token(s) of yours from ${it.token} matching criteria root ${tokenIdHex(it.criteriaRoot)}; which tokens that root covers cannot be shown offline.`); partial = true; }
  }
  for (const it of consideration) if (it.nft && it.criteria && !it.any) partial = true;
  if (kind === 'listing' && offerNFT.length > 1) {
    const contracts = unique(offerNFT.map(i => i.token.toLowerCase())).length;
    warnings.push(`This listing sells ${offerNFT.length} NFT items${contracts > 1 ? ` from ${contracts} contracts` : ''} together in one order.`);
  }
  if (ctx.signer && !same(ctx.signer, o.offerer))
    warnings.push(`HIGH RISK: The order offerer ${o.offerer} differs from the requested signer ${ctx.signer}. This signature only matters if the offerer is a contract wallet that accepts it.`);
  warnings.push(...expiryWarnings(o.startTime, o.endTime));

  const give = offer.map(i => i.text), receive = nothing && !decaying.length ? ['Nothing'] : mine.map(i => i.text);
  const others = elsewhere.map(i => `${i.text} → ${shortAddress(i.recipient)} (${recipientLabel(i.recipient)})`);
  let headline, money;
  if (kind === 'listing') {
    headline = nftSummary(offerNFT);
    const paid = totalAmount(paidTotals, 'min');
    money = totalAmount(receiveTotals, 'min')
      ?? (nothing ? { amount: '0', symbol: paid?.symbol ?? ctx.network?.symbol ?? 'native units', key: paid ? paid.key : 'native', known: paid ? paid.known : !!ctx.network } : undefined);
  } else if (kind === 'offer') {
    const nfts = mine.filter(i => i.nft);
    headline = nfts.length ? 'For ' + nftSummary(nfts) : 'For nothing';
    money = totalAmount(giveTotals, 'max');
  } else headline = kind === 'empty' ? 'Empty order (nothing offered or requested)' : `Give ${plural(offer.length, 'item')} · receive ${plural(mine.length, 'item')}`;
  const nftItems = kind === 'offer' ? mine.filter(i => i.nft) : offerNFT.length ? offerNFT : consideration.filter(i => i.nft);
  return { kind, headline, money, give, receive, others, fields, warnings, partial, nftItems };
}

function reviewSeaport({ primaryType, types, domain, domainFields, message, network, signer }) {
  const itemsOk = sameFields(types.OfferItem, OFFER_ITEM) && sameFields(types.ConsiderationItem, CONSIDERATION_ITEM) && sameFields(types.OrderComponents, ORDER_COMPONENTS);
  if (!itemsOk) return undefined;
  let height = 0;
  if (primaryType === 'BulkOrder') {
    height = treeHeight(types.BulkOrder, 'OrderComponents', 24);
    if (!height || !onlyTypes(types, ['BulkOrder', 'OrderComponents', 'OfferItem', 'ConsiderationItem'])) return undefined;
  } else if (primaryType !== 'OrderComponents' || !onlyTypes(types, ['OrderComponents', 'OfferItem', 'ConsiderationItem'])) return undefined;

  const version = Object.keys(SEAPORT).find(v => exactDomain(domain, domainFields, 'Seaport', v, SEAPORT_CHAINS, SEAPORT[v]));
  const recognised = !!version && !!network;
  const ctx = { network, signer, labels: recognised && OPENSEA_CHAINS.includes(network.chainId) };
  const protocol = recognised ? `Seaport ${version}` : 'unrecognised contract';
  const contract = domain.verifyingContract;
  const fields = [field('Marketplace', recognised ? `${contract} (Seaport ${version})` : `${contract ?? 'None bound'} (unrecognised Seaport-format contract)`)];
  const warnings = [];
  if (!recognised) warnings.push(`HIGH RISK: Seaport-format order for an unrecognised contract (${contract ?? 'no verifying contract'}). It may transfer your assets on terms other than those shown.`);

  const bulk = primaryType === 'BulkOrder';
  const leaves = bulk ? treeLeaves(message.tree, height) : [message];
  // seaport-js pads bulk trees with all-zero orders (no offer, no consideration).
  const real = bulk ? leaves.filter(o => o.offer.length || o.consideration.length) : leaves;
  if (bulk) {
    fields.push(field('Bulk order', `${plural(real.length, 'order')} in a tree of ${leaves.length} entries (height ${height}); ${plural(leaves.length - real.length, 'empty padding entr')}`.replace(/entrs?$/, m => m === 'entr' ? 'entry' : 'entries')));
    if (real.length > MAX_ITEMISED) warnings.push(`HIGH RISK: This bulk order contains ${real.length} orders; only the first ${MAX_ITEMISED} are itemised here. The rest appear only in the signed values.`);
  }
  const orders = real.map((o, i) => seaportOrder(o, ctx, bulk && real.length > 1 ? `Order ${i + 1} · ` : ''));
  const give = [], receive = [], others = [];
  let partial = !recognised;
  const many = bulk && orders.length > 1;
  orders.forEach((o, i) => {
    const label = `Order ${i + 1}`;
    if (i < MAX_ITEMISED) fields.push(...o.fields);
    const tag = s => many ? `${label}: ${s}` : s;
    give.push(...o.give.map(tag)); receive.push(...o.receive.map(tag)); others.push(...o.others.map(tag));
    partial ||= o.partial;
  });
  warnings.push(...orderWarnings(orders.map(o => o.warnings), many));

  const nftItems = orders.flatMap(o => o.nftItems);
  const assetContract = commonContract(nftItems);
  let action, headline, money, summary;
  const prefix = recognised ? 'Seaport' : 'Seaport-format';
  if (!bulk) {
    const [o] = orders;
    ({ headline, money } = o);
    action = o.kind === 'listing' ? `List NFT for Sale (${protocol})` : o.kind === 'offer' ? `Make NFT Offer (${protocol})` : `Sign Seaport Order (${protocol})`;
    summary = o.kind === 'listing' ? `${prefix} listing: ${headline}${money ? ` for ${money.amount} ${money.symbol}` : ''}`
      : o.kind === 'offer' ? `${prefix} offer: ${money ? `${money.amount} ${money.symbol} ` : ''}${headline.replace(/^For /, 'for ')}` : `${prefix} order`;
  } else {
    const listings = orders.length > 0 && orders.every(o => o.kind === 'listing');
    action = listings ? `Bulk List (${plural(orders.length, 'order')})` : `Bulk Seaport Orders (${plural(orders.length, 'order')})`;
    const brief = o => o.kind === 'listing' ? `${o.headline}${o.money ? ` for ${o.money.amount} ${o.money.symbol}` : ''}` : o.headline;
    headline = orders.length ? orders.slice(0, 2).map(brief).join('; ') + (orders.length > 2 ? ` (+${orders.length - 2} more)` : '') : 'No orders (only padding)';
    money = sumMoney(listings, orders);
    summary = `${prefix} bulk ${listings ? 'listing' : 'orders'}: ${plural(orders.length, 'order')}${money ? ` for ${money.amount} ${money.symbol}` : ''}`;
  }
  return {
    title: 'Sign NFT marketplace order', summary, fields, warnings: unique(warnings), decodeStatus: partial ? 'partiallyDecoded' : 'fullyDecoded',
    display: display(action, { amount: money?.amount, symbol: money?.amount !== undefined ? money.symbol : undefined, headline,
      counterpartyLabel: recognised ? 'Marketplace' : 'Contract', counterparty: contract, assetKind: 'nftOrder',
      assetContract, assetContractLabel: assetContract ? 'NFT contract (not verified)' : undefined, tokenId: bulk ? undefined : singleTokenId(nftItems),
      give: capLines(give), receive: capLines(receive), others: capLines(others) }),
  };
}
/**
 * Bulk listing total: only when every order is paid in the same known currency
 * (native coin or one registry token, by address). Raw units are never summed.
 */
function sumMoney(listings, orders) {
  if (!listings || !orders.length || !orders.every(o => o.money?.known && o.money.key)) return undefined;
  if (unique(orders.map(o => o.money.key)).length !== 1) return undefined;
  const sums = orders.map(o => o.money.amount);
  return sums.every(s => /^[0-9]+(\.[0-9]+)?$/.test(s)) ? { amount: addDecimals(sums), symbol: orders[0].money.symbol } : undefined;
}
/** Exact sum of non-negative decimal strings. */
function addDecimals(values) {
  const scale = Math.max(0, ...values.map(v => (v.split('.')[1] ?? '').length));
  const total = values.reduce((n, v) => { const [w, f = ''] = v.split('.'); return n + BigInt(w + f.padEnd(scale, '0')); }, 0n);
  return decimal(total, scale);
}

// ---------------------------------------------------------------------------
// Blur (Ethereum only). v1 Root and V2 Order both sign a blind Merkle root:
// the listed token IDs and prices are not in the request. Prices are never shown.
// v1: code-423n4/2022-10-blur lib/EIP712.sol = deployed implementation 0x983e96c2…;
// V2: deployed implementation 0x5fa60726… contracts/exchangeV2/Signatures.sol.

const BLUR_V1 = '0x000000000000Ad05Ccc4F10045630fb830B95127';
const BLUR_V2 = '0xb2ecfE4E4D61f8790bbb9DE2D1259B9e2410CEA5';
const BLUR_ROOT = [['root', 'bytes32']];
const BLUR_V2_ORDER = [['trader', 'address'], ['collection', 'address'], ['listingsRoot', 'bytes32'], ['numberOfListings', 'uint256'], ['expirationTime', 'uint256'],
  ['assetType', 'uint8'], ['makerFee', 'FeeRate'], ['salt', 'uint256'], ['orderType', 'uint8'], ['nonce', 'uint256']];
const BLUR_FEE_RATE = [['recipient', 'address'], ['rate', 'uint16']];

const BLUR_HIGH_FEE_BPS = 5000n; // engine policy: a maker fee over half of each fill is flagged red

function reviewBlur({ primaryType, types, domain, domainFields, message: m, network, signer }) {
  const v1 = primaryType === 'Root' && onlyTypes(types, ['Root']) && sameFields(types.Root, BLUR_ROOT)
    && exactDomain(domain, domainFields, 'Blur Exchange', '1.0', ['1'], BLUR_V1);
  const v2 = primaryType === 'Order' && onlyTypes(types, ['Order', 'FeeRate']) && sameFields(types.Order, BLUR_V2_ORDER) && sameFields(types.FeeRate, BLUR_FEE_RATE)
    && exactDomain(domain, domainFields, 'Blur Exchange', '1.0', ['1'], BLUR_V2);
  if (!v1 && !v2) return undefined;
  const common = { title: 'Sign NFT marketplace order', decodeStatus: 'opaque' };
  if (v1) return { ...common, summary: 'Blur blind bulk listing (Merkle root)',
    fields: [field('Marketplace', `${BLUR_V1} (Blur Exchange v1, Ethereum)`), field('Merkle root', m.root)],
    warnings: ['HIGH RISK: This signs only a Merkle root of Blur orders. Which NFTs are listed, and at what prices, is not in this request and cannot be shown. Anyone holding the matching order list can fill every order it covers.'],
    display: display('Blur Bulk Listing (blind)', { headline: `Merkle root ${shortHex(m.root)}`, counterpartyLabel: 'Marketplace', counterparty: BLUR_V1, assetKind: 'nftOrder' }) };
  const side = m.orderType === 0n ? 'Ask (sell)' : m.orderType === 1n ? 'Bid (buy)' : `Invalid (${m.orderType})`;
  const warnings = ['HIGH RISK: This signs only a Merkle root of Blur listings. Which token IDs are included, and at what prices, is not in this request and cannot be shown. Anyone holding the matching listing data can fill every listing it covers.'];
  if (m.orderType > 1n) warnings.push(`HIGH RISK: Invalid Blur order type ${m.orderType}.`);
  if (m.assetType > 1n) warnings.push(`HIGH RISK: Invalid Blur asset type ${m.assetType}.`);
  if (signer && !same(signer, m.trader)) warnings.push(`HIGH RISK: The order trader ${m.trader} differs from the requested signer ${signer}.`);
  // Blur V2 Validation.sol only bounds makerFee + takerFee + protocolFee by 10,000 bps.
  if (m.makerFee.rate > BLUR_HIGH_FEE_BPS)
    warnings.push(`HIGH RISK: The maker fee is ${decimal(m.makerFee.rate, 2)}% (${m.makerFee.rate} bps) of each fill, paid to ${m.makerFee.recipient}.`);
  const meta = fungibleToken(m.collection, { network });
  if (meta) warnings.push(disguisedText('The collection', m.collection, meta, m.assetType !== 1n, 'Token IDs in the signed listings may move amounts of this token instead of NFTs.'));
  warnings.push(...expiryWarnings(undefined, m.expirationTime));
  const fields = [field('Marketplace', `${BLUR_V2} (Blur Exchange V2, Ethereum)`), field('Trader', m.trader), field('Collection', m.collection),
    field('Order side', side), field('Asset type', m.assetType === 0n ? 'ERC721 (0)' : m.assetType === 1n ? 'ERC1155 (1)' : `Invalid (${m.assetType})`),
    field('Number of listings (as signed)', m.numberOfListings), field('Listings root', m.listingsRoot), field('Expires (UTC)', utcTime(m.expirationTime)),
    field('Maker fee', `${decimal(m.makerFee.rate, 2)}% (${m.makerFee.rate} bps) → ${m.makerFee.recipient}`), field('Salt', m.salt), field('Nonce', m.nonce)];
  const action = m.orderType === 0n ? 'Blur Listing (blind)' : m.orderType === 1n ? 'Blur Bid (blind)' : 'Blur Order (blind)';
  return { ...common, summary: `Blur blind ${m.orderType === 1n ? 'bid' : 'listing'} root for ${shortAddress(m.collection)}`, fields, warnings,
    display: display(action, { headline: `Listings root ${shortHex(m.listingsRoot)} · ${shortAddress(m.collection)}`, counterpartyLabel: 'Marketplace', counterparty: BLUR_V2,
      assetKind: 'nftOrder', assetContract: meta ? undefined : m.collection, assetContractLabel: meta ? undefined : 'NFT contract (not verified)' }) };
}

// ---------------------------------------------------------------------------
// LooksRare v2 (Ethereum). contracts-exchange-v2 libraries/OrderStructs.sol
// _MAKER_TYPEHASH and BatchOrderTypehashRegistry.sol (height 1..10).

const LOOKSRARE = '0x0000000000E655fAe4d56241588680F86E3b2377';
const MAKER = [['quoteType', 'uint8'], ['globalNonce', 'uint256'], ['subsetNonce', 'uint256'], ['orderNonce', 'uint256'], ['strategyId', 'uint256'],
  ['collectionType', 'uint8'], ['collection', 'address'], ['currency', 'address'], ['signer', 'address'], ['startTime', 'uint256'], ['endTime', 'uint256'],
  ['price', 'uint256'], ['itemIds', 'uint256[]'], ['amounts', 'uint256[]'], ['additionalParameters', 'bytes']];

function looksRareMaker(o, ctx, prefix) {
  const fields = [], warnings = [];
  let partial = false;
  const ask = o.quoteType === 1n, bid = o.quoteType === 0n;
  const erc721 = o.collectionType === 0n, erc1155 = o.collectionType === 1n;
  const cur = currency(o.currency === ZERO_ADDRESS, o.currency, ctx);
  const price = cur.text(o.price);
  const strategy = o.strategyId === 0n ? 'Standard (0)' : o.strategyId === 1n && bid ? 'Collection offer (1)' : `Non-standard (${o.strategyId})`;
  const collectionOffer = bid && o.strategyId === 1n;
  const sa = shortAddress(o.collection);
  // A registry token is fungible: its "token IDs" are amounts, so nothing here is shown as an NFT.
  const fungible = fungibleToken(o.collection, ctx);
  let items = [];
  if (o.itemIds.length === o.amounts.length) items = o.itemIds.map((id, i) => {
    const amount = o.amounts[i];
    const text = fungible ? (erc721 ? `${decimal(id, fungible.decimals)} ${fungible.symbol} (typed as NFT ${tokenIdText(id)}) · ${sa}` : `ERC-1155 item ${tokenIdText(id)} on ${fungible.symbol}, a fungible token · ${sa}`)
      : erc1155 ? `${quantityText(amount)} × ${tokenIdText(id)} · ${sa}` : `NFT ${tokenIdText(id)}${amount === 1n ? '' : ' × ' + quantityText(amount)} · ${sa}`;
    return { token: o.collection, id, text, short: erc1155 ? `${quantityText(amount)} × ${tokenIdText(id)}` : tokenIdText(id) };
  });
  fields.push(field(prefix + 'Signer', o.signer), field(prefix + 'Side', ask ? 'Ask (sell)' : bid ? 'Bid (buy)' : `Invalid (${o.quoteType})`),
    field(prefix + 'Strategy', strategy),
    field(prefix + 'Collection type', erc721 ? 'ERC721 (0)' : erc1155 ? 'ERC1155 (1)' : `Invalid (${o.collectionType})`), field(prefix + 'Collection', o.collection),
    field(prefix + 'Currency', o.currency === ZERO_ADDRESS ? 'Native ETH' : `${o.currency}${cur.known ? ` (${cur.symbol})` : ' (not in the local registry)'}`),
    field(prefix + 'Price', `${price}${cur.known ? ` (raw ${o.price})` : ''}`),
    field(prefix + 'Price note', ask ? 'This is the price before LooksRare protocol and creator fees; you receive less than this amount.'
      : 'This is the most you pay; protocol and creator fees are taken from the seller\'s proceeds.'),
    field(prefix + 'Items', collectionOffer ? `Any token ID; quantity ${o.amounts.map(quantityText).join(', ') || 'none'}`
      : o.itemIds.map((id, i) => `#${id} × ${o.amounts[i] ?? '?'}`).join('\n') || 'None'),
    field(prefix + 'Starts (UTC)', utcTime(o.startTime)), field(prefix + 'Expires (UTC)', utcTime(o.endTime)),
    field(prefix + 'Nonces (global / subset / order)', `${o.globalNonce} / ${o.subsetNonce} / ${o.orderNonce}`));
  if (o.additionalParameters !== '0x') fields.push(field(prefix + 'Additional parameters', o.additionalParameters));

  if (!ask && !bid) { warnings.push(`HIGH RISK: Invalid LooksRare quote type ${o.quoteType}.`); partial = true; }
  if (!erc721 && !erc1155) { warnings.push(`HIGH RISK: Invalid LooksRare collection type ${o.collectionType}.`); partial = true; }
  if (o.strategyId !== 0n && !collectionOffer) { warnings.push(`Non-standard strategy ${o.strategyId}; its additionalParameters are not decoded.`); partial = true; }
  if (!collectionOffer && (o.itemIds.length !== o.amounts.length || !o.itemIds.length)) { warnings.push('The item IDs and amounts do not match, so this order cannot be filled as shown.'); partial = true; }
  if (collectionOffer && o.amounts.length !== 1) { warnings.push('A collection offer must have exactly one amount; this order cannot be filled.'); partial = true; }
  if (!cur.known) { warnings.push('Unknown token contract: amounts are shown in raw units; token metadata is unavailable offline.'); partial = true; }
  if (fungible) {
    warnings.push(disguisedText('The collection', o.collection, fungible, !erc1155, erc1155 ? 'The effect of ERC-1155 transfers on this token cannot be predicted offline.'
      : 'LooksRare moves ERC-721 items with transferFrom, so each "token ID" in this order is an amount of this token.'));
    partial = true;
  }
  if (ask && o.price === 0n) warnings.push('HIGH RISK: You receive nothing for the items you give.');
  else if (ask && dustLimit(cur) !== undefined && o.price < dustLimit(cur)) warnings.push(dustWarning([`${price} (before fees)`]));
  if (bid && o.currency === ZERO_ADDRESS) warnings.push('LooksRare rejects bids in native ETH, so this bid cannot be filled.');
  if (ask && items.length > 1) warnings.push(`This listing sells ${items.length} NFT items together in one order.`);
  if (ctx.signer && !same(ctx.signer, o.signer)) warnings.push(`HIGH RISK: The order signer ${o.signer} differs from the requested signer ${ctx.signer}.`);
  warnings.push(...expiryWarnings(o.startTime, o.endTime));

  const anyQty = o.amounts.map(quantityText).join(', ') || '?';
  const itemLines = collectionOffer ? [`ANY ${anyQty} token${anyQty === '1' ? '' : 's'} · ${sa}`] : items.map(i => i.text);
  const nftItems = collectionOffer || fungible ? [] : items;
  const headline = ask ? nftSummary(items) ?? `No items · ${sa}` : collectionOffer ? `For ANY NFT in ${sa}` : 'For ' + (nftSummary(items) ?? `no items · ${sa}`);
  const money = { amount: cur.value(o.price), symbol: cur.symbol, key: cur.key, known: cur.known };
  return { kind: fungible ? 'invalid' : ask ? 'listing' : bid ? 'offer' : 'invalid', headline, money, fields, warnings, partial, nftItems, collection: fungible ? undefined : o.collection,
    give: ask ? itemLines : [price], receive: ask ? [o.price === 0n ? 'Nothing' : `${price} (before fees)`] : itemLines, others: [] };
}

function reviewLooksRare({ primaryType, types, domain, domainFields, message, network, signer }) {
  if (!sameFields(types.Maker, MAKER) || !exactDomain(domain, domainFields, 'LooksRareProtocol', '2', ['1'], LOOKSRARE)) return undefined;
  let height = 0;
  if (primaryType === 'BatchOrder') {
    height = treeHeight(types.BatchOrder, 'Maker', 10);
    if (!height || !onlyTypes(types, ['BatchOrder', 'Maker'])) return undefined;
  } else if (primaryType !== 'Maker' || !onlyTypes(types, ['Maker'])) return undefined;
  const ctx = { network, signer };
  const bulk = height > 0;
  const leaves = bulk ? treeLeaves(message.tree, height) : [message];
  // The LooksRare SDK pads trees with an all-zero Maker (signer 0x0), which can never be filled.
  const real = bulk ? leaves.filter(o => !(o.signer === ZERO_ADDRESS && o.collection === ZERO_ADDRESS && o.price === 0n)) : leaves;
  const fields = [field('Marketplace', `${LOOKSRARE} (LooksRare v2, Ethereum)`)], warnings = [];
  if (bulk) {
    fields.push(field('Batch order', `${plural(real.length, 'order')} in a tree of ${leaves.length} entries (height ${height}); ${plural(leaves.length - real.length, 'empty padding entr')}`.replace(/entrs?$/, m => m === 'entr' ? 'entry' : 'entries')));
    if (real.length > MAX_ITEMISED) warnings.push(`HIGH RISK: This batch contains ${real.length} orders; only the first ${MAX_ITEMISED} are itemised here. The rest appear only in the signed values.`);
  }
  const many = bulk && real.length > 1;
  const orders = real.map((o, i) => looksRareMaker(o, ctx, many ? `Order ${i + 1} · ` : ''));
  const give = [], receive = [];
  let partial = false;
  orders.forEach((o, i) => {
    const label = `Order ${i + 1}`;
    if (i < MAX_ITEMISED) fields.push(...o.fields);
    const tag = s => many ? `${label}: ${s}` : s;
    give.push(...o.give.map(tag)); receive.push(...o.receive.map(tag));
    partial ||= o.partial;
  });
  warnings.push(...orderWarnings(orders.map(o => o.warnings), many));
  const nftItems = orders.flatMap(o => o.nftItems);
  const collections = unique(orders.map(o => o.collection));
  const assetContract = collections.length === 1 ? collections[0] : undefined;
  let action, headline, money, summary;
  if (!bulk || orders.length === 1) {
    const [o] = orders;
    if (!o) return undefined;
    ({ headline, money } = o);
    action = o.kind === 'listing' ? 'List NFT for Sale (LooksRare)' : o.kind === 'offer' ? 'Make NFT Offer (LooksRare)' : 'Sign LooksRare Order';
    summary = o.kind === 'listing' ? `LooksRare listing: ${headline} for ${money.amount} ${money.symbol}` : o.kind === 'offer' ? `LooksRare offer: ${money.amount} ${money.symbol} ${headline.replace(/^For /, 'for ')}` : 'LooksRare order';
    if (bulk) action = orders[0].kind === 'listing' ? 'Bulk List (1 order, LooksRare)' : 'LooksRare Batch (1 order)';
  } else {
    const listings = orders.length > 0 && orders.every(o => o.kind === 'listing');
    action = listings ? `Bulk List (${plural(orders.length, 'order')}, LooksRare)` : `LooksRare Batch (${plural(orders.length, 'order')})`;
    headline = orders.length ? orders.slice(0, 2).map(o => o.kind === 'listing' ? `${o.headline} for ${o.money.amount} ${o.money.symbol}` : o.headline).join('; ') + (orders.length > 2 ? ` (+${orders.length - 2} more)` : '') : 'No orders (only padding)';
    money = sumMoney(listings, orders);
    summary = `LooksRare batch: ${plural(orders.length, 'order')}${money ? ` for ${money.amount} ${money.symbol}` : ''}`;
  }
  return {
    title: 'Sign NFT marketplace order', summary, fields, warnings: unique(warnings), decodeStatus: partial ? 'partiallyDecoded' : 'fullyDecoded',
    display: display(action, { amount: money?.amount, symbol: money?.symbol, headline, counterpartyLabel: 'Marketplace', counterparty: LOOKSRARE,
      assetKind: 'nftOrder', assetContract, assetContractLabel: assetContract ? 'NFT contract (not verified)' : undefined,
      tokenId: orders.length === 1 ? singleTokenId(nftItems) : undefined, give: capLines(give), receive: capLines(receive) }),
  };
}

// ---------------------------------------------------------------------------

/**
 * Reviews a recognised NFT marketplace order, or returns undefined so the
 * caller uses its generic typed-data review. `message` holds normalised values
 * (checksummed addresses, bigint integers, lowercase hex).
 */
export function reviewNftOrder(input) {
  return reviewSeaport(input) ?? reviewBlur(input) ?? reviewLooksRare(input);
}

// Marketplace SDK payloads may carry keys outside the signed struct (e.g. seaport-js
// OrderParameters' totalOriginalConsiderationItems). Only these primary types on
// these verifying contracts have such keys stripped with a warning; every other
// typed-data request still refuses undeclared keys.
const LENIENT_REQUESTS = [[SEAPORT['1.6'], ['OrderComponents', 'BulkOrder']], [SEAPORT['1.5'], ['OrderComponents', 'BulkOrder']],
  [LOOKSRARE, ['Maker', 'BatchOrder']], [BLUR_V1, ['Root']], [BLUR_V2, ['Order']]];
/** True when undeclared message keys may be stripped (recognised marketplace request shapes only). */
export function marketplaceRequest(primaryType, domain) {
  return LENIENT_REQUESTS.some(([contract, primaryTypes]) => same(domain?.verifyingContract, contract) && primaryTypes.includes(primaryType));
}

/** Safety net for unrecognised typed data that signs an opaque hash or Merkle root. */
export function opaqueRootWarning(primaryType, types) {
  const defs = types[primaryType] ?? [];
  const single = defs.length === 1 && defs[0].type === 'bytes32';
  const rootField = defs.some(f => f.type === 'bytes32' && /root|merkle/i.test(f.name));
  if (single || rootField || /root|tree|merkle/i.test(primaryType))
    return 'HIGH RISK: This signs an opaque hash or Merkle root; what it commits to cannot be shown. It may authorize orders or transfers that are not visible here.';
  return undefined;
}
