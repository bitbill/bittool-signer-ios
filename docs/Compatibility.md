# BitTool Signer 1.0.0：公开协议、导出语义与兼容验收

2026-09-21 修改规范是 Revision 1 的基准。Revision 3（2026-09-22）按用户的新要求改变了其中几项决定：BTC 默认导出改为 Account XPUB 并移除叶子公钥模式；TRON 可导出任意地址索引（不再限 0–99）；支持钱包列表移除 Ownbit，只列有第一方依据的钱包。以下内容已按 Revision 3 更新。以下区分代码/参考 SDK 验证与指定热钱包版本的真机配对、请求、扫回响应。**参考库能解析，不等于 App Store 中某个钱包已经完成三阶段互通。** 当前没有可据此展示为已认证的完整热钱包往返矩阵。

## 公共传输范围

| 链 | 连接导出 | 签名请求 → 响应 | 限制 |
|---|---|---|---|
| BTC | `crypto-account`：单签账户 XPUB（默认）或纯地址；多签 cosigner XPUB | `crypto-psbt` → `crypto-psbt`；`ur:psbt` → `ur:psbt` | 保留既有公开 BBQR H/2/Z 与 PSBT hex/base64 文件兼容（含多行折叠的 Base64）；响应使用与请求相同的 UR 类型；不增加产品格式 Tab |
| EVM | `crypto-hdkey` 账户节点；可切纯地址 | `eth-sign-request` → `eth-signature` | dataType 1/2/3/4；具体签名类型、网络与风险由链解析器检查 |
| SOL | `crypto-multi-accounts`，只装当前预设的一项；可切纯地址 | `sol-sign-request` → `sol-signature` | Transaction / Message 分开；返回 64 字节 detached Ed25519 签名 |
| TRON | 当前 index 的纯地址（`m/44'/195'/0'/0/i`，i = 0 … 2³¹−1） | `tron-sign-request` → `tron-signature` | 已核对公开 Keystone SDK 字段与固定 wire 样例；2026-09 调研未发现任何主流热钱包对纯地址导出生成该请求（见下文） |

TP 的 `scheme:action-version=...&protocol=TokenPocket...`、TP 动态分片、旧 `keystone-sign-request`、外部 `bittool-signer-json` 签名请求与响应均已移除/拒绝。内部 Swift↔JS 的 JSON dispatch 只是进程内接口。PSBT 文件仍能导入；普通地址、助记词与交易签名入口保持分离。

## 助记词语言与备份格式

- **导入**：支持 BIP39 官方 10 种词表，即 English、简体中文、繁體中文、日本語、한국어、Español、Français、Italiano、Čeština、Português。词表逐字节取自 bitcoin/bips，并固定 SHA-256，已与 @scure/bip39、ethers 两个独立来源逐词核对。seed 按 BIP39 规定，用 NFKD 规范化后的词计算，与其他标准钱包一致；已用 @scure/bip39 参考向量和 bip32JP 官方日文向量（含兼容字符 passphrase）验证。
- **容错**：可不输入重音、可用大写、可带编号或逗号；中文可不加空格，日文可用全角空格分隔。App 始终换回官方拼写再计算 seed。若同一组无重音的词在两种语言中都有效（例如意大利语 “nomina solido comodo …” 加上重音后也是有效的西班牙语），两者是不同的钱包，App 会请用户选择语言。
- **二维码导入**：Standard SeedQR 只定义英文词表；含单词原文的二维码（例如 BitTool Signer 自己的助记词二维码）支持所有语言，并按二维码中的原样拼写导入，不再询问语言。
- **创建**：新钱包仍生成英文助记词，兼容性最广。
- **助记词二维码**：备份页“二维码”标签显示助记词明文二维码（单词以空格分隔，不含 BIP39 passphrase），用于在私密环境下把钱包迁移到自己的另一台设备；任何能扫码导入助记词的钱包都能读取。默认遮盖，点击后显示，不提供保存或分享。上一版的加密备份格式（`BSBK1:`）已移除。
- **助记词卡片（2/3）**：三张卡片，每张隐去三分之一的单词，任意两张可恢复完整助记词。布局只取决于单词数（按每行三个位置、每行各隐去一个、逐行错开），重复打开或在其他设备上生成都一致。24 词时单张卡片缺 8 词（约 80 位），12 词时只缺 4 词（约 40 位，可被暴力破解），因此 12/15 词会显示警告。

