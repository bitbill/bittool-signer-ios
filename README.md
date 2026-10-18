# BitTool Signer iOS · 1.0.0

**BitTool Signer**（BitTool 签名器），BITTOOL PTE. LTD. 出品的离线签名 App，与 **BitTool Wallet**（BitTool 钱包）配套使用：[bittool.com](https://bittool.com) · [bittool.com/signer](https://bittool.com/signer) · [bittool.com/wallet](https://bittool.com/wallet)。两个 App 共用同一个标记，签名器用深色版本，钱包用浅色版本。本仓库即 App 的开源代码：[https://github.com/bitbill/bittool-signer-ios](https://github.com/bitbill/bittool-signer-ios)。图标下的名称按设备语言显示（`BitToolSigner/<语言>.lproj/InfoPlist.strings`，共 10 种），App 界面本身为英文。

SwiftUI + JavaScriptCore 离线签名器，最低 iOS 17，iOS 26 使用 Liquid Glass。Revision 3（2026-09-22）按反馈修复了连接页卡住、加入 NFT 审核、扩充 Token 表与钱包列表并改用 Ownbit 式备份；Revision 2（2026-09-21）在尚未发布的工程上做了全面重构：界面按原生设计重写，安全、逻辑、JS 引擎与密码学经过审查和加固，测试全面补齐。App 未上线，因此本轮直接采用新的存储格式，不迁移旧开发数据。

**测试结果、修复清单与仍需外部验收的范围见 [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md)。工程可编译、测试通过，不等于已获第三方钱包兼容认证或独立安全审计。**

## 许可与审查

代码以 [MIT License](LICENSE) 发布（BITTOOL PTE. LTD., 2026）。

[docs/audit/](docs/audit/) 收录了一次 AI 辅助的代码审查及其 4 条发现的修复记录。
**那不是第三方独立安全审计**，也不构成任何安全保证；独立审计仍在待办清单里。

## 运行

打开 `BitToolSigner.xcodeproj`，选择 BitTool Signer scheme。真机创建钱包需要设置系统锁屏密码，并配置自己的 Development Team。JavaScript 引擎、Token 表和全部图标都随包提供，运行时不联网。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project BitToolSigner.xcodeproj -scheme BitToolSigner \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO test

cd engine
npm ci --ignore-scripts
npm test
npm run build
```

开发时安装依赖需要网络；App 运行时不下载依赖、不执行远程代码。截图巡检见 `BitToolSignerUITests/ScreenshotTour.swift`：设置 `TEST_RUNNER_BITTOOL_SIGNER_SHOT_DIR` 可把浅色／深色截图写到本机目录；设置 `TEST_RUNNER_BITTOOL_SIGNER_EXTRA_ARGS` 可附加启动参数（例如更大的动态字体）。

## 界面结构

底部四个 Tab：**Wallets · Scan · Activity · Settings**。

- **Wallets**：所有钱包并列，没有“当前钱包”。卡片显示身份色块、名称、主指纹（Fingerprint，与配对二维码中的 masterFingerprint 相同）和支持的网络，并直达 Connect / Addresses。详情页包含四条链和 Wallet Level 的配对入口、收款地址、查看助记词、改密码、改名和删除；点某条链直接进该链的 Coin Level，点“钱包级”或卡片上的 Connect 进 Wallet Level。Connect 页顶部可切换 Coin Level（各链标准格式）与 Wallet Level（一个二维码包含 BTC、ETH/EVM、TRON 的账户级 xpub 和 1 个 Solana 地址，格式见 [docs/Wallet-Pairing-v1.md](docs/Wallet-Pairing-v1.md)）；链选择器用强调色描边标出当前链；BTC 默认导出 Account XPUB；TRON 可导出任意地址索引（0 到 2³¹−1）。
- **Scan**：整张扫码卡片都可点击，也可粘贴或导入文件。审核页顺序为摘要 → 风险提示 → 签名钱包 → 完整字段 → 请求指纹；风险确认和 Sign 按钮固定在底部。每次签名单独输入该钱包的密码。请求授权出去的地址（approve 的 spender、setApprovalForAll 的 operator、EIP-712 的 spender 或 verifying contract）会与内置的 1,720 个**已知公开合约**离线比对：命中就写出它是谁（例如 `Permit2 — Uniswap · infra`），没命中就直说不在名单里，未收录的 spender／operator 还会抬高风险等级（见 [docs/KnownContracts.md](docs/KnownContracts.md)）。收录只是辨识部署，不代表请求安全。 NFT 转账、授权和市场挂单（Seaport、LooksRare、Blur，以及 Solana 的 Metaplex/Bubblegum/Core）有专门的审核卡片：NFT 合约或 Mint、完整 Token ID、“你给出 / 你收到 / 其他人收到”，并对常见钓鱼特征给红色警告。
- **Activity**：本机签名记录，按日期分组；BitTool Signer 不广播交易。每条记录都能看到**输入与输出**：输入是当初签的那份请求（打开时重新交给引擎审核一遍，字段与审核页一致，请求指纹必须对得上，也可展开原文），输出是产出的那份签名（可重新显示二维码给对方钱包扫、可导出文件、可展开原文）。只为最近 25 条保留原文，更早的记录只留摘要；存的都是公开数据，文件带完整加密保护、不进备份。
- **Settings**：Face ID 锁、外观与界面语言（简体中文／繁體中文／العربية，阿拉伯语为从右到左布局；其余语言陆续补齐）、Networks, Tokens & Contracts（离线 Token 表 3,350 条覆盖 10 条链，以及 1,720 个已知公开合约地址，均可搜索）、兼容说明（按“可扫码签名 / 仅观察”列出核实过的钱包）、离线设备指南、Open Source（开源说明、仓库地址、本机构建信息与第三方声明）、版本与运营主体。
- 首次使用：欢迎页 → 三页引导（只出现一次，保留创建／导入意图）→ 创建四步（生成 → 备份助记词 → 按顺序补全空缺单词 → 设置密码）或导入两步（输入并校验 → 设置密码）。
- 备份助记词（参考 Ownbit 方案，沿用本 App 配色）：顶部可切换“单词 / 二维码”。单词、二维码和助记词卡片都默认遮盖，点一下就直接显示（不再弹确认框）；截屏、切到后台或录屏时立即重新遮盖。“二维码”是助记词明文二维码，只用于在私密环境下迁移到自己的另一台设备，不提供保存或分享。“Recovery Cards”把助记词分成三张卡片，每张隐去三分之一，任意两张即可恢复；12/15 词时提示单张卡片泄露过多。“Security Tips”集中列出安全提示；底部“I’ve Written Them Down in Order”进入检查。检查页只遮盖大部分单词，其中 4–5 个位置留空，需按顺序点选打乱的单词补全。
- 导入支持 BIP39 全部 10 种语言：English、简体中文、繁體中文、日本語、한국어、Español、Français、Italiano、Čeština、Português。自动识别语言并校验 checksum；西班牙语、法语可不输入重音，中文可不加空格。若同一组词在两种语言中都有效（会得到两个不同钱包），App 会请你选择备份所用的语言。输入时，候选词显示在键盘上方，也支持扫描助记词二维码（含 BitTool Signer 自己的助记词二维码）和 SeedQR。

BTC、ETH、BNB Chain、Arbitrum、Base、TRON、Solana 的网络图标和 App 图标都是矢量重绘（见 [design/Brand.md](design/Brand.md)），其余代币图标来自核对过的官方来源与 CoinMarketCap 榜单图，按内容去重后打包在一个文件里（见 [docs/TokenRegistrySources.md](docs/TokenRegistrySources.md)）。

## 安全模型要点

- 每个钱包独立加密：PBKDF2-HMAC-SHA256 600,000 次 + AES-256-GCM，外层再用仅本机 Keychain 设备密钥加密。vault 格式 2 以存储的原始 header 字节作为认证数据。
- 使用条款与隐私政策（v1.0，英文）随 App 内置，在 Settings › About 与欢迎页内阅读，不跳转浏览器；App 全程不发起任何网络连接。
- 地址与配对只读取本地公开索引，不解锁 seed。公开索引文件带 HMAC-SHA256 认证（Keychain 密钥），被篡改或缺失时进入“Repair”，输入一次密码即可重建。
- 扫码 → 本地解析 → 按公钥自动匹配钱包 → 固定签名任务 → 每个任务单独输入密码。没有手动选签名钱包、全局解锁或免密签名。
- BIP39 seed 由原生 CommonCrypto 计算后交给引擎。凡涉及秘密或外部输入的引擎操作都在全新的 JavaScriptCore 上下文中执行，Release 版只开放固定的操作白名单。
- App Lock 可选，默认关闭，只保护界面，从不授权签名。冷启动、或后台满 120 秒（计时包含设备休眠）后需要重新验证。进入后台时立即清除密码、风险确认和已显示的助记词。

完整说明见 [docs/Security.md](docs/Security.md)。

## 文档

- [实施状态、测试结果与修复清单](IMPLEMENTATION_STATUS.md)
- [安全模型与权限边界](docs/Security.md)
- [协议、导出语义与兼容证据](docs/Compatibility.md)
- [引擎 API 与测试](engine/README.md)
- [Token 表来源与筛选](docs/TokenRegistrySources.md)、[钱包图标来源](docs/WalletLogoSources.md)
- [发行验收](docs/Release-1.0.0.md)
- [品牌与图标](design/Brand.md)

`docs/validation` 中的旧报告只作历史记录，不代表本轮验收结果。
