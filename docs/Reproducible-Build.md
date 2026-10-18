# 可验证构建：如何核对你装的这个 App 就是这份源码

BitTool Signer 是离线签名器，它唯一的价值在于**你可以不相信我们**。所以这篇文档要诚实地写清楚：**哪些能验证、哪些验证不了、为什么。**

## 先说验证不了的那部分

**App Store 的二进制无法做字节级复现。** 这不是我们偷懒，是平台决定的：

1. 你上传的包会被 **Apple 重新签名**，签名数据因此和你本地构建的不同；
2. 下发到设备的可执行文件带 **FairPlay 加密**（Mach-O 里的 `LC_ENCRYPTION_INFO_64`，`cryptid=1`），同一份代码在不同时间、不同账号下载到的密文都不一样；
3. Xcode 与 Swift 编译器本身也不保证逐字节确定性（路径、时间戳、符号顺序都会进去）。

任何声称「App Store 应用可以字节级复现」的说法都是错的。**所以不要去对比可执行文件的哈希，那条路不通。**

## 能验证的那部分，而且这恰好是最要紧的部分

`.ipa` 里**只有主可执行文件被 FairPlay 加密，资源文件不加密**。而 BitTool Signer 的全部交易解析、风险判断与签名逻辑都在一个资源文件里：

```
BitToolSigner.app/signer.js
```

这是一个由 `engine/src/` 打包出来的 JavaScript 文件，**可以从你自己手机上装的那个包里原样取出来，和你自己从源码重建的结果逐字节比较**。换句话说：决定「你签的到底是什么」的那部分代码，是可验证的。

> 原生 Swift 层负责界面、Keychain 与加密存储；它的源码一并公开，但只能靠阅读审查，不能靠哈希比对。两者的分工就是这篇文档的边界。

## 第一步：从源码重建引擎

需要 Node.js（版本见 `engine/package.json` 的 `engines` 字段；发布时用的确切版本记在 `release-manifest.json` 里）。

```bash
git clone https://github.com/bitbill/bittool-signer-ios
cd bittool-signer-ios
git checkout v1.0.0            # 或你要核对的那个 tag / commit
cd engine
npm ci --ignore-scripts        # 按 lockfile 安装确切版本，不跑任何安装钩子
npm run build
shasum -a 256 ../BitToolSigner/Resources/signer.js
```

`--ignore-scripts` 不是可选项：依赖的安装钩子能改动构建结果，关掉它才能保证你拿到的是 lockfile 描述的那份代码。

得到的哈希应当与 `release-manifest.json` 里的 `engineBundle.shippedSHA256` 一致，也与仓库里 `engine/bundle-manifest.json` 记录的一致。仓库里那份 `signer.js` 是提交进去的产物，`npm run build` 会原地覆盖它——所以如果 `git status` 在构建后仍然干净，就说明**提交的产物和源码重建的结果完全相同**，这本身就是一次验证：

```bash
cd .. && git status --porcelain BitToolSigner/Resources/signer.js   # 无输出 = 一致
```

## 第二步：从你装的那个 App 里取出 signer.js

不需要越狱。

1. 在 Mac 上用 **Apple Configurator** 登录你的 Apple ID，把 App 下载为 `.ipa`
   （`Apple Configurator` → 设备 → 添加 → 应用，下载的包在
   `~/Library/Group Containers/K36BKF7T3D.group.com.apple.configurator/Library/Caches/Assets/TemporaryItems/MobileApps/`）；
2. `.ipa` 就是 zip：

```bash
unzip -o BitToolSigner.ipa -d extracted
shasum -a 256 extracted/Payload/BitToolSigner.app/signer.js
```

把它和第一步的哈希对比。**一致，就说明你手机上跑的交易解析代码正是这份源码编译出来的。**

## 第三步：核对整份源码快照

`scripts/release-manifest.sh` 会生成一份发布清单：

```bash
scripts/release-manifest.sh
```

它要求工作区干净（否则清单会指向一个别人签不出来的状态），然后输出：

- `SHA256SUMS.txt`：**每一个被 Git 跟踪的文件**的哈希，顺序固定，方便两份清单直接 `diff`；
- `release-manifest.json`：commit、文件数、清单哈希、引擎产物的哈希，以及**在一份干净克隆里重新安装依赖后重建出来的哈希**——记录下来的是一个「能复现」的哈希，不是「本机恰好存在」的哈希；
- `clean-install.log` / `clean-build.log`：上面那次重建的完整输出。

第三方要核对，只需在同一个 tag 上自己跑一遍，然后比较两份文件：

```bash
diff release/SHA256SUMS.txt their-SHA256SUMS.txt
```

## 第四步：别只看哈希，去读代码

哈希只证明「你看到的源码就是打包的源码」，不证明这份源码是安全的。真正值得花时间的是这些地方：

| 看什么 | 在哪 |
| --- | --- |
| 交易解析与风险判断（决定你看到的摘要对不对） | `engine/src/bitcoin.js`、`evm.js`、`solana.js`、`tron.js` |
| 签名计划与签名字节（决定你签的到底是什么） | `engine/src/resolver.js`、`engine/src/keys.js` |
| 助记词加密存储 | `BitToolSigner/Core/VaultCrypto.swift`、`WalletVault.swift` |
| 密码授权与会话失效 | `BitToolSigner/Models/AppStore.swift` |
| 「不联网」这件事 | 全仓库搜 `URLSession`、`Network`、`CFNetwork`；并在构建产物上跑 `otool -L`（不应出现 CFNetwork 或 Network.framework） |

引擎产出的审核文案**只有英文**，这是故意的：那段文本被请求指纹覆盖，重建引擎时必须逐字节复现，不能随界面语言变化。界面在绘制的最后一刻翻译它（`BitToolSigner/Models/ReviewText.swift`）。

## 这份文档承诺与不承诺什么

**承诺**：公开的源码、锁定的依赖、可复现的引擎产物，以及一条你能自己走完、不依赖我们的核对路径。

**不承诺**：没有未知缺陷。哈希一致只说明代码没被替换，不说明代码没有 bug。请把资金风险和你自己的审查结论放在一起判断。
