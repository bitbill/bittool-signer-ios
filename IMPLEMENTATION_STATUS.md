# BitTool Signer 实施状态 · Revision 9（2026-10-18）

本轮按用户要求对尚未上线的 App 做全面重构：原生化并重做全部界面，Settings 放进 Tab Bar（共 4 个 Tab），审查并加固安全、逻辑、JS 引擎与密码学，重绘七个主网络图标，重建热门 Token 表与图标，补齐自动化测试。App 未上线，因此直接采用新存储格式，不兼容旧开发数据。[Revision 1 规范](docs/Modification-Spec-2026-09-21.md)中的产品决定（D01–D28）在 Revision 2 中全部保留；Revision 3 按用户的新要求改变了其中几项：BTC 默认导出改为 Account XPUB（移除叶子公钥模式）、TRON 可导出任意地址索引、移除 Ownbit 及其显示规则。

版本 **1.0.0 (1)**，最低 iOS 17；iOS 26 使用 Liquid Glass，iOS 17/18 有对应的原生回退样式。

## Revision 4（2026-10-16）：品牌更名与条款

App 由 **BitSigner** 更名为 **BitTool Signer**（中文：BitTool 签名器），原 BitTool 改称 **BitTool Wallet**（BitTool 钱包），运营主体 **BITTOOL PTE. LTD.**，网址 [bittool.com](https://bittool.com)（通用）、[bittool.com/signer](https://bittool.com/signer)、[bittool.com/wallet](https://bittool.com/wallet)，联系邮箱 support@bittool.com。App 未上线，因此一次改彻底、不做兼容：

**1. 工程与标识符**：`BitToolSigner.xcodeproj`、target/scheme/源码目录全部更名；bundle id 改为 `com.bittool.signer`（测试 `.tests`/`.uitests`），显示名 `BitTool Signer`。Keychain service、加密 AAD、公开索引 AAD、UI 测试的参数与环境变量、本地目录（`Application Support/BitToolSigner/…`）统一改到 `com.bittool.signer.*`。钱包身份的域分隔串改为 `BitTool-Signer/WalletKeyId/v1`，`walletKeyId` 向量随之更新（测试里的固定向量同步改掉）。**设备上已有的开发期钱包因此无法再打开，需要重新导入助记词。**

**2. 配对协议**：钱包级载荷 `protocol` 改为 `bittool-signer-wallet`，签名回执 transport 改为 `bittool-signer-json`，`crypto-account` / `crypto-multi-accounts` 里第三方钱包显示的设备名改为 `BitTool Signer`。[docs/Wallet-Pairing-v1.md](docs/Wallet-Pairing-v1.md) 与 [docs/bittool-handoff/](docs/bittool-handoff/) 顶部都加了更名说明，夹具已用新名字重新生成——**BitTool Wallet 侧的解析需要同步更新**。

**3. 图标**：两个 App 共用 BitTool 的标记（环 + 实心节点），几何尺寸直接量自 Wallet 图标（环 288–372、节点半径 94.8 居于 (828.5, 511.5)）。Wallet 用浅色版（墨色标记、白底），Signer 用深色版（白色标记、`#0A0A0C` 底）。`scripts/make-brand-assets.py` 重写为不依赖第三方库：形状都是圆，直接按覆盖率栅格化并用 zlib 写 PNG。

**4. 使用条款（v1.1）**：按“出现任何问题赔偿为 0、用户自己负责”的要求重写，参考自托管钱包通行写法。新增“自托管：一切都在你手里”“你接受的风险”“你对我们的赔偿责任”“争议解决”等章节，并把责任限制写明为 **总责任为零、不作任何赔偿**（保留不可排除的法定权利与消费者保护的例外）。管辖法律为新加坡。隐私政策同步更新为 v1.1，补上运营主体与联系方式。两份文档的联系方式都是 BITTOOL PTE. LTD. / support@bittool.com / https://bittool.com/signer。

**5. Connect 默认钱包级**：Connect 页打开即是 **Wallet Level**，Coin Level 变成第二个选项。预取也改为预取钱包级二维码（原先预取的是 BTC 币种级），所以首次推入依然在第一帧就是完整页面；Coin Level 在选中时再加载。



**6. 本机模拟器环境**：这台 Mac 上 Xcode 已升到 **26.4**，但唯一安装的 iOS 26 运行时仍是 **beta（23A5276e）**。用 26.4 的 SDK 编译出来的包在那个旧 beta 运行时上会在 `glassEffect`（`GlassCircle`）处因找不到类型元数据而 `SIGABRT` 崩溃——与本次改名无关，换成 iOS 18.6 运行时全部通过。本轮的验证因此跑在 **iPhone 16 Pro · iOS 18.6**（UI 15/15、截图巡检通过）。要再验 Liquid Glass 路径，需要在 Xcode 里装一个与 26.4 匹配的 iOS 26 正式运行时。

**7. App 名称**：所有语言都叫 **BitTool Signer**，不做翻译。名称只有一处设置：工程里的 `INFOPLIST_KEY_CFBundleDisplayName`（上架名另在 App Store Connect 按语言填）。App 刻意**不声明任何额外语言**——一旦声明，系统自己的控件（权限弹窗按钮、键盘、分享表单）会跟着设备语言走，而 App 界面仍是英文，看起来像翻译了一半；`AppNameTests` 会守住这一点。

**8. BIP39 passphrase 可见切换与 AutoFill**：创建和导入的 passphrase 输入框右侧加了眼睛按钮，可切换明文；切到后台自动恢复遮盖。passphrase 打错不会报错，只会悄悄打开另一个钱包，所以必须能读回来核对。该输入框改为 UIKit `UITextField` 承载（`MaskedTextField`）：遮盖与否只是它的一个属性，不需要换一个视图，并且对“新建的秘密”（passphrase、新设密码）**关闭 iOS AutoFill**——AutoFill 的强密码流程会直接替换掉用户输入的内容。其余密码输入框仍是原来的 SwiftUI `SecureField`，未改动。此外给 passphrase 输入框设了空的 `passwordRules`，彻底关掉 iOS 的强密码生成入口。

**9. 欢迎页卖点**：第二条由“Sign with QR codes”换成 **Fully open source**（“Every line that touches your keys is published. Read it, or rebuild it and compare.”），扫码签名的说明并入第三条，引导页第二页仍完整介绍二维码兼容性。

**10. 中国区“无线数据”弹窗**：App 不含任何联网代码，链接的框架里也没有 CFNetwork/Network.framework（`otool -L` 可验证）。中国大陆销售的 iPhone 上，iOS 对每个 App 都有一个无线数据开关，首次使用时会询问，这个弹窗来自系统而不是 App。离线指南新增一条“若 iOS 询问是否允许无线数据，选 Don't Allow”，隐私政策也加了一小节说明。

## Revision 5（2026-10-17）：界面语言、删除确认与若干修正

**1. 界面语言（Settings › Appearance › Language）**：在 Theme 下面加了语言选择，切换即时生效、无需重启——选中的语言通过 `.environment(\.locale)` 作用于整棵视图树（`AppLanguage` + `LanguageEnvironment`）。阿拉伯语同时切换 `layoutDirection`，整个界面镜像为从右到左（Tab 顺序、行内对齐、返回箭头都会翻转）。导航栏标题由系统缓存，所以切换语言时整棵树重建一次，会回到第一个 Tab。

语言表按 BitTool Wallet／Ownbit 的清单，共 **21 种**（en、zh-Hans、zh-Hant、ja、ko、ru、uk、es、es-419、de、fr、it、pt-BR、pt-PT、pl、id、tr、th、vi、fil、ar）。选择器只列出**真正已翻译**的语言，不会出现选了还是英文的情况。

**已完成：简体中文、繁體中文、العربية**，每种 388 条，全部通过校验。待补：其余 17 种。

字符串清单不再靠手工正则，而是用 Xcode 自己的提取（`xcodebuild -exportLocalizations`）得到权威列表，再并入引擎产出的静态文案（见 Revision 9），存在 [engine/data/interface-strings.json](engine/data/interface-strings.json)；[scripts/write-localizations.py](scripts/write-localizations.py) 把 `translations/<语言>.json` 写成 `.lproj/Localizable.strings`，并拒绝漏条目或改动 `%@`／`%lld` 占位符的译文（占位符错位会让运行时按错误的值格式化）。

为了让"翻译彻底"，把所有以 `String` 接收显示文案的组件和局部辅助函数改成 `LocalizedStringKey`（`Callout`、`DetailLine`、`WalletGroup`、`StepRow`、`PayloadDisclosure`、`SetupScaffold`、`ProfileMenu`、引导页 `Page`、Scan 页的 `optionTile`、密码规则行、地址页的分组标题与脚注等）；引擎返回的动态文案走 `verbatim:` 入口保持原样。

仍是英文的部分：**JS 引擎生成的审核文案**（警告、字段名、风险说明，几百条，安全相关性最高）与条款／隐私政策（按决定保持英文）。

**2. 删除钱包改为 Face ID + 密码**：点 Delete Wallet 先做一次 Face ID（设备支持时；取消即中止，生物识别不可用或失败则继续走密码），然后弹出密码输入框，输入正确的钱包密码才真正删除。原来密码框是内嵌在表单里的一行，容易被忽略。垃圾桶图标在红色按钮上显示为深色，改为强制白色。

**3. passphrase 输入框可收起键盘**：该输入框自带 Done 工具条（`inputAccessoryView`），因为它紧贴底部操作栏，页面本身没有别的收起键盘的办法。同时给输入框加了 `frame(maxWidth: .infinity)`，避免 UIKit 文本框按内容宽度收缩。

**4. Settings 调整**：Reference 里移除 Offline Setup Guide（引导页首次使用时仍会出现）；About 里 Open Source 改名 **Fully Open Source**。

## Revision 9（2026-10-18）：21 种语言全覆盖、引擎文案本地化、动态配对二维码、Connect 改名 Pair、钱包目录与提交入口

**1. 语言补齐到 21 种**：新增 uk、es-419、it、pt-BR、pt-PT、pl、id、tr、th、vi、fil 共 11 种，与既有的 en、zh-Hans、zh-Hant、ja、ko、ru、de、fr、es、ar 合为 21 种，和 BitTool Wallet 的语言数量一致。pt-BR／pt-PT 与 es／es-419 是分别逐条写的，不是机械替换：葡语两版在 palavra-passe／senha、ecrã／tela、ficheiro／arquivo 以及进行时（“A descodificar…”对“Decodificando…”）上系统性不同；西语两版在 billetera／cartera、monto／importe、Configuración／Ajustes 上不同。`knownRegions` 同步补齐到 22 项（含 Base）。

**2. 引擎产出的审核文案现在也翻译**：引擎（JS）仍然只写英文——那是请求指纹覆盖的文本，也是重建引擎时必须逐字节复现的内容，不能随语言变化。改为在**绘制的最后一刻**翻译：新增 [BitToolSigner/Models/ReviewText.swift](BitToolSigner/Models/ReviewText.swift)，`phrase` 翻译整句（Details 的字段名、`display.action`、对手方标签），`label` 翻译带单位括号的字段名（“Amount (USDC)”只译前半截），`headline` 翻译“Method 0x3593564c”这类“固定词 + 引擎填值”的标题。查不到译文时原样回退成引擎的英文，所以以后引擎新增标签只会显示英文，不会消失。字符串清单 [engine/data/interface-strings.json](engine/data/interface-strings.json) 从 548 条增加到 **742 条**：558 条来自 Xcode 提取，另外 184 条是从引擎源码里抽出的静态字段名、display action、counterparty 标签、review title 与 resultType。

**3. 手续费上限只显示 8 位小数**：审核页原样显示 `0.000396834604360128 ETH`。`ReviewText.shortDecimal` 截到 8 位，并且**向上取整**（丢掉的尾数非零时末位加一，必要时进位到整数位），因为这是“最多多少”的上限，向下取整会低报。Details 里仍保留完整数值。

**4. 扫码页退出后界面变深色**：`QRScannerView` 用 `.preferredColorScheme(.dark)` 给相机界面配深色材质，但那是**窗口级**偏好；当 App 的外观设置是“跟随系统”（根视图传 `nil`，即“无偏好”）时，模态关闭后没有偏好去覆盖它，窗口就停在深色。改成 `.environment(\.colorScheme, .dark)`，只影响扫码页自己的视图树，不碰窗口。

**5. 之前漏掉的界面文案**：`QRScannerView` 的 `title`／`hint` 改成 `LocalizedStringKey`（“Scan Request”“Scan Recovery QR”及两段提示语此前是 `String`，永远按原文绘制）；助记词输入框的状态行（“12–24 words · any BIP39 language”“1 word”“%lld words”“Unknown: %@”）改用 `String(localized:bundle:)`；地址详情标题 `%@ address #%lld`、Solana 的 `%@ account`、签名按钮 `Sign with %@` 同样补上。

**7. 钱包级二维码改为动态，并带上全部地址类型**：原来只导出 BTC 的 BIP84（bc1q）一种和一个 Solana 地址。现在 `accounts` 带 **4 个 BTC 账户 xpub**——`p2wpkh`（bc1q，m/84'）、`p2tr`（bc1p，m/86'）、`p2sh-p2wpkh`（3，m/49'）、`p2pkh`（1，m/44'）——以及 EVM、TRON 的 xpub 和 **3 个 Solana 地址**（standard／trust／legacy；Ed25519 是硬化派生，观察钱包无法由一个推出另一个，所以三个都得送）。`m/48'` 的两个多签 profile 不在其中：多签需要全部 cosigner 公钥与阈值，那是 Coin Level 的 cosigner 导出负责的。载荷因此从 755 字节增加到 **1561 字节**，一张二维码装不下，改为 **多帧 `ur:bytes` 动态二维码**（400 字节分片，测试钱包是 4 帧 × 831 字符；分片长度取 `min(400, ⌈载荷/2⌉)`，保证至少 2 帧）。上限从 1024 字节放宽到 4096。校验区现在列出**每一个导出账户**的首地址：4 个 BTC、EVM、TRON、3 个 Solana，共 9 条。

> **BitTool Wallet 侧必须同步更新**：`accounts` 数组从 4 项变成 7 项，解码方要按每项的 `chain`／`script` 读取，不能再按下标；Solana 条目新增 `profile` 字段；并且必须先收齐所有帧再解码。协议文档 [docs/Wallet-Pairing-v1.md](docs/Wallet-Pairing-v1.md) 已更新，测试向量与 SHA-256 重新生成。

**6. 回归测试**：[BitToolSignerTests/ReviewTextTests.swift](BitToolSignerTests/ReviewTextTests.swift) 覆盖“查不到译文要回退英文”“前缀翻译要保留引擎填的值”以及手续费截断的进位（`0.999999999 → 1.00000000`）与不该动的情形（没有小数、没有单位、已经很短）。钱包级配对的新形状在 `engine/test/wallet-pairing.test.mjs`（186 个引擎测试全通过）与 `BitToolSignerTests/SessionTests.swift` 里都有断言：4 种脚本类型各自的 xpub、3 个 Solana 地址、不含 `m/48'`、帧数 ≥ 2。

**8. Connect 改名为 Pair（配对）**：按钮与标题从 `Connect` 改为 `Pair`——`Connect Wallet` → `Pair Wallet`（配对钱包）、`Connect Bitcoin` → `Pair Bitcoin`、`Connect a Wallet` → `Pair a Wallet`，以及正文里按名字引用该按钮的两句话。理由有三：一是 App 里解释这个功能的文案本来就在说 pair／配对（`Pairing level`／配对级别、`wallet pairing`／钱包配对、`Pair BitTool Signer with a watch-only wallet…`），只有按钮写着「连接」，自己和自己打架；二是「连接」恰恰是离线签名器**永远不做**的事，App 里甚至有一句「这个 App 从不联网」，按钮却写「连接」；三是 dApp 世界的 Connect Wallet 指的是把你的钱包接到网站上，方向与这里相反（这里是把公钥导出给观察钱包），沿用反而容易误导。

> 只改面向用户的文案。无障碍标识符（`connect.level`、`connect.copy`、`wallet.connect.*`）、类型名（`ConnectView`、`PairingLevel`）和代码注释保持不变，避免无谓的改动面。`Network connections`（设置里的网络连接）、`the app never connects` 等含义不同的词不受影响。

**9. 配对页校验区地址重复（Revision 9 自身引入的回归）**：第 7 条把导出账户从 4 个增加到 9 个之后，页面上 4 个 Bitcoin 行显示的是同一个 bc1q 地址和同一条路径，3 个 Solana 行也一样。引擎其实给出的是 9 个各不相同的地址，问题在 `WalletPairingPayload.Line` 的 `var id: String { chain }`——一条链以前只有一行，现在有四行，`ForEach` 看到重复的 id 就只画了第一条的内容。修法：引擎的 `verify` 条目加上 `profile`（`native`／`taproot`／`nested`／`legacy`，以及 Solana 的 `standard`／`trust`／`legacy`），`id` 改成 `chain + "/" + profile`。同时每行现在标出是哪一个账户——「Bitcoin · Taproot」「Solana · Trust」，名称直接复用 Coin Level 选择器里的 `AccountProfile`，两个页面说法一致；标题也从「核对每条链的首个地址」改为「核对每个账户的首个地址」（一条链已经不止一个账户了）。

> `profile` 只出现在 `verify`（界面数据）里，不在 CBOR 载荷中，所以协议的测试向量与 SHA-256 不变，BitTool Wallet 侧不受这一条影响。回归断言加在 `SessionTests`：9 行的 id、地址、路径必须两两不同，且 BTC／SOL 的 profile 顺序正确。

**10. 提交钱包与钱包目录**：

- **「提交钱包」入口**：Connect（配对）页每个「适用钱包」卡片底部新增一个链接，进入 [SubmitWalletView](BitToolSigner/Features/Settings/SubmitWalletView.swift) 说明怎么提交：收件人 `support@bittool.com`、主题 `Add supported wallet`，以及至少要写的五项——钱包名称、官网、App 图标（链接或附件，方形不小于 512 px）、源码仓库（若开源）、支持的二维码格式（钱包级，以及 BTC／EVM／TRON／SOL 的币种级）。App 不联网也不唤起邮件客户端，所以收件人和主题都是**可复制的文本**，不是按钮。
- **设置 › 兼容性新增「钱包」分页**：顶部分段控件切换「格式」（原有内容）与「钱包」。[WalletDirectoryView](BitToolSigner/Features/Settings/WalletDirectoryView.swift) 按字母序列出 App 里出现过的全部 24 个钱包，含图标、平台、能否签名，以及**官网（可复制，不可点击——App 默认没有网络）**。
- **免责声明放在最显眼的位置**（页面顶部两条 Callout）：这里的钱包只是支持、或**声称**自己支持 BitTool Signer 的二维码；**任何人都可以提交并作出这样的声称**；我们没有完全核实，也不对任何一个钱包做审计、背书或担保；本页仅作信息展示，用户需自行审查；通过其他钱包发生的漏洞、黑客、诈骗或任何损失，BitTool 概不负责。提交页底部也重复了一遍。
- **24 个官网逐个核对过**（2026 年 10 月，实际抓取各站点确认内容属于该钱包），写在 [CompatibleWallets.sites](BitToolSigner/Models/CompatibleWallets.swift)。这些网址是给人复制到另一台有网设备上打开的，写错等于指向钓鱼站，所以没有凭记忆填写。另有断言保证 24 个钱包与 24 条网址一一对应。

## Revision 8（2026-10-17）：欢迎页底部间距、保持 iOS 17

**1. 欢迎页法律链接贴近底部**：`bottomActionBar` 增加 `bottomPadding` 参数（默认仍是 8），欢迎页传 0。以 Terms of Use / Privacy Policy 这行结尾的操作栏不需要按钮那样的留白。实测（iPhone 16 Pro，@3x）：链接下方的空白从 130 px 缩到 106 px，即 **43.3pt → 35.3pt**，正好少掉那 8pt。**剩下的约 34pt 是系统的 home indicator 安全区，再压就会画到手势条下面，不能动。** 其余三处调用（创建流程、签名结果页、欢迎页的引导分支）行为不变。

**2. 保持最低 iOS 17**：Revision 7 的评估已采纳结论“不降”，代码未改，评估记录保留在 [docs/DeploymentTarget.md](docs/DeploymentTarget.md) 供以后重开时参考。

**3. 修回被 Xcode 改掉的部署目标**：做 iOS 15 评估时临时把 `IPHONEOS_DEPLOYMENT_TARGET` 改成 15.0、构建后已按备份还原；但之后 Xcode（项目处于打开状态）把**工程级**的两个配置自作主张改成了 `$(RECOMMENDED_IPHONEOS_DEPLOYMENT_TARGET)`（target 级的四个仍是 17.0）。症状是 iOS 17／18 的模拟器从可用目标列表里消失，只剩 26.4／27.x。已改回 17.0，`project.pbxproj` 与评估前逐字节一致，模拟器列表恢复正常。

## Revision 7（2026-10-17）：Connect 默认层级、Activity 的输入与输出

**1. 点币种进 Coin Level**：钱包详情页的 Bitcoin / Ethereum & EVM / TRON / Solana 四行，点进去现在直接是 **Coin Level** 且已选中该链——选了币种本身就是币种级的选择。Revision 4 定下的“默认 Wallet Level”保留在**不指定币种**的入口上：钱包卡片的 Connect 按钮、创建完成页的“Connect a Wallet”，以及详情页的“钱包级”一行，这三处改走 `connectWallet` 路由。顺带修掉一个遗漏：钱包级路由此前没有接上预取的二维码，现在两条路由都接上了，所以从币种页切到 Wallet Level 也是第一帧就完整。

**2. Activity 展示输入与输出**：每条签名现在记下**签进去的那份请求**（引擎审核过的规范 JSON）和**产出的那份签名**（二维码帧 + 导出文本）。详情页因此多了两段：

- **Input**：操作、金额、交易对手、手续费几行要点，一个“All Decoded Fields”进到完整页面（直接复用审核页的摘要卡、合约提示、警告与 Details），以及可展开的请求原文。要点不是存下来的摘要——打开页面时把存下的请求**重新交给引擎审核一遍**，所以字段和当初审核页看到的是同一套，而且重算出的请求指纹必须等于记录里的那个，对不上就不显示解码内容。这样“解码字段”不占额外存储，也永远不会和原文脱节。
- **Output**：`Show QR Code` 把当初那张签名二维码再显示一次（对方钱包没扫上时很有用；再扫一次不产生任何新东西）、`Export as File`，以及可展开的签名原文。

存储：`SigningReceipt` 增加 `requestJSON` / `responseFrames` / `responseText`，单条载荷上限 32 KiB（超过就整条不存，不做截断），只为**最近 25 条**保留载荷，更早的记录保留其余字段、只丢载荷；文件上限从 256 KiB 提到 2 MiB，读取时逐条校验。文件本身仍是 `completeFileProtection` + 0o600 + 不进备份。存的两样都是公开数据（请求和签名），不涉及任何秘密，测试会检查记录文件里不出现助记词、密码或私钥。

**3. 请求指纹改为大写**：同一张卡片上“指纹”是大写（`store.fingerprint(for:)` 一直如此）而“请求指纹”是小写，两个都叫指纹却不一致。`HashText` 统一改为大写显示（只影响显示，比对仍大小写无关）。

**4. 本轮测试**：引擎 **179/179**（未变动）；原生单元 **166/166**（新增 `ActivityRecordTests` 10 项：记录确实带上请求与签名、存下的请求能重新审核出同一套字段且指纹必须对上、对不上或非 JSON 一律拒绝、只保留最近 25 条载荷且老记录不丢本体、超限载荷整条不存不截断、记录文件里不出现助记词／密码／私钥、上限算术保证下次启动一定读得回、多条签名跨启动仍可读、列表要点行的取值）；UI 自动化 **16/16**（`testPastedRequestIsMatchedReviewedAndSignedWithPassword` 扩到 Activity 的 Input／Output：进“All Decoded Fields”、重新显示签名二维码、展开签名原文；`testRenameThenDeleteLastWalletReturnsToWelcome` 增加“点链进 Coin Level”的断言）。截图巡检新增 `31b/31c/31d`。

**5. 一个测试工具问题**：新加的已知合约 UI 测试单独跑稳过、放进整套里必失败。原因不在 App：`typeText` 在模拟器有负载（整套并行克隆）时会吞字符，400 字符的 UR 二维码文本因此校验失败，表现成“审核页一直没出来”。改为输入后读回 `field.value` 校验、不一致就重输（`typePayload(_:into:in:)`），三处长载荷粘贴都走它。

**6. 最低系统版本评估（已决定不降）**：评估了 iOS 17 → iOS 15 的可行性，**最终决定保持最低 iOS 17**，代码未改；评估记录在 [docs/DeploymentTarget.md](docs/DeploymentTarget.md)。要点：工具链接受 iOS 15.0；降到 **iOS 16** 约 63 处机械替换、不动架构（多覆盖 iPhone 8）；再降到 **iOS 15** 还要把 `NavigationStack` 重写成 `NavigationView`，而导航恰好与签名后的状态流转耦合最深。当时的建议是先降 16、iOS 15 单独立项；现已决定两步都不走。

## Revision 6（2026-10-17）：已知公开合约

把 Ownbit 整理的 WalletConnect 已知合约库搬了过来，用在**签名审核**和 **Settings 浏览**两处。详见 [docs/KnownContracts.md](docs/KnownContracts.md)。

**1. 合约库**：来自 Ownbit 安全中心（`wallet-ios-core/scripts/security-center/known_contracts.json`，sourceVersion 1，2026-10-09），共 **1,720 个地址、307 个项目**：Ethereum 329、Base 217、BNB Smart Chain 194、Polygon 191、Arbitrum 186、OP Mainnet 169、Solana 262、TRON 139、Avalanche 6，另有 27 个 CREATE2 确定性部署（Permit2、Seaport、ERC-4337 EntryPoint、Multicall3、Safe 等），在所有 EVM 网络上是同一个地址，作为链内查不到时的兜底，并在审核里注明“在每条 EVM 网络上都是同一个地址”。HyperEVM（999，132 条）因为 App 不审核该网络而舍弃。`scripts/build-known-contracts.py` 校验地址格式、类别、重复后写出两份投影：引擎用的列式字符串（139 KiB，按首次使用才切分，所以不涉及合约的请求不付这笔开销）和 App 浏览用的完整 JSON（277 KiB）。

**收录只代表“这个地址是项目方自己公布的部署”，不代表请求安全**——已知合约一样能掏空账户，区别只在于能不能把“大家都在用的 Permit2”和“没见过的地址”分开，而仿冒合约正是靠这一点。

**2. 签名时应用**：查的是**请求授权出去的那个地址**，不一定是被调用的合约——`approve` 查 spender，`setApprovalForAll(…, true)` 查 operator，EIP-712 消息里有 `spender`/`operator` 就查它，否则查 `domain.verifyingContract`，其余情况查被调用的合约。`SafeTx` 的 verifying contract 直接跳过：每个 Safe 都是用户自己部署的，提示“不在名单里”只会变成噪音。

命中时审核多一行 `Spender (known contract)` 等字段，`review.contract` 带上名称、项目与类别。未命中时先问代币表——已经被代币表认出来的地址按代币显示，不叫“未知”；否则给出警告，并且**只有未收录的 spender／operator** 才把风险等级抬到 `warning`。未收录的普通合约不抬等级：绝大多数合约都是新的或私有部署，全部标红会让这个信号失去意义。

**3. Solana**：Solana 一笔交易是多条指令、没有单一的交易对手，所以不设 `review.contract`；改为给**引擎自己不解码**的程序加一行 `Program (known)`（例如一条本来只是裸字节的指令旁边写出“Raydium AMM v4 — Raydium · dex”）。引擎自己解码的程序（System、Token、Token-2022、ATA、Compute Budget、Memo、Stake、Squads 以及 Metaplex 与市场程序）保留自己的名字，因为它们的 Action 字段比名单标签说得更多。未收录的 Solana 程序不额外报警：指令有没有被解码本身就是信号，未解码的指令已经是高风险。

**4. 审核页展示**：地址已经出现在摘要卡的交易对手框里时（授权类请求），提示就跟在地址下面一行；地址不同时（代币转账授权的是代币合约、不是收款人），单独给一张卡片。四种状态：已收录＝琥珀色 + 印章图标（**不用绿色**——给一个正在拿到无限额度的地址打绿勾，等于说了名单支撑不了的话）、未收录的 spender／operator＝红色、未收录的普通合约＝灰色问号、代币表认识的＝强调色。

**5. Settings 合并为 Networks, Tokens & Contracts**：原“Networks & Tokens”扩成同时浏览代币和已知合约。每个网络页用一个分段控件在代币与合约之间切换，共用一个搜索框（合约可按名称、项目、类别或地址搜），只有一边有内容时不显示切换器（如 Gnosis 只有代币）。确定性部署单列一行“All EVM networks”。

**6. 本轮测试**：引擎 **179/179**（新增 Solana 已知程序一项：命中命名、未收录不额外报警、引擎自己解码的程序不被改名）；原生单元 **156/156**（新增 `KnownContractTests` 14 项：打包文件的记录完整性与声明计数、每条链都能在 Settings 里走到、`ReviewContract` 的解析与降级、摘要是否已经展示该地址）；UI 自动化 **16/16**（新增 `testApprovalNamesAKnownSpenderAndFlagsAnUnlistedOne`：用真实 `eth-sign-request` 二维码走一遍 USDT 无限授权给 Permit2 与授权给未收录地址，断言审核页出现／不出现对应提示；`testSettingsReferencePagesAndGuide` 扩到合约浏览与搜索）。截图巡检新增 `28/29-review-known-contract`、`44c/44d/44e-contracts`。

**7. 顺带修的**：Info.plist 的相机与 Face ID 用途说明原先只能是英文（它们来自构建设置，不走 `Localizable.strings`），现在 `translations/<语言>.json` 增加 `infoPlist` 段，由 `scripts/write-localizations.py` 一并写出 `InfoPlist.strings`，三种语言都已翻译；`AppNameTests` 相应改为“可以翻译系统提示，但不许改 App 名字”。

## Revision 3（2026-09-22）：连接、备份与 NFT 审核

本次按用户的 10 条反馈修改（第 8 条末尾“另外现在点：”没有写完，未能据此修改）。

**1. 创建完成后点“Connect a Wallet”卡住**：确认是 App 的问题。原先在关闭创建 sheet 的同时向钱包导航栈推入连接页，两个转场同时进行，推入动画停在半途。现在路由先记下，等 sheet 完全关闭（`onDismiss`）后再推入。UI 测试从完成页进入连接页，并确认二维码加载、链切换可用。

**2. 连接页顶部看不出选中了哪条链**：选中项改为强调色描边的浅色底块、图标全彩并略放大，未选中项图标降低饱和度与透明度、文字变灰；浅色和深色模式下都一目了然。大字号下只显示图标（VoiceOver 仍读出链名）。

**3. TRON 地址索引**：由 0–99 改为 0 到 2³¹−1（BIP32 非硬化索引上限）。连接页可用步进器，也可直接输入索引，路径随时显示在下方；超出上限时自动夹到最大值。引擎按账户节点现场派生，地址页可无限下拉。`tron-sign-request` 总是带路径，所以任何索引的签名请求都能匹配；只带地址、不带路径的请求仍只比对缓存的 0–99。

**4. Sparrow / BlueWallet 与 XPUB**：调研确认两者默认导入账户 xpub（`crypto-account`），并能用 `crypto-psbt` 扫码签名。BTC 默认改为 Account XPUB。同时发现上一版的 “Public Key”（只含 `/0/0` 叶子公钥、没有 chain code）不符合 BCR-2020-015，调研的钱包都无法导入，因此从界面和引擎中移除。

**5. 支持的钱包**：移除 Ownbit。逐个钱包、逐种导出查官方文档、源码或 Keystone 官方指南与固件，再由独立核查者反驳，只保留确认的条目；Connect 页和 Settings › Compatibility 分为“可扫码签名”和“仅观察”两组（`BitToolSigner/Models/CompatibleWallets.swift`，证据见 [docs/Compatibility.md](docs/Compatibility.md)）。
- BTC 可签名：Sparrow、BlueWallet、Nunchuk、Bitcoin Keeper、BULL Bitcoin、Specter、Bitcoin Safe、ZEUS（无 Legacy）；多签协调器：Sparrow、BlueWallet、Nunchuk、Keeper、Specter、Bitcoin Safe；地址观察：BlueWallet、Electrum。
- EVM 可签名：MetaMask、Rabby、imToken、TokenPocket（EIP-4527）、Ambire；地址观察：Rabby、TokenPocket、OKX Wallet、Trust Wallet。
- Solana 可签名：Solflare、Helium Wallet；地址观察：Phantom、Backpack、Jupiter、OKX Wallet、TokenPocket。
- TRON 只能观察：TokenPocket、TronLink、OKX Wallet、OneKey。**TP 确实支持观察 TRX 和 SOL 地址**，但它的冷钱包签名是自有协议；目前没有主流热钱包对纯地址导出生成 `tron-sign-request`。
- 移除 Safe（旧 iOS App 已归档，新版没有 QR 签名器）；Backpack 的 SOL 签名流程无官方记录，降为仅观察。新增 14 个官方钱包图标，移除 Ownbit、Safe 图标（[来源](docs/WalletLogoSources.md)）。

**6. Token 表扩充**：从 358 条扩到 **596 条**（Ethereum 196、BNB Smart Chain 112、Arbitrum 67、Base 86、TRON 14、Solana 121）。新增发现脚本 `scripts/discover-token-candidates.py`（放宽门槛），每条网络由一名审核者挑选主流代币，再由独立核查者按一手资料逐条复核，删掉 28 个（已废弃的 ERC-20、低层级 meme、刚上线几周的代币、一个刚被攻击的代币等），全部 596 条由构建脚本重新核对 CoinGecko 映射、独立列表或发行方文档、链上 decimals 与符号，并逐一目检图标。TRON 没有新增：CoinGecko 映射到 TRON 的主流、活跃 TRC-20 已全部收录。构建脚本新增：发行方文档（`officialSource`，原始页面必须含该地址）可作为独立来源；按哈希拒绝 CoinGecko 的“破图”占位图。引擎只打包精简版 `token-registry.engine.json`。

**6b. Token 表再扩充（CoinMarketCap 前 2000）**：在 596 条人工核定条目之上，加入 CoinMarketCap 前 2000 榜单中部署在受支持链上的代币，共 **3,350 条**（Ethereum 1,008、BNB Smart Chain 876、Solana 585、Base 333、Arbitrum 225、Polygon 137、Avalanche 75、OP Mainnet 53、Gnosis 32、TRON 26）。榜单只决定“收录哪些”并提供名称、符号和图标；**decimals 一律从链上读取**（EVM `decimals()`、Solana `getMultipleAccounts`、TRON `triggerconstantcontract`），3,250 个合约中 3,242 个读到，读不到的直接不收录。符号以合约自报的 `symbol()` 为准（2,276 条），与榜单不一致的 235 条里有 161 条只差大小写或标点（`frxUSD`、`$MBG`），其余多是跨链桥/包装版本（Avalanche 的 `LINK.e`、`UNI.e`、`DAI.e`，`wROSE`、`pONT`、`axlSAGA`，以及改名前的 `LUNA`、`UST`）——按榜单显示反而会把它们说成原版代币。与原 596 条重叠的 486 个合约是一次独立验证：链上读到的 decimals 与人工核定值**全部一致**。新增 `scripts/refresh-cmc-snapshot.py`（API key 只从环境变量 `CMC_API_KEY` 读取，绝不写入仓库）与 `scripts/build-expanded-registry.py`（人工条目永远优先）。审核界面对新旧条目一视同仁，不加任何额外标注；收录本身从来不代表背书。

**6c. 图标改为内容寻址的打包文件**：596 个 `token_*.imageset` 全部移出 Assets.xcassets（资源目录 10.9 MB → 484 KB），3,350 条记录的图标按字节 SHA-256 去重后只剩 **1,985 张**（同一代币在多条链上共用一张），拼成单个 `TokenIcons.pack`（10.7 MiB）加 `TokenIcons.index.json` 偏移表；App 侧 `TokenIconStore` 以 mmap 方式读取并按需解码。散放 2,000 个小文件在设备上每个都要占满一个文件系统块，约多 4 MB。

引擎侧的精简表改成“网络/程序字符串只存一份 + 每行用制表符分隔的一整个字符串”（313 KiB），进入新 VM 时只分配一个字符串，只有真正涉及代币的请求才会在首次查询时切分建表；模拟器实测单次 VM 启动 66–75 ms（596 条时 47–59 ms），首次代币查询 <1 ms。

**7. NFT 显示**：新增专门的 NFT 审核（详见 [docs/Compatibility.md](docs/Compatibility.md) “NFT 的审核显示”）。
- EVM/TRON：ERC-721/1155/TRC-721 转账与授权；`approve`/`transferFrom` 选择器与 ERC-20 相同时明确显示两种解释；`setApprovalForAll(true)` 红色警告；ERC-1155 批量合并显示；超长 Token ID 缩写并完整显示；MultiSend 内的 NFT 调用逐条标注。
- NFT 市场签名：Seaport 1.5/1.6（含批量挂单）、LooksRare v2 解码为“你给出 / 你收到 / 其他人收到”，并对 0 价、价格降到 0、任意代币可被挑走、永不过期、被伪装成 NFT 的 ERC-20 等钓鱼特征给红色警告；Blur 的盲签 Merkle root 标为未解码的高风险。
- Solana：0 位小数、数量 1 的 SPL 转账（“likely NFT”）、Metaplex Token Metadata TransferV1、Bubblegum 压缩 NFT、Core TransferV1、Token-2022 转账钩子、NFT 委托/锁定/销毁，以及市场程序名称。
- 审核卡片新增 NFT 图标、NFT 合约（not verified）或 Mint/Asset ID 地址框、完整 Token ID、给出/收到/其他收款列表。所有常量按官方仓库核对并经独立复核；NFT 显示从不使用绿色“已验证”提示。

**8. Tap to Reveal**：点一下直接显示，不再弹确认框；截屏、切后台、录屏时仍立即遮盖，截屏警告确认前不能再次显示。

**9. 二维码**：改为 Ownbit 式的助记词明文二维码（单词以空格分隔，不含 passphrase），默认模糊，点一下显示；上方说明用途，下方红字警告，不提供保存或分享。导入扫码时按二维码原样拼写，不再询问语言。上一版的加密备份（`BSBK1:`）、备份密码表单和相册写入权限已全部移除。

**10. 助记词卡片（2/3）**：“Word Cards”改为 Ownbit 式的 Recovery Cards：三张卡片各隐去三分之一的单词（显示为 xxxx），任意两张可恢复；布局只取决于单词数（每行三个位置、每行各隐去一个），重复打开或在其他设备上生成都一致；默认遮盖、点一下显示。12/15 词时单张卡片只缺 40/50 位，界面会提示单张卡片也要妥善保管。

**测试与审查中发现并修复的问题**
- 连接页把 TRON 的索引也发给了 BTC/EVM/SOL，改过 TRON 索引后其他链会报错不出二维码（独立审查发现）。
- 打开 Recovery Cards 或 Security Tips 时，被遮住的助记词视图仍在监听截屏：一次截屏会同时触发两个警告，可能让“Tap to Reveal”失效。现在被 sheet 遮住时暂停下层会话。
- 3 列单词网格在 375 pt 宽的 iPhone（SE、mini）上会把 8 个字母的单词截成 “…”（Revision 2 起就存在），可能导致抄错。现在按实际宽度和字号计算列数，放不下就改为 2 列或 1 列；备份、卡片和补全检查三处都已处理。
- 12/15 词时卡片说明原先写“丢一张仍然安全”，与熵计算矛盾，已按单词数改写。
- 地址索引行：6 位以上时标签被挤成两行、路径被截断；输入框宽度不随字号变化；超出上限时显示的数字与实际导出不一致。均已修正。
- Multisig 开关状态带到 EVM 页，使 EVM 显示 “Cosigner account path”。已修正。
- 助记词扫码出错时显示的是签名请求的文案。已按用途区分。
- 二维码页的 “Hide QR Code” 在底栏下方时无法点到；已移到二维码正下方。
- Token 构建：CoinGecko 给 DoubleZero（2Z）的图片是“破图”占位图，自动检查未能识别；已剔除该代币并按哈希拦截。另一工具留在缓存中的非标准 404 标记会导致构建崩溃，已清理。

### Revision 3 后续修改（同日）

- **单词字号统一、全部完整显示**：此前每个格子各自缩小以放下单词，长词比短词小，放不下时还会出现 “proper…”。现在同一张网格只用一个字号：取能完整放下最长单词的最大字号（不小于正常字号的 80%）；再小就改为 2 列或 1 列。助记词网格、恢复卡片、补全检查三处一致。
- **钱包级配对（Wallet Level）**：按用户提供的 *BitTool Signer Wallet-Level QR Pairing Protocol v1* 草案实现，Connect 页顶部新增 Coin Level（默认，原有各链格式）/ Wallet Level 切换。按用户后续要求，Wallet Level 只有一种类型：一个静态二维码（单个 `ur:bytes`，不分帧、不动画）只包含 BTC（BIP84）、EVM、TRON 的账户级 xpub 和 1 个 Solana 地址（`m/44'/501'/0'/0'`；Ed25519 为硬化派生，没有 xpub），界面不出现 Simple/Full 字样。测试钱包的载荷为 755 字节，二维码文本 1533 个字符（QR 版本 23，纠错级别 L）。编码为 `ur:bytes` + canonical CBOR（RFC 8949 §4.2.1，字段名即 JSON 键名），另加 `masterFingerprint` 字段；精确规则与测试向量见 [docs/Wallet-Pairing-v1.md](docs/Wallet-Pairing-v1.md)。默认支持的钱包为 **BitTool Wallet**（BITTOOL PTE. LTD.，iOS；按用户指定列出，官方图标已加入并记录来源），Connect 页与 Settings › Compatibility 都会显示。Solana 地址直接取已有的标准预设，公开索引保持版本 1，已有钱包无需 Repair。（中间版本曾导出 10 个 Solana 账户并为此把公开索引升到版本 2，已按用户要求撤回。）
- **后台任务**：用户看到的 3 个 “running” 任务核实过：没有进程在运行，所有工作都已完成；其中两个是已结束的子任务残留的监听记录，已清理。
- **真机启动卡在启动页、后台卡片变深色**：不是 App 代码问题。Xcode 在 14:58 两次 Run 重叠，第二次附加调试器失败后在手机上留下了孤立的 debugserver；此后每次 Run 都停在 “Launching suspended and the debugger is responsible for resuming”，App 进程被挂起、一行代码都没执行，所以手机上一直是系统启动图（不跟随 App 内外观设置）。清除调试会话后恢复正常。另外在模拟器上逐一验证了外观组合（系统浅/深 × App 设置 System/Light/Dark，以及进入后台后系统外观切换）：切到后台后的卡片一直跟随 App 设置；只有 App 设置为 System、手机自己切换到深色时卡片才变深色，这是正确行为。作为加固，隐私遮罩窗口现在显式使用 App 的外观设置（改设置时实时更新）；录屏或镜像时遮罩上会说明“Hidden while your screen is recorded or mirrored”，不再像启动卡住。
- **钱包级二维码改为一个静态大码**：不再分 4 帧动画，改为单个 `ur:bytes`（单段 UR，1533 个字符，QR 版本 23、纠错 L），页面上以最大 360 pt 显示。载荷超过 1024 字节时拒绝导出，保证始终能放进一个易扫的二维码；解码端仍接受其他导出方的多段 `ur:bytes`。
- **Address type 右侧内边距**：原来是菜单样式 Picker，系统自带的内边距在各 iOS 版本不同，值和箭头几乎贴着卡片右边。现在改成自定义标签的 Menu，左右各 14 pt，整行可点；辅助功能大字号下改为上下排列，VoiceOver 同时读出当前值和说明。Connect 与 Addresses 共用。
- **TRON 地址列表不再显示派生路径**：分组标题由 “Receive · m/44'/195'/0'/0/i” 改为 “Receive · TRX and TRC-20 tokens”（与 BTC 的 “Receive · Native SegWit”、EVM 的 “Receive · All EVM networks” 同一写法）；BTC 页脚也去掉了 “(…/0/i)”。UI 测试与截图巡检新增 TRON 地址列表。
- **首次从主页进入 Connect 时动画中途停顿**：在模拟器上用计时探针（不经过 XCUITest，避免其无障碍查询干扰）实测：首次进入时 JS 引擎冷启动，配对结果在滑入动画进行到一半时才返回，主线程随即插入二维码、验证卡片并重排整页（约 300 pt 位移并带淡入动画），CoreImage/Metal 首次渲染二维码也在同一时间。修复：钱包显示出来后（App 处于前台、未锁定、未录屏），在后台为每个钱包预先生成 Connect 默认打开的二维码（BTC Native SegWit 账户 xpub，只用本机已认证的公开索引，仅存内存）；Connect 页打开时直接带着成品，推入动画期间不再调用引擎、不再渲染二维码、不再重排。二维码改用 CPU 渲染（1 像素/模块，开销极小），避开 Metal 首次初始化；未命中预生成时，首次结果也不再带淡入动画。实测首次推入：原来开头 286–329 ms 的卡顿加动画中途再 75–83 ms；现在只剩开头一次约 190 ms（Debug 构建，页面首次构建），动画中途没有停顿。预生成结果与 warm JS 上下文在切到后台、App Lock、录屏时清除（此前文档写明 warm VM 会在后台释放，但代码并未调用，现已补上），回到前台后重新预生成。

### Revision 3 后续修改（第二轮）

- **钱包标识改为指纹**：钱包卡片、详情页、审核页的签名钱包、密码输入头部和 Activity 详情，原来的 “Wallet ID”（`walletKeyId` 截断）统一改为 **Fingerprint**，显示 BIP32 master fingerprint（如 `C6A5A927`），与 Wallet Level 载荷中的 `masterFingerprint`、Connect 页的 Master fingerprint 完全一致。签名记录新增保存指纹。内部身份与请求匹配仍用 `walletKeyId`，指纹只作显示。App Lock 解锁前的钱包选择只显示钱包名：指纹也会出现在导出的 PSBT/xpub 里，不在解锁前暴露。
- **Coin Level 每个二维码增加 Payload**：验证卡片在指纹下面新增 “Format”（如 `ur:crypto-account · CBOR · 162 bytes`）和默认折叠的 “Payload (JSON)” / “Payload (Text)”。内容由引擎把刚生成的帧重新解码得到，字段名按 BC-UR 注册表，详见 [docs/Compatibility.md](docs/Compatibility.md) 的“二维码载荷视图”。UR 中的指纹是 32 位整数，Payload 区会注明对应的十六进制指纹。Wallet Level 改用同一个组件。复制改为 “Copy Payload”（本机、会过期的剪贴板），不再允许把全文选中复制到通用剪贴板。
- **审核页签名钱包卡片精简**：详情里已经列出请求的签名地址和派生路径（EVM、Solana、TRON）时，签名钱包卡片不再重复；比特币 PSBT 的详情里没有签名路径，所以仍然显示。
- **Format 与 Master fingerprint 顺序统一**：Coin Level 与 Wallet Level 的验证卡片都是 Format 在上、Master fingerprint 在下，最后是 Payload。
- **使用条款与隐私政策改为随 App 内置（v1.0）**：原来 Settings › About 和欢迎页底部是指向 `bittool.com/signer` 的网页链接，点击会跳出到浏览器（页脚那句 “Legal links open in your browser.” 就是在提示这一点，现已删除）。这与“全程离线”矛盾，且未上线时链接也打不开。现在两份英文文档 `BitToolSigner/Resources/TERMS_OF_USE.txt`、`PRIVACY_POLICY.txt` 随 App 打包，在 App 内阅读（Settings › About 进入页面，欢迎页以 sheet 打开），可选中复制，全文不含任何网址。这是对 [Revision 1 规范](docs/Modification-Spec-2026-09-21.md) 中 D27 的有意改动。
  - 隐私政策逐条对应实际行为：不收集任何数据、无网络代码、无第三方 SDK；本机保存的内容（加密的助记词与 passphrase、带认证标签的公开钱包数据、最多 100 条 Activity 记录、偏好设置）、文件保护与不进备份；相机只在扫码时打开且不保存帧；Face ID 只返回成功与否；复制只进本机剪贴板并在两分钟后过期；切后台、录屏与镜像时遮挡界面；删除钱包或 App 会一并删除 Keychain 中的设备密钥。
  - 文档中 `[Publisher legal name]`、`[Governing law jurisdiction]`、`[Contact email]` 三处占位需在上架前填写；单元测试会检查不出现其他占位符、不出现任何网址。
  - 初稿由多个审查者逐句与代码核对，改掉了几处不实表述：备份页的助记词明文二维码属于“会离开设备”的例外；偏好设置存在 UserDefaults，会进入设备备份（钱包文件、公开数据、Activity 才不进备份）；删除钱包不会删掉它的 Activity 记录（界面显示为 “Deleted wallet”）；删除 App 后 Keychain 里的设备密钥可能残留；Activity 记录字段补全；补上失败次数计数文件；文件导入导出可能落到 Files 里的云盘目录。Terms 补上 passphrase 与忘记密码的说明、Apple 要求的 EULA 最低条款、修正条款存续清单。
  - 顺带修好 Settings › Third-Party Licenses：原文件有 3 条 “undefined undefined” 和 1 条 “[object Object]”。新增 `scripts/build-third-party-licenses.mjs`，直接按 `engine/bundle-manifest.json` 里实际打包的 67 个包重新生成（含嵌套的 @noble/curves 1.2.0、@noble/hashes 1.3.2、ethers 6.17.0），每条都有名称、版本、许可证与完整许可证文本。
- **钱包详情页新增 Wallet Level 入口**：Connect 分组在四条链下面多了一行 “Wallet Level · One QR code for all four chains”，点进去直接打开 Connect 的 Wallet Level（新路由 `WalletRoute.connectWallet`）。
- **签名结果页**：底部只保留 **Done** 一个主按钮。结果二维码下方新增卡片：Format、默认折叠的 “Payload (JSON)”（eth/sol/tron 签名显示 `request-id` 与 `signature`；比特币显示 `psbt_base64` 与按 Bitcoin Core `decodepsbt` 字段名解析的 `decoded`（排在前面，大 PSBT 截断显示时仍可见）），以及降级为次要操作的 “Export as File”。

## Revision 2.1（2026-09-22）：多语言助记词导入与新的备份流程

本次按新增需求实现两项：一是导入 BIP39 其他语言的助记词；二是参考 Ownbit 最新方案重做助记词备份，样式沿用本 App 的配色和组件。

**多语言导入**
- 支持 BIP39 官方全部 10 种词表：English、简体中文、繁體中文、日本語、한국어、Español、Français、Italiano、Čeština、Português。
- 词表逐字节取自 bitcoin/bips，固定 SHA-256，并与 @scure/bip39、ethers 两个独立来源逐词核对。校验（含 checksum）改为原生实现。
- 输入时实时识别语言，状态栏显示语言名，候选词也来自该语言。
- 可不输入重音、可用大写、可带编号或逗号；中文可不加空格，日文可用全角空格。App 始终换回官方拼写再计算 seed，vault 以 NFC 保存。
- 一组不带重音的词可能在两种语言中都有效，并对应两个不同的钱包（测试找到的实例：意大利语 “nomina solido comodo …”，加上重音后也是有效的西班牙语）。这时 App 请用户选择备份所用的语言，不会自行猜测。输入了重音则按原拼写处理。
- 助记词输入框改用系统键盘，以便使用苹果的中文、日文、韩文输入法；第三方键盘仍在全 App 范围内被拒绝。

**新的备份流程**
- 备份页顶部可切换“单词 / 二维码”：
  - 单词默认模糊，确认后才显示。
  - “Word Cards”每次只显示一个大号单词（Revision 3 已改为 2/3 Recovery Cards）。
  - “Security Tips”集中列出安全提示。
  - 单词显示过一次后，才能点底部的 “I’ve Written Them Down in Order”。
- 二维码页曾生成加密备份二维码（Revision 3 按用户要求改为助记词明文二维码，加密备份已移除）。
- 检查页改为补全空缺单词：
  - 所有位置显示为 “n. ••••••”，其中 4 个（18 个词以上为 5 个）留空；空位对应的单词打乱后显示在底部（固定在底栏，小屏也始终可点）。
  - 按顺序点选补全；点空位可指定下一个要填的位置，点已填的位置可撤回；当前空位会自动滚动到可见处。
  - 答错会清空已填的词，但空位和单词顺序不变；切到后台或截屏也会清空。

**本次测试发现并修复的问题**
- 忽略编号（如 “1.”）的规则原本按 Unicode 数字判断，导致 “一”“十” 等中文数字助记词被丢弃；现只忽略 ASCII 数字。
- 上述跨语言歧义原本会被静默导入为另一个钱包；现改为优先精确拼写，有歧义时请用户选择。
- 备份密码表单中按 Return 不会跳到确认框（该表单已在 Revision 3 移除）。
- 小屏上补全用的单词被底栏遮住，需先滚动才能点击；现固定在底栏。当前空位的高亮被系统的禁用样式变灰；现已修正。
- 导入页文案仍写 “English words”，已改为支持十种语言。
- 辅助功能大字号下：助记词状态会被截断，现改为换行显示；二维码页两个按钮改为纵向排列；“Security Tips” 移到底栏主按钮上方（与 Ownbit 布局一致），任何字号下都可点击。
- 用歧义短语制作的加密备份在恢复时会再次询问语言（Revision 3 改为：扫描的助记词二维码按原拼写导入）。

## 测试结果

| 检查 | 结果 | 范围 |
|---|---|---|
| JS 引擎（Node） | **173/173 通过** | 协议、公开索引、resolver、四链签名、`hardening.test.mjs`（Revision 2 审查问题回归）；Revision 3 新增钱包级配对（单个静态二维码、3 个 xpub + 1 个 Solana 地址、canonical CBOR）、NFT 显示（EVM 与 Solana）、TRON 任意索引、BTC 默认 Account XPUB，以及二维码载荷视图（22 种 Connect 导出、17 种签名返回；重新解码帧、UR 与签名与 Keystone 解析器核对、原始字节中无私钥）；Token 表逐项核对全部 3,350 条记录（地址形态、唯一性、链上 decimals、图标包无空洞且每张图的哈希等于其 id、Solana 的 token program 绑定） |
| 原生单元测试 | **117/117 通过**（Swift Testing 计数） | 真实 JavaScriptCore bridge、载荷视图解析与签名结果载荷、签名记录保存指纹、vault 与公开索引 HMAC、钱包级配对（只读公开索引、单个静态二维码、恰好 3 个 xpub 和 1 个 Solana 地址、公开索引版本 1）、Connect 预生成（仅在允许时生成、挂起时清除、过期结果丢弃）、隐私遮罩窗口跟随 App 外观、恢复卡片 2-of-3 布局、单词网格统一字号、恢复隐私（直接显示、截屏提示）、扫码用途、兼容钱包列表（含 BitTool Wallet、无 Ownbit）、NFT 显示、十种 BIP39 语言 |
| UI 自动化 | **15/15 通过**（同一次完整运行） | iPhone 17 Pro · iOS 26.4 模拟器，隔离 fixture，公开无资金向量；含 Connect 链选中态、TRON 任意索引、Wallet Level（“one Solana address”、BitTool Wallet）、TRON 地址列表不显示派生路径、钱包卡片显示指纹、Coin Level 载荷展开、签名结果页只有 Done 主按钮且载荷与导出在卡片内、备份页恢复卡片与明文二维码 |
| 截图巡检 | **全部通过** | iPhone 17 Pro 浅色／深色（120 张）、iPhone SE 第三代 iOS 17.2 浅色（60 张），新增 TRON 地址列表、使用条款与隐私政策 |
| Release 真机构建 | **通过** | `generic/platform=iOS`，未签名，App 19 MB |
| Bundle | 854,090 bytes | SHA-256 `36a00e6a35405519baf58595d09029ed099626beb52f37634fea71db5fc6d72b`，见 [engine/bundle-manifest.json](engine/bundle-manifest.json) |

UI 自动化流程：引导只出现一次且保留导入意图；导入并封存钱包；创建（隐藏式备份、重新显示、后台隐藏、按顺序补全空缺单词、顺序错误后空位不变、撤回已填单词、后台清除已填单词与密码）；备份页的 Recovery Cards（2/3）、Security Tips 与助记词明文二维码；导入不带重音的西班牙语助记词并识别语言，以及意大利语／西班牙语歧义时请用户选择；“再看一遍助记词”回到同一草稿；导入草稿跨后台保留；粘贴请求 → 自动匹配 → 风险确认 → 后台清除授权 → 错误密码 → 签名 → Activity → 清空；拒绝请求；整张扫码卡片打开相机；Connect / Addresses 只用公开数据；改密码（错误密码有提示、留在原页面、旧密码失效、后台不崩溃）；改名后删除最后一个钱包回到欢迎页；App Lock 冷启动、Face ID 取消、错误密码、钱包密码解锁、短暂后台不再锁；Settings（App Lock 需生物识别成功、Networks & Tokens 列表与搜索、兼容页跨后台保留、离线指南）。

## 本轮主要变更

### 界面

- 新结构 `Features/{Main, Wallets, Setup, Onboarding, Sign, Activity, Settings, Lock}` 与共用 `Design/`，删除旧 `Views/`。
- 底部 4 个 Tab：Wallets · Scan · Activity · Settings。Tab Bar 始终展开，滚动后也不收起，保证 Activity 和 Settings 随时一步可达。
- 设计系统：系统分组背景、卡片、Liquid Glass 主次按钮（iOS 17/18 为填充／描边胶囊按钮）、底部操作栏（iOS 26 `safeAreaBar`）、Callout、状态胶囊、地址分组显示（首尾加粗）、复制提示，以及可被 VoiceOver 读出的状态提示。
- 钱包卡片：按密钥身份生成的色块头像、名称、主指纹（Revision 3 后续由 Wallet ID 改为 Fingerprint）、网络图标，以及 Connect / Addresses 快捷入口。详情页包含四链配对、收款地址、助记词、改密码、改名、删除与修复。
- 创建／导入：统一的步骤页面；输入助记词时实时计数并检查单词；候选词在键盘上方；支持 SeedQR；BIP39 passphrase 可选；密码强度与要求清单；完成页可直接去配对。
- 签名：扫码卡片整体可点；审核页依次为摘要（金额、对方地址、网络与代币图标）→ 警告 → 签名钱包 → 完整字段 → 请求指纹；风险确认和 Sign 固定在底部；授权 sheet 单独输入密码；结果页显示动画 QR 并可导出文件。
- Activity 按日期分组，有详情页，可清空；Settings 含 Face ID 锁、外观、Networks & Tokens（可搜索）、兼容说明、离线指南、Open Source 与法律文档。
- 品牌：App 图标、启动画面与应用内标识按原有 “B + 闪电签名带” 概念重新绘制为精确矢量（[design/Brand.md](design/Brand.md)，`scripts/make-brand-assets.py` 可重复生成）。BTC、ETH、BNB Chain、Arbitrum、Base、TRON、Solana 七个网络图标为矢量重绘。
- 文案统一为 “this device”，适配 iPhone 与 iPad；相机权限说明改为实际用途（扫描签名请求和助记词二维码）。

### 安全、逻辑、JS 与密码学

内部审查发现的问题均已修复，并有回归测试（明细见 [docs/Security.md](docs/Security.md#2026-09-21-review-fixes)）：

- **F1（严重）**：EIP-712 值必须与声明类型严格一致。此前真值字符串可能被当作 `bool: true` 签名，而界面显示的是字符串。
- **F2**：`eth-signature` 的 `v`：legacy 交易为 EIP-155，typed 交易为 y-parity。
- **F3–F6、F10–F12**：Safe gas refund、原生币附带金额、手续费、TRON call value 与 fee limit、非文本 TRON 消息、Solana durable nonce、Token 表外代币转账都会在审核中显示，需要时提高风险等级；摘要不再把不同转账的金额和地址拼在一起。
- **F7、F14**：拒绝歧义的整数和地址写法；按声明的 domain 顺序计算 separator；未使用的类型被忽略。
- **F8**：App Lock 的后台计时改用设备休眠期间也继续走的时钟。
- **F9**：vault 格式 2 以存储的原始 header 字节作为 AES-GCM 认证数据。
- **F13**：动画 QR 在每次扫码的独立上下文中增量收集，结果与批量解码一致，并拒绝混入其他请求的帧。
- **F15**：支持 `ur:psbt` 请求（以同类型响应）以及多行折叠的 Base64 PSBT 文件。
- **F16**：Release 版只开放固定的引擎操作白名单。
- **F17**：公开索引文件使用 Keychain 密钥做 HMAC-SHA256 认证，被篡改时要求修复。
- **F18**：Taproot（BIP340）签名使用新的 32 字节辅助随机数。
- BTC 找零只认可由签名钱包自身公钥重新派生出的输出。

性能与引擎边界：BIP39 seed 改为原生 CommonCrypto 计算。JSC 在 iOS 上没有 JIT，JS 版 PBKDF2 约 0.6 秒，原生只需几毫秒；创建、导入、签名因此明显更快。凡涉及秘密或外部输入的操作都使用全新 JS 上下文；只有读取本机公开索引的地址页和配对页复用一个预热上下文，进入后台即丢弃。

### Token 表与图标

- 离线 Token 表共 **3,350 条**，分两层。人工核定层 596 条（Ethereum 196、BNB Smart Chain 112、Arbitrum One 67、Base 86、TRON 14、Solana 121）：按“各网络实际价值”（CoinGecko 市值与链上供应量 × 价格取较小值）排序，要求交易量、持有人数量和至少一个独立列表佐证，排除股票代币、基金、凭证类代币、已废弃合约和受制裁资产。榜单层 2,754 条来自 CoinMarketCap 前 2000，只用于决定收录范围和提供名称/符号/图标，decimals 全部从链上读取，符号以合约自报为准。两层在界面上不作区分，收录都不代表背书。来源、选取方式与排除理由见 [docs/TokenRegistrySources.md](docs/TokenRegistrySources.md)，可用 `scripts/build-token-registry.py` 与 `scripts/build-expanded-registry.py` 复现。
- 覆盖的网络从 6 个增加到 10 个：Polygon、Avalanche C-Chain、OP Mainnet、Gnosis 上的代币现在也能按名称和小数位显示，不再只显示原始数值。
- 图标共 1,985 张（按内容去重，最大 128 px），打包为单个 `TokenIcons.pack` 加偏移表，整套约 10.7 MiB，App 以 mmap 读取、按需解码，永不联网下载。Networks & Tokens 页按网络分组、按排名显示，热门代币在前，并支持按符号、名称或地址搜索。
- 兼容页的钱包图标均为官方 App 图标或官方仓库图标，Revision 3 为 23 个（[来源](docs/WalletLogoSources.md)）。

## 测试中发现并修复的问题

- **崩溃**：在“查看助记词” sheet 显示内容时切到后台，App 必然崩溃（UIKit `NSInternalInconsistencyException`，两个导航栏争用同一导航项）。原因是 `.privacySensitive()` 包在 sheet 的 `NavigationStack` 外层：iOS 26 在后台截图时会遮盖隐私内容，从而触发这一冲突。已移到内部内容上，并用 UI 测试复现后验证修复。
- **错误被吞掉**：改密码或删除钱包时输入错误密码，界面没有任何提示。原因是 store 先调用了 `suspend()` 使会话失效，sheet 再比对会话时丢弃了错误。现在先校验密码，失败时正常显示错误（此前也不会误删，只是没有任何提示）。
- 改密码成功后导航被重置回钱包列表。现在留在原页面，并显示 “Password Changed” 提示。
- 备份校验页的 “Show the Phrase Again” 位于内容底部，与 iOS 26 悬浮底栏重叠，点击中心会落在底栏上。已移入底栏，位于 Continue 下方。
- Networks & Tokens 点击网络无法进入（被推入的页面中使用了值类型 NavigationLink）；iOS 26 下 Token 搜索框默认收起、辅助功能也读不到。现在搜索框始终显示。
- SF Symbols：备份提示使用了不存在的 `camera.slash`，图标空白；Wallets Tab 的 `wallet.bifold` 需要 iOS 18，iOS 17 上会缺图标。已换为有效符号，并按系统版本回退。全部 74 个符号已对照系统符号表核对。
- iOS 17 与小屏（iPhone SE）：禁用状态的主按钮文字在浅灰底上几乎看不见（Sign、Continue、Change Password），现改为灰色文字，忙碌指示同样处理；授权 sheet 在中等高度下文字被截断，改为可滚动内容 + 固定底部 Sign；引导页插图在矮屏上缩小，要点不再被底栏遮住；Activity 标题允许两行；设置中 “Offline Setup Guide” 和法律链接的文字被染成主题绿，已与相邻行统一为正文颜色。
- 创建流程中推入的步骤把 “Back” 与 “Cancel” 挤在左侧；推入步骤的 Cancel 已移到右侧。
- 视觉问题：卡片按钮文字断行出现连字符；导入状态被底部栏遮挡；候选词被挡住；风险确认离 Sign 太远；空状态图标太淡；设置行样式不一致。均已修正。
- 旧截图流程的风险确认控件类型写错，导致从未真正签过名。已随 UI 测试一并重写。

## 界面检查

截图巡检（`BitToolSignerUITests/ScreenshotTour.swift`）覆盖欢迎、引导、导入、密码、创建与备份（隐藏状态）、钱包列表与详情、改密码／查看助记词／删除 sheet、四链 Connect、地址与地址详情、Scan、粘贴、审核（上中下三段与已确认）、授权、签名结果、Activity 与详情、Settings、Networks & Tokens（ETH／SOL／TRON）、兼容页、离线指南和 App Lock。设备与环境：iPhone 17 Pro 浅色和深色（iOS 26，Liquid Glass）；iPhone SE 第三代（iOS 17.2，最小屏幕与旧版样式）；iPad Air 11 英寸（顶部浮动 Tab、表单式 sheet、可读宽度）；AccessibilityL 大字号（徽章自动改为纵向排列、按钮文字可换行、卡片按钮收为图标）。巡检中发现的问题都已修复并复查，见上一节。截图只使用公开测试钱包，不含任何助记词内容。

## 仍需外部验收

- **真机**：Keychain 与设备密码、Face ID 成功／失败／锁定、相机扫码、截屏与录屏遮盖、文件保护与备份排除、重装、断电中改密码、后台 119／120 秒边界。
- **第三方钱包往返**：Connect 页列出的“可扫码签名”钱包（Sparrow、BlueWallet、Nunchuk、Bitcoin Keeper、BULL Bitcoin、Specter、Bitcoin Safe、ZEUS、MetaMask、Rabby、imToken、TokenPocket、Ambire、Solflare、Helium Wallet）的配对 → 请求 → 签名 → 回扫，以及“仅观察”钱包的地址导入，每条都要记录版本号。官方文档与源码证据不等于已完成真机互通。
- **NFT 市场签名**：用 OpenSea、LooksRare 实际导出的 `eth_signTypedData_v4` 请求在真机验收 Seaport/LooksRare 解码。
- **独立安全审计**、依赖审查、可复现构建，以及 TestFlight／App Store 签名分发。
- Token 排名反映 2026-09-21 的数据快照，只影响浏览顺序，不影响签名与风险判断。
