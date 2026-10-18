# BitTool Wallet × BitTool Signer 开发 Prompt

依据：2026-09-22 本地 BitTool Signer 最新工作区代码、实际二维码往返测试，以及用户提供的 `BitTool Signer_Wallet_Level_QR_Pairing_v1_v2.md`。具体源码摘要见随附 `fixtures/source-snapshot.json`。这是给 BitTool Wallet 的实现任务，以下正文可直接交给开发 Agent。

## 1. 你的任务

请直接在现有 **BitTool Wallet** 项目中实现与 BitTool Signer iOS 兼容的联网钱包端，沿用项目现有架构、设计系统、RPC 服务和账户体系，完成实现、自动测试和联调说明。先检查项目，不要停留在方案或 UI mock。

新增一种账户来源：**BitTool Signer 离线签名钱包 / BitTool Signer air-gapped wallet**。它在 BitTool Wallet 内是一个仅持有公开账户资料的多链钱包；BitTool Wallet 负责联网查余额、资产、历史、手续费、nonce、UTXO、blockhash，构造交易、生成待签名二维码、接收签名、验证、组装、广播和查询确认。私钥始终留在 BitTool Signer。

**连接必须使用 wallet-level QR，一次导入 BTC、EVM、TRON、SOL。** 用户不应被要求逐链配对。这里的 Connect wallet 指本地扫码配对，**不是 Web3 WalletConnect relay/session**；不要为连接 BitTool Signer 建立 WebSocket、深链握手、蓝牙或 HTTP 服务。BitTool Wallet 原有 DApp/WalletConnect 功能如需使用此账户，应转交二维码签名流程。

BitTool Wallet 不得要求导入 BitTool Signer 助记词、seed、私钥、xprv、BIP39 passphrase 或 vault 密码。扫码配对不需要解锁冷端私钥；交易扫码审核后，BitTool Signer 在实际签名时授权。BitTool Wallet 不维护或假设冷端“已解锁会话”。

保留 BitTool Wallet 原有钱包功能。在这个新账户类型上，把本地签名替换为外部二维码签名；不要把整个 BitTool Wallet 改成只读钱包。

## 2. 先明确当前兼容目标

以下是**当前代码事实**，不要根据旧截图或草案的占位符推断：

| 项目 | 当前 BitTool Signer | BitTool Wallet 实现要求 |
|---|---|---|
| 钱包协议版本 | 整数 `1` | 未知版本明确拒绝；附件文件名中的 v2 不代表 wire version 2 |
| 钱包二维码 | `ur:bytes`，内含 CBOR 字节串，字节串内部再是 canonical CBOR 对象 | 必须正确解两层 CBOR |
| `mode` | 当前导出仍带 `"full"`，仅导出这一种格式 | 兼容当前导出，不显示 Simple/Full UI |
| 参考稿无 `mode` | 当前代码尚未去掉这个字段 | **BitTool Wallet 接收端兼容扩展**：允许缺省或 `full`，两者同义；其他值暂拒绝。不得宣称当前 BitTool Signer 已输出无 mode 格式 |
| 指纹 | 顶层 `masterFingerprint`，8 位小写 hex | 保存，用于签名定位；不能当作唯一钱包身份或真实性证明 |
| BTC | BIP84，account xpub，receive/change 两个分支 | 钱包级配对只启用这一种 BTC 地址类型 |
| EVM / TRON | 分别为 account xpub，`0/*` | 从导出的根公钥派生，不从 BTC xpub 推导其他链 |
| SOL | 当前只导出 1 个标准地址，index 0 | 保存明确的 path/address；不能推导额外 Solana 账户 |
| 内部 public index | 属于冷端内部缓存，不是 wallet QR | 它不属于外部协议，不要要求热端提交或解析此缓存 |
| 当前网络 | BTC/TRON/SOL mainnet，EVM 支持下列 8 个 chainId | 不擅自假设 testnet、任意 EVM 链已支持 |

参考稿优先指导产品交互，实际字节协议以当前代码及随附向量为兼容基线。无 mode 接收是本任务要求的热端兼容策略，单独测试。不要为了简化热端而静默改变冷端协议。

## 3. 产品流程

### 3.1 添加钱包

入口建议：添加钱包 → 连接硬件 / 离线钱包 → BitTool Signer → 扫描 Wallet QR。

