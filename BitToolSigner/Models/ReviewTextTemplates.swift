import Foundation

/// The engine text that carries a value, as English with `%@` where the value
/// goes. Each is both a translation key and the pattern the engine's output is
/// matched against. A more specific template must come before one that could also
/// match it; `ReviewWarningTests` checks that no two claim the same sentence.
///
/// Numbered parts ("Call 3", "Order 2", "Instruction 4") are not listed here:
/// `ReviewText` splits them off and translates them on their own.
enum TemplateTable {
    static let all: [String] = [
        // Refusals that carry a value. A refusal is the only thing on screen
        // when it happens, so these matter as much as the warnings do.
        "This message is %@ bytes. BitTool Signer signs messages of up to 1024 bytes, which is far more than a sign-in or ownership message needs; anything larger is refused because it is usually transaction data in disguise.",
        "Authorization %@ is for chain %@, but this transaction is for chain %@.",
        "Authorization %@ cannot take effect: it is signed for nonce %@, but this wallet\u{2019}s nonce will be %@ when it is applied.",
        "Typed %@ must be exactly %@ bytes.",
        "Typed value is outside the %@ range.",

        // Fees.
        "HIGH FEE: This transaction allows up to %@ in network fees. Check the gas settings in your other wallet.",
        "HIGH FEE: This transaction allows up to %@ SOL in priority fees. Check the fee settings in your other wallet.",
        "HIGH FEE: This transaction allows up to %@ TRX in energy fees. Check the fee limit in your other wallet.",
        "HIGH FEE: Every output returns to this wallet, so the fee of %@ BTC is the whole cost of this transaction. Verify it carefully.",
        "This device does not recognise EVM chain %@, so it cannot name the network or its native currency, and no token or contract on it is registered here — every address below reads as unregistered. Amounts are shown to 18 decimals, the usual EVM convention. Check the network in the wallet that built this request.",
        "This device has no reference for a normal network fee on %@, so it cannot tell you whether this one is unusual. The maximum is shown above.",

        // Solana lookup tables, accounts and delegates.
        "HIGH RISK: %@ of this transaction\u{2019}s %@ accounts come from %@ address lookup table. Those addresses are stored on-chain and BitTool Signer is offline, so it cannot show you what they are. Anything marked \u{201C}lookup table\u{201D} below could be any account at all — including a recipient you did not intend. Only continue if you trust the wallet that built this transaction and you have checked it there.",
        "HIGH RISK: %@ of this transaction\u{2019}s %@ accounts come from %@ address lookup tables. Those addresses are stored on-chain and BitTool Signer is offline, so it cannot show you what they are. Anything marked \u{201C}lookup table\u{201D} below could be any account at all — including a recipient you did not intend. Only continue if you trust the wallet that built this transaction and you have checked it there.",
        "%@ of this instruction\u{2019}s %@ accounts come from an address lookup table and cannot be shown.",
        "HIGH RISK: This transfer supplies accounts for transfer-hook program %@. The mint\u{2019}s actual transfer hook is on-chain state and cannot be verified offline; whichever hook the mint configures will run with the accounts listed.",
        "HIGH RISK: This permanently destroys %@ %@. Burning cannot be undone.",
        "HIGH RISK: Output %@ permanently destroys %@ BTC. It pays to an unspendable OP_RETURN data output, and no one can ever spend it.",
        "HIGH RISK: This funds a new account controlled by program %@. That program, not you, will control the %@ SOL.",
        "HIGH RISK: The delegate %@ can transfer this NFT without asking you again.",
        "HIGH RISK: The delegate %@ can lock this NFT and transfer it to any address without asking you again (the locked address in the arguments is not enforced by Token Metadata).",
        "HIGH RISK: The delegate %@ can transfer, burn and lock up to the delegated amount of this token without asking you again.",
        "HIGH RISK: The delegate %@ can burn and lock this NFT without asking you again.",
        "HIGH RISK: The delegate %@ can lock this NFT so it cannot be transferred until the delegate unlocks it.",
        "HIGH RISK: The delegate %@ gains %@ authority over this asset\u{2019}s metadata, collection or configuration.",
        "HIGH RISK: The new delegate %@ can transfer or burn this compressed NFT without asking you again, until the delegate is changed or the NFT is transferred.",
        "HIGH RISK: The new delegate %@ can transfer, burn or freeze this compressed NFT without asking you again, until the delegate is changed or the NFT is transferred. While it is frozen, you cannot transfer it or change the delegate.",
        "HIGH RISK: The signing authority %@ is not the NFT owner %@. You are transferring it as its delegate or as the collection\u{2019}s permanent transfer delegate.",
        "HIGH RISK: The transfer authority %@ is not the token owner %@. This transfer is authorised as a delegate of that wallet (for example a sale, transfer, locked-transfer, standard or migration delegate), not by the owner.",
        "HIGH RISK: You are transferring an NFT owned by %@ as its delegate.",
        "HIGH RISK: This %@ NFT marketplace instruction (list, delist, buy, sell, bid or pool deposit) is not decoded. It may move your NFT into marketplace escrow, give the marketplace a sale delegate, or spend SOL. Only sign if you started exactly this action on %@.",

        // EIP-7702.
        "HIGH RISK: %@ carries a signature this device cannot read, so it cannot say whose account is being changed.",
        "HIGH RISK: %@ hands this wallet\u{2019}s own account (%@) to the contract at %@. From then on that contract\u{2019}s code runs as your account and can move everything in it, on every later transaction, until the delegation is replaced. BitTool Signer is offline and cannot read that contract. Only continue if you set this up and trust that contract completely.",
        "HIGH RISK: %@ hands the account %@ to the contract at %@. That contract\u{2019}s code then runs as that account and can move everything in it.",
        "HIGH RISK: %@ is signed for chain 0, so it applies on every EVM chain, not only %@.",
        "%@ removes the code delegation on %@. That restores a plain account and takes no new permission.",
        "%@ asks to remove the code delegation on %@. It takes effect only if that account\u{2019}s nonce is %@ when this transaction runs, which BitTool Signer cannot check offline.",

        // EVM calls, Safe and batches.
        "HIGH RISK: %@ will be able to transfer every token held by this account in contract %@ (ERC-721 or ERC-1155), including ones received later, until the approval is revoked.",
        "If this is an ERC-721 contract, this clears the approval for token %@. Many ERC-20 implementations reject a zero spender.",
        "This call also sends %@ to the contract.",
        "HIGH RISK: Call %@ uses DELEGATECALL.",
        "Call %@ encodes a value of %@ wei on a DELEGATECALL. MultiSend does not transfer it; it is not part of the amount shown.",
        "This Safe transaction encodes a value of %@ wei on a DELEGATECALL. The Safe does not transfer it; it is not part of the amount shown.",
        "HIGH RISK: This Safe transaction pays a gas refund of up to (gas used + %@) × %@ %@ to %@. Only approve refunds you expect.",
        "This pays %@ to the batch contract.",
        "This pays %@ to the batch contract, of which %@ is forwarded by the calls below.",
        "HIGH RISK: %@ is sent to the batch contract but not forwarded by any call in it. A batch contract has no refund path, so that amount stays there and anyone able to call the contract may be able to take it.",
        "HIGH RISK: The amount shown is incomplete. %@ DELEGATECALL branch runs with the Safe's own balance and its body is not fully decoded, so what it spends cannot be counted.",
        "HIGH RISK: The amount shown is incomplete. %@ DELEGATECALL branches run with the Safe's own balance and their bodies are not fully decoded, so what they spend cannot be counted.",
        "Token %@ appears %@ times in this batch; its total quantity is %@.",
        "Item %@ has quantity 0.",
        "Items %@ have quantity 0.",
        "The request included %@ field(s) that are not part of the signed data. They were ignored and are not shown as signed values.",

        // NFT marketplace orders.
        "HIGH RISK: %@ more order-specific warning is not listed here. Review every order in the signed values.",
        "HIGH RISK: %@ more order-specific warnings are not listed here. Review every order in the signed values.",
        "HIGH RISK: This bulk order contains %@ orders; only the first %@ are itemised here. The rest appear only in the signed values.",
        "HIGH RISK: Most of the %@ payment goes to other addresses: you receive %@ of %@.",
        "HIGH RISK: Seaport-format order for an unrecognised contract (%@). It may transfer your assets on terms other than those shown.",
        "HIGH RISK: The buyer may choose ANY %@ token(s) of yours from %@.",
        "HIGH RISK: The buyer may choose %@ token(s) of yours from %@ matching criteria root %@; which tokens that root covers cannot be shown offline.",
        "HIGH RISK: %@ is typed ERC-721, but %@ is %@, a fungible token in the local registry, not an NFT contract. %@",
        "HIGH RISK: %@ is typed ERC-1155, but %@ is %@, a fungible token in the local registry, not an NFT contract. %@",
        "Seaport moves ERC-721 items with transferFrom, which on this token moves %@ (the \"token ID\" is the amount).",
        "Seaport moves ERC-721 items with transferFrom; the token ID is chosen when the order is filled (any ID is accepted), and on this token it is an amount of %@.",
        "Seaport moves ERC-721 items with transferFrom; the token ID is chosen when the order is filled, and on this token it is an amount of %@.",
        "HIGH RISK: The maker fee is %@% (%@ bps) of each fill, paid to %@.",
        "HIGH RISK: The order offerer %@ differs from the requested signer %@. This signature only matters if the offerer is a contract wallet that accepts it.",
        "HIGH RISK: The order signer %@ differs from the requested signer %@.",
        "HIGH RISK: The order trader %@ differs from the requested signer %@.",
        "HIGH RISK: This order effectively never expires (end time %@). It stays valid until you cancel it on-chain.",
        "HIGH RISK: This order stays valid for more than 10 years (until %@). It can be filled at any time until then unless you cancel it on-chain.",
        "This order stays valid for more than a year (until %@).",
        "This listing sells %@ NFT items together in one order.",
        "This listing sells %@ NFT items from %@ contracts together in one order.",
        "This restricted order is validated by zone %@, whose rules are not decoded.",
        "Non-standard strategy %@; its additionalParameters are not decoded.",
        "You receive only %@ for the items you give. Check that this very low price is intended.",

        // Actions that name a version, a count or a delegate type.
        "List NFT for Sale (Seaport %@)",
        "Make NFT Offer (Seaport %@)",
        "Sign Seaport Order (Seaport %@)",
        "Bulk List (%@ orders)",
        "Bulk List (%@ orders, LooksRare)",
        "Approve Metaplex %@ delegate",
        "Revoke Metaplex %@ delegate",
        "Approve NFT %@ delegate",
        "Revoke NFT %@ delegate",

        // Headlines that carry a value.
        "Destroys %@ BTC in an unspendable output · %@",
        "Destroys %@ BTC in an unspendable output",
        "%@ recipients · %@",
        "%@ transfers · review each below",
        "%@ · not decoded",
        "All your NFTs in %@",
        "Operator for all NFTs in %@",
        "Owner threshold %@ · %@ key",
        "Owner threshold %@ · %@ keys",

        // Pieces of other text: a unit beside a refund, a contract caption.
        "raw units of %@",
        "receives the %@",
    ]

    /// Values that are engine text themselves rather than data: the part of an
    /// order a warning is about, a sentence that explains it, a unit. These are
    /// translated in turn when the catalogue has them, and otherwise drawn as given.
    static let slots: [String: [Int: ReviewText.Kind]] = [
        "HIGH RISK: %@ is typed ERC-721, but %@ is %@, a fungible token in the local registry, not an NFT contract. %@": [0: .label, 3: .sentence],
        "HIGH RISK: %@ is typed ERC-1155, but %@ is %@, a fungible token in the local registry, not an NFT contract. %@": [0: .label, 3: .sentence],
        "HIGH RISK: This Safe transaction pays a gas refund of up to (gas used + %@) × %@ %@ to %@. Only approve refunds you expect.": [2: .phrase, 3: .phrase],
        "Destroys %@ BTC in an unspendable output · %@": [1: .headline],
    ]
}