## 配对输出的精确区别

BTC 单签 profile 顺序为 `native`、`taproot`、`nested`、`legacy`，对应账户 `m/84'/0'/0'`、`m/86'/0'/0'`、`m/49'/0'/0'`、`m/44'/0'/0'`。

| BTC 模式 | 实际内容 | 能否继续公开派生 |
|---|---|---|
| `accountXpub`（默认） | 账户节点公钥、chain code、origin、父指纹及脚本表达式 | 可派生 `/0/i`、`/1/i` |
| `address` | `/0/0` 的完整收款地址原文 | 不能 |

上一版的 `publicKey`（`/0/0` 叶子公钥、无 chain code）已移除：BCR-2020-015 规定 `crypto-account` 只放账户级 HD 公钥，2026-09 调研的钱包（Sparrow、BlueWallet、Nunchuk、Specter、Keeper、ZEUS 等）的解析代码都要求 chain code，没有一个能导入这种格式。引擎现在拒绝该模式。

Taproot 使用 BCR 输出表达式 `tr` 的标准 tag **409**，导出的 internal key 保持未 tweak，地址正确应用 BIP86 tweak。独立 CBOR 解码器补登记该已公开标准 tag 后检查输出，另用 BIP86 公布的 internal key/地址向量验证；没有把 Taproot 伪装为 `wpkh`。

BTC `multisig-native` / `multisig-nested` 固定导出 `m/48'/0'/0'/2'` / `m/48'/0'/0'/1'` 账户 XPUB，带 `wsh` / `sh(wsh)` cosigner 上下文。该容器只有一位参与者，**没有门槛、其他参与者、最终收款地址或完整策略**；不进入链上脚本生成。不同脚本路径的实际公钥不同。

EVM Wallet 导出 `m/44'/60'/0'` 的 `crypto-hdkey`，children 为 `0/*`；Address 固定 index 0。地址浏览页仍可分页浏览多个索引。

SOL Standard / Trust / Legacy 分别是 `m/44'/501'/0'/0'`、`m/44'/501'/0'`、`m/44'/501'`。三项公钥本地缓存；每次只导出当前项，不提供 SOL XPUB。Keystone 向 Solflare/Helium 提供的正是这三类路径（account-based、single account、sub-account）；恢复路径一致本身不等于扫码签名认证。

TRON 只导出 `m/44'/195'/0'/0/i` 当前地址，`i` 可为 0 到 2³¹−1 的任意非硬化索引（步进器或直接输入）；本地保存账户节点和 index 0–99 的地址缓存，其他索引由账户节点按需派生。没有已验证公共配对 payload 时不显示虚构 Wallet 格式。

所有 Address 模式只编码地址原文：无 URI scheme、JSON、UR 前缀、金额、UUID 或路径。复制文本等于二维码实际内容；动画导出是所有显示帧的换行文本。

## 钱包级配对（bittool-signer-wallet v1）