支持动画二维码、乱序、重复帧，显示实际解码进度。完成组包后验证协议和所有已知字段，展示四条链的首地址、指纹、账户数量，由用户与 BitTool Signer 的地址核对区比较后命名保存。完整地址应可查看和复制，不能只靠前后几位确认。

扫描失败必须有明确反馈：二维码不完整、格式不支持、版本不支持、网络不支持、内容损坏、账户资料无效、混入其他二维码；不能“扫码无反应”。在配对入口扫到交易请求或签名，应解释类型不符；普通扫码入口可以识别类型并导向正确流程。

默认展示每链 index 0 即可，保持 BitTool Wallet 简洁；数据层必须保存全部 descriptor 和导出的 SOL 账户。多地址入口可复用现有 BitTool Wallet 能力，不另造二维码格式。BTC 如使用 change 分支，必须同步监控、备份恢复和发现找零地址，不能只监控接收地址后丢失余额显示。记录已使用索引，采用明确的地址发现/gap limit 策略。

重复导入相同描述符应识别为已有钱包；相同指纹但不同公钥不允许覆盖。钱包名与 BitTool Wallet 本地 ID 由热端生成，不从任意 QR 文本推导授权。

### 3.2 发送与授权

选择资产 / 交易 → 在线构造并展示详情 → 用户确认 → 冻结待签名字节和请求 → 显示动画签名 QR → 用户用 BitTool Signer 扫描并授权 → BitTool Wallet 扫回签名 → 本地验证 → 组装交易 → 广播 → 跟踪确认。

热端钱包状态显示“由 BitTool Signer 签名”，不要提示“请先 unlock vault 才能扫码”。需要多人签名的交易显示已收集数量、缺少的签名者、所需门限；门限满足且验证通过才允许广播。

消息 / EIP-712 返回签名给原始请求方，不当作链上交易广播；签名完成、已广播、链上确认、链上失败必须是不同状态。

应用短暂进入后台后保留当前流程和公开的待签名状态。交易过期、nonce 已用、blockhash 失效或内容修改后，旧签名不复用，创建新 requestId 和新二维码重新签名。

## 4. 钱包级二维码的精确结构

### 4.1 传输与编码

```text
payloadObject
  → inner = deterministicCBOR(payloadObject)
  → urCBOR = CBOR_BYTE_STRING(inner)
  → new UR(urCBOR, "bytes")
  → BC-UR single/multipart QR
```

解码：BC-UR 组包 → `ur.type === "bytes"` → 解外层 CBOR 得到 bytes → 解 bytes 得到内部 map。不是 JSON 字符串，不是把 UTF-8 hex/base64 当 bytes，不是 `ur:bittool-signer-wallet`，也不额外包 tag 24。

内部对象使用下表中的**文本键**。确定性 CBOR：固定长度、整数和长度采用最短编码、map 键按其完整 CBOR 编码的字节序排序。不要用 JSON 键字母序代替。当前已知字段只有 text、uint、array、map；未知可选字段可以安全忽略，但仍要检查编码、重复键、大小和复杂度。不要为了忽略未知字段而先丢弃再重新编码、误拒合法扩展。

当前导出内层最大 4096 bytes，默认 fragmentLength 为 200 bytes；当前示例是 755 bytes / 4 帧，**这不是所有钱包必须固定的长度/帧数**。UR 大小写都应识别；帧不是简单字符串分片，使用 BC-UR fountain decoder，校验 Bytewords/UR 完整性，支持乱序和冗余帧，拒绝混合不同会话。

使用有界组包：单帧最多 4300 字符、累计保留文本最多 1,048,576 字符、签名 payload 上限 131,072 bytes、帧处理有数量/时间限制。钱包配对另执行 4096-byte 内层上限。识别重复帧但不要永久保存；取消或切换会话时清空 collector。二维码动画支持暂停、继续、重扫，浅深色模式均保持黑码白底及足够 quiet zone。

最小 canonical 编码校验例：

```text
{version: 1, mode: "full", b: "x", aa: 2}
→ a46162617862616102646d6f64656466756c6c6776657273696f6e01
```

### 4.2 Envelope 和各链 descriptor

以下 xpub/address 为占位符，真实数据见随附向量，不能把这里的占位符当测试输入：

