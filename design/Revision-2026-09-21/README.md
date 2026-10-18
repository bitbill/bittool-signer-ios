# 2026-09-21 界面验收截图

来源：iPhone 16 Pro 模拟器，iOS 18.6；实际 UI 自动化截图。钱包和签名均为隔离的公开测试向量，无用户钱包或资金。明暗页面已逐张检查，二维码和地址没有人工重绘。

| 页面 | 截图 | 验证点 |
|---|---|---|
| 全部钱包 | [浅色](Wallets-Light.png) | 八钱包总数、稳定 ID、Connect / Addresses |
| BTC 配对 | [浅色](Bitcoin-Pairing-Light.png) | Single-sig / Multisig、路径顺序、Public Key QR |
| 地址浏览 | [深色 BTC](Addresses-Dark.png) / [浅色 SOL](Solana-Addresses-Light.png) | 完整地址按字符换行，公开浏览，SOL 三路径 |
| 交易审核 | [浅色](Message-Review-Light.png) | 真实消息、独立 High risk / Decoded locally 状态 |
| 签名结果 | [浅色](Signature-Result-Light.png) | 公共 ETH 签名响应；不代表已广播 |
| App Lock | [深色](AppLock-Dark.png) | 面容取消状态、重试和钱包密码兜底 |
| Welcome | [浅色](Welcome-Light.png) | 本地 Logo、slogan、创建／导入入口 |
| 输入错误 | [浅色](Invalid-Recovery-Light.png) | 无效助记词明确报错，不能继续 |
| 完整助记词 | [隐藏状态](Recovery-Hidden-Light.png) | 默认不展示词语 |

横向路径选项与纵向内容可滚动；截图只表示当时视口，不表示视口外内容丢失。动态字体、VoiceOver、更多屏幕尺寸与真实相机质量仍列为设备验收项。
