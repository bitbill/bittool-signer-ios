# BitTool Wallet 开发交付包

> **Renamed, 16 October 2026.** The app is now **BitTool Signer** (BitTool 签名器) and the wallet **BitTool Wallet** (BitTool 钱包), both published by BITTOOL PTE. LTD. The wire identifiers changed with it, and the receiving side must be updated: the payload `protocol` is now **`bittool-signer-wallet`** (was `bitsigner-wallet`), the signing transport type is `bittool-signer-json`, and the device name inside `crypto-account` / `crypto-multi-accounts` is `BitTool Signer`. Everything else in this document is unchanged; the fixtures in this package are regenerated with the new names.

将整个目录或 ZIP 交给 BitTool Wallet 开发人员 / 开发 Agent，首先阅读：

**`BitTool_Wallet_Development_Prompt_2026-09-22.md`**

可以使用这段开场指令：

> 请读取附件中的 BitTool_Wallet_Development_Prompt_2026-09-22.md，在现有 BitTool Wallet 项目中实现 BitTool Signer 离线签名账户。连接使用 wallet-level QR，一次导入四链公开账户；签名使用文档规定的各链 UR 协议。以 fixtures 中当前代码生成的字节向量作互操作基线，完成实现、自动测试及联调说明。先检查现有项目，然后直接执行。

## 内容

| 文件 | 用途 |
|---|---|
| `BitTool_Wallet_Development_Prompt_2026-09-22.md` | 完整开发任务、协议表、产品流程、边界和验收要求 |
| `fixtures/wallet-pairing-current.json` | 当前 wallet QR 的完整逻辑对象、CBOR、4 个动画帧、核对地址 |
| `fixtures/wallet-pairing-no-mode-receiver-extension.json` | 针对参考稿无 mode 字段的热端兼容测试，不是当前冷端输出 |
| `fixtures/signing-roundtrips.json` | 四条链共 9 个请求/响应向量，全部由真实冷端签名代码生成 |
| `fixtures/source-snapshot.json` | 本地源码与应用 JS bundle 的摘要，锁定本包采用的代码快照 |
| `generate-fixtures.mjs` | 在 BitTool Signer 仓库重新生成向量的脚本；不进入 BitTool Wallet 生产包 |
| `VERIFICATION.md` | 本次已经执行的检查及尚未进行的实机/广播验证 |

## 使用注意

当前 wallet QR 为协议 version 1，导出 BTC/EVM/TRON 三个 account xpub 和 **1 个 SOL 标准地址**。`mode: "full"` 是现有 wire 字段，不应成为 UI 模式选择。参考文档、旧实现与当前代码之间的差异已经写入 prompt。

`frames` 中每个字符串应直接编码成 QR 后轮播，不要把整个数组或 JSON 文件生成一个二维码。BC-UR 字符串和其 CBOR hex 是同一内容的不同表示。

签名向量中的 `expected.serializedTransaction`：EVM 是带 `0x` 的 hex，Solana 是 base64；BTC 的 `signedPSBTBase64` 是 PSBT。这些字段用于热端组装结果对照；实际回签 QR 通常只返回签名，BTC 返回 PSBT。生产实现必须独立验签，不使用固定 expected 字符串替代验证。

这些向量来自公开的 BIP39 测试账户。所有交易均为测试用途，含人工 UTXO / blockhash / reference block，**不广播，不存放资产**。不需要提供任何真实钱包助记词或密码。

## 重新生成

需要已安装依赖的 BitTool Signer engine 与 Node ≥20.19.0。从本目录执行：

```sh
node generate-fixtures.mjs /absolute/path/to/BitToolSigner/engine
```

在 BitTool Signer engine 目录运行协议回归：

```sh
node --test test/wallet-pairing.test.mjs test/protocols.test.js
```

脚本检查生成前后源码未变化，且 `signer.js` 实际摘要与 bundle manifest 一致。生成新快照后，开发者仍需重新核对 prompt 的协议事实；脚本不自动更新 Markdown 的规则、验收记录或测试结果。