```json
{
  "protocol": "bittool-signer-wallet",
  "version": 1,
  "mode": "full",
  "network": "mainnet",
  "masterFingerprint": "73c5da0a",
  "accounts": [
    {"chain":"btc","accountPath":"m/84'/0'/0'","script":"p2wpkh","xpub":"<BTC account xpub>","derive":{"receive":"0/*","change":"1/*"}},
    {"chain":"evm","accountPath":"m/44'/60'/0'","xpub":"<EVM account xpub>","derive":"0/*"},
    {"chain":"tron","accountPath":"m/44'/195'/0'","xpub":"<TRON account xpub>","derive":"0/*"},
    {"chain":"sol","profile":"bip44-solana","accounts":[
      {"index":0,"path":"m/44'/501'/0'/0'","address":"<32-byte public key in Base58>"}
    ]}
  ]
}
```

**当前钱包级二维码一次包含 BTC、EVM、TRON 三个账户级 xpub，以及 1 个 Solana 账户：index 0、`m/44'/501'/0'/0'`。** 不要补齐或推导任何未导出的 Solana 账户。

接收端验证要求：

- `protocol`、整数 `version`、`network` 必须匹配；本期仅支持 mainnet。未知版本/网络明确拒绝，不能 fallback。
- 正常当前导出要求四个已知 chain 各一项，按 chain 查找，不靠数组顺序判断。已知链重复、缺失或非法时整包拒绝，不创建看似完整的残缺钱包。未知未来链可提示未导入，其内容不用于签名；未知可选 metadata 可忽略。
- 当前兼容模式要求有效 `masterFingerprint`；草案没规定指纹不等于可以用全零值补齐。缺失时提示需要兼容的完整 Wallet QR。该值是 master BIP32 fingerprint，不是账户 xpub 自己的 fingerprint，也不是 xpub 中的 parent fingerprint。
- 三个 xpub 使用标准主网 BIP32 公钥版本 `0x0488b21e`，Base58Check 有效，depth=3，child index=`0x80000000`，有效 secp256k1 压缩公钥和 chain code。拒绝 xprv、tpub、损坏值和意外的 zpub/其他版本；本接口输出的是 xpub，脚本由 `script` 决定。
- 只能检查 xpub 的结构及导出字段一致性，不能仅凭 xpub 证明它来自宣称的 hardened 路径、指纹或与其他链同一个 seed。地址人工核对仍有必要。
- 路径、脚本、derive 必须匹配上面的 v1 profile，不能把未知路径静默重写为默认路径。BIP32 子索引是非 hardened `0 ≤ i < 2^31`，不要遍历整个空间或接受不受限搜索。
- SOL 当前要求一项 index 0，path 为 `m/44'/501'/0'/0'`，Base58 解码恰为 32 bytes，有效 Ed25519 公钥，拒绝重复地址、异常/小阶公钥。未来多账户扩展需要另行明确范围；本期不生成 xpub，不推导未导出账户。
- 任意 QR 都是不可信输入：拒绝重复 CBOR map 键、截断、尾随垃圾、非法 UTF-8、不规范整数长度、无限长对象、超深结构。存储时重建经过验证的内部模型，不将原始对象直接 spread 进应用配置。

### 4.3 地址派生

| 链 | 从导出资料到地址 |
|---|---|
| BTC | `xpub → /0/i` 接收、`/1/i` 找零；HASH160(compressed public key)，P2WPKH witness v0，主网 `bc1q…` |
| EVM | `xpub → /0/i`，解压 secp256k1 公钥，去掉 `04` 后对 64 bytes 做 Keccak-256，取后 20 bytes，展示 checksum address |
| TRON | 独立 TRON xpub → `/0/i`，同类 Keccak 派生后取后 20 bytes，前缀 `0x41`，Base58Check；不能复用 EVM 地址路径 |
| SOL | 直接使用对应显式公钥和完整 hardened path |

标准公开测试向量的首地址必须等于：

```text
masterFingerprint = 73c5da0a
BTC  bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu
EVM  0x9858EfFD232B4033E47d90003D41EC34EcaEda94
TRON TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdH
SOL0 HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk
```

这些是公开、不可存放资产的测试账户。生产导入不能依赖或嵌入其助记词。

钱包去重使用规范化后的已知公钥 descriptors；可生成 domain-separated hash 作为 BitTool Wallet 本地 pairing ID。**不要用 32-bit masterFingerprint 作为唯一 ID**。BitTool Signer 内部 `walletKeyId`、HMAC、公钥缓存等不是二维码协议的一部分，不要求热端仿造。

