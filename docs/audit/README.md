# 安全审查记录

## 这份报告是什么

[BitTool-Signer-1.0.0-Security-Audit-GPT-6-Astra.pdf](BitTool-Signer-1.0.0-Security-Audit-GPT-6-Astra.pdf)
是一次 **AI 辅助的代码审查**（2026-10-17），不是第三方独立安全审计，也不是任何形式的认证。

**请不要把它当作"本 App 已通过安全审计"的凭据。** 独立审计仍在
[IMPLEMENTATION_STATUS.md](../../IMPLEMENTATION_STATUS.md) 的「仍需外部验收」清单里。

## 报告中的问题与处理

报告提出 4 条发现，逐条复现后确认全部为真实问题，已在 2026-10-18 修复并补了回归测试：

| 编号 | 问题 | 修复 |
| --- | --- | --- |
| BTS-01 | 比特币审核页丢弃 `OP_RETURN` 等不可花费输出，销毁的金额不显示 | `engine/src/bitcoin.js` 改为显示 Burn 动作并给出高风险警告 |
| BTS-02 | EVM MultiSend 批量交易中，发往批量合约但未被任何子调用转出的原生币不提示 | `engine/src/evm.js` 补上未转出金额的高风险警告 |
| BTS-03 | TRON 的 `fee_limit` 被当作总手续费上限显示 | `engine/src/tron.js` 改为「能量预算」，并说明离线无法得知总费用 |
| BTS-04 | BIP39 passphrase 的字节上限写死 512，长的韩语助记词会被误拒 | `BitToolSigner/Core/BIP39Seed.swift` 按实测最坏情况改为 1024 |

回归测试：`engine/test/audit-bts-2026-1017.test.mjs`。

## 校验

[BitTool-Signer-1.0.0-Audit-SHA256SUMS.txt](BitTool-Signer-1.0.0-Audit-SHA256SUMS.txt) 是报告与证据包的摘要。
