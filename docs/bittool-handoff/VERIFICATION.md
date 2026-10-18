# 本次交付验证

日期：2026-09-22。仅生成 BitTool Wallet 开发文档和公开互操作数据，没有修改 BitTool Signer 应用或签名引擎。

## 已执行

1. 实际读取用户的 `BitTool Signer_Wallet_Level_QR_Pairing_v1_v2.md`，对照当前 `protocols.js`、public index、resolver、四链签名实现和测试。
2. 执行 `node --test test/wallet-pairing.test.mjs test/protocols.test.js`：**24 passed / 0 failed / 0 skipped**。这是最后采用的单 SOL 地址实现对应的测试结果。
3. 执行 `generate-fixtures.mjs`：钱包级 UR 乱序组包、inner/outer CBOR 字节一致；**9 个真实签名往返样例通过**。
4. 样例经过公开账户定位和固定签名任务，独立 CBOR 解码响应，检查 requestId 与 signature/PSBT bytes 原样保留。EVM 检查恢复地址（含 Legacy 多字节 v），SOL 检查 Ed25519，TRON 检查 secp256k1 签名，BTC 检查 BIP143 digest 上的 ECDSA 签名并完成 PSBT finalize/extract。
5. 生成前后所有登记源文件摘要一致，随后再校验一次仍与快照一致。应用 bundle 的文件大小和 SHA-256 与 manifest 一致。

## 本包基线

```text
Wallet pairing protocol: 1
Current mode field: full
BTC / EVM / TRON: account xpubs
SOL: one explicit standard address, index 0
Inner CBOR bytes: 755
BC-UR frames: 4 (fragmentLength 200)
Inner CBOR SHA-256:
efdab5c36d0fc48fc62b2af4dd0f3aae7739fed6117c72462f2dccfb62185d44

BitToolSigner/Resources/signer.js bytes: 849836
Bundle SHA-256:
23b11291453ef177aefe17715901932e3242994261b9d52f4d822b3480dba2af
```

精确生成时间、各源文件摘要与运行时版本见 `fixtures/source-snapshot.json`。源码是本地工作区版本，不是发布认证或 Git commit 快照。

## 验证范围

- 未访问 BitTool Wallet 源码，未实现 BitTool Wallet 功能；本次交付是供其开发使用的 prompt 和向量。
- 未进行 BitTool Wallet ↔ BitTool Signer 真机相机闭环、真钱广播或外部钱包认证，未宣称这些已通过。
- 无 mode 向量是拟定的 BitTool Wallet 接收端兼容用例，当前 BitTool Signer reference decoder 仍要求 mode；不能把这份向量当作已由当前冷端导出的证据。
- 公共向量覆盖协议基础路径，不代表所有 Token、NFT、多签、网络异常与 UI 验收已完成；完整待测清单写在 prompt 中。