## 5. 配对之后：公共签名传输

钱包级 QR 仅用于导入公开账户，**不是统一的交易签名 envelope**。不要创造 `bittool-signer-json`、`ur:bittool-signer-sign-request` 或把 BitTool Signer 内部 `operation/request/plan` JSON 作为外部二维码。

| 链 | BitTool Wallet 展示给冷端 | BitTool Wallet 从冷端接收 |
|---|---|---|
| BTC | `ur:crypto-psbt`，也支持 `ur:psbt` | 同类型的已增加签名 PSBT |
| EVM | `ur:eth-sign-request` | `ur:eth-signature` |
| TRON | `ur:tron-sign-request` | `ur:tron-signature` |
| SOL | `ur:sol-sign-request` | `ur:sol-signature` |

签名请求 UR 的 `cbor` 是下述**整数键 map 本身**，不是钱包配对那样的双层 bytes 包装。BTC 是 CBOR byte string 包裹原始 PSBT。不要混淆三种层次。

每个非 BTC 请求生成新的随机 16-byte requestId；编码 `tag(37, byteString)`，不是 UUID UTF-8 文本。响应 key 1 原样回显。BitTool Signer 的 ETH 兼容解析还接受 1–64-byte opaque ID，但 BitTool Wallet 新建请求统一用 16 bytes，匹配时按 bytes 比较。

签名路径用 CBOR `tag 304` 包住 `crypto-keypath` map：

```text
304({
  1: [44, true, 60, true, 0, true, 0, false, 0, false],
  2: 0x73c5da0a
})
```

上例是 `m/44'/60'/0'/0/0`。key 1 为 index / hardened boolean 交替数组，**不要同时给 hardened index 加 0x80000000**；key 2 是把 4-byte 指纹按 big-endian 解释的 uint32。选择实际叶子路径，不能传账户根或 wildcard。PSBT 内部的 BIP32 path 序列化另按 BIP174，由 PSBT 库处理，不套用这个交替数组规则。

`origin` 使用 `BitTool Wallet`，仅用于显示，不是经过认证的身份，不是任意远程 callback URL。签名 map 不要添加未定义字段：当前 ETH 只接受 key 1–7，SOL/TRON 只接受 key 1–6。

## 6. BTC：P2WPKH 闭环及多签边界

基线完成 wallet-level 配对导出的 BIP84 单签钱包，构造 PSBT v0 或 v2；建议首版发送 v0。使用真实 UTXO、完整上一笔交易，校验 txid、vout、金额和脚本。

**当前冷端对 Legacy / SegWit v0 要求 `nonWitnessUtxo` 完整上一笔交易，不能只给 `witnessUtxo`。** 即使 Bitcoin 网络对 P2WPKH 不强制该字段，BitTool Signer 的安全策略要求它。可同时给 `witnessUtxo`，必须一致。

每个待签输入包含对应公钥、masterFingerprint、完整叶子路径的 `bip32Derivation`。找零输出也附相应派生元数据及一致脚本。使用 SIGHASH_ALL；不要产生 NONE / SINGLE / ANYONECANPAY 等当前拒绝的策略。冷端是否将输出标识为找零由其独立校验决定，热端的标签不是证明。

收到 PSBT 后核对原始交易的 inputs/outputs/金额/脚本/sequence/locktime 等未改变，对新增签名按输入脚本和 sighash 独立验证，保留已有 cosigner 签名及 metadata，最后 finalize / extract / broadcast。BTC 无上述 requestId，应将响应与本地 pending 的 unsigned transaction 和 PSBT 关键约束绑定，而非只看 QR 类型或 txid 字符串。

当前冷端还支持 chain-level 导出的 BIP44/49/86、BIP48 多签，以及其策略范围内的 Taproot。**钱包级 BIP84 xpub 不构成多签钱包，也不包含 BIP48 cosigner key、门限或其他签名者。** 不得从本次配对假造这些账户。若 BitTool Wallet 原有 BTC 多签功能需要对接，应单独导入 cold signer 的 chain-level BIP48 cosigner QR，保存完整 descriptor、门限和全部 cosigner 公钥，采用 PSBT 逐个收集签名。该扩展单独标记与验收；MuSig2 和未知 Taproot 脚本不宣称支持。

