# 最低系统版本评估：iOS 17 能不能降到 iOS 15

> **已决定（2026-10-17）：保持最低 iOS 17，不降。** 下文是支撑这个决定的评估，留作记录；如果以后要重开这件事，从这里接着看即可。

**评估结论：能降，但 iOS 16 才是划算的那一步；iOS 15 要多付一次导航架构重写，而且和“安全产品”这个定位相冲突。评估期间代码未改（临时改过部署目标构建一次，构建后已还原）。**

测量方法：把 `IPHONEOS_DEPLOYMENT_TARGET` 临时改成 15.0 真实构建一次（构建后已还原），再对全部 48 个 Swift 文件（10,878 行）逐个 API 清点。

## 工具链本身没有拦路

Xcode 26.4 接受 iOS 15.0 的部署目标，没有任何 "deployment target too low" 警告。构建停在 `SwiftEmitModule` 阶段，报了 9 个错误——但那一阶段只检查**声明的签名**，函数体根本没轮到类型检查，所以那 9 个远不是全部。真实工作量要靠 API 清点。

不构成障碍的部分：JavaScriptCore（iOS 7）、CryptoKit（13）、LocalAuthentication、`.privacySensitive()`（15）、`@AppStorage`（14）、async/await（回溯部署到 13）。关键的一点是**全仓库没有用 `@Observable`**（`ObservableObject` 一以贯之），否则这件事根本不用讨论。

## 工作量清点

### 降到 iOS 16 要处理的（iOS 17 API）

| API | 出现次数 | 替代方案 |
|---|---:|---|
| `.onChange(of:) { old, new in }` 双参数形式 | 37 | 改回 iOS 14 的单参数形式；需要旧值的地方自己存一份 |
| `.sensoryFeedback` | 8 | `UIImpactFeedbackGenerator` |
| `.symbolEffect` / `.contentTransition(.symbolEffect)` | 8 | 去掉，或 `#available` 包起来 |
| `UIScene.isSceneCaptured` | 5 | `UIScreen.isCaptured`（iOS 11）+ `capturedDidChangeNotification` |
| `ContentUnavailableView` | 3 | 自己写一个空状态视图 |
| `AVCaptureDevice.RotationCoordinator` | 2 | 回到已废弃的 `videoOrientation` |

共约 **63 处**，全是逐点替换，**不动架构**。唯一需要小心的是 `isSceneCaptured`：它是安全功能（录屏／投屏时遮盖助记词、挂起签名会话），替代品 `UIScreen.isCaptured` 是全屏而非按 scene 粒度，在 iPad 多窗口下语义略宽——对这个 App 反而更保守，可以接受。

### 再降到 iOS 15 还要多付的（iOS 16 API）

| API | 出现次数 | 替代方案 |
|---|---:|---|
| `NavigationStack` + `navigationDestination` | 16 + 3 | **重写成 `NavigationView` + `NavigationLink(isActive:)`** |
| `Grid` / `GridRow` | 14 | `VStack`/`HStack` 手工对齐 |
| `Duration` / `Task.sleep(for:)` | 5 | `Task.sleep(nanoseconds:)` |
| `AnyLayout` | 4 | 按尺寸类别分支，写两套布局 |
| `.scrollBounceBehavior`（16.4） | 4 | 去掉 |
| `ProposedViewSize` | 3 | 自己算尺寸 |
| `.presentationDetents` | 3 | 自定义 sheet 高度或全屏 |
| `ViewThatFits` | 2 | 按尺寸类别分支 |
| `.scrollContentBackground` | 2 | `UITableView.appearance()` |
| `.scrollIndicators` / `.presentationDragIndicator` | 1 + 1 | 去掉 |
| `Locale.Language.characterDirection` | 1 | `Locale.characterDirection(forLanguage:)`（iOS 8） |

共约 **55 处**，但其中 `NavigationStack` 那一条不是"替换"而是**改架构**：`AppRouter` 现在靠类型化的路由值做程序化 push/pop（创建完成后跳 Connect、删钱包后回欢迎页、`navigationResetEpoch` 整栈重置），iOS 15 的 `NavigationView` 只有 `isActive` 绑定，这些流程都要重新设计，而且 iPad 上 `NavigationView` 默认是 split view，还得额外压成 stack。多条 UI 测试直接断言返回栈行为，也要跟着改。

## 换来多少设备

| 最低版本 | 新增覆盖的机型 |
|---|---|
| iOS 17（现状） | iPhone XS / XR（2018）及以后 |
| iOS 16 | 多覆盖 iPhone 8 / X（2017） |
| iOS 15 | 再多覆盖 iPhone 6s / SE 一代（2015–2016） |

对一个离线签名器来说，"拿旧 iPhone 专门当签名设备"是真实用法，所以降版本有实际意义，不是纯凑数。

## 建议

**降到 iOS 16，不降到 15。**

- iOS 16 那 63 处是机械替换，没有架构风险，收益是 2017 年的 iPhone 8——二手市场上最便宜、量最大的那一档。
- iOS 15 额外的代价集中在导航重写，而导航正好是"签名后回到哪里""删钱包后回到哪里"这类**与安全状态耦合**的地方，是全仓库最不该为了兼容性而动的部分。
- 还有一条与机型无关的理由：iOS 15 机型早已停止接收安全更新。把一台不再打补丁的设备推荐成专用签名设备，和这个 App 自己的安全主张是矛盾的；iPhone 8（iOS 16）同样如此，所以无论降到哪一档，引导页都应该说明"专用设备请尽量用仍在维护的系统"。

如果最终要做，顺序建议：先降 16 并跑通全部测试与截图巡检，观察一轮；iOS 15 单独立项，因为它要动导航。