Connect 页新增 **Wallet Level**（页面默认仍打开 Coin Level；钱包详情页的 Connect 分组里也有直接入口）：一个静态二维码（单个 `ur:bytes`，不分帧、不动画）包含 BTC、EVM、TRON、Solana 四条链的观察信息，供专门实现了 BitTool Signer 钱包级配对的多链钱包一次导入。只有一种类型：BTC BIP84、EVM、TRON 的账户级 xpub，以及 1 个 Solana 地址 `m/44'/501'/0'/0'`（Ed25519 为硬化派生，没有 xpub；payload 中 `mode` 为草案定义的 `full`；界面不出现 Simple/Full 选择）。格式按用户提供的草案实现：`ur:bytes` 承载 canonical CBOR（RFC 8949 §4.2.1），字段名即 JSON 键名；额外加入 `masterFingerprint` 字段（v1 解析器会忽略未知字段），以便观察钱包在 PSBT/签名请求中带上正确的指纹。精确编码、测试向量和安全说明见 [docs/Wallet-Pairing-v1.md](Wallet-Pairing-v1.md)。默认支持的钱包为 **BitTool Wallet**（BITTOOL PTE. LTD.，iOS，[App Store 6761503126](https://apps.apple.com/app/id6761503126)，官网 bittool.com 链接到该 App；按用户指定列出）。Sparrow、MetaMask 等仍使用 Coin Level 的链专用格式。

## 支持的钱包（2026-09 调研，只列有第一方依据的）

调研方法：每个钱包、每种导出分别查官方文档、官方源码或 Keystone 官方文档与固件（BitTool Signer 与 Keystone 使用相同的 UR 类型），再由独立核查者逐条尝试反驳；只保留“已确认”的条目，“不明确”的一律不列。Connect 页与 Settings › Compatibility 使用同一份列表（`BitToolSigner/Models/CompatibleWallets.swift`），并分为“可扫码签名”和“仅观察”两组。**列出不等于认证**：钱包版本会变，收款前仍须比对第一个地址。Ownbit 已按要求移除。

| 导出 | 可扫码签名（导入 + 扫码发起签名 + 扫回签名） | 仅观察（只能看余额，不能交给 BitTool Signer 签名） |
|---|---|---|
| BTC 单签 Account XPUB（`crypto-account` + `crypto-psbt`） | Sparrow（桌面）、BlueWallet、Nunchuk、Bitcoin Keeper、BULL Bitcoin（iOS/Android）、Specter、Bitcoin Safe（桌面）、ZEUS（LND 钱包，无 Legacy） | — |
| BTC 多签 cosigner（BIP48） | Sparrow、BlueWallet、Nunchuk、Bitcoin Keeper、Specter、Bitcoin Safe | — |
| BTC Address | — | BlueWallet、Electrum |
| EVM Wallet（`crypto-hdkey`，EIP-4527） | MetaMask（扩展 + 手机）、Rabby（扩展 + 手机）、imToken、TokenPocket、Ambire（扩展） | — |
| EVM Address | — | Rabby、TokenPocket（观察钱包）、OKX Wallet、Trust Wallet |
| SOL Wallet（`crypto-multi-accounts`） | Solflare、Helium Wallet | — |
| SOL Address | — | Phantom、Backpack、Jupiter、OKX Wallet、TokenPocket（观察钱包） |
| TRON Address | — | TokenPocket（观察钱包）、TronLink、OKX Wallet、OneKey |

要点：

- **Sparrow / BlueWallet 默认导入账户 xpub**：Sparrow 的 Airgapped Hardware Wallet › Scan 读取 `crypto-account`，并按钱包的 Script Type（默认 Native SegWit）选对应描述符；BlueWallet 把 `crypto-account` 转为 HD 观察钱包并用 `crypto-psbt` 往返签名，四种单签路径（84'/86'/49'/44'）都按路径识别正确。因此 BTC 默认改为 Account XPUB。BitTool Signer 每个二维码只含一个描述符，Sparrow 中需先选与所导出地址类型一致的 Script Type。
- **TokenPocket**：用户的判断正确，TP 的“观察钱包”支持 TRON 和 Solana 地址（输入或扫码）；但 TP 的冷钱包签名使用自有协议，BitTool Signer 不支持，所以这两条链只算“仅观察”。另外调研发现 TP 支持 EIP-4527：EVM 的 `crypto-hdkey` 可导入为观察钱包并用 `eth-sign-request` 扫码签名，因此 EVM Wallet 列为“可扫码签名”。
- **TRON 扫码签名**：Keystone 的 `tron-sign-request` 只被 NuFi（USB）和 OneKey（未合并 PR）使用；OKX、Keystone Nexus 走旧的 `keystone-sign-request` 并需要设备级账户 xpub；TronLink 只支持 Ledger。纯 `T…` 地址无法与这些钱包配对签名，所以 TRON 目前只能“仅观察”。
- **已移除**：Ownbit（按要求）；Safe（旧 iOS App 已归档，新 App 与网页版没有 QR 签名器）；Backpack 的 SOL Wallet（扩展可扫码导入，但签名流程与 BitTool Signer 单 key 负载均无官方记录，降为“仅观察”）。
- **未列出（证据不足或不支持）**：OKX/Bitget/Keplr 的 EVM 或 SOL 扫码签名（依赖 Keystone 专用多账户包，闭源无法确认）；Zerion、Rainbow、Frame、Trust Wallet、1inch、Uniswap、Taho（只支持 Ledger/Trezor 或无硬件）；Core、BlockWallet、CTRL、Magic Eden（已停止支持或停运）；imToken 的地址观察（仅 EVM，且需其授权签名握手）；Trust/Bitget/SafePal 的 TRON、Solana 观察（官方文档未点名这些链）。

主要来源（节选）：[Sparrow 硬件钱包 QR 文档](https://sparrowwallet.com/docs/airgapped-wallet-qr.html)、[BlueWallet 观察钱包](https://bluewallet.io/watch-only/)、[BlueWallet UR 解析源码](https://github.com/BlueWallet/BlueWallet/blob/c4ca946610e75933a9770130bacccabc158b76e3/blue_modules/ur/index.js#L146-L150)、[Keystone × Nunchuk](https://guide.keyst.one/docs/btc-nunchuk)、[Specter Keystone 设备](https://github.com/cryptoadvance/specter-desktop/blob/5d3d5b91e614991c2dedb87c0e0e608e2c6382ae/src/cryptoadvance/specter/devices/keystone.py#L16-L17)、[Bitcoin Keeper QR 服务](https://github.com/bithyve/bitcoin-keeper/blob/1adf4f66399a2bfac4572d9da94440323bff02f2/src/services/qr/index.ts#L19-L70)、[Keystone × Bitcoin Safe](https://guide.keyst.one/docs/bitcoinsafe)、[BULL Bitcoin UR](https://github.com/SatoshiPortal/bullbitcoin-mobile/blob/83e4098e58b5b005b808baaa825c0e1c438b81cc/lib/core/urqr/urqr.dart#L101-L104)、[ZEUS 扫码处理](https://github.com/ZeusLN/zeus/blob/0171262a1cce532375270fabbd29cd83a9b5b88c/views/HandleAnythingQRScanner.tsx#L114-L153)、[MetaMask QR keyring](https://github.com/MetaMask/accounts/blob/main/packages/keyring-eth-qr/src/device.ts)、[Rabby QRCodeConnect](https://github.com/RabbyHub/Rabby/blob/develop/src/ui/views/ImportHardware/QRCodeConnect/index.tsx)、[imToken 连接其他钱包](https://support.token.im/hc/zh-cn/articles/26676911412377)、[TokenPocket EIP-4527](https://help.tokenpocket.pro/cn/wallet-operation/tool/eip-4527/tokenpocket)、[TokenPocket 观察钱包](https://help.tokenpocket.pro/cn/the-basics/watch-wallet)、[TokenPocket Solana 协议](https://help.tokenpocket.pro/developer-en/scan-protocol/solana)、[Ambire × Keystone](https://help.ambire.com/en/articles/14612715-how-to-connect-ambire-wallet-to-keystone)、[OKX 观察钱包](https://web3.okx.com/help/how-do-i-manage-my-wallet-app)、[Trust Wallet 观察地址](https://trustwallet.com/blog/guides/how-to-import-a-watch-address)、[Solflare × Keystone](https://docs.solflare.com/solflare/onboarding/web-app-and-extension/import-your-keystone-device)、[Keystone × Helium](https://guide.keyst.one/docs/helium)、[Phantom 观察账户](https://help.phantom.com/hc/en-us/articles/28355420369939-Manage-watch-only-accounts-in-Phantom)、[Backpack 入门](https://support.backpack.exchange/wallet/get-started)、[Jupiter 钱包管理](https://docs.jup.ag/user-docs/global/mobile/managing-wallets)、[TronLink 多钱包](https://support.tronlink.org/hc/en-us/articles/4579986719513-How-to-Switch-between-Multiple-Wallets)、[OneKey TRON 设置](https://github.com/OneKeyHQ/app-monorepo/blob/x/packages/kit-bg/src/vaults/impls/tron/settings.ts)。完整调研记录（每条的原文摘录与核查结论）保存在本轮会话的工作区，未随仓库提交。

## 二维码载荷视图（Payload）

Connect 的每个 Coin Level 二维码、Wallet Level 二维码和签名结果二维码下面，都有一个默认折叠的 “Payload” 区域，点开可以看到这个二维码实际携带的内容，另有 “Copy Payload”（只复制到本机、会过期的剪贴板，不经 Handoff）。Coin Level 与签名结果的内容由引擎把**刚生成的帧重新解码**得到（`describeQR`，`engine/protocols.js`），不是用生成时的输入另行拼出来，所以与二维码逐字节一致；帧无法按自身类型解回时直接报错，不显示二维码。Wallet Level 显示的是被 canonical CBOR 编码的那个对象本身（v1 的 CBOR 文本键即 JSON 键名，编码规则与向量见 [Wallet-Pairing-v1.md](Wallet-Pairing-v1.md)）。

- **格式**：UR 映射显示为 “Payload (JSON)”；只含一个字节串的 UR 显示为 “Payload (Hex)”；纯文本二维码（仅地址导出）显示为 “Payload (Text)”，内容就是二维码文本本身。卡片上的 “Format” 行给出传输方式和字节数，例如 `ur:crypto-account · CBOR · 162 bytes`、`Plain text · 34 bytes`（字节数是 UR 内 CBOR 的长度，或 PSBT 本身的长度）。
- **命名**：整数键按注册表字段名显示（crypto-hdkey / crypto-keypath / crypto-coin-info 按 BCR-2020-007，crypto-account 按 BCR-2020-015，crypto-multi-accounts、eth-/sol-/tron-signature 按 Keystone 注册表）；带 tag 的值显示为以 tag 名为键的单键对象（303 crypto-hdkey、304 crypto-keypath、37 uuid；输出描述符 400–410 用 BCR-2020-010 的 CDDL 名，如 `witness-public-key-hash`、`script-hash`、`taproot`）；字节串为小写 hex。JSON 按键名排序显示（CBOR 映射本身无序）。
- **与规范的差异如实显示**：BitTool Signer 的 crypto-account 采用 Keystone/Sparrow 的写法，输出描述符外**没有** BCR-2020-015 的 `#6.308(crypto-output)` 包装；视图显示的就是实际编码。
- **指纹**：UR 里的 master/source/parent fingerprint 按规范是 32 位整数，所以 JSON 里显示十进制（测试助记词为 1942346250）；Payload 区域会注明它就是界面上的指纹（1942346250 = 73C5DA0A）。钱包卡片、详情页、审核页和 Activity 统一显示这个 master fingerprint（原 “Wallet ID” 已改为 “Fingerprint”），与 Wallet Level 载荷中的 `masterFingerprint` 相同；内部身份与签名匹配仍然用 `walletKeyId`，指纹只作显示。
- **签名结果**：eth-/sol-/tron-signature 显示 `request-id`（`{"uuid": …}`）和 `signature`。比特币 PSBT 的所有返回形式（crypto-psbt、psbt、BBQr、Base64/hex 文本）都用与读取请求相同的收集器重新拼回，显示 `psbt_base64`（二维码携带的完整 PSBT）和 `decoded`（从中解析出的参考信息，字段名采用 Bitcoin Core `decodepsbt`，金额为整数 `value_sat`，txid 为未签名交易的 txid；按键名排序排在前面，大 PSBT 截断显示时仍可见）；超过 30,000 字符时界面只排版前 30,000 字符，复制仍是全文。
- 签名结果页只保留一个主按钮 **Done**；“Export as File” 移到 Payload 卡片内作为次要操作。

## 编码与原始字节

- 使用 bc-ur 1.1.13 的 Bytewords/fountain；支持乱序、重复及混合 fountain 帧恢复。类型、数量、checksum、message length 和 fragment length 必须同组。
- BBQR 校验 base36 索引、编码、分片长度；Z 使用 fflate 的有界流式 raw-DEFLATE 解压。该协议没有全局 session ID，完整 PSBT 仍须审核。
- ETH 请求 ID 若存在，接受带 tag 37 的 **1–64 原始字节**。imToken 实际请求使用过 36 字节不透明关联 ID；不转 UTF-8、不截断、不重新生成。SOL/TRON 当前保持 16 字节 UUID 边界。错误 tag、类型、空/超限值拒绝。
- ETH 签名编码：legacy 交易返回 EIP-155 `v`（大 chain ID 不截断），typed 交易（2930/1559）返回 y-parity，消息与 EIP-712 返回 27/28。SOL 固定 64 字节；TRON 固定 65 字节 `r || s || recovery`，公开 SDK 样例恢复位为 0/1。
- `tron-sign-request` CBOR 字段：1 request ID、2 signData bytes、3 dataType、4 derivation keypath、5 可选地址 bytes、6 origin。dataType 1 是原始 `raw_data` protobuf；2 是 personal message。当前可选地址按 21 字节、首字节 0x41 的二进制 TRON 地址验证。没有地址时仍须满足公开索引匹配规则。
- TRON 公共响应为 detached signature；热端保留/汇总其他成员签名。内部交易签名同时验证并保留请求已有签名，不把 operated account、新权限成员或 owner 字段直接当签名者。
- 原 CBOR/PSBT bytes 留在标准化 request 的 transport 中；签名前重新验证其与待签结构一致。origin 只是未认证的展示信息。
- 可预期协议拒绝返回 `QR_PROTOCOL` 受控文案；未知类型名称、输入键名和第三方异常不会原样回显到错误提示。

2026-09-21 imToken 问题的本地复现确认：实际单帧 `eth-sign-request` 的 36 字节 ID 被旧版误限为 16 字节。修复后的 bundle 对实际二维码解析与审核成功，**没有签署或广播该真实交易**。真实内容没有进入仓库/线上查询。该事实不等于 imToken 已完成扫回签名验收。

## 公开索引、解析与授权接口

完整接口见 [engine/README.md](../engine/README.md)。产品调用顺序：

```text
derivePublicIndex（创建/导入/修复时短期授权一次；宿主以原生 PBKDF2-HMAC-SHA512 计算 BIP39 seed 后传入）
  → 仅公开缓存 derivePublicAddresses / createPublicPairing
  → decodeQR / decodePayload
  → review + resolveSigningPlan（全部本地公开钱包记录）
  → 对固定 task 输入对应钱包密码
  → signPlanTask（校验计划、重新派生并核对真实公钥）
  → encodeResponse（原请求的公开 profile）
```

每个钱包保存六个 BTC 节点、一个 EVM 节点、一个 TRON 节点及 100 地址、三个 SOL 预设公钥（公开索引版本 1）。稳定 `walletKeyId` 使用版本域分离 SHA-256 绑定有效 seed 的 master 公钥材料；不输出 master XPUB，不用短 fingerprint 代替身份。

EVM 缺 path 仅回退 index 0；SOL 仅三个预设；TRON 带 path 的请求（`tron-sign-request` 必带 path）可匹配任意索引，只有地址、没有 path 的请求仅比对缓存的 index 0–99；BTC 缺 derivation 只尝试各注册单签 `/0/0`，cosigner 还需脚本中明确匹配公钥。有效带 path 请求可匹配 BTC Receive/Change 和 EVM 非零索引。看过某个地址不会扩大回退范围。

无匹配、信息缺失、歧义、缓存待补齐、结构无效均不可签；无手动选择或全库秘密试解。PSBT 可产生多个固定钱包任务，每个任务独立密码授权。累积 PSBT 除增加签名外，global/input/output 元数据与原交易必须不变。

## 链解析与签名边界

- BTC：PSBT v0/v2，四类单签、P2SH/P2SH-P2WSH/P2WSH 多签、Taproot key-path 与 c0 CHECKSIGADD/CHECKSIGVERIFY 阈值 leaf。只接受 ALL/DEFAULT；legacy/SegWit v0 需要完整前序交易，全部 Taproot 可用 witness UTXO。不支持 MuSig2 和任意未知脚本。
- EVM：legacy/2930/1559、任意 bytes 的 personal message、EIP-712（值必须与声明类型严格一致，拒绝真值字符串冒充 bool 及歧义的整数/地址写法；按声明的 `EIP712Domain` 顺序计算 separator，忽略未使用的类型）；Safe gas refund、调用附带的原生币金额、手续费及 Token 表外代币转账会在审核中显示并提高风险；解析 Safe CALL/DELEGATECALL、MultiSend、权限修改、规范 Permit/Permit2。未知调用和部署标 opaque，custom typed data 标 partially decoded，按请求确认风险；不把未知内容当已解码。主网表包含 1/56/42161/8453/10/137/100/43114，Token 表现已覆盖全部八个 EVM 主网（另加 TRON 与 Solana）。Blob、7702、raw-hash eth_sign 和未知网络拒绝。
- SOL：legacy/v0 静态 keys、正确 required signer 槽位；System、常见 SPL、ATA、compute、memo 和 stake 指令。Token-2022 扩展与 Squads 提案引用部分解析，未知 program 为 opaque；ALT 仍拒绝。Message 为独立类型，只允许 1–1024 bytes 可识别 UTF-8 文本（含中文），拒绝交易 header 前缀；不把无法解析的交易降级为消息。durable nonce 交易会被标记；摘要不会把一笔转账的金额与另一笔的收款地址拼在一起。
- TRON：TRX、常见 Token/NFT ABI、权限更新、Stake 2.0/resource 类型 54–59、官方长度前缀 personal message（非文本消息显示原始字节并标为 opaque，需逐次确认）；显示 call value 与较高的 fee limit。未知 protobuf/contract 和 TRC10 拒绝。离线无法确认当前权限成员、余额或最终广播网络。

### NFT 的审核显示（Revision 3）

离线签名器拿不到 NFT 名称、图片或地板价，所以只显示请求字节能证明的内容，并在无法确定时明确说“无法确定”。审核卡片对 NFT 使用专门的图标（NFT、ERC-1155、“NFT 或代币”带橙色问号、市场挂单），在标题下方显示“NFT contract (not verified)”/“Mint”/“Asset ID”与完整地址，超长 Token ID 在标题中缩写（前 8 + 后 8 位并注明位数），同时完整显示在卡片里。

- **EVM / TRON 合约调用**：`safeTransferFrom`（ERC-721）显示“Send NFT · NFT #id”；ERC-1155 单笔显示“数量 × #id”，批量合并为一个“Items”字段并提示重复 ID 和数量为 0；`setApprovalForAll(true)` 为红色 HIGH RISK，说明操作者可转走该合约中此账户的所有代币（包括以后收到的），撤销为黄色；`approve`/`transferFrom` 在合约不在代币表时按“NFT 或代币”显示两种解释，`approve(X, 0)` 不再误显示为“Revoke”，`approve(0x0, id)` 显示为“Clear NFT Approval (if ERC-721)”；MultiSend 标题列出各子调用，子警告带“Call k:”前缀并去重；ENS `.eth` 域名（仅以太坊主网）只加说明字段，不猜测名称。TRON 的 TRC-721 同样处理，地址以 Base58 显示。
- **NFT 市场签名（EIP-712）**：按精确的类型字符串和 (name, version, verifyingContract) 识别 Seaport 1.5/1.6（含 BulkOrder）、LooksRare v2 Maker/BatchOrder 与 Blur。Seaport/LooksRare 显示“你给出 / 你收到 / 其他人收到”，并对以下情况给红色警告：什么都收不到、荷兰拍价格降到 0、大部分款项付给他人、买方可任选你合约中的任意代币（criteria 0）、订单实际上永不过期、订单签名人不是签名钱包、被标成 NFT 的条目其实是代币表中的 ERC-20（例如“NFT #5e18”其实会转走 5 WETH）、Seaport 格式但合约未识别。Blur 的 Root/V2 只签 Merkle root，内容不可见，一律标为未解码并给红色警告；其他只签单个 bytes32 或类型名含 root/tree/merkle 的 typed data 也给同样警告。OpenSea 手续费地址、conduit、zone 标签只在已核实的链上作为说明文字出现，永远不降低风险。只对这些已识别的市场请求，才会忽略未声明的消息字段（不参与签名、不显示，给出数量警告）；其他 typed data 仍然拒绝多余字段。
- **Solana**：SPL/Token-2022 中 0 位小数、数量 1 且不在代币表的转账显示为“Send Token (likely NFT)”（因为 0 位小数的普通代币也符合这个模式）；同一交易中有匹配的 ATA 创建指令且没有未解码指令时，收款方显示为钱包地址，否则显示代币账户并提醒。Metaplex Token Metadata TransferV1 只有在提供了该 mint 的 edition PDA 时才标为 NFT，并校验 metadata/edition/token record 的 PDA；Bubblegum 压缩 NFT（transfer 与 transfer_v2）校验 tree config PDA 并从树和 nonce 推导 Asset ID；Metaplex Core TransferV1 只接受精确的 `[14,0]` 数据。委托人签名、规则集、转账钩子（只能说明“交易提供了钩子 X 的账户”，无法离线确认 mint 实际的钩子）都有相应警告。Magic Eden、Tensor、Auction House 等市场程序只显示名称并标为未解码的高风险；Token Metadata 的 Delegate/Revoke/Lock/Unlock/Burn 按角色准确说明委托人能做什么（例如 StandardV1 可转移、销毁和冻结）。所有实质指令都未解码时，整笔交易标为“Not decoded”。

所有 NFT 显示都不使用绿色“已验证”提示；常量（选择器、类型字符串、合约地址、程序 ID、判别符、账户顺序）均按官方仓库核对，并由独立审核者复核。测试见 `engine/test/nft-evm.test.mjs`、`engine/test/nft-solana.test.mjs` 与 `BitToolSignerTests/NFTReviewDisplayTests.swift`。

结构无效、签名算法不支持和缺少可信密钥定位证据，不能通过风险确认绕过。静态 Token 资料只用于显示，不证明合约行为。

## 限额与测试证据

接收最多 2048 帧（BBQR 最多 1295）、单帧 4300 字符、累计文本 1 MiB、解码载荷 128 KiB。CBOR 深度 24/节点 20000；JSON 深度 32/节点 20000。拒绝重复键、不精确整数、无限长 CBOR、通配符签名路径、未知签名类型和可识别混合会话。QR 校验和不是身份认证。

2026-09-22（Revision 3）engine 全套 **173/173 通过**，无失败、跳过或取消。在原有协议、公开索引、resolver、链覆盖与 `test/hardening.test.mjs`（Revision 2 内部审查的全部 engine 问题、BTC 找零重新派生、seed 与助记词输入一致）之外，新增 `test/wallet-pairing.test.mjs`（钱包级配对）、`test/nft-evm.test.mjs` 与 `test/nft-solana.test.mjs`（NFT 显示）、`test/pairing-payload.test.mjs` 与 `test/response-payload.test.mjs`（二维码载荷视图：22 种 Connect 导出、17 种签名返回；UR 导出与 eth/sol 签名、crypto-psbt 逐项与 Keystone 解析器交叉核对，地址、BBQr、PSBT 文本与 tron-signature 以独立解码核对）。Token 表测试逐项核对全部 3,350 条记录：地址形态、身份唯一性、链上读到的 decimals、两层各自的来源字段、Solana 的 token program 绑定，以及图标包无空洞且每张图的字节哈希等于其 id。

当前 bundle 为 **854090 bytes**，SHA-256 `36a00e6a35405519baf58595d09029ed099626beb52f37634fea71db5fc6d72b`，见 [bundle-manifest.json](../engine/bundle-manifest.json)。公开宿主向量 [public-plan-vectors.json](../engine/test/fixtures/public-plan-vectors.json)。原生 JavaScriptCore、UI 和真机相机结果见实施状态；Node 测试不代替它们。

发布前每条 QR signing 记录必须包含：钱包/平台/版本、链/路径/输出模式、配对 payload、请求方法与样例、响应、独立验签及真实相机扫码往返。没有热端实机证据的路线保持待验证。

## 第一方来源

- [BC-UR](https://github.com/BlockchainCommons/Research/blob/master/papers/bcr-2020-005-ur.md)、[输出脚本表达式（含 tr=409）](https://github.com/BlockchainCommons/Research/blob/master/papers/bcr-2020-010-output-desc.md)、[BIP86](https://bips.dev/86/)、[BIP48](https://bips.dev/48/)。
- [Keystone registry](https://github.com/KeystoneHQ/ur-registry)、[ERC-4527](https://eips.ethereum.org/EIPS/eip-4527)、[MetaMask QR keyring](https://github.com/MetaMask/accounts/blob/03e1e383d02db2407699a4a24d5bac1ff7766479/packages/keyring-eth-qr/src/device.ts)。ERC-4527 状态为 Stagnant，不能称为所有钱包已支持的 Final 标准。
- [Keystone Solana 公共 UR](https://dev.keyst.one/docs/integration-tutorial-advanced/solana)、[Trust Wallet 路径资料](https://github.com/trustwallet/wallet-core/blob/5031fe6dd14b6d11a5de9892ea4ea1ee443fa13f/docs/registry-fields.md)。
- [TronSignRequest 固定源码](https://github.com/KeystoneHQ/keystone-sdk-base/blob/cda9c6edf21518ed5bf4d64f665aaf4494e88c1f/packages/ur-registry-tron/src/TronSignRequest.ts)、[TronSignature](https://github.com/KeystoneHQ/keystone-sdk-base/blob/cda9c6edf21518ed5bf4d64f665aaf4494e88c1f/packages/ur-registry-tron/src/TronSignature.ts)、[同版本公开测试](https://github.com/KeystoneHQ/keystone-sdk-base/tree/cda9c6edf21518ed5bf4d64f665aaf4494e88c1f/packages/ur-registry-tron/__test__)、[TronWeb 消息签名](https://github.com/tronprotocol/tronweb/blob/master/src/utils/message.ts)。
- [AirGap imToken 指南](https://support.airgap.it/guides/imTOKEN/)、[AirGap 的 QRType.METAMASK 映射](https://github.com/airgap-it/airgap-vault/blob/master/src/app/pages/account-address/account-address.page.ts)、[Coinkite BBQR](https://github.com/coinkite/BBQr/blob/master/BBQr.md)。

以上是协议、派生及源码依据，不是对商业钱包某一发行版的兼容认证。