## 7. EVM：请求、恢复地址与组装

`eth-sign-request` CBOR map：

| key | 类型 | 内容 |
|---|---|---|
| 1 | tag37(bytes16) | requestId；BitTool Wallet 必填 |
| 2 | bytes | 待签数据，语义见下表 |
| 3 | uint | dataType 1 / 2 / 3 / 4 |
| 4 | uint | chainId；链上交易和带网络上下文的请求明确填写 |
| 5 | tag304(map) | 完整 derivationPath + masterFingerprint |
| 6 | bytes20 | 派生签名地址，原始 bytes，不含 `0x` 字符串 |
| 7 | text | `BitTool Wallet`，最多 256 字符 |

| dataType | key 2 内容 |
|---|---|
| 1 | Legacy 未签交易 RLP；有明确 EIP-155 chainId 的 unsigned serialization，不是交易哈希 |
| 4 | EIP-2718 typed unsigned transaction，首字节 `0x01` 或 `0x02`，支持 2930/1559 |
| 2 | UTF-8 编码的完整 EIP-712 JSON：domain/types/primaryType/message |
| 3 | personal_sign 的原始消息 bytes；不能预先加 prefix 或 hash |

当前允许 chainId：`1, 56, 42161, 8453, 10, 137, 100, 43114`。同一个 EVM descriptor 用于这些网络；交易 bytes 中、UR key 4 中、EIP-712 domain 中的 chainId 如存在必须一致。Token registry 的覆盖不等于网络签名能力；禁止将测试网、Blob 交易、EIP-7702 或 `eth_sign` 原始 hash 请求伪装为支持的请求。

大整数使用 bigint / 十进制字符串，不用 JS 浮点数运算金额。EIP-712 保留精确 schema 与值：bool 必须真 bool、整数无歧义、address 恰为 20-byte hex，不接受重复 JSON 键。自定义 EIP712Domain 的字段顺序参与计算，不能改写签名前的声明。

`eth-signature` 返回 `{1: tag37(requestIdBytes), 2: signatureBytes}`。**它不是已签交易**。当前冷端返回 `r[32] || s[32] || v[1..9]`，v 为无符号 big-endian 最短字节序列：

- Legacy 交易：`v = chainId * 2 + 35 + yParity`，可多于 1 byte，整个签名可超过 65 bytes。
- Typed 交易：`v = yParity`，0 或 1。
- personal / EIP-712：`v = 27 + yParity`。

必须根据本地 pending 类型解析，不能给所有场景固定截取第 65 byte 当 v。校验 r/s 范围与低 S，Legacy 反推 chainId/parity 必须等于 pending；从正确 digest 恢复地址并与配对地址一致，组装原始交易后再核对交易哈希。QR requestId 一致不代表签名有效。

完成原生币、ERC20、ERC721、ERC1155 常用转账和授权。已有 DApp 请求统一路由到该适配器；未知合约调用仍可能在冷端显示 opaque，不能在热端标为“冷端已完整解析”。

Safe 多签使用 owner 的已配对 EOA 签 `SafeTx` EIP-712。Safe 合约地址、network、owner 列表、threshold、nonce、操作与 gas refund 参数由热端获取并明确展示，不能把 Safe 合约地址当作 key 6 的签名地址。按 Safe 协议收集/校验/排序 owner 签名并执行。优先 EIP-712，避免误套 personal_sign 的 v 调整。delegatecall / MultiSend / 权限修改逐项展示并提示风险。

## 8. TRON：原始 protobuf、权限和回签

`tron-sign-request` CBOR map：

| key | 类型 | 内容 |
|---|---|---|
| 1 | tag37(bytes16) | requestId |
| 2 | bytes | dataType=1：`raw_data_hex` 解 hex 后的原始 protobuf bytes；dataType=2：原始消息 bytes |
| 3 | uint | 1 transaction / 2 personal message |
| 4 | tag304(map) | `m/44'/195'/0'/0/i` + masterFingerprint |
| 5 | bytes21 | `0x41` + 20-byte 签名地址；从 Base58Check 解码，不传地址文本 |
| 6 | text | `BitTool Wallet` |

这是当前 BitTool Signer 采用的公共 Keystone TRON UR 合约。不要发送 TronLink/TokenPocket 私有 action JSON、URL scheme、`keystone-sign-request` 或包含完整 transaction JSON 的自造 QR。

