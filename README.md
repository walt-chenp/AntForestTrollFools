# AntForest TrollFools Port

基于iOS巨魔插件的支付宝蚂蚁森林能量自动收取插件，支持巨魔商店 TrollStore + 巨魔注入器 TrollFools 。它不依赖 MobileSubstrate、Theos 或 CaptainHook，使用 Objective-C Runtime Hook 构建为 `arm64 + arm64e` 通用 dylib。

## 来源与致谢

本项目基于 [qsirwyk/AntForestOneCollect](https://github.com/qsirwyk/AntForestOneCollect) 二次开发，保留原项目的 MIT 许可证与版权声明。感谢原作者 qsirwyk 的开源贡献。

> 请自行评估账号、服务规则与设备安全风险。本项目不提供绕过风控或安全机制的功能。

## 效果图

![收取记录面板](docs/ui-preview.png)

功能包括：

- 右侧悬浮叶子按钮：首页首次打开或从后台返回后完整显示；静置约 2 秒自动贴边缩小。左侧向右滑、右侧向左滑可展开，拖动位置会保存在本机。
- 收取记录面板：紧凑统计与四项收取控制；通过右上角“功能设置”管理定时收取、步数模拟、好友浇水和赚能量开关；支持“清空日志”与“复制日志”。
- 自动收取总开关：控制常规自动收取；关闭后好友/自己收取、后台循环与定时收取都会暂停。
- 收取自己能量：独立开关；开启后每轮优先查询并提交自己的成熟能量收取，再继续扫描好友能量。
- 自动能量雨：可独立开关；开启后进入能量雨并点击“立即开启”，插件会自动点击屏幕内正在下降的能量。
- 自动赚能量（打地鼠玩法）：在“功能设置”独立开关；手动进入并开启活动后，自动识别活动 Canvas 内出现的好友头像并点击；仅在活动专用页面生效，不影响森林首页收取。
- 循环收取（面板中显示为“后台循环”）：可独立开关；支持设置 1～60 分钟间隔，默认 5 分钟；当前以森林首页前台运行作为可靠使用条件。
- 每日定时收取：可设置多个每日固定时刻；到点仅执行一次好友/自己能量收取，不触发能量雨。已添加时间支持点选修改，并可向左滑动删除。
- 好友浇水：在“功能设置 → 好友浇水设置”从总能量榜选择好友，统一选择 10g、18g、33g 或 66g；支持手动浇水、多个固定时刻定时浇水，以及首次打开蚂蚁森林自动浇水。三种触发方式互不影响，每位好友每天最多 3 次。
- 浇水赠能：开启“自动收取”与“收取自己能量”后，识别首页浇水赠能位置并智能连续领取重叠能量球；达到无新命中状态后停止。
- 神奇海洋（清理垃圾与拼图）：在“功能设置”独立开关；扫描好友时自动清理海域垃圾、搜集拼图碎片与新物种；支持每日最多 10 人上限检测与单好友 1 次清理防封控制。
- 自动复活好友过期能量：在“功能设置”中独立开关；最多帮助 6 位可复活好友，并自动收取本人获得的 5g 奖励。
- 步数模拟（测试）：在“功能设置”中独立开启，设置范围后向支付宝返回当日稳定的模拟步数；关闭即恢复真实读取值。
- 巨魔真后台：可配合 `ImmortalizerJailed.dylib` 尽量维持进程；退到桌面后不保证 H5/RPC 回包及实际收取。
- 收取日志：最新记录显示在顶部；保留开关状态、本轮扫描开始/结束、浇水赠能、好友浇水和成功收取结果，并区分自己与好友能量。
- 能量统计：今日显示 g；累计满 1,000 g 后按两位小数换算为 kg；收取成功回包会去重计入统计。

> v2.8.1 正式版：iOS 15 及以上请使用 [`AntForestPort-v2.8.1.dylib`](build/AntForestPort-v2.8.1.dylib)；iOS 14 请使用独立兼容包 [`AntForestPort-v2.8.1-iOS14.dylib`](build/AntForestPort-v2.8.1-iOS14.dylib)。包含 iPhone 7 Plus/8 Plus 界面显示修复、全量 200+ 好友排行榜拉取与无限翻页、自动复活好友过期能量、神奇海洋自动清理与拼图搜集。产物均为 `arm64 + arm64e` 通用 dylib。

## v2.8.1 正式版更新说明

- **修复 iPhone 7 Plus / 8 Plus 等 16:9 传统屏幕日志面板显示不全**：在 iOS 15 系统且屏幕高度 <= 736pt 时默认开启 Large Detent 展高，并将日志列表布局绑定为弹性安全边距自适应，完美解决底部日志框被挤压的问题。

## v2.8 正式版更新说明

- **全量 200+ 好友排行榜拉取与自动无限翻页**：
  - 并发请求 `listRank.html` 独立大榜接口（带 `pageSize: 200`），突破支付宝首页默认仅返回 10~20 位好友的分页隔离限制；
  - 增加 `queryRankPage:` 自动多页连续拉取机制，支持 300 人、500 人、1000 人大号自动逐页拉取全量好友名单，确保后排（如第 48~56 名及靠后）待复活好友零遗漏；
  - 结合“找能量（TakeLook）”候选全图搜寻，保障全图能量收取与复活无死角。
- **自动复活好友过期能量**：
  - 深度识别橙色 `+5g` 复活标志（覆盖 `giftingEnergy``giftEnergy``protectStatus` 等 12 种可能数据结构）；
  - 彻底拔除旧 `ariverRpcTraceId` 校验阻断与本地 `autoReviveCount` 预判死锁，100% 由支付宝官方服务端权威判定 `PROTECT_REBORN_TIRED` 上限；
  - 复活成功后自动刷新本人首页并智能收取获得的 5g 奖励能量，不卡顿后续扫描流程。
- **神奇海洋（清理垃圾与拼图搜集）**：
  - 全自动扫描神奇海洋好友、清理垃圾、搜集拼图碎片与新物种；
  - 支持每日最多 10 人上限与单好友 1 次清理防封控制，完善每日上限透明化日志提示。
- **扫描并发互斥锁（`isScanRunning`）**：
  - 增加扫描运行原子互斥锁与 45 秒安全守护，彻底解决生命周期重复触发引起的并发冲突、扫描腰斩与补跑日志重复问题。

## 使用限制

- 退到桌面后不保证 H5/RPC 回包及实际收取；回到蚂蚁森林首页时会立即尝试补跑一次。

## iOS 14 独立版本

- iOS 14 请使用独立包 `AntForestPort-v2.8.1-iOS14.dylib`；该兼容包包含 v2.8.1 正式功能，不替代 iOS 15+ 的标准包。
- 该包移除了 iOS 15 才提供的 `UISheetPresentationControllerDetent` 与 `customDetent` 引用，面板使用 iOS 14 可用的标准 PageSheet。
- 已在 iPhone 12 Pro Max、iOS 14.2.1、支付宝 12.12.10、TrollFools 环境完成注入与功能验证。

## 使用说明

1. 使用巨魔注入器 TrollFools 注入 [`AntForestPort-v2.8.1.dylib`](build/AntForestPort-v2.8.1.dylib) 到支付宝。
2. 注入前移除旧的 `AntForestProbe.dylib`，避免两个 dylib 同时 Hook 同一方法。
3. 完全杀掉并重开支付宝，进入蚂蚁森林。
4. 点击右侧叶子按钮；需要调整位置时，直接拖动叶子图标。静置约 2 秒后叶子会自动贴边缩小；左侧向右滑、右侧向左滑可再次展开。
5. 在收取记录面板中按需打开“自动收取”、“收取自己能量”和“自动能量雨”。“收取自己能量”仅在自动收取已开启时生效；能量雨保持独立。面板中的“复制日志”仅导出正式收取记录。
6. “后台循环”可单独开关，点击分钟按钮可设置 1～60 分钟间隔；在蚂蚁森林首页前台时，首次开启自动收取且后台循环已开启会立即执行一次。
7. 点击右上角齿轮进入“功能设置”：可管理多个每日固定收取时刻（点选修改、左滑删除）、“步数模拟（测试）”、“好友浇水设置”、“赚能量（打地鼠玩法）”和“自动复活好友过期能量”独立开关。好友浇水支持手动执行、定时执行，以及“打开蚂蚁森林自动浇水”独立开关。
8. 如需收取能量雨，进入能量雨页面并手动点击“立即开启”；开始后无需再手动点击雨滴。
9. 如需使用赚能量，手动进入并开启活动；活动开始后无需手动点击好友头像，插件会自动处理当前局。该玩法每日机会由支付宝规则控制。
   如出现没有自动收集能量雨滴，立即退出能量雨界面，保留能量雨次数，不妨碍下次使用。
   
设备控制台出现下列日志，表示注入入口已安装：

```text
[AntForestPort] installed: view=1 appearance=1 response=1
```

## 巨魔真后台（可选）

`AntForestPort` 自身不提供 iOS 后台保活。可配合
[ImmortalizerJailed](https://github.com/sergealagon/ImmortalizerJailed) 尽量减少支付宝进程被系统挂起或终止的情况，但不能保证支付宝 H5/WebView 在退到桌面后继续处理 RPC 回包。

### 为什么无法保证真后台运行？

iOS 不像 Android 一样允许用户为第三方工具授予“无障碍服务”权限，以读取其他 App 的界面节点、执行手势点击或提供跨 App 悬浮控制。对普通 App 而言，iOS 不开放跨 App 的界面层级读取、全局点击/手势注入和持续后台执行权限。

TrollStore 与 TrollFools 解决的是安装、签名绕过和向目标 App 注入 dylib 的问题，并不会自动获得这些系统级权限。因此，即使支付宝进程和插件定时器仍被保活，系统仍可能暂停离屏 H5/WebView 的网络回包与页面执行；这也是退到桌面后无法承诺稳定收取的根本原因。

后台使用步骤：

1. 使用 TrollFools 同时向支付宝注入 `AntForestPort-v2.8.dylib` 和 `ImmortalizerJailed.dylib`。
2. 完全杀掉并重新打开支付宝，进入蚂蚁森林首页。
3. 点击叶子按钮，在收取记录面板中开启“自动收取”。
4. 点击 ImmortalizerJailed 的浮动按钮启用保活。
5. 保持蚂蚁森林首页为当前页面；需要离开时可退到桌面，但不要从多任务界面划掉支付宝。

注意：

- 已观察到：退到桌面后，进程和循环定时器可能仍在运行，但 H5/RPC 回包可能暂停，因此不能承诺后台实际收取。
- 目前可靠行为是：保持蚂蚁森林首页在前台；从桌面回到森林首页后，插件会在 Bridge 就绪时立即尝试补跑一次。
- 后台循环默认间隔为 5 分钟，可调整为 1～60 分钟；首次开启开关时会立即执行一次。
- 能量雨依赖可见的 WebGL 页面和触摸事件，仍需在前台进入能量雨并点击“立即开启”。
- 真后台会持续占用 CPU、网络和电量，请根据需要启用。
- `ImmortalizerJailed` 使用 GPL-3.0 许可证，本项目不打包或再分发该 dylib，请从其官方仓库获取并单独注入。

## 当前兼容范围

发布产物均为 `arm64 + arm64e` 通用 dylib：

| 项目 | 当前状态 |
| --- | --- |
| CPU 架构 | A11 及以下使用 `arm64`；A12 及以上使用 `arm64e` |
| iOS | 标准 v2.8.1 包支持 iOS 15 及以上；iOS 14 继续使用独立 `AntForestPort-v2.8.1-iOS14.dylib` |
| 屏幕尺寸 | 使用 Auto Layout；标准版、Plus、Pro、Pro Max 均应自适应 |
| 非越狱 | 需要巨魔商店 TrollStore 与巨魔注入器 TrollFools 都支持目标系统 |
| 越狱 | 可手动注入 dylib；暂未提供 rootful/rootless `.deb` 包 |

“支持巨魔商店 TrollStore”并不等于必然兼容：巨魔注入器 TrollFools 的注入能力、支付宝版本、私有类和响应字段也必须匹配。

典型设备：iPhone X、iPhone 8/8 Plus、iPhone 7 等为 `arm64`；iPhone XS/XR、iPhone 11 至 iPhone 16 系列为 `arm64e`。

## 已验证环境

以下是探针及正式移植版的真机验证结果：

| 项目 | 结果 |
| --- | --- |
| 设备 | iPhone 14 Pro（A16，`arm64e`） |
| 系统 | iOS 16.2 |
| 安装环境 | 非越狱：巨魔商店 TrollStore + 巨魔注入器 TrollFools |
| 支付宝 | 12.12.6、12.12.8、12.12.10、12.12.12 |
| 探针结果 | `H5WebViewController` 与 `PSDJsBridge` Hook 成功 |
| 森林首页 | 新版顶层 `bubbles`、`userBaseInfo` 已确认 |
| 好友气泡 | `id`、`userId`、`collectStatus`、`overTime` 等字段已确认 |
| 好友排行榜 | `friendRanking`、`myself`、`totalDatas` 已确认 |
| 自动能量雨 | 已确认能识别下降中的能量并自动收取 |
| 自动赚能量（打地鼠玩法） | 已验证自动点击与正常结算；仅活动专用页面生效 |
| iOS 15.7 验证 | iPhone 13 Pro Max、支付宝 12.12.10；叶子面板可打开，自动收取的排行与好友状态查询正常 |
| iOS 15.0.1 验证 | iPhone X（A11，`arm64`）；通用 dylib 可通过 TrollFools 注入并正常使用 |
| iOS 14.2.1 验证 | iPhone 12 Pro Max（A14，`arm64e`）、支付宝 12.12.10；iOS 14 独立包注入及功能正常 |
| 巨魔真后台 | iOS 16.2 下配合 ImmortalizerJailed：后台可维持周期定时器与请求发起，但 H5/RPC 回包及实际收取不保证；切回森林首页后可恢复补跑 |

## 构建

需要完整 Xcode：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make TARGET=build/AntForestPort-v2.8.1.dylib
```

本地 v2.8.1 正式产物位于 `build/AntForestPort-v2.8.1.dylib`。

GitHub Release 的通用 dylib 按 `AntForestPort-vX.Y.dylib` 命名。

在 iOS 14 独立兼容分支构建 iOS 14 包：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make TARGET=build/AntForestPort-v2.8.1-iOS14.dylib IOS_DEPLOYMENT_TARGET=14.0
```

产物为 `build/AntForestPort-v2.8.1-iOS14.dylib`。

## 开发分支约定

- `release/v2.8.1`：正式维护线；包含 iPhone 7 Plus/8 Plus 面板显示修复、全量 200+ 好友排行榜拉取、自动无限翻页、自动复活好友能量、神奇海洋清理与拼图搜集。
- `release/v2.8`：上一正式维护线。
- `release/v2.8.1-ios14`：iOS 14 独立兼容构建，单独发布，不影响 iOS 15+ 正式包。
- `feature/earn-energy-probe`：保留“赚能量”玩法的实验与诊断记录；已验证的自动点击逻辑已合入正式开发线。
- 后续每项新功能或缺陷修复均从独立 `feature/...` 或 `fix/...` 分支开发；真机验证后再合入新的 `release/...` 分支，避免实验代码影响稳定版。

## 反馈

- TG 讨论群：[iOS_AntFore](https://t.me/iOS_AntFore)，用于日常交流、使用讨论和问题收集。
- TG 频道：[AntFore](https://t.me/AntFore)，用于发布版本与项目动态。
- GitHub [Issues](../../issues) 用于提交可复现的问题、兼容性反馈和设备日志，便于持续跟踪处理。

### 获取 `[AntForestPort]` 设备控制台日志

1. 用数据线连接 iPhone，解锁设备并在 iPhone 上选择“信任此电脑”。
2. 在 Mac 打开“控制台”App，左侧选择该 iPhone，点击“开始流式传输”。
3. 在搜索框输入 `AntForestPort`。
4. 完全杀掉并重开支付宝，进入蚂蚁森林，并按需要点击右侧叶子按钮或开启自动收取。
5. 复制出现的 `[AntForestPort]` 行并附到 Issue。

也可在 Xcode 中打开 `Window → Devices and Simulators → 你的 iPhone → Open Console`，再搜索 `AntForestPort`。

正常注入时会看到：

```text
[AntForestPort] installed: view=1 appearance=1 response=1
```

请同时附上从启动支付宝到复现问题前后的相关行；不要提交账号、手机号、用户 ID 或能量球 ID 等敏感内容。

Issue 请附上：

- 设备型号与 CPU 架构
- iOS、支付宝、巨魔商店 TrollStore 与巨魔注入器 TrollFools 版本
- 注入方式
- `[AntForestPort]` 相关设备控制台日志
- 是否出现浮窗、是否闪退、是否能打开日志面板
