# BitTool Signer iOS：现有版本修改与优化实施规范

> **版本：** 2026-09-21 · Revision 1  
> **用途：** 交给开发者或编码 AI，修改已经完成的 BitTool Signer iOS 项目。不是重新开发一套 App，也不是一份兼容性宣传稿。  
> **需求基准：** 2026-09-21 本次完整讨论；发生冲突时，以本文件中的最终决定覆盖此前 v1 设计及早期口头建议。  
> **文档语言：** 中文工程说明；本次 App 的用户界面、提示和按钮使用英文。  
> **交付边界：** 本文件是实施要求，不表示已经修改源码、下载全部资产图标或通过真机扫码测试。

---

## 目录

1. [0. 给编码 AI 的执行指令](#section-0)
2. [1. 最终决定总表](#section-1)
3. [2. 信息架构与页面路由](#section-2)
4. [3. 首页、钱包身份与详情页](#section-3)
5. [4. 地址浏览页：和“配对导出”分开](#section-4)
6. [5. 配对页的公共规则](#section-5)
7. [6. BTC 配对与导出](#section-6)
8. [7. EVM 配对、地址和签名](#section-7)
9. [8. SOL：三个路径、单项导出、两种签名](#section-8)
10. [9. TRON：index 0–99 与交易签名](#section-9)
11. [10. 签名支持矩阵：解析容器与真正能签分开](#section-10)
12. [11. 本地公开元数据：单独存储，不为匹配解锁 seed](#section-11)
13. [12. 自动匹配钱包：无手动选择、无全库秘密试解](#section-12)
14. [13. 签名页：Summary → Details → Wallet → Authorize](#section-13)
15. [14. 最大化本地解析与风险分级](#section-14)
16. [15. 内置离线 Token Registry 与图标](#section-15)
17. [16. 签名授权：彻底移除 Unlock Vault](#section-16)
18. [17. App Lock：Face ID 只锁界面](#section-17)
19. [18. 主网范围与内部网络校验](#section-18)
20. [19. 完全离线：架构、移除项与文案](#section-19)
21. [20. 启动视觉：不空白、不闪白、不人为延时](#section-20)
22. [21. Welcome、首次引导、创建/导入衔接](#section-21)
23. [22. Scan、Activity 和 Settings 的具体修改](#section-22)
24. [23. 现有数据迁移与不回归要求](#section-23)
25. [24. 建议的内部模块与状态边界](#section-24)
26. [25. 自动化测试与验收清单](#section-25)
27. [26. 实施优先级与最终交付](#section-26)
28. [27. 仍须核验、但不得凭猜测实现的项目](#section-27)
29. [28. 需求优先级与参考来源](#section-28)
30. [29. 给编码 AI 的最终检查口令](#section-29)

---

<a id="section-0"></a>

## 0. 给编码 AI 的执行指令

请先完整阅读本文，再检查现有项目结构、最低 iOS 版本、存储格式、二维码库、派生实现和签名引擎。**在当前技术栈上修改，不创建另一套平行产品，不为了本次 UI 调整重写已经可靠的密码学实现。**

实施顺序：

1. 找出现有的钱包模型、全局选中钱包、Unlock Vault、二维码导出、扫码签名、Activity、Settings 和启动路由。
2. 对照本文建立变更清单，列出真实文件路径、已有能力、缺失能力和数据迁移方案。
3. 先完成数据与权限边界，再改页面；最后补充二维码互操作测试、安全测试和截图验收。
4. 对本文明确要求的功能，不用假数据、仅 UI 开关、空实现或“暂时返回成功”代替真实实现。
5. 没有通过验证的钱包兼容性不能显示为已支持；没有匹配到本地密钥不能让用户随便选择钱包继续签名。
6. 新建 `IMPLEMENTATION_STATUS.md`，逐项写明完成、测试通过、待验证和具体阻塞原因。不能把“能编译”写成“兼容所有热钱包”。

**本次不做：** TP 私有扫码协议、旧式 Keystone 专用压缩封装、按热钱包名称分别造格式、联网功能、测试网产品入口、全局解锁、签名钱包手动切换、签名免密、语言切换功能。

### 0.1 三个必须正确落地的技术边界

- **BTC 单公钥导出与账户 XPUB 导出不同。** 本次保留用户决定的默认 `Public Key`，但不能把它宣传成与账户 XPUB 一样兼容所有 HD 钱包。连接 Sparrow/BlueWallet 的账户导入通常应验证 `Account XPUB` 模式；兼容提示随当前模式变化。
- **地址相同、可以观察，不等于支持扫码签名。** 原始地址能被导入观察，并不证明接收方会生成 BitTool Signer 支持的签名请求；兼容标签必须区分这两种能力。
- **iOS 不能用“没申请一个通用联网权限”证明不能联网。** 产品必须通过没有网络调用、没有联网依赖和实际审计来实现离线；不要编造 iOS 中不存在的通用 `INTERNET` 授权开关。

这些是实现约束，不改变用户确定的页面结构和离线定位。

---

<a id="section-1"></a>

## 1. 最终决定总表

| ID | 最终要求 |
|---|---|
| D01 | 所有钱包并列，没有全局“当前钱包”“默认签名钱包”。 |
| D02 | 首页列出全部钱包；每张卡片显示自定义名称、稳定身份后缀，以及 `Connect`、`Addresses` 快捷入口。 |
| D03 | 配对从 Settings 移到钱包自身；钱包详情页也保留 `Connect` 和 `Addresses`。 |
| D04 | BTC 顶层为 `Single-sig` / `Multisig` 两组，不以 Sparrow、BlueWallet 作为协议 Tab。 |
| D05 | BTC 单签顺序：Native SegWit（84，默认）→ Taproot（86）→ Nested SegWit（49）→ Legacy（44）。 |
| D06 | BTC 多签顺序：Native SegWit（48、type 2，默认）→ Nested SegWit（48、type 1）。 |
| D07 | BTC 单签输出方式为互斥三选一：`Public Key`（默认）、`Account XPUB`、`Address`。多签固定导出 cosigner 的账户级扩展公钥，不提供这组三选一。 |
| D08 | BTC 不导出真正的 master/root XPUB，不把 Receive/Change 分支增加为导出类型。 |
| D09 | BTC 签名不仅支持 PSBT 容器，还必须实现主流单签、多签及 Taproot 的具体花费规则。 |
| D10 | EVM 连接格式为 `crypto-hdkey`；签名使用 `eth-sign-request` / `eth-signature`，支持交易、普通消息和 EIP-712。 |
| D11 | SOL 有三个短名称路径 Tab；默认只导出当前 Tab 的一个公钥；三条路径的公钥与地址都保存在本地。 |
| D12 | TRON 默认 index 0，选择范围固定为 0–99；一次只展示一个地址，内部保存账户 XPUB。 |
| D13 | EVM、SOL、TRON 都提供纯地址 QR；BTC 仅单签提供，BTC cosigner 不提供。 |
| D14 | QR 下方显示当前模式有依据的兼容钱包名称和本地图标；不将“恢复路径兼容”写成“扫码签名兼容”。 |
| D15 | 扫码后自动匹配钱包。匹配成功只读展示；失败标红 `No matching wallet` 并禁用签名。 |
| D16 | 每次新的签名操作必须输入对应钱包密码。Face ID 只保护 App 页面，不代替签名密码。 |
| D17 | 签名页大号 Summary 在上，详情在下；尽量解析动作、金额、地址、权限和网络含义。 |
| D18 | 内置 Ethereum、BNB Smart Chain、Arbitrum One、Base、TRON、Solana 的主流 Token 信息与图标；运行时不下载。 |
| D19 | 移除所有 Unlock Vault / Unlock Wallet 全局解锁入口及会话状态。 |
| D20 | Settings 新增可选 App Lock，默认关闭；开启后冷启动验证，后台达到 120 秒回来再次验证，不提供时长选择器。 |
| D21 | Face ID 失败可重试，或选任意已有钱包验证密码进入 App；这不产生签名权限。 |
| D22 | 产品只提供主网；去掉 Mainnet/Testnet/Devnet 选择和常驻标签，但保留内部网络校验。 |
| D23 | 删除网络状态检测、联网警告、联网/离线状态灯。设备有网无网都不影响 App 本地使用。 |
| D24 | 新增轻量启动视觉，使用现有 Logo、slogan，适应浅色/深色，不人为延时。 |
| D25 | 无钱包先进入欢迎页；先创建或导入成功，才进入钱包首页。 |
| D26 | 首次创建/导入前展示 2–3 页本地引导，介绍离线、开源、兼容流程和设备断网建议。 |
| D27 | 欢迎页底部放官网英文路径的 Terms of Use / Privacy Policy 占位链接。 |
| D28 | Scan 页的大图标和整个主要扫码区域都可点击，不只按钮可点击。 |

**两项口头表述的纠正，必须保留：**

- EVM **地址浏览页可以浏览多个索引地址**。此前助手复述成“只能显示 index 0”不准确。限制在 index 0 的是本次 EVM 的纯地址配对默认值，以及缺失派生路径时的匹配回退。
- SOL 的三个预设按实际路径定义，而不是凭名字猜。下文根据 Trust Wallet 官方实现资料修正了早期口头讨论中 Trust 路径的位置。

---

<a id="section-2"></a>

## 2. 信息架构与页面路由

### 2.1 无钱包与有钱包分开

```text
启动视觉
  ├─ 没有钱包 → Welcome
  │               ├─ Create Wallet → 首次引导 → 创建流程
  │               └─ Import Wallet → 首次引导 → 导入流程
  │                                      ↓ 成功保存第一个钱包
  │                                   Wallets 首页
  └─ 已有钱包 → App Lock（如启用）→ Wallets / Scan / Activity
```

Settings 保留现有合理入口，不强行增加新的底部 Tab。已有三个主要 Tab 的方向保持：`Wallets`、`Scan`、`Activity`。

### 2.2 没有全局 active wallet

删除或者停止使用类似状态：

```text
selectedWalletId / activeWalletId / defaultSigningWallet
isVaultUnlocked / globalUnlockedSeed / unlockedWalletSession
```

钱包详情页、地址页、配对页可以有显式路由参数 `walletId`。这只是“当前正在查看谁”，**不影响全局签名，不是 active wallet**。

从钱包 A 的配对页退出后，扫描钱包 B 的请求，必须匹配到 B。不得沿用最近浏览的钱包 A。

---

<a id="section-3"></a>

## 3. 首页、钱包身份与详情页

### 3.1 钱包卡片

示意：

```text
Personal Wallet
ID · A17C-93D4-52B0

[ Connect ]                  [ Addresses ]
```

要求：所有钱包都展示；名字可以改；身份后缀不随名字、排序、密码、界面设置改变。点击卡片进入钱包详情。两个快捷入口直接进入该钱包的功能，不先弹“选择钱包”。

不要给某张卡片打“当前”“默认”“正在使用”的选中勾，也不自动高亮第一个钱包。

### 3.2 “signature 后缀”的正确命名

用户希望有一个与密钥关联的固定标识。界面建议叫 **`Wallet ID`**，不要叫 `Signature`，以免与交易签名混淆。

区分三个字段：

| 字段 | 用途 | 是否用于确认密钥归属 |
|---|---|---|
| `localWalletId` | 本机数据库主键，沿用既有值 | 否 |
| `walletKeyId` | 密钥身份的稳定长标识 | 用于本机去重及索引，仍须核对公钥 |
| `masterFingerprint` | BIP32 的 4 字节指纹，兼容协议字段 | 只用于候选筛选，不能单独充当安全身份 |

**工程补充方案：** 若项目还没有合适的稳定长标识，可以在创建/导入时基于该钱包的有效 seed 推导 BIP32 master 公钥材料，用带版本域分离的 SHA-256 生成 `walletKeyId`：

```text
walletKeyId = SHA256(
  UTF8("BitTool-Signer/WalletKeyId/v1") ||
  masterCompressedPublicKey[33] || masterChainCode[32]
)

显示后缀 = walletKeyId 的前 12 个十六进制字符，按 4-4-4 分组
```

这是 **BitTool Signer 本地标识的设计，不是新的钱包互操作标准，也不是交易签名**。保留完整 32 字节用于比较；12 位仅用于人眼区分，碰撞时延长显示。无需为了此标识把 master XPUB 导出给热端，或长期保存 master 私钥。

同一助记词 **加同一 BIP39 passphrase** 才表示同一有效 seed；不同 passphrase 必须是不同身份。已有 passphrase 功能不得因此丢失。若项目已有稳定且安全的身份算法，先检查兼容性，不随意使现有用户 ID 变化。BIP32 指纹本身只有短长度，不能代替长标识。[S01]

### 3.3 钱包详情页

至少包含名字、固定后缀、支持链，以及 `Addresses`、`Connect`。备份/改密码等现有功能保留，并继续要求该钱包密码，不继承 App Lock 的认证。

---

<a id="section-4"></a>

## 4. 地址浏览页：和“配对导出”分开

地址浏览只使用缓存的公开材料，不要求逐个解锁 seed；也不查余额、不查历史、不查是否用过。

| 链 | 浏览范围 | 数据来源 | 不应出现的功能 |
|---|---|---|---|
| BTC | 四种单签类型，每种可分页看 Receive 索引 0、1、2…… | 对应账户 XPUB 派生 `/0/i` | 为看地址解锁所有钱包、联网判断地址是否使用 |
| EVM | `m/44'/60'/0'/0/i`，可分页看多个索引 | EVM 账户 XPUB | 错误地限制为仅 index 0 |
| TRON | `m/44'/195'/0'/0/i`，仅 i=0…99 | TRON 账户 XPUB / 100 地址缓存 | index 100、无限地址发现 |
| SOL | 三个固定预设路径，分别展示一条地址 | 三项公钥缓存 | 将 Ed25519 公钥当作可公开派生的 XPUB |

分页尺寸属于实现参数，例如每页 20 条；不增加设置项。BTC/EVM 的索引范围需限制为有效非 hardened 索引，不能产生无限数组或一次性生成海量地址。

每一项显示：完整可复制地址、索引、可展开的完整路径。若提供单地址 QR，也只能是当前地址本身。

**BTC 多签例外：** 只有本机 cosigner XPUB 时，不能计算最终多签收款地址。钱包详情不得把 cosigner 派生公钥转换成某种单签地址，再冒充多签收款地址。若以后有完整且验证过的 descriptor，才可以据此展示多签地址。

**无路径签名的限制不因浏览而放宽：** 看过 BTC Receive 5 或 EVM index 8，不代表后续无路径请求可以自动全库扫描。本次的有限回退规则见 §12。

---

<a id="section-5"></a>

## 5. 配对页的公共规则

### 5.1 页面术语与控件

主入口使用 `Connect`，页面标题可用 `Connect wallet`。说明这一步是导出公开信息，不是传私钥，也不是发起链上交易。

BTC 的三种输出方式是**互斥单选**，用 segmented control、radio 或下拉框，不要用允许同时勾选三个的 checkbox。

所有链共用：

- QR 区域、复制当前 QR 原始内容、完整路径/地址的核对区。
- 配对只导出公开数据；助记词备份 QR 保持独立页面，不能混入 Connect。
- 一个界面一次只显示一个 payload；较大 payload 使用统一 BC-UR 动态分片。
- 切换类型、索引或输出方式后，必须一起更新 QR、地址、路径、说明和兼容列表。
- 可复制的内容必须等于屏幕 QR 的实际内容，不能屏幕是公钥 QR、复制出来却是地址。

### 5.2 最小协议集合

本次不按钱包品牌扩展协议。采用一个 BC-UR 传输引擎；链级解析/签名是独立模块。

| 链 | 标准连接输出 | 请求 | 回传 | 额外展示 |
|---|---|---|---|---|
| BTC | `crypto-account` | `crypto-psbt` | `crypto-psbt` | 单签可以切纯地址；Pub/XPUB 都在同一账户容器内表达 |
| EVM | `crypto-hdkey` | `eth-sign-request` | `eth-signature` | 纯地址，仅默认 index 0 |
| SOL | `crypto-multi-accounts`，当前只放 1 项 | `sol-sign-request` | `sol-signature` | 当前预设路径的纯地址 |
| TRON | 一次一个地址；若现有已核验公共 UR 配对模式存在，则保留 | 公共 `tron-sign-request` 路径需按实际 SDK 实现/核验 | 对应 `tron-signature` | 默认可提供纯地址，index 0…99 |

**TRON 边界：** 本次没有授权加入 TP 的 action+JSON 或旧 `keystone-sign-request` 封装。TRON 原生交易可用 JSON 表达，不代表已经有一套被 TronLink、TP 共用的 JSON 扫码协议。编码 AI 必须盘点现有 TRON transport；只有明确支持的公共类型才能进入扫码识别表。`tron-sign-request` 的公有参考实现见 [S14]；旧 Keystone TRON 集成路线不是它的同义词。[S15]

### 5.3 `Address` 模式定义

QR payload 是地址原文，例如：

```text
bc1q...
0x...
<完整 Solana Base58 地址>
T...
```

不加 `bitcoin:`、`ethereum:`、JSON、path、金额、UUID、说明文字或 UR 前缀。上面的省略号只是本文示意，真实 QR 必须是完整地址。

此模式的提示：`Address only. No public key or derivation path is included.`

### 5.4 兼容钱包 Footer

用户期望在 QR 下看到主流钱包名称和 Logo。实现为小型本地配置驱动组件，不在 Tab 名称中堆长文字。

兼容记录至少区分：

```text
QR signing      完成配对、请求、回传的特定版本路径
Watch-only      仅确认能导入地址/观察信息
Address format  只确认恢复路径或地址生成一致
```

Footer 不能把三类混在一个无说明的“全部兼容”列表里。发布 UI 优先显示 `QR signing`、`Watch-only`；单纯路径一致的信息放简短帮助说明。

候选验证对象：BTC 的 Sparrow/BlueWallet；EVM 的 MetaMask/Rabby/imToken/Safe/Ownbit；SOL 的 Solflare/Backpack/Ownbit；TRON 的 TronLink/TP/Ownbit。**列为验证对象不是已经通过兼容认证。**

**Ownbit 显示规则：**

- EVM 可以加入候选兼容列表，但需要区分它能观察地址和能否接受当前 QR 协议。
- SOL 官方资料记录 `m/44'/501'/0'/0'`，对应本文 `Standard`；因此可把 Ownbit 归到这个路径说明下，不能据此宣称 Ownbit 已完成 UR 全流程接入。[S07]
- TRON 遵循用户本次决定：**只有 index 0 可显示 Ownbit；1–99 不显示 Ownbit**。即使后续产品变化，本版本不自动扩大这一声明。
- Phantom、Trust 的路径兼容不能直接变成扫码硬件钱包兼容 Logo。

所有钱包 Logo 静态打包；无远程图片、无 Logo CDN、无运行时下载。

---

<a id="section-6"></a>

## 6. BTC 配对与导出

### 6.1 固定页面结构

```text
Connect Bitcoin

[ Single-sig ] [ Multisig ]

Single-sig:
[ Native SegWit ] [ Taproot ] [ Nested SegWit ] [ Legacy ]

                    QR
           Verify your first address
               完整地址 / 完整路径

Export as
[ Public Key ] [ Account XPUB ] [ Address ]

当前模式对应的兼容钱包说明
```

四类 Tab 的顺序不能打乱。窄屏可以横向滚动或采用等价紧凑布局，不靠过度缩小字号解决。深浅色、较大字体都必须可用。

### 6.2 单签路径与类型

本次默认 account=0。配对的单公钥/纯地址模式固定 Receive=0、index=0。

| 顺序 | UI | Purpose | 实际脚本 | 保存/导出 XPUB 的节点 | 默认单地址路径 |
|---|---|---:|---|---|---|
| 1 | Native SegWit | 84 | P2WPKH | `m/84'/0'/0'` | `m/84'/0'/0'/0/0` |
| 2 | Taproot | 86 | 单 key P2TR | `m/86'/0'/0'` | `m/86'/0'/0'/0/0` |
| 3 | Nested SegWit | 49 | P2SH-P2WPKH | `m/49'/0'/0'` | `m/49'/0'/0'/0/0` |
| 4 | Legacy | 44 | P2PKH | `m/44'/0'/0'` | `m/44'/0'/0'/0/0` |

这些数字是派生方案中的 purpose，不是四种“原子签名算法”。`P2SH` 也不能笼统等同于 49；表中 49 特指 P2SH 包裹的单签 SegWit。BIP86 定义的是单 key Taproot 派生，不能据此推断任何 Taproot 多签均已支持。[S02][S03]

### 6.3 三种输出方式的语义

| 模式 | 内容 | 是否含 chain code | 接收方能否继续派生 |
|---|---|---|---|
| Public Key，默认 | 当前类型 `/0/0` 的叶子公钥、完整 origin path、fingerprint、脚本表达式，封装 `crypto-account` | 否 | 不应提供公开派生能力 |
| Account XPUB | 表中账户节点的公钥＋chain code＋origin＋父指纹等，封装 `crypto-account` | 是 | 可以派生账户下的 `/0/i`、`/1/i` |
| Address | 当前类型 `/0/0` 的完整地址文本 | 不适用 | 不能 |

`Account XPUB` 是**数据内容模式**，不是要求另外新增裸 `xpub...` QR 协议。当前默认仍使用 UR 账户容器。无需为了 xpub/ypub/zpub 单独增加三种 UI。

`Public Key` 可使用带 origin 的公开 `CryptoHDKey` 子结构，但不提供 chain code；不是把公钥 hex 直接作为整个二维码。不得向热端发送私钥字段、seed 或助记词。[S04]

**兼容性硬约束：** 一些 HD 钱包导入器需要 chain code 才能重建 XPUB。不要为了让默认 `Public Key` 看似可导入，暗中附带账户 XPUB。要诚实提示 `Use Account XPUB for HD wallet pairing.` 并让用户切换。默认模式的兼容列表必须通过对应实测。

### 6.4 Taproot 编码不可“只换一个路径”

Taproot 地址按正确的 internal key、tweak、输出 key 规则生成。导出公钥材料与页面地址的关系必须可复算；不能把 tweaked 输出 key 冒充账户 XPUB 中的未 tweak 公钥。

`crypto-account` 内的脚本表达式必须正确标识 `tr`。Blockchain Commons 的 output descriptor 文档定义了 `tr` 对应的标签；旧库未支持时，需要更新/补齐标准编解码并做测试，不能发明标签，也不能把 BIP86 标成 `wpkh` 或 `wsh`。[S03][S05]

### 6.5 多签导出

```text
[ Single-sig ] [ Multisig ]

[ Native SegWit ] [ Nested SegWit ]

            Cosigner account QR

Export this cosigner key to your multisig wallet.
```

| 顺序 | 选项 | 公开节点 | 脚本语义 |
|---|---|---|---|
| 1，默认 | Native SegWit | `m/48'/0'/0'/2'` | P2WSH cosigner |
| 2 | Nested SegWit | `m/48'/0'/0'/1'` | P2SH-P2WSH cosigner |

这里必须输出 **cosigner 的账户级扩展公钥**，包含 chain code。`1'`、`2'` 是脚本类别，不是签名门槛。[S02]

不增加 Public Key/XPUB/Address 开关，不显示虚构的多签地址；不让用户在冷端选 2-of-3、3-of-5 来创建热钱包多签。多签协调及完整策略由热端负责。

二维码仍使用 `crypto-account`。其内容是一位参与者的 key，不是自动附带完整 m-of-n 策略。脚本表达式采用与目标导入器验证过的标准编码；不得让 `wsh(key)` 这样的 cosigner 占位表达式进入链上脚本生成逻辑。

### 6.6 XPUB 层级限制

本次不提供：真正的 `m` master XPUB、`m/84'` 等无法跨 hardened 节点公开派生的上层 XPUB、自定义任意路径、Receive-only XPUB、Change-only XPUB。

多签节点停在 BIP48 的 `script_type'` 层；单签节点停在 `account'` 层。后续 `/0/i`、`/1/i` 用公开派生计算。每个 account=0 的钱包一共缓存六个 BTC 节点，详见 §11。

---

<a id="section-7"></a>

## 7. EVM 配对、地址和签名

### 7.1 配对 UI

不按 MetaMask、Rabby 或不同 EVM 链重复设置类型 Tab。

```text
Connect EVM

                  QR

Export as
[ Wallet ] [ Address ]

当前能力范围对应的兼容钱包
```

- `Wallet` 默认输出 `ur:crypto-hdkey/...`。
- 节点固定为 `m/44'/60'/0'`；带正确 origin 和账户公钥材料；children 为 `/0/*` 的已验证表达方式。
- 一个 EVM 账户公开节点用于各个 EVM 网络，不为 Ethereum、BSC、Arbitrum、Base 各存一份相同节点。
- `Address` 只输出 `m/44'/60'/0'/0/0` 的地址。配对页不新增 EVM 索引选择器。
- 地址浏览页可以看多个索引；不要把配对默认值误当成钱包只有一个地址。

ERC-4527 是本次协议选型依据，但其页面状态为 Stagnant；文案不得声称“所有 EVM 钱包都正式支持一个 Final 标准”。[S04]

### 7.2 请求与回传

| `eth-sign-request.dataType` | 必须处理的内容 |
|---:|---|
| 1 | Legacy transaction 的待签 RLP |
| 2 | EIP-712 typed data |
| 3 | 普通消息，采用该协议分支对应的 personal-sign 语义 |
| 4 | 已支持的 EIP-2718 typed transaction；至少包含 EIP-2930、EIP-1559 |

返回 `eth-signature`；原 request ID 必须按字节保留。JSON 只是 EIP-712 `signData` 的内容表达，不替代外层 CBOR/UR。

签名编码必须按实际 keyring 验证。内部使用明确的 `r/s/recoveryParity` 表示；消息的 27/28、typed transaction 的 parity、legacy 的 EIP-155 v 不能混用。不能盲目截断大 chainId 下的 v，也不能套用消息签名编码来签交易。历史实现差异以锁定版本的往返测试为准。

### 7.3 Safe 与 Web3

必须识别和审核 SafeTx、普通 EIP-712、personal_sign、Permit/Permit2；冷端作为具体 owner 签名，不实现 Safe 的提案服务器或多签协调。

Safe 的合约账户地址不是 owner 地址；权限阈值也不一定包含在每个请求里。部分流程可能只有交易 hash，另有部署/执行用的普通 EVM 交易。没有完整原文时，不能把 hash-only 请求展示成已核验的资产转账。[S10]

对内置解析器已认识的 Safe 批量调用、权限变更、delegatecall，要展开显示风险。签一个 permit 并不等同于登录，不能统一 Summary 为 `Sign in`。

---

<a id="section-8"></a>

## 8. SOL：三个路径、单项导出、两种签名

### 8.1 Tab 名称及固定路径

短名称采用：**`Standard` / `Trust` / `Legacy`**。完整路径显示在下面，不塞入 Tab。

| 顺序 | Tab | 本次固定路径 | 说明 |
|---|---|---|---|
| 1，默认 | Standard | `m/44'/501'/0'/0'` | 本次默认；Ownbit 官方资料记录此路径 |
| 2 | Trust | `m/44'/501'/0'` | Trust Wallet Core 文档列出的默认派生路径 |
| 3 | Legacy | `m/44'/501'` | 两级 SLIP-0010/BIP44 前缀预设；不宣称等同于所有 CLI 默认生成方式 |

**修正早期口头说法：** 不把 Trust 固定写成 `m/44'/501'`。官方 Wallet Core 文档将 `m/44'/501'/0'` 放在默认项，并把四级路径列为另一项。[S06] Ownbit 的 SOL 路径另有官方资料支持。[S07]

不同软件版本可能支持多种派生方式；`Legacy` 只是本产品的短标签，不是“所有旧钱包/CLI 都必然如此”的事实声明。不要因为两条路径都带 `501'` 就认为同一个地址。

### 8.2 导出范围

- 默认格式：`crypto-multi-accounts`，但 `keys` **只放当前 Tab 的一项**。
- 每项包含当前 32-byte Ed25519 公钥及完整 origin、fingerprint 等对应字段。
- 三个预设都在创建/导入时预先派生并缓存；切 Tab 不需要解锁。
- `Address` 模式输出当前 Tab 的 Base58 地址。
- 本次不增加一次导出全部三项的 UI，不增加 SOL XPUB 开关，不增加 SOL index 0…99。

`crypto-multi-accounts` 能装多账户，不代表“多签钱包”。Solana 公钥地址在此路线中是具体 key，而不是 BTC 式可公开派生的账户 XPUB。[S08]

### 8.3 签名

`sol-sign-request` 至少处理 Transaction / Message 两种模式；返回 `sol-signature` 的 detached Ed25519 签名和原 request ID。

Transaction 必须处理 legacy 与 v0；正确确定 required signer 的位置，支持非 fee payer、read-only signer；热端原有签名不能丢失或被覆盖。不能重新构造一笔“差不多”的 message，必须签原始待签 message bytes。[S08][S09]

Squads 的提案批准、执行等通常是链上指令，不等于把多份 Ed25519 签名直接拼成一个普通转账。若批准指令只引用 proposal account，却没有提案全文，要明确“提案内容未随请求提供”，不能假装解析到了资产去向。

Message 不得用隐式失败回退替代 Transaction：一个损坏的 transaction 不能因为解析失败就被改当普通消息签掉。

---

<a id="section-9"></a>

## 9. TRON：index 0–99 与交易签名

### 9.1 地址选择与页面

只有一块二维码区域；下面是索引**单选**控件，可以用 picker/dropdown，不做 100 个 Tab 或可多选 checkbox。

```text
Connect TRON

                    QR

Address index       [ 0 ▾ ]
Address             T...
Path                m/44'/195'/0'/0/0

Export as           [ Wallet* ] [ Address ]
```

`Wallet*` 只在确实已有公共配对 payload、且通过接收端验证时显示；没有这一路径时直接显示 `Address`，不制作看起来像兼容但无人识别的私有 JSON。

| 项目 | 决定 |
|---|---|
| 本地公开节点 | `m/44'/195'/0'` |
| 地址派生 | `/0/i` |
| 默认 index | 0 |
| 范围 | 0…99，包含两端，共 100 个 |
| 每次输出 | 一个当前选择的地址/对应公开信息，不把 100 个地址一起塞进 QR |
| Ownbit Footer | 只在 index 0 显示；其他索引隐藏 |

即使对外只给单个地址，也要在本地保存 XPUB，以便不解锁 seed 就能派生/匹配 100 个地址。100 个结果可以预先缓存。

### 9.2 签名引擎范围

必须支持 TRX 转账、常见 TRC20 操作、智能合约调用、原生账户权限多签及 `AccountPermissionUpdateContract`。其他已支持的主流合约类型不因本次 UI 改动退化。

对公共 UR 的交易分支，`signData` 的实际类型以 [S14] 为准：不能因 HTTP API 通常用 JSON，就把 protobuf 原始 bytes 当作 UTF-8 JSON。内部可统一解析成结构化交易视图。

```text
收到 QR → 解码实际 transport → 得到 raw_data 的原始 protobuf bytes
        → 解析可读视图 → 核对 txID / 原始数据 / signer
        → 审核 → 密码授权 → 签名 → 按原 profile 回传
```

必须保持原始 `raw_data` 不变；已有签名保留；根据协议返回 detached signature 或原交易加签结果，不能随便更换返回类型。

### 9.3 权限多签的关键区别

TRON 的 `owner_address` 表示被操作的账户，并不保证就是实际签名私钥对应的地址。要单独识别：

```text
operatedAccountAddress   被操作账户
permissionId             本次使用的权限
signerAddress            实际签名者地址
```

权限更新交易中出现的**新权限成员列表**不能被误用为“当前谁有权签这笔权限更新”。批准更新的是现有权限，不能让新加入者先用自己的 key 为自己授权。[S11]

离线端不能自动确认最新链上 permissions。可以依据请求的明确 signer/path 选择本地 key，但必须对无法核验的链上权限上下文做标记；不能因用户刚好持有 owner_address 对应私钥就忽略 Permission ID。

对只有 owner_address、没有可唯一确定 signer 的多签请求，不弹钱包选择器，不任意挑钱包；显示 `Signer information is missing` 并禁用签名。

### 9.4 TRON 消息签名

保留和公共接口明确对应的消息签名语义；不要把交易 SHA-256 签名规则套到消息，也不要把 EVM 的消息前缀套到 TRON。

单个成员对消息签名，不代表整个权限多签账户达到权重门槛。当前格式没有足够信息表达账户级多签消息授权时，不把成员签名标注为“多签账户签名成功”。

---

<a id="section-10"></a>

## 10. 签名支持矩阵：解析容器与真正能签分开

### 10.1 BTC 必须实现的花费类型

| 类别 | 必须覆盖的内容 | QR |
|---|---|---|
| Legacy 单签 | P2PKH，正确验证非 SegWit 前序交易材料 | `crypto-psbt` |
| Nested SegWit 单签 | P2SH-P2WPKH，验证 redeemScript | `crypto-psbt` |
| Native SegWit 单签 | P2WPKH | `crypto-psbt` |
| Taproot 单签 | P2TR key-path，正确 BIP340 签名与 tweak | `crypto-psbt` |
| 传统多签 | P2SH m-of-n，正确 redeemScript、公钥排序及增签 | `crypto-psbt` |
| Nested SegWit 多签 | P2SH-P2WSH m-of-n，验证两层脚本关系 | `crypto-psbt` |
| Native SegWit 多签 | P2WSH m-of-n | `crypto-psbt` |
| Taproot 脚本路径 | 可验证的 control block、tapleaf、受支持的阈值脚本/主流 `CHECKSIGADD` 结构 | `crypto-psbt` |

签名引擎支持 PSBT v0/v2 及 BIP371 的 Taproot 字段；不得把“成功解码 PSBT”视为上表全部已实现。[S12][S13]

要求支持多 input、多 UTXO、多个地址、Receive 与 Change 分支。保留已有部分签名、必要的未知/proprietary 字段以及原交易内容。默认回传部分签名 PSBT，不在冷端擅自 finalize 或广播。

**路径不是花费策略：** 导出 UI 使用 BIP48，不表示引擎只允许 `48'` 的公钥参与多签。只要请求路径属于本地已登记公开节点、可验证公钥一致、脚本合法，就可以处理用其他已登记路径组成的传统多签。不能单凭 `84'` 就判定“这必然只能单签”。

**完整性边界：** 未实现的任意脚本、未支持的未来 witness 版本不能静默盲签。MuSig2 等交互式聚合多签需要独立 nonce/会话实现，不能用普通 PSBT 一次加签冒充支持；若现有实现没有完成，必须明确报 `Unsupported signing protocol`，并单列能力状态，不把它藏在“Taproot 已支持”之下。

### 10.2 EVM、SOL、TRON 的基础要求

| 链 | 必做 | 不允许的偷换 |
|---|---|---|
| EVM | 普通交易、已支持 typed transaction、personal_sign、EIP-712；Safe owner、Permit/Permit2 语义解析 | 只支持转账却宣称完整 Web3；把所有消息当登录 |
| SOL | legacy/v0、Transaction/Message、正确 signer 槽位、非 fee payer 增签 | 只签第一个账户；把整个 signed transaction 当 message |
| TRON | 原始交易、多签增签、Permission ID、权限更新、公共接口消息签名 | 签 JSON 字符串；以 owner_address 代替所有 signer；无视已有签名 |

对于批量请求：逐个交易/消息建立不可变任务并审核；默认每个独立任务都需要相应密码授权。**一个 PSBT 的多个输入属于同一笔交易，可以一次授权完成本钱包所有被明确展示的输入签名；这不等于跨交易免密。**

---

<a id="section-11"></a>

## 11. 本地公开元数据：单独存储，不为匹配解锁 seed

### 11.1 每个默认 HD 钱包的缓存清单

| 链 | 必须缓存的公开材料 |
|---|---|
| BTC | master fingerprint；四个单签账户 XPUB；两个 BIP48 cosigner XPUB；各自 origin、depth、父指纹、脚本类型 |
| EVM | `m/44'/60'/0'` 账户 XPUB、origin、默认 index 0 的地址/公钥 |
| TRON | `m/44'/195'/0'` 账户 XPUB；index 0…99 的 path/pubkey/address 索引 |
| SOL | Standard/Trust/Legacy 三条路径的 path、32-byte pubkey、Base58 address |
| 钱包公共信息 | 名字、本机 ID、稳定 key ID、缓存版本、创建时间等 |

BTC 六个节点必须精确保存：

```text
m/84'/0'/0'
m/86'/0'/0'
m/49'/0'/0'
m/44'/0'/0'
m/48'/0'/0'/2'
m/48'/0'/0'/1'
```

合计是**每个默认钱包 6 个 BTC 公开节点＋1 个 EVM 公开节点＋1 个 TRON 公开节点＋3 个 SOL 具体公钥**。不是六个 seed，更不是六份私钥。

### 11.2 存储结构示意

以下为内部模型示意，不是新增 QR 协议，也不是指定必须使用某一种数据库：

```text
WalletRecord
  localWalletId
  displayName
  walletKeyId
  masterFingerprint
  encryptedSecretReference
  publicMetadataVersion
  publicMetadataStatus: ready | needsCompletion | invalid
  bitcoinPublicNodes[6]
  evmAccountNode
  tronAccountNode
  tronAddressIndex[100]
  solanaPublicKeys[3]

PublicHDNode
  originPath
  compressedPublicKey
  chainCode
  parentFingerprint
  depth
  scriptProfile
```

完整 origin 和预期 children 规则必须保存；不能只存一串 XPUB，再靠字符串猜它是在账户层还是已经进入 `/0` 分支。

### 11.3 公开不等于没有隐私价值

XPUB/地址不是可直接花钱的秘密，但会暴露地址关联。应使用合适的 iOS Data Protection 保护本地文件、关闭不必要的备份同步、禁止日志/遥测收集，并受 App Lock 的界面遮挡保护。

这些缓存应当能在 **seed 仍加密** 的情况下使用；不代表必须把整个 seed 解密后常驻内存。公钥 derivation 只允许注册节点下的非 hardened 后缀。[S01]

所有原始私钥、seed、助记词、解密后的敏感缓冲区和密码，都不能进入这里。

### 11.4 创建、导入与旧数据

新钱包在创建/导入合法授权的短暂 seed 生命周期内，一次性生成上述材料后立即清理秘密缓冲区。重新命名不改变 key ID；改密码不改变 public key；改变 passphrase 表示另一密钥身份，不能覆盖成“同一钱包换了密码”。

已有钱包缺少公开节点时，不能凭空从别的 hardened 分支 XPUB 推出来，也不能要求用户启动时连续输入 8 个钱包密码。迁移方法见 §23。

---

<a id="section-12"></a>

## 12. 自动匹配钱包：无手动选择、无全库秘密试解

### 12.1 总体流程

```text
完整接收并冻结 QR payload
   ↓
按真实类型解码；检查大小、字段、网络及签名方法
   ↓
提取 signer selectors：fingerprint / path / public key / address / script
   ↓
只使用各钱包公开缓存做匹配
   ↓
无匹配       → 只读展示可解析内容＋红色错误，不能签
唯一匹配     → 锁定显示钱包和真实路径，用户审核后输该钱包密码
多个确定任务 → 显示只读任务列表，分别授权；不变成随意钱包选择器
证据有冲突   → 报错，不能“选一个试试”
```

要区分 `No matching wallet`、`Missing signer information`、`Ambiguous wallet match`、`Wallet setup required`。它们都不能被误写成成功。

**自动匹配不是保证所有请求都带足够身份信息。** 缺失或冲突时可以明确拒绝；不能为了实现“不要选择钱包”而猜一个钱包。

### 12.2 通用校验规则

1. fingerprint 是筛选线索，不是可靠的全局唯一 ID。
2. 有完整公钥/地址时，用本地公开派生结果做逐字节匹配。
3. 有路径时必须在已登记节点覆盖范围内，不能任意跨 hardened account 搜索。
4. 对请求中同时存在的 selector 做一致性检查；不能 address 指 A、path 指 B 时只挑一个方便字段。
5. 匹配成功并不自动签；详情里显示钱包名称、稳定后缀、签名地址和实际路径。
6. 真正解密后再次验证派生公钥等于此前选中的公钥，防止公开缓存与秘密钱包错配。
7. 外部 `origin` 字符串只是显示线索，不是可信身份认证；不能写成“已验证来自 MetaMask”。

### 12.3 EVM

**正常请求：** 用 path 找到本地 EVM 节点下的 key，有 address 则计算并比较。支持注册账户下的 `/0/i`，不限定为 index 0。

**请求有 path、fingerprint，但没有 address：** 这在实际 QR keyring 中可能出现。若 fingerprint 在本地唯一、路径在节点范围内，可形成一个明确候选，显示“按公开 key metadata 定位”的地址，并在密码解密后重新核对；不能虚称已用请求 address 验证。若 fingerprint 缺失或碰撞导致无法唯一定位，拒绝。

**只有地址、缺失路径：** 按用户决定，**只比较每个钱包 EVM index 0**。不遍历任意地址索引，不用最近浏览索引代替。若 profile 本身要求必须有 path 却缺失，应先判定格式错误，而不是用回退让不合法包变合法。

**只有 path、没有任何可区分钱包的线索：** 多钱包之间 path 可相同，不能挑首页第一个钱包。

`eth-sign-request.address` 在标准中是可选项，不能实现成“所有请求一定带 address”。[S04]

### 12.4 SOL

先检查 `sol-sign-request` 的 path、source fingerprint、可选公钥/地址与本地三项缓存的关系。交易类还要从真实 message 的 required signer 集合核对签名位置。

有些实现不会填写可选 address，不能把“必有 signer pubkey 字段”当作前提。Message 本身也未必包含公钥，必须使用 envelope 的 selector。

无 path 但有合法 signer public key/address 的已支持 profile：只匹配三个预设缓存。不能临时解锁所有 seed 搜索路径。

交易中出现本地地址不代表它是 signer：必须核对 message header 的 required signers，不能给只收款或普通 readonly account 签名。[S09]

### 12.5 TRON

- 有 signer path 和可验证 address：用 TRON XPUB 派生并匹配，index 必须 0…99。
- 无 path、有明确 signer address：在本地 100 个地址索引里查找。
- 普通账户交易可利用 owner_address 做一致性核对；权限多签不能把 owner_address 当成必然 signer。
- 只有 owner_address 而权限信息不足以唯一确定本地 signer：报错，不请求用户选择钱包。
- 明确多签成员上下文可以辅助匹配，但“由热端传来”不等于已验证当前链上状态。[S11]

### 12.6 BTC：正常 PSBT 匹配

读取每个 input 的 BIP32 derivation，或者 Taproot BIP32 derivation：公钥、master fingerprint、完整路径；在本地六个已登记节点下派生后比较。路径中的 Receive/Change 和 index 来自请求，不来自当前导出页面。

还必须验证 input 的 UTXO/script 与该 key 的实际花费关系；只匹配 fingerprint 和 path 不够。Taproot 要正确区分 internal key、输出 key、tapleaf 与 tweak。[S12][S13]

**缺失路径的有限回退：**

- 用户确定的四种单签只尝试各自 **Receive 0 / index 0**，即 `<账户节点>/0/0`。
- 不扫 `/0/1…`，不扫 Change，不穷举账户，不打开手动钱包选择器。
- PSBT 通常不是“直接给一条地址”；要用其中的 UTXO scriptPubKey、公钥或脚本材料，与本地重建结果比较。
- 多签若无 derivation，只能在脚本明确提供 cosigner 公钥等足够材料时，尝试已缓存 cosigner 节点的 `/0/0` 并验证；不能仅凭一个 P2SH/P2WSH 地址定位本机成员。
- 找不到就按规则报错，不悄悄扩大搜索范围。

### 12.7 一笔 PSBT 涉及多个本地钱包

PSBT 可以包含多个输入及多个本地可签参与者，不能为了页面只有一个 Wallet 字段就选错 key。

实施方案：生成不可更改的 `SigningPlan`。如果只有一个本地钱包，显示一张只读卡；如果确定涉及两个不同本地钱包，显示两项固定任务，分别审核并分别输入对应钱包密码。绝不能一次输入钱包 A 密码后顺便签钱包 B。

同一笔交易内，同一个钱包的多个输入可在一次授权中完成，界面必须显示本次实际要签哪些输入。外部参与者未签不属于错误；返回部分签名 PSBT。

这是多签完整性要求，不是重新引入签名钱包选择器。若仅仅因为重复导入相同 seed 或指纹碰撞而存在歧义，则拒绝并引导在 Wallets 页面处理重复记录。

### 12.8 签名与 UI 选择完全解耦

不得以以下状态作为密钥选择依据：最近使用的钱包、最近浏览地址、上次导出的 coin、当前 BTC Tab、当前 TRON index、列表排序。

签名的唯一依据是当前请求、本地公开索引和可验证的实际花费/签名条件。

---

<a id="section-13"></a>

## 13. 签名页：Summary → Details → Wallet → Authorize

### 13.1 页面顺序

```text
Review request

[ 大号 Summary：动作 / 金额 / 目标 ]
[ 重要风险提醒，如有 ]

Details
  Network / Chain ID
  Recipient / Contract / Program
  Amount / Fee / Nonce / Method
  Path / Inputs / Permission 等

Signing wallet
  Wallet name · stable ID
  Signing address
  Derivation path
  （只读，不可切换）

[ Sign ] → 输入这个钱包的密码
```

不必把 `Summary` 单词做成占很多空间的标题，重点是顶部结论清晰、有可读层级。

### 13.2 Summary 文案实例

以下是 UI 模板，不是真实交易记录：

| 场景 | 推荐 Summary |
|---|---|
| 原生币转账 | `Send 0.1 ETH` / `To 0x1234…abcd` |
| 内置 Token 可识别 | `Send 100 USDT`，使用本地图标并展示目标 |
| Token 不在内置表 | `Token transfer` / `Contract 0x1234…abcd` / `Raw amount: 1000000` |
| ERC20 approve | `Approve token spending`，展示 spender、额度及无限授权警告 |
| EIP-712 Permit | `Authorize token spending`，展示 spender、金额、期限，不写成登录 |
| Safe owner 批准 | `Approve a Safe transaction`，能解析时列出实际操作 |
| TRON 权限更新 | `Update account permissions`，显示门槛/成员变化 |
| SOL 提案批准 | `Approve a multisig proposal`，内容缺失时额外提示 |
| 普通消息 | `Sign a message`，展示真实文本/hex，不能只显示 hash |
| 无法完整解析 | `Contract interaction` 或 `Transaction request`＋醒目警告 |

### 13.3 地址和金额展示

Summary 可以缩写地址；Details 必须能查看和复制完整地址。不能只显示开头结尾而无法展开，不能用来源不明的联系人名掩盖地址。

对 decimals 已验证的资产采用整数/十进制精确格式化，不能用 Double/Float 处理金额。Summary 不得四舍五入到让小额看成零，也不能隐藏有意义的精度；原始整数可在详情查看。

未知 Token 不猜 USDT/USDC、不默认 decimals=18、不把 Token 合约地址当接收地址。ERC20 外层 `to` 是合约地址，真实接收者通常在 calldata 中，要分别显示。

### 13.4 网络可读化

至少内置：

| Chain ID | 展示 | 原生币 |
|---:|---|---|
| 1 | `1 (Ethereum)` | ETH |
| 56 | `56 (BNB Smart Chain)` | BNB |
| 42161 | `42161 (Arbitrum One)` | ETH |
| 8453 | `8453 (Base)` | ETH |

Arbitrum One/Base 的 ID 与原生币信息按官方链文档校验。[S16][S17] BTC、TRON、SOL 展示清晰的网络名称，不增加 Mainnet 下拉框。

其他现有支持的 EVM 主网可保留在本地已审查网络表中；不要把“本次四个网络有 Token 表”错误实现成“其他主网的通用 EVM 签名全部删除”。未知且无法判断主网性质的 network/chainId 不静默放行，显示不支持。

### 13.5 匹配失败

仍可展示**已经安全解析出来**的请求信息；钱包区域使用红色文本：

```text
No matching wallet
This request does not match a supported key in your wallets.
```

Sign 禁用；不显示“选择其他钱包”“强行签名”。若原始 payload 连结构都不合法，不为了展示交易而继续猜测字段。

---

<a id="section-14"></a>

## 14. 最大化本地解析与风险分级

### 14.1 四类结果

| 状态 | 含义 | 签名行为 |
|---|---|---|
| Fully decoded | 在支持范围内解析出动作，关键内容由原始待签字节绑定 | 常规审核＋密码 |
| Partially decoded | 结构/签名规则有效，但一部分业务语义未知 | 明确列出未知部分；逐请求风险确认＋密码 |
| Opaque but structurally valid | 已知签名方法和精确 bytes，但无法解释业务内容 | 高风险提示，显示目标/方法/hash/原始数据；仅在该已支持方法允许的审查模式中确认 |
| Invalid / unsupported | 结构损坏、字段冲突、签名算法未知、关键输入缺失、无法验证 key 或不支持的协议 | 必须拒绝，风险勾选不能绕过 |

“尽量解析”不是“随便能生成一个 signature 就允许签”。警告不能替代 UTXO、脚本、签名者、公钥或原始数据完整性校验。

不增加永久开启的 Blind Signing 总开关。部分解析的确认只绑定**这一份不可变请求**，不能沿用到下一笔。

建议警告：

```text
This request could not be fully decoded.
Some effects cannot be verified offline. Continue only if you understand the request.
```

### 14.2 解析器覆盖方向

**EVM：** 原生币、ERC20 transfer/transferFrom/approve、ERC721/ERC1155 常见转账及 setApprovalForAll、EIP-712/Permit/Permit2、SafeTx、已知 MultiSend/批量操作、部署与权限相关调用。能识别 selector 只是第一步，不能由此保证目标合约实现无恶意。

**TRON：** Transfer、TriggerSmartContract 中的常见 TRC20 语义、AccountPermissionUpdate、资源/质押/委托等现有支持的常见操作。权限变更优先展示账户、permissionId、threshold、keys/weights、允许操作。

**SOL：** System Program、SPL Token/Token-2022 已实现指令、关联 Token 账户、Compute Budget、常见质押和授权变更、已知 Squads 指令。对多个 instruction 逐个解释，不只看第一条。

**BTC：** 全部输入输出、手续费、找零证明、签名数量/门槛（能从受支持脚本确定时）、sighash 风险、Taproot 路径及脚本约束。

### 14.3 离线解析无法凭空取得链上状态

以下不得假装“已经查证”：

- Safe 当前 owners/threshold、代理合约当前实现和最新权限。
- TRON 当前权限权重及是否已满足签名门槛。
- SOL Address Lookup Table 当前内容、proposal account 全文。
- Token 税费、实际成交数量、余额、交易模拟结果、区块确认状态。

热端可以提供补充资料，但要标记为 supplied/unverified；只有能和签名字节或可信本地登记信息绑定的资料，才用于“已验证”显示。

尤其 SOL 的普通 unchecked token transfer 未必直接含 mint，不能看到一个 token account 就拿它去 Token mint 表查询并乱算 decimals。v0 的 ALT 缺失时不能伪造 program/recipient；金额/目标无法确认必须如实提示。严重缺失导致无法确认安全签名条件时拒绝。[S09]

---

<a id="section-15"></a>

## 15. 内置离线 Token Registry 与图标

### 15.1 本次必须打包的生态

Ethereum、BNB Smart Chain、Arbitrum One、Base、TRON、Solana。

本次讨论确定的是每链核心主流资产，规模约 Top 30/50/100，不是要求 App 做实时市值排名。**执行建议初始目标**：Ethereum 100、BSC 50、Arbitrum 50、Base 50、TRON 30、SOL 100；数量不是安全白名单门槛，不为凑数加入没有可靠资料的 Token。

正式交付必须有实际 Token manifest 和实际本地图标，而不是只有字段结构。数量有差异时在实施报告说明具体覆盖和原因。**本 MD 本身不声称这些资源已经下载完成。**

### 15.2 字段

```json
{
  "schemaVersion": 1,
  "registryVersion": "2026-09-21.1",
  "assets": [
    {
      "chainFamily": "evm",
      "chainId": "1",
      "assetAddress": "<完整且核验过的合约地址>",
      "name": "<核验后的名称>",
      "symbol": "<核验后的符号>",
      "decimals": 6,
      "iconAsset": "token_eth_example",
      "metadataSource": "<构建阶段来源>",
      "verifiedAt": "<核验日期>",
      "iconSha256": "<图标文件摘要>"
    }
  ]
}
```

这只是结构示例，不能把占位字段打进发布版本。TRON 使用规范化合约地址；SOL 使用 mint，并记录必要的 token program 信息。

唯一匹配键：**链/网络＋完整合约地址或 mint**。同名 symbol、同图标、不同链上的同地址文本，都不能自动合并。

### 15.3 资源获取和验证

在开发/构建阶段整理官方 Token 资料、可信 Token List 或资产仓库；交叉核对网络、地址、decimals、symbol。保存来源和版本。图标在开发时下载、检查许可、转换为安全的静态资源后进入工程。

运行时只读取 Bundle，不访问来源 URL；manifest 中的来源用于审查，不是自动更新入口。去掉 AsyncImage/远程 SVG/网页 favicon 等会产生联网行为的实现。

图标缺失时使用本地通用 Token 图标，不尝试联网补图。SVG 如含外部资源、脚本或复杂不受控内容，应构建时转换为经过检查的静态图像。

### 15.4 显示优先级

```text
原始 bytes 明确资产标识
  → 精确匹配内置 Registry
  → 使用内置 symbol / decimals / icon
  → 格式化可读金额

无法明确资产标识或不在表中
  → Unknown token / Token transfer
  → 显示合约或 mint（如果确实知道）
  → 显示 raw amount，不猜小数
```

二维码自带的 symbol/decimals/iconURL 不得覆盖内置项。发生 decimals 冲突要显示明确风险并按具体指令规则处理；不能挑一个更好看的金额。

Token 命中内置列表仅说明其显示资料可识别，不表示该交易安全、该资产无风险或合约永不升级。无需内置价格，不显示由过期价格推测的法币金额。

---

<a id="section-16"></a>

## 16. 签名授权：彻底移除 Unlock Vault

### 16.1 删除内容

删除全局 `Unlock Vault`、`Unlock Wallet`、解锁倒计时、全局解锁状态徽章、先解锁再操作的前置流程。不得把它换个名字继续保留，例如 `Enable signing for 10 minutes`。

地址浏览、公开 QR 配对、公开索引匹配不需要解锁 seed。备份、私密导出、改密码、签名等敏感动作仍独立授权。

### 16.2 一次签名的生命周期

```text
用户审核确定的请求和固定钱包
   ↓
输入该钱包密码（不能用另一个钱包密码）
   ↓
验证并解密最小必要秘密
   ↓
重新核对派生公钥和 SigningPlan
   ↓
生成当前任务的签名，并本地验签
   ↓
立即清理 seed/private key/password 的临时持有
   ↓
只保留可展示的签名结果 QR
```

密码失败不换钱包；密码不可保存到可供下一次签名复用的属性。Face ID 成功、刚用钱包密码打开 App、刚签完上一笔，都不能免除下一笔密码。

### 16.3 中断与结果展示

进入后台、App Lock 出现、用户取消、扫码包被替换时，立即取消敏感操作并清理秘密；不要等 App Lock 的 120 秒宽限期。

已有签名结果的 QR 再次展示是展示公开签名材料，不是重新签名；可以在 App 隐私锁规则下查看，无需制造第二份签名。点击“重新签署新请求”则必须重新审核和授权。

Swift/托管层的拷贝和字符串不能被承诺可完美擦除；应减少秘密对象拷贝、使用适当安全缓冲区及最小作用域。不得将 seed、密码或整个请求打印到日志。

---

<a id="section-17"></a>

## 17. App Lock：Face ID 只锁界面

### 17.1 唯一设置

Settings 增加：

```text
App Lock                                  [ Off ]
Protect access to the app with Face ID.
Signing always requires the wallet password.
```

默认 Off。用户主动开启；不在创建每个钱包时要求设置一遍 Face ID，不添加“签名使用 Face ID”的选项。

通过 iOS LocalAuthentication 使用 Face ID，应用只消费系统认证结果，不收集人脸影像、不自行做人脸识别。[S18]

### 17.2 固定规则

| 场景 | 行为 |
|---|---|
| 未开启 App Lock | 不自动弹 Face ID；每次签名仍需要密码 |
| 开启后的每次冷启动 | 先认证再显示钱包/Activity，不能先闪现首页 |
| 进入后台不足 120 秒后返回 | 不重复认证；后台期间仍立即遮挡快照 |
| 进入后台达到或超过 120 秒后返回 | 必须重新认证 |
| App 被杀死后重开 | 冷启动规则，不能沿用持久化“已解锁” |
| Face ID 取消/失败 | 保持锁定，提供重试与钱包密码入口 |
| Face ID 不可用/系统锁定 | 提供钱包密码入口，不死锁 |

时长固定 **120 秒**，不提供立即/1 分钟/5 分钟等设置。这个时间表示后台宽限期，不是签名密钥在内存里保留时间，也不是每两分钟打断前台正常使用。

尽可能使用单调时钟记录后台间隔；时间倒退、状态不确定、进程重启按需要重新认证处理。系统 Face ID 弹窗造成的临时 inactive 不应被错误算作一次完整后台离开，避免循环弹窗。

### 17.3 备用解锁

```text
App locked

[ Try Face ID Again ]
[ Use Wallet Password ]

选择任意一个已有钱包 → 输入该钱包密码 → 验证成功 → 进入 App
```

这是**唯一允许为了认证选择钱包的地方**，不等于签名页的钱包选择。任何一个有效钱包密码可解除整个 App 的界面隐私锁，这是本次明确的产品决定；知道较弱钱包密码的人也能进入界面，因此它不应被描述为所有钱包共同提供的多重保护。

备用认证只调用钱包凭据验证路径。如果现有加密格式必须解密才能验证，也只能最短生命周期完成校验后立即销毁，不能把 seed 放到签名 Session 或全局属性里。

认证成功只设置进程内的 `AppAccessState`，不设置 `walletUnlocked = true`，不缓存密码，不自动打开该钱包。

### 17.4 设置及异常

- 开启 App Lock 前验证 Face ID 可用并完成一次成功认证；不可用时解释原因，不创建无法解锁的状态。
- 关闭 App Lock 需要当前合法 App 访问认证；不能从遮挡页面或未认证深链直接关闭。
- 第一个钱包创建前不能启用基于钱包密码兜底的 App Lock；如果最后一个钱包被合法删除，清除 App Lock 启用状态并回到 Welcome，避免空钱包死锁。
- Face ID 未授权、无注册面容、系统锁定、设备无 Face ID 都要有清晰失败处理。是否兼容已有 Touch ID 实现取决于现有项目，不新增第三种 App 主密码。
- 密码错误使用合理限速/退避，不能自动抹除用户钱包；不能以失败为由切换钱包或猜测密码。
- App Lock 的锁屏只展示解锁所需最少信息；备用钱包选择可显示名字/稳定后缀，不暴露地址列表或 Activity 详情。

### 17.5 隐私遮挡独立于 App Lock

只要 App 进入后台，就覆盖钱包地址、历史、助记词等可见内容，避免系统多任务预览泄露。即使 App Lock 默认关闭，这个快照遮挡也应保留。

120 秒内返回可移除遮挡恢复正常界面；超过时先显示锁屏，不先还原一帧私密页面。

---

<a id="section-18"></a>

## 18. 主网范围与内部网络校验

### 18.1 用户界面

删除产品中的 Mainnet/Testnet/Devnet 切换、网络环境选择页、测试币入口和常驻 Mainnet 标签。链名称直接显示 Bitcoin、Ethereum、BNB Smart Chain、Arbitrum One、Base、TRON、Solana。

开发者文档和单元测试仍可以包含这些技术词，不能用全库字符串替换破坏第三方协议、测试向量或原始数据展示。

### 18.2 内部策略

内部保留 network/chainId，不能因为 UI 不显示 Mainnet 就删除防跨链校验。默认主网路径、地址前缀和本地网络表要一致。

- 明确包含不支持网络标识的请求拒绝，用户提示 `Unsupported network`。
- EVM 交易的 chainId 从真实待签结构读取，外部 envelope 的 chainId 若冲突则拒绝；不能用 UI 选择的链覆盖待签字节。
- EIP-712 有 domain.chainId 时核对；没有 chainId 的消息，不填一个假的 `1` 来冒充已验证网络。
- 不能把“没有网络字段”等同于“确认是主网”。BTC 原始交易、SOL message、TRON 原始内容以及某些消息协议，并不总能离线证明目标网络。对此保留协议原义，详情必要时标记 `Network context not included`。
- 测试只使用公开测试 seed、虚构 UTXO/块引用或受控离线 fixtures；不能为验收动用真实用户资金，也不能因为测试网 UI 被移除就删除所有自动化测试。

**对用户的产品范围是主网，不是宣称离线端能为所有签名方法证明最终广播网络。**

---

<a id="section-19"></a>

## 19. 完全离线：架构、移除项与文案

### 19.1 必须删除

删除 Reachability/NWPathMonitor 等网络状态检测、是否联网的警告、红绿连接灯、断网重试弹窗、网络权限引导、定时网络状态轮询。

设备有 Wi-Fi/蜂窝网络时，BitTool Signer 仍正常工作，也不显示网络状态。App 自身不需要为展示“建议断网”而检测设备状态。

### 19.2 发布 target 不得包含联网业务

不得调用 RPC、HTTP、WebSocket、DNS 探测、远程图标、在线 ABI、价格接口、广告/统计/崩溃上传、远程配置、网页脚本、WalletConnect relay 或在线更新器。

不要只审查显式 `URLSession`，还要检查 SDK 自动行为、图片加载器、WebView、Background Tasks、CloudKit/同步配置及间接依赖。ATS 是连接安全配置，不是“无网证明”。

构建脚本可以在开发机器上联网收集公开 Token 和图标；必须与 App runtime target 隔离，发布包只带静态产物。

### 19.3 iOS 的准确表达

不向用户许诺“系统因未授予网络权限而从根本上阻止所有网络访问”。实现目标和文案统一为：

```text
Built to work entirely offline.
Keys and signing stay on this device.
No network connection is required.
```

若工程审计确认没有运行时网络连接，可以写 `BitTool Signer does not make network connections.`。不要在没有审计时把“设计上不用”升级成“绝不可能联网”的系统级保证。

不要使用 `We won't upload your seed to iCloud` 这种暗示 App 有云端上传工作流的核心宣传。核心表达是本地、离线、没有在线账户或云端签名服务。与此同时，工程上仍要真实配置存储和备份边界，而不只改文案。

### 19.4 官网法律链接的唯一边界

按用户要求保留静态官网 URL。用户主动点击时，**交给系统外部浏览器**，不在 App 内使用 WKWebView/SafariViewController 加载网页，不预加载，不探测网站是否上线，不添加跟踪参数，也不传任何钱包信息。

外部浏览器是否联网由用户和系统决定；这不允许 BitTool Signer 引入任何内部网络流程。必要的提示是 `Opens in your browser.`，不做网络状态检查。

---

<a id="section-20"></a>

## 20. 启动视觉：不空白、不闪白、不人为延时

使用现有 Logo 和 slogan。新增系统 Launch Screen/与之连续的首帧视觉，适应系统 Light/Dark Appearance。

要求：

- 不增加固定 2 秒、3 秒等广告式停留。
- 深色模式不先出现大白底；从 Launch Screen 到 App 首帧、App Lock、Welcome 的背景色连续。
- Logo、文字和背景使用 Asset Catalog 的明暗资源或等价原生实现；不要运行时下载。
- 启动阶段不初始化联网 SDK，不阻塞在在线配置或 Token 资源获取。
- 若现有 App 有自己的主题覆盖，需要确保与系统 Launch Screen 的衔接；不能把“系统无法读取 App 内用户偏好”的差异掩盖成白屏。
- 最低 iOS 版本沿用现有工程；使用当前部署目标实际支持的启动配置，不为本需求强行升级系统门槛。

启动页保持静态、轻量。动画只用于后续本地 onboarding，不影响快速可交互。Apple 启动设计资料见 [S19]。

---

<a id="section-21"></a>

## 21. Welcome、首次引导、创建/导入衔接

### 21.1 Welcome

无钱包时不进入空钱包列表首页，也不展示一个没有意义的 Unlock Vault。

建议内容：

```text
BitTool Signer
[已有 slogan]

An offline signer for Bitcoin, EVM, Solana and TRON.
Keep your keys on this device. Review and sign with QR codes.

[ Create Wallet ]
[ Import Wallet ]

Terms of Use · Privacy Policy
```

Create/Import 是两块主要操作区域，点击后保留用户选择的 intent。首次引导结束后，直接继续对应流程，不能又让用户重选一次。

### 21.2 固定三页首次引导

仅首次从 Welcome 发起创建/导入时出现。三页都为本地图文，可以加很轻的原生动画，尊重 Reduce Motion。

**第 1 页：Offline by design**

```text
Your keys stay on this device.
BitTool Signer works without a network connection.
```

本地插图：离线签名器、密钥和二维码；不出现服务器处理密钥的图示。

**第 2 页：Open source. Built for wallet compatibility.**

```text
Review and sign requests from supported wallets.
Use one offline signer across Bitcoin, EVM, Solana and TRON.
```

展示经过验证的少量核心钱包 Logo；候选方向为 MetaMask、Safe、Sparrow、BlueWallet、Solflare/Backpack。不为凑满 Logo 显示不支持的当前路径。不声称“全部 DApp”“所有钱包”“已审计”或“100% secure”。`Open source` 文案需要发行前确实有可访问的源代码及许可证，不能用尚未公开的仓库假装已经开源。

**第 3 页：Prepare your offline device**

```text
For stronger isolation, use a dedicated device and turn off its network connections.
Enable Airplane Mode, then confirm Wi-Fi, cellular data and Bluetooth are off.
Keep your recovery phrase private. Anyone with it may control your funds.
```

此处提供设备层面的安全建议，不探测设置、不报告网络状态、不要求 App 有网络权限。飞行模式可能保留用户此前的 Wi-Fi/蓝牙设置，所以文字要求确认关闭，不能仅用飞行模式图标替代实际隔离。

按钮为 `Next`、最后 `Continue`。本次把安全说明作为必要步骤，**不提供一键跳过全部安全说明**。这覆盖此前助手随口提出的“可跳过”建议。

### 21.3 一次性标记

使用本地 `onboardingVersionCompleted` 等标记；完成第三页后记录。用户中途退出，下次继续/重进未完成引导；不因看了第一页就标完成。

只在真正创建/导入成功、钱包和公开缓存完成原子写入后进入首页。失败或取消仍留在创建/导入/Welcome 流程，不出现半个钱包卡片。

后续添加第二个钱包不重复强制三页；帮助入口可再次查看安全说明，但不新增冗余设置项。

### 21.4 法律链接占位

本次固定 URL 形状如下，网站尚未上线也不在 App 内验证可达性：

```text
Terms of Use
https://bittool.com/signer/en/terms-of-use

Privacy Policy
https://bittool.com/signer/en/privacy-policy
```

用户口头说的 `privacy policy` 作为网站路径时规范化为连字符形式，不在 URL 里加入裸空格。集中在一个常量文件，后续官网上线若路径变化可以一次修改。

只保留链接，不自动增加条款同意复选框或登录流程。法律正文的正式内容另行发布，本文件不伪装已经形成法律文本。

---

<a id="section-22"></a>

## 22. Scan、Activity 和 Settings 的具体修改

### 22.1 Scan

- 大扫码图标和周围主要卡片区域都可点；文字按钮同样进入唯一的扫码入口。
- 保持明确的可访问性标签，例如 `Scan signing request`；支持 VoiceOver。
- 相机权限只在需要扫码时请求；拒绝权限要有系统设置指引，但不增加网络权限。
- 连续点击防重复 present；首次权限弹窗/Face ID 弹窗和 App 生命周期互不造成循环。
- QR 完整重组前不进入签名审核，不把片段当完成请求。

### 22.2 Activity

保留本地操作记录，但删除 Unlock Vault/Wallet 控件和全局解锁提示。

记录可以包含本地时间、链、方法、签名钱包 ID、请求 hash/ID、结果类型、解析风险和最小摘要；不得保存密码、seed、助记词、明文私钥。

使用 `Signed`、`Signature created`、`Cancelled` 等本地状态；BitTool Signer 不广播，不能显示自己无法知道的 `Confirmed`、`Broadcast successful`、余额变化或链上是否执行。

是否保存原始请求和签名 QR 沿用经审查的本地隐私策略：尽量最小化数据，必要时只保存可重新显示的结果；不把完整消息私密内容作为默认日志。Activity 受 App Lock 统一保护，不另有“钱包解锁后才看历史”的全局状态。

### 22.3 Settings

移走 Connect 主入口；增加 App Lock；保留现有主题、About 等合理功能。删除网络状态检测相关设置、网络模式/Testnet/Devnet、全局 Unlock Vault、记住密码和生物识别替代签名等设置。

About 的文案遵循完全离线原则；不添加自动检查更新、在线客服网页、数据同步等行为。

---

<a id="section-23"></a>

## 23. 现有数据迁移与不回归要求

### 23.1 最优先保护现有用户数据

不能通过重装、清空数据库、重新生成 seed 或强制用户重导助记词来实现新 UI。保留现有加密秘密数据、钱包名称、密码和已支持的合法派生资料。

先读取实际 schema，再设计升级版本；本文不假定项目当前数据库已经叫 v1 或 v2。采用原子写入、失败可重试、幂等迁移。不要生成含明文秘密的临时备份。

### 23.2 缺失公开缓存

有足够现有 XPUB/公钥就直接迁移；缺少某条 hardened 子树的资料时，标记该钱包 `Wallet setup required`。

在该钱包卡片/详情提供 `Complete setup`。用户为**这个确定的钱包**输入一次密码，补齐全部公开索引后立即清理 seed。不弹全局钱包选择器，也不要求 8 个钱包一次性全部解锁。

如果在某次合法的该钱包敏感操作中已经获得了 seed，可顺便完成缺失公开缓存，但不能把成功 App Lock 认证升级为永久解锁。

签名时缺少足够公开信息就禁用签名并说明 setup required。不能扫描所有加密库、试所有密码或临时解锁所有钱包来匹配。

### 23.3 重复导入与身份冲突

新导入相同有效 seed 时，基于完整稳定 key ID 检测重复，提示已有钱包，不默认再创建第二份无法区分的记录。旧数据若已有重复项，不自动删除用户数据；迁移报告列出，并在签名匹配出现歧义时拒绝。

短显示后缀或 4-byte fingerprint 相同不意味着同一钱包，必须比较真实公钥/长身份。

### 23.4 已有功能不受破坏

已有 BIP39 输入、粘贴、助记词备份、passphrase、加密格式和安全随机数实现，除本文明确改变外保留。App 当前仅英文界面，不意味着把已有多语言 BIP39 词表或历史恢复能力删除。

如果现有工程确实包含非 HD 私钥导入钱包，要单独盘点，不为它伪造 XPUB。对非 HD 类型的支持边界在实施报告说明，不能以字段缺失为由破坏原私钥。

创建/导入若原来有“用 Face ID 直接签名”的选项，按本次决定删除；Face ID 只保留 App Lock。

---

<a id="section-24"></a>

## 24. 建议的内部模块与状态边界

沿用现有代码位置；下面是职责划分，不要求重新起一个工程：

| 模块 | 职责 |
|---|---|
| WalletRepository | 钱包集合、名字、稳定 ID、原子持久化；不保存 current wallet |
| PublicKeyIndex | 六个 BTC 节点、EVM/TRON 节点、SOL 三项；公开派生及查找 |
| QRCodec | BC-UR、CBOR、类型路由、分片和大小限制；无钱包密码 |
| PairingPresenter | 当前明确 walletId 的 coin/profile/outputMode/index → 精确 payload |
| RequestParser | 请求 → 不可变原始 bytes＋结构化视图＋风险 |
| WalletResolver | 只读公开索引 → 签名任务或明确错误 |
| SigningPlan | 锁定请求 digest、钱包 ID、路径、input/signer 槽位和签名方式 |
| SigningService | 单次密码验证、短期秘密使用、签名与验签、立即清理 |
| AppAccessController | Face ID、120 秒后台宽限、钱包密码兜底；不持有签名 key |
| TokenRegistry | 静态资产显示资料，不能自动联网补信息 |
| CompatibilityRegistry | profile/mode/path/index/method/版本 → 可展示钱包能力 |
| ActivityRepository | 最小本地记录；无广播状态推断 |
| OnboardingRouter | Welcome、首次说明、创建/导入 intent、首个钱包成功后路由 |

### 24.1 不可变 SigningPlan

```text
SigningPlan
  payloadDigest
  originalPayloadBytes
  protocolProfile
  chainContext
  parsedSummary
  riskFlags
  tasks[]
    walletKeyId
    localWalletId
    exactPath
    expectedPublicKey
    targetInputsOrSignerSlot
    signatureAlgorithm
    signingBytesDigest
```

用户审核后、密码输入期间，不得被新扫码、导航切换或异步任务替换原请求。真正签名时核对 digest 与原计划一致。

### 24.2 资源与输入防护

所有外部 QR 都是不可信输入。设置总 payload、分片数、CBOR 深度、PSBT 输入数、EIP-712 嵌套和数组规模等合理上限；超过时给明确错误，不崩溃。

拒绝重复冲突 key、不合法长度、整数溢出、负金额、错误公钥/曲线、CBOR 类型错配。保留需要保留的未知字段，但未知字段不得改变 UI 已承诺的签名语义。

相同 UR 会话的分片要严格归组；QR CRC32 只用于传输错误检测，不作为真实性或安全签名验证。Raw Address 入口、助记词导入入口、交易签名入口必须分开，不能扫描到任意字符串就“尽力当交易”。

---

<a id="section-25"></a>

## 25. 自动化测试与验收清单

### 25.1 钱包与导航

- [ ] 创建 8 个钱包，首页全部显示，无 active/default wallet。
- [ ] 任意重命名、排序不会改变钱包稳定后缀、公钥或签名归属。
- [ ] 每张卡片的 Connect/Addresses 指向自己；详情也有入口。
- [ ] 从 A 的页面返回后扫描 B 的请求，正确锁定 B。
- [ ] 无钱包进 Welcome；有钱包不重复 Welcome；第一个钱包保存成功后才进首页。
- [ ] 最后一个钱包删除后回 Welcome，无 App Lock 死锁。

### 25.2 BTC 配对

- [ ] 单签四个 Tab 按 84、86、49、44 排列，84 默认。
- [ ] 默认 Public Key 为真实 `/0/0` 叶子 key，且没有 chain code/额外账户 XPUB。
- [ ] Account XPUB 的 origin 停在正确账户层，能复算 Receive 与 Change。
- [ ] Address QR 只有完整地址文本。
- [ ] 多签默认 type 2，可切 type 1，实际 key 跟随路径变化。
- [ ] 多签始终为 cosigner XPUB，不显示最终多签地址或三选一开关。
- [ ] Taproot 的 internal key、tweak、地址和 UR 脚本类型相互一致。
- [ ] 只要输出模式不同，兼容 Footer 就按当前真实能力显示。
- [ ] 样例由上游/独立编解码器复核，不只用自己 encode 再自己 decode 证明正确。

### 25.3 BTC 签名

- [ ] 四种单签及 P2SH、P2SH-P2WSH、P2WSH 多签分别通过独立验签。
- [ ] Taproot key-path 与支持的 script-path 阈值脚本分别有测试。
- [ ] PSBT v0/v2、多个 input、不同地址、Change 分支均覆盖。
- [ ] 加签后原 input/output、已有签名、必要未知字段不变。
- [ ] 使用 84 路径 key 构造的合法多签不会仅因不是 48 而被拒绝。
- [ ] 无路径只回退 `/0/0`；index 1 的无路径请求不被错误签成 index 0。
- [ ] 伪造金额、错误前序 tx、错误 redeem/witness script、Taproot control block 不匹配被拒绝。
- [ ] 两个本地钱包参与的请求生成两项固定任务，需分别授权。
- [ ] 不支持的聚合签名协议明确报错，不能当普通 Schnorr 签名处理。

### 25.4 EVM / SOL / TRON

- [ ] EVM Wallet QR 为账户 `crypto-hdkey`；Address QR 为 index 0。
- [ ] EVM 地址浏览可看多个 index，正常带 path 的请求可匹配相应非零 index。
- [ ] EVM 缺 path 的回退只匹配 index 0；缺可选 address 的合法请求按 selector 规则处理。
- [ ] EVM 交易、personal_sign、EIP-712、SafeTx、Permit 类签名分别验签。
- [ ] 不同请求类型的 v/parity/chainId 编码符合对应参考实现。
- [ ] SOL 三条精确路径分别有固定向量；Trust 不错误使用两级路径。
- [ ] SOL 默认每次只导出一项；后台保存三项；不存在伪造 XPUB。
- [ ] SOL legacy/v0、非 fee payer、read-only signer、Message 均可正确签署。
- [ ] SOL 原 message bytes 和其他签名保持不变；错误 signer 槽位被拒绝。
- [ ] TRON index 0 和 99 可用；100 不可选；Ownbit 仅 index 0 显示。
- [ ] TRON 100 个地址匹配不需要解密 seed。
- [ ] TRON signer 不等于 owner_address 的合法权限多签场景可处理。
- [ ] 权限更新中的新成员不会被误认成当前授权 signer。
- [ ] TRON 加签保持 raw_data/txID；已有签名不丢失。
- [ ] 没有标准 transport 证据的 TronLink/TP 路线不假装支持，不新增 TP 私有格式。

### 25.5 自动匹配与逐次密码

- [ ] 所有 seed 都锁定时，正常公开索引匹配仍能完成。
- [ ] 不要求依次输入多个钱包密码来寻找匹配。
- [ ] 无匹配显示红色错误，Sign 禁用，无手动钱包选择器。
- [ ] fingerprint 碰撞、path/address 冲突、公钥错配不会误选。
- [ ] 解密后再次核对真实 key 与 SigningPlan 一致。
- [ ] 每个新请求都要求对应钱包密码，上一笔签完不免密。
- [ ] App Lock 的钱包密码验证成功后，签名仍再要一次对应钱包密码。
- [ ] 密码失败不切换钱包；取消/后台/并发扫码替换不会产生非预期签名。
- [ ] 内存中不保留可被下一笔复用的 unlocked seed/session。

### 25.6 App Lock

- [ ] 默认关闭；只有用户开启才使用 Face ID。
- [ ] 冷启动开启时先锁后显示；无首页闪现。
- [ ] 后台 119 秒返回不重验，120 秒及更久必须重验。
- [ ] 无时长选择器；没有“保持签名解锁”的等价状态。
- [ ] Face ID 失败/取消可重试、可选择任意已有钱包密码兜底。
- [ ] 兜底仅打开 App，不保留钱包 seed 或签名授权。
- [ ] 面容不可用/系统 lockout/未授予权限不会把用户锁死。
- [ ] App 进入后台立即遮挡快照；签名秘密立即清理，不等待 120 秒。
- [ ] Face ID 系统弹窗触发的 inactive 不会导致重复认证循环。

### 25.7 Summary、Token 和风险

- [ ] 顶部 Summary 能读出操作、金额和目标，下面有完整 Details。
- [ ] 已知 Token 使用真实静态 symbol/decimals/icon；未知不猜名称或小数。
- [ ] 同名 Token 跨链/不同合约不会混淆。
- [ ] ERC20 合约地址、接收者、spender 分开显示。
- [ ] Chain ID 至少有四个主流网络的可读名称。
- [ ] 普通 SPL transfer 不凭 token account 猜 mint/decimals。
- [ ] EIP-712/Safe/Squads hash-only 或引用-only 不能假装已知全部操作。
- [ ] 部分解析明确列出未知内容，风险确认只限当前请求。
- [ ] 结构损坏、未知签名算法、关键证据冲突不能靠风险确认绕过。
- [ ] 所有重要地址可查看完整形式；金额使用精确整数/十进制。

### 25.8 启动、欢迎与无网

- [ ] Light/Dark 启动均无白屏/闪白，无人为等待。
- [ ] Logo/slogan 使用已有本地资源，首帧与后续页面连续。
- [ ] Welcome 的两个主入口、法律链接和首次三页引导完整。
- [ ] 引导完成后沿用原 Create/Import intent。
- [ ] 后续添加钱包不反复弹首次说明。
- [ ] Scan 大图标、区域和按钮都可触发同一个扫码流程。
- [ ] 无网络状态探测/警告/连接灯；有网无网 UI 和核心操作一致。
- [ ] runtime target 无 RPC/HTTP/远程图标/遥测/动态 ABI 下载。
- [ ] 法律链接只由用户主动交给外部浏览器，不做预取或连通性探测。
- [ ] 所有 Token/钱包 Logo 和引导图文均随 App 打包。
- [ ] 主网产品 UI 无环境切换；内部 network 校验未被删除。
- [ ] Activity 不显示未经网络证实的广播或确认状态。

### 25.9 真机兼容验收记录格式

每一条“兼容”必须记录：

```text
wallet / platform / version
chain / path profile / output mode
connect payload fixture
sign request method + fixture
returned signature/PSBT fixture
独立验签结果
真实相机扫码往返结果
未覆盖的功能
```

参考 SDK 接受一个 payload 只能证明编码层；商店中某一版热钱包能完成三阶段流程，才能给那条路径挂 `QR signing` 标签。

---

<a id="section-26"></a>

## 26. 实施优先级与最终交付

### P0：数据和签名边界

首先消除 active wallet/global unlock，建立公开索引和确定性 WalletResolver，落实逐次密码、原始 bytes 不变、无匹配不能签和主流脚本/签名类型的实际支持。同步完成安全数据迁移。

### P1：用户工作流

完成钱包卡片、地址页、Connect 页、BTC/SOL Tab 与输出类型、TRON 索引、签名 Summary/Details、App Lock 120 秒及失败兜底。

### P2：离线资源和首次体验

完成 Token Registry/本地图标、兼容 Footer、启动视觉、Welcome/首次引导、法律 URL 占位、Scan 点击区域、Activity 状态和全局文案清理。

P2 不是可用占位图和假 Token 表敷衍的“可选项”；最终版本仍须交付上述功能。优先级只表示实施顺序。

### 最终交付要求

- 修改后的现有项目源码与可构建的工程。
- 可迁移既有数据的 schema/迁移代码；不能要求清空用户钱包。
- 实际本地 Token 清单及图标、来源与版本；钱包 Logo 同样本地化。
- 主流二维码、派生和签名的测试向量及独立验证测试。
- Light/Dark 的关键页面截图，以及 App Lock、Welcome、错误态的验收结果。
- `IMPLEMENTATION_STATUS.md`：逐条对应 D01–D28，明确哪些已完成、哪些经过了什么测试。

若环境不能运行 Xcode/真机相机，报告真实限制，不声称已构建或 E2E 通过；仍完成能够实施的代码和离线测试。不要因某个热钱包尚未验证就停止其它已明确的修改。

---

<a id="section-27"></a>

## 27. 仍须核验、但不得凭猜测实现的项目

| 项目 | 明确处理方式 |
|---|---|
| BTC 默认叶子 Public Key QR 是否被特定热钱包接受 | 默认模式按需求保留；没有通过验收就不挂其 QR signing Logo；提示 Account XPUB 适合 HD 配对 |
| Taproot UR 旧库缺少对应脚本支持 | 使用标准标签和参考向量补齐/更新库，不伪装 wpkh，也不仅换路径 |
| Ownbit 与各链 UR 的实际接入 | 已确认路径只用于 Address format；实际三阶段互通单独验收；TRON index 0 的产品限制保留 |
| TRON 公共请求类型与 TronLink/TP 入口 | 实现/核验已选公共接口，不加入 TP 私有协议，不把“接受一个地址”当完整签名兼容 |
| 主网无法从部分签名 payload 独立识别 | 保留主网产品范围和可做的校验，不伪造无从证明的网络结论 |
| 已有项目具体类名/存储版本/最低 iOS | 以仓库实情为准；本文未取得现有 BitTool Signer 源码，不能假设真实路径 |
| Token 集合和图标快照 | 必须开发阶段采集并核验；本文不是已经采集好的资产包 |

---

<a id="section-28"></a>

## 28. 需求优先级与参考来源

本次用户最后明确的决定优先于此前讨论中的泛化建议。本文没有要求重读大量外部材料才能理解需求；下面来源仅用于协议、路径及系统 API 的复核。

既有附件《BitTool Signer v1 设计文档》《BitTool Signer 四链 QR 协议研究与实现规范》《BitTool Signer BTC/SOL Connect Examples》可作为历史测试资料，不可将其中 TP 私有协议、额外输出格式或此前生物识别替代签名的建议重新带回来。

本次额外核对了 Ownbit 的已保存知识库及官方资料：SOL/SPL 路径为 `m/44'/501'/0'/0'`；这只证明路径资料，不证明 UR 接口已实现。保存文档为 `Ownbit_Knowledge_Base_10_Languages.md`（Library version 1，恢复参数表），其公开依据为 [S07]。

### 标准与第一方资料

[S01]: https://bips.dev/32/ "BIP32：公开派生、节点层级、XPUB 和 fingerprint"
[S02]: https://bips.dev/48/ "BIP48：cosigner 路径和 1'/2' 脚本类型"
[S03]: https://bips.dev/86/ "BIP86：单 key Taproot 派生及 tweak"
[S04]: https://eips.ethereum.org/EIPS/eip-4527 "ERC-4527：crypto-hdkey、请求 dataType、可选 address 与返回"
[S05]: https://github.com/BlockchainCommons/Research/blob/master/papers/bcr-2020-010-output-desc.md "输出描述符及脚本标签，包括 tr 和 cosigner"
[S06]: https://github.com/trustwallet/wallet-core/blob/5031fe6dd14b6d11a5de9892ea4ea1ee443fa13f/docs/registry-fields.md "Trust Wallet Core：默认及替代 Solana derivation"
[S07]: https://ownbit.io/en/docs/concepts/keys-and-standards/ "Ownbit 官方路径资料；与 QR 协议兼容不是同一件事"
[S08]: https://dev.keyst.one/docs/integration-tutorial-advanced/solana "Keystone Solana 公共 UR 集成资料"
[S09]: https://solana.com/docs/core/transactions "Solana 交易、message、签名及版本结构"
[S10]: https://docs.safe.global/advanced/smart-account-signatures "Safe 多种签名类型及编码"
[S11]: https://developers.tron.network/docs/multi-signature "TRON 账户权限、权重和权限更新"
[S12]: https://bips.dev/174/ "PSBT 数据及签名角色"
[S13]: https://bips.dev/371/ "PSBT Taproot 字段"
[S14]: https://github.com/KeystoneHQ/keystone-sdk-base/blob/cda9c6edf21518ed5bf4d64f665aaf4494e88c1f/packages/ur-registry-tron/src/TronSignRequest.ts "公共 TronSignRequest 的实际字段；需配合真实签名与返回实现核验"
[S15]: https://dev.keyst.one/docs/integration-tutorial-advanced/tron "Keystone TRON 旧集成路径，不能视为 tron-sign-request 的等价物"
[S16]: https://docs.arbitrum.io/for-devs/dev-tools-and-resources/chain-info "Arbitrum One 网络资料"
[S17]: https://docs.base.org/get-started/connect-to-base "Base 网络资料"
[S18]: https://developer.apple.com/documentation/localauthentication/logging-a-user-into-your-app-with-face-id-or-touch-id "Apple：LocalAuthentication"
[S19]: https://developer.apple.com/design/human-interface-guidelines/launching "Apple：启动体验设计"

可进一步使用的官方/维护者规范：

- [BIP44](https://bips.dev/44/)、[BIP49](https://bips.dev/49/)、[BIP84](https://bips.dev/84/)、[BIP370](https://bips.dev/370/)。
- [BC-UR](https://github.com/BlockchainCommons/Research/blob/master/papers/bcr-2020-005-ur.md)。
- [Keystone CryptoAccount](https://github.com/KeystoneHQ/ur-registry/blob/bd8f408127c420f723222c1934c5666873a94c3e/src/CryptoAccount.ts)、[CryptoMultiAccounts](https://github.com/KeystoneHQ/ur-registry/blob/bd8f408127c420f723222c1934c5666873a94c3e/src/extended/CryptoMultiAccounts.ts)。
- [MetaMask QR keyring 参考代码](https://github.com/MetaMask/accounts/blob/03e1e383d02db2407699a4a24d5bac1ff7766479/packages/keyring-eth-qr/src/device.ts)。

**资料核验日期：2026-09-21。固定 commit 的来源表示对应代码快照，不自动代表 App Store 中最新发行版。**

---

<a id="section-29"></a>

## 29. 给编码 AI 的最终检查口令

> 修改的是现有 BitTool Signer iOS App。保留钱包和密钥数据；取消全局选中钱包与 Unlock Vault。严格按四链的页面、路径、公开缓存和签名要求实现；扫码后由公开索引自动匹配，不让用户任意换签名钱包。签名每次输入对应钱包密码，Face ID 只做 App 隐私锁，默认关闭、后台 120 秒固定重验，并允许任意已有钱包密码兜底。所有核心功能完全离线，Token 与 Logo 静态打包，不检测网络。没有钱包先 Welcome，首次三页引导后再创建/导入；启动适应明暗主题。未验证的兼容性不宣传，无法安全解析或匹配的请求不能假成功。最终逐条报告代码改动和真实测试结果。