交易 key 2 只包含 **raw_data protobuf**，不是包着 raw_data 和 signature 的完整 Transaction protobuf，不是 ASCII hex，不是 txID。BitTool Wallet 负责 RPC 构造、reference block、timestamp、expiration、fee_limit、permission_id，并在展示 QR 后冻结这些值。交易 digest / txID 为 `SHA256(raw_data_bytes)`。

当前冷端每笔支持一个 contract；支持 TRX、常见 TRC20/TRC721/TRC1155 ABI、AccountPermissionUpdate 和 Stake 2.0/resource 类型 54–59，未知 protobuf 字段/contract 和 TRC10 拒绝。权限 ID=1 的 witness-only 权限不用于此签名。

`tron-signature` 为 `{1: tag37(requestIdBytes), 2: bytes65}`；签名 `r32 || s32 || recoveryId1`，当前 recoveryId 使用 0/1 格式（不是 EVM 的 27/28）。基于原 digest 验证并恢复 signer，保持原始 `raw_data_hex` 不变，把签名追加到原 transaction 的 `signature[]`。如 SDK 的消息验证接口要求其他 v 表示，应在调用边界按该标准显式转换，不能修改交易签名协议。

消息采用 TronWeb signMessageV2 长度前缀：

```text
Keccak256(0x19 || UTF8("TRON Signed Message:\n") || UTF8(decimalByteLength) || originalMessageBytes)
```

支持 1–8192 bytes。不要使用 SHA256(message)、固定 32-byte 旧式前缀或重复添加 prefix。

TRON 多签：owner_address 可以不同于实际签名成员；key 5 和 path 应描述**本次成员 signer**。冷端 UR 只获得 raw_data，不接收热端已有 signature[]、完整权限快照或网络证明；因此热端保存并校验已有签名，逐成员生成请求，去重 signer，确认其当前 permission membership / weight / threshold / operation mask 后广播。不能假设冷端已校验线上权限或签名已达到门限。

TRON 字节没有可信网络身份证明；BitTool Wallet 必须限制本账户 mainnet endpoint，明确显示网络，防止把同一签名发错网络。索引可为任意合法非 hardened i，不要沿用早期 0–99 的限制。

## 9. Solana：显式公钥与签名槽位

`sol-sign-request` CBOR map：

| key | 类型 | 内容 |
|---|---|---|
| 1 | tag37(bytes16) | requestId |
| 2 | bytes | signType=1：序列化 Message；signType=2：原始 UTF-8 消息 |
| 3 | tag304(map) | 导出的 `m/44'/501'/0'/0'` + masterFingerprint |
| 4 | bytes32 | 所选显式 Ed25519 公钥，Base58 解码后的 bytes |
| 5 | text | `BitTool Wallet` |
| 6 | uint | 1 transaction / 2 message |

交易发送 **Message bytes**，不是带 signature count/signature slots 的完整 Transaction，也不是 message hash。当前支持 legacy message 和 v0 静态账户，**不支持带 Address Lookup Table 的消息**。如现有构造器使用 ALT，必须在签名前重编译为冷端支持且不超过网络 packet limit 的消息；不能仅去掉查找表。无法重编译的交易明确禁用并说明原因。

`sol-signature` 返回 `{1: tag37(requestIdBytes), 2: bytes64}`，仅 detached Ed25519 signature。对冻结 Message 原始 bytes 与预期公钥验签；找到 header 指定 required signers 中的正确 slot 后填入，保留并校验其他 slots，全部所需签名齐全后序列化和广播。不能总填 slot 0；非 fee payer / readonly required signer 也可能是本次 signer。

热端保存完整 unsigned/partial Transaction 与全部 signatures，冷端 UR 不携带已有 signatures。blockhash 过期后不能在已有签名上换 blockhash；生成新 message/requestId 后重新收集全部受影响签名。已签交易与 fee payer、blockhash、instructions、账户顺序均绑定。

普通消息当前限定 1–1024 bytes 可识别 UTF-8 文本，拒绝交易 header 伪装；无法解析的交易不能降级成 signType=2。Ed25519 签原消息本身，不先做 SHA256。

