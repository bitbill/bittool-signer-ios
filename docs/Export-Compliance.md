# 出口合规：为什么 `ITSAppUsesNonExemptEncryption = NO`

这份文档只记录一件事：**这个判断的技术依据**。下次有人要重新填上架问卷时，
不必再凭印象猜，照着下面的表核对代码就行。

## 结论

```
ITSAppUsesNonExemptEncryption = NO
```

含义是：**本 App 不使用、或仅使用豁免于出口合规文档要求的加密。**

> 1.0.0 (build 1) 的工程里这个键曾被设为 `YES`，没有留下理由。
> 经逐项核对代码后改为 `NO`——见下表。

## 常见的误解

「加密钱包 ⇒ 当然用了加密 ⇒ 填 YES」。**这是错的，因为签名不是加密。**

出口管制（美国 EAR，Category 5 Part 2 / ECCN 5A002）管的是**保密性**
（confidentiality）功能。**数字签名、哈希、身份认证明确不在管制范围内**。
一个离线签名器的主要工作恰好全部落在不受管制的那一侧。

## 这个 App 到底用了什么

| 功能 | 在哪 | 由谁实现 | 是否受管制 |
| --- | --- | --- | --- |
| 数字签名 ECDSA secp256k1 / Ed25519 | JS 引擎 | 自带（`@noble/curves`） | **否**——数字签名是被排除的功能 |
| 哈希 SHA-256/512、Keccak、RIPEMD-160 | JS 引擎 | 自带（`@noble/hashes`） | **否**——哈希不是加密 |
| BIP39 助记词 → 种子（PBKDF2-HMAC-SHA512） | 原生 + `@scure/bip39` | CommonCrypto／自带 | 密钥派生，非保密性 |
| 密码 → 密钥（PBKDF2-HMAC-SHA256，600,000 轮） | 原生 | **Apple CommonCrypto** | 操作系统提供 |
| **助记词落盘加密（AES-GCM）** | 原生，仅此一处 | **Apple CryptoKit** | 操作系统提供 |
| 公开索引认证（HMAC-SHA256） | 原生 | **Apple CryptoKit** | 认证，非保密性 |
| 随机数 | 原生 | **Apple Security（`SecRandomCopyBytes`）** | 操作系统提供 |

两条独立的豁免依据，任一成立即可：

1. **全部保密性加密都来自 iOS 本身。** 这个 App 里唯一会「把数据变成密文」的地方
   是钱包落盘加密，走的是 Apple CryptoKit 的 AES-GCM。App 自己没有实现任何密码算法。
2. **App 自己实现的部分只有签名、哈希和密钥派生**，这些不作为加密受管制。

## 怎么自己复核

```sh
# 原生层只用 Apple 的加密框架，没有自己实现任何分组密码
git ls-files '*.swift' | xargs grep -h '^import' | sort -u | grep -iE 'crypto|security|common'
#   -> CryptoKit / CommonCrypto / Security

# 打包进 App 的 JS 引擎里，一行保密性密码算法都没有
for p in aes gcm chacha salsa secretbox; do
  printf '%s: %s\n' "$p" "$(grep -o -i "$p" BitToolSigner/Resources/signer.js | wc -l)"
done
#   -> 全部为 0
```

最后这一条是关键证据：引擎打包了自己的密码学库，但其中**没有任何一种对称密码**
被链接进来——因为引擎从不加密任何东西，它只做解析、哈希和签名。

## 边界

这是一份技术事实记录，**不是法律意见**。上架问卷的最终答复请由你和法务确认；
如果结论与此不同（例如将来加入了端到端加密的同步功能，那就真的引入了保密性功能），
**必须同时改回工程里的这个键**，不要让工程设置与问卷答复不一致。