完成 SOL、SPL Token 转账，NFT/Token-2022 使用现有链库并保留 mint、decimals、authority 和额外账户的正确语义；支持范围按真实消息验证。Token-2022 extensions、链上元数据和 transfer hook 不能假定冷端完全验证。SPL 多签是多个 required signer 收集；Squads 是程序级多签，proposal 引用不等于冷端已拿到并完整审阅提案内容。两者与普通多 signer Transaction 区分。

## 10. 本地 pending、响应校验与数据安全

实现可恢复的状态机，例如：

```text
draft → prepared → awaitingSignature → signatureVerified
      → readyToBroadcast → broadcasting → submitted → confirmed / failed
```

多签可在 awaitingSignature 与部分验签状态间循环。签名过期 / 请求取消 / 交易被替换是独立状态，不能直接跳到成功。

至少保存：本地 pendingId、walletId、chain/network、signer address/pubkey/path、requestId（BTC 用其交易绑定）、请求类型、**确切待签 bytes**、digest、完整未签交易、已验证签名、创建时间、过期/nonce/blockhash 约束及广播结果。pending 内的网络不能被回签 QR 替换。

扫描返回前不信任任何 signature bytes。先检查 UR type、CBOR 类型和长度、requestId，再执行链特定验签、signer/交易内容绑定、已用/取消/过期请求检查。拒绝错误钱包、错网络、错 ID、篡改 payload、重复签名和跨请求重放；不要仅根据同一个 masterFingerprint 接受。

拒绝签名/取消操作在当前二维码协议中没有 error-response UR；提供取消/返回/重新生成，不能一直等待联网 callback。本地解析错误与冷端拒绝原因分开显示。

所有地址/xpub 是公开密码学数据，但会暴露完整账户关联及资金活动。按 BitTool Wallet 的隐私与本地存储策略保护，不记录完整 xpub/QR/消息到日志、分析平台或崩溃报告，不自动上传完整配对包。联网查询尽量只提交所需地址。远端 Token/NFT 图片、URL、符号、名称不能覆盖用户要确认的真实合约/mint/收款地址。

不要把配对指纹、UR checksum 或“来源 BitTool Signer”的文字当作认证签名。此协议没有热端挑战认证，也不包含资金余额和交易授权。

## 11. 实现结构建议

遵循现有代码组织，可拆出这些职责；不强制重写项目或引入另一套状态管理：

- `BitTool SignerPairingCodec`：BC-UR、双层 CBOR、schema 校验及 descriptor 归一化。
- `BitTool SignerWatchWallet`：链账户、地址派生/发现、去重与持久化。
- `AirGapSigningCoordinator`：不可变 pending、动画 QR、扫码响应和恢复状态。
- `Bitcoin/EVM/Tron/SolanaSigningAdapter`：构造公共 request、验 response、组装和广播。
- `ExternalSignerAccount`：作为 BitTool Wallet 原有账户/交易/DApp 接口的一种 signer provider。

复用成熟密码学和协议库，锁定版本，不自行实现生产 ECDSA/Ed25519/BIP32/CBOR/fountain。当前冷端测试使用 `@ngraveio/bc-ur 1.1.13`、Keystone ETH registry `0.22.1` / SOL registry `0.9.5`，依赖版本只是对照基线，不要求热端照搬全部运行库。无论使用 JS/Swift/Kotlin，都必须通过同一份向量。

## 12. 必须完成的测试与验收

### 自动测试

1. 导入随附真实 current pairing；逐项比对三个 account xpub、四链首地址、唯一 SOL path/address。验证 inner CBOR 和 UR outer bytes，乱序/重复帧完成同一结果。
2. 单独测试无 mode 接收扩展；拒绝版本 `"1"`、版本 2、mode simple、未知 network、xprv、损坏 xpub、错误 depth/index/路径、重复链、缺链、重复 SOL、超大 payload、重复 CBOR key、混会话和损坏 checksum。未知可选字段可以忽略。
3. BTC receive/change 多索引、EVM/TRON 非零索引及 TRON ≥100、SOL index 0 正确；拒绝从本次配对使用 SOL index 1 或未导出的其他路径，以及 hardened public child。公钥派生使用独立库交叉验证。
4. 四链 request → 冷端 decode/review/public matching/sign → response → 热端独立验签/组装。覆盖随附 9 个签名向量；不要只 mock 出 success 或比较固定 UI 字符串。
5. EVM 包含 Legacy 多字节 v（示例 chainId 43114）、1559、personal、EIP-712、ERC20/NFT、Safe。错 chainId、错误 v/parity、错 signer、修改 amount/to 必须失败。
6. BTC 测 witness-only 缺完整前交易被拒绝、receive/change 混合输入、已有签名保留、PSBT 修改输出拒绝；如支持 BTC 多签扩展，再测试真实 2-of-3 流程。
7. TRON 测 raw_data/txID 绑定、成员与 owner 不同、permission ID、已有签名合并、重复 signer、过期交易；不把完整交易 JSON 当 key 2。
8. SOL 测 message 与 transaction 区分、非零 signer slot、已有签名保留、多 signer、过期 blockhash、ALT 拒绝。失败交易不能 fallback 为消息签名。
9. UI 测扫码错误可见、相机权限拒绝可恢复、进入后台/回前台保留流程、取消后不接纳旧响应、二维码深浅模式、动态字体、小屏布局、无网络时展示已配对公开资料及 pending。
10. 广播层使用 mock RPC 做状态机、费用变化、nonce 冲突、超时重试和重复广播测试；不能以“收到签名”作为交易成功。网络不确定时查询 tx hash 后再决定重试，不能重复付款。

### 实机联调

以**新建专用测试钱包**验证 BitTool Signer 真机 ↔ BitTool Wallet 相机扫描、配对首地址核对、四链传送签名与响应。自动向量中的假 UTXO / ref block / blockhash 不得广播。当前冷端不接受任意 testnet profile，不为了测试自动发真钱或改 chainId；真实资产广播需单独安排明确授权的联调环境。

报告区分“单元测试通过”“相机闭环通过”“链上广播确认通过”。未完成实机或链上验证不能写成已认证兼容所有 Token/NFT/多签。无法完成的环境检查列明具体原因和复现步骤；继续完成可测试的代码。

### 交付要求

交付实际代码、测试和结果，附：新增文件/关键入口、支持矩阵、协议差异说明、操作步骤、未完成联调清单。基础四链配对和单签闭环必须完成；多签/Token/NFT按上述明确边界实现与验收，不要用按钮或品牌名称代替真正互操作能力。

先检查现有 BitTool Wallet 的账户模型、交易构建、QR scanner 和外部 signer 扩展点，简述实施顺序，然后直接实现。除非缺少无法推断的必要条件，不要反复询问是否开始。

## 13. 附件与来源

- `fixtures/wallet-pairing-current.json`：实际当前代码生成的对象、inner/outer CBOR、全部动画帧、四条链核对地址。
- `fixtures/wallet-pairing-no-mode-receiver-extension.json`：热端兼容草案的无 mode 测例；明确不是当前冷端输出。
- `fixtures/signing-roundtrips.json`：9 个公开测试请求与真实回签：BTC PSBT，EVM personal/1559/Legacy/EIP-712，TRON message/TRX，SOL message/legacy transfer。
- `fixtures/source-snapshot.json`：生成时源码与 bundle 的 SHA-256、capabilities、fixture 检查信息。以这里的文件摘要锁定实际工作区基线，不把 Git HEAD 当作未提交源码的版本。
- `generate-fixtures.mjs`：可在 BitTool Signer 仓库依赖已安装时重新生成。它调用冷端引擎作测试，不应进入 BitTool Wallet 生产 bundle；热端不需要助记词或冷端内部 API。

代码依据：`engine/protocols.js`（pairing、UR/CBOR 与 response）、`engine/src/public-index.js`（路径/公钥）、`engine/src/resolver.js`（公开资料定位与固定签名任务）、`engine/src/{bitcoin,evm,tron,solana}.js`（实际签名和拒绝条件）、`engine/test/{wallet-pairing.test.mjs,protocols.test.js,public-index.test.js}`（互操作向量）。仓库内其他说明与源码不一致时报告差异，以此快照的实际字节和行为为联调基线。

标准参考仅补充编码/注册格式，不替代上述 BitTool Signer 约束：确定性 CBOR 参见 [RFC 8949 §4.2.1](https://www.rfc-editor.org/rfc/rfc8949.html#section-4.2.1)；UR 传输参见 [Blockchain Commons BCR-2020-005](https://github.com/BlockchainCommons/Research/blob/master/papers/bcr-2020-005-ur.md)；生态类型库参见 [Keystone UR Registry](https://github.com/KeystoneHQ/ur-registry)。
