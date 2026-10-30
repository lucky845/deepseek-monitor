# 桌面小组件

三个尺寸各自回答一个问题，共享同一个快照与同一个后台任务。回到 [README](../README.md)。

## Android

长按桌面空白处 → Widgets → 找到「DeepSeek 用量」→ 拖到桌面。

| 尺寸 | 回答的问题 | 放什么 |
|---|---|---|
| 2×1 | 还剩多少、今天花了多少 | 余额 + 今日两行，各自带标签 |
| 2×2 | 还剩多少、今天花得凶不凶 | 余额 + 今日 + 本月请求/命中 + 更新时间 |
| 4×2 | 这个月的全貌 | 四列（今日消费/本月消费/本月请求/本月命中）+ 最近七天柱图 + 日均与可用天数 |

`resizeMode` 是 `none`：三个布局的内容都是按各自的格子数选的，允许拉伸只会得到一张更空或更挤的卡。

## 它会自己更新

| 时机 | 行为 |
|---|---|
| 应用每次拉完数据 | 立即写快照并重绘，不额外请求 |
| 后台每 30 分钟 | WorkManager 自己拉一次（余额、本月、今日、最近七天），不需要打开应用 |
| 刚拖到桌面时 | 立刻拉一次 |
| 桌面最后一个小组件被删 | 停掉后台任务 |
| 断开连接 / 清除凭据 | 清掉快照并停掉后台任务 |

用 `WorkManager` 而不是 `AlarmManager`，因为周期任务需要能在重启后存活。30 分钟是权衡值：余额不是秒级变化，而每次刷新要花 4 次 API 调用。

**后台任务没有加网络约束。** 加了 `NetworkType.CONNECTED` 之后任务在模拟器上从来不跑：Android 在无法访问连通性探测服务器时会把网络标成 `PARTIAL_CONNECTIVITY`，此时基于 `NetworkType.CONNECTED` 的约束永不成立。去掉约束后失败本来就有兜底（保留旧快照 + 重试两次），所以那个保护是多余的。

刷新失败时保留旧快照连同它的时间戳，显示的是"上次真正知道的数字 + 那个数字是什么时候的"，而不是零或者假装刚刚更新过。重试两次仍失败就等下一个周期。

读不到数据时写「打开应用连接后显示你的账单」，不显示 `¥0.00`——零会被读成"余额是空的"。

未来日期不进柱图：月度窗口到 1 号结束，平台会为当月剩下的每一天返回零桶，画出来会让图表末尾出现悬崖，还会把"最新一天"的标记落在明天。

## 布局要点

- 标签和数字在同一个居中块里：标签是数字的名字，拆开就会浮在无关的位置。
- 主数字 38sp 是这个宽度的上限（刚好容纳 `¥9999.99`），更长的余额由 provider 逐级降到 31sp / 25sp，宁可缩小也不截断人民币符号。
- `fontFeatureSettings="tnum"`：等宽数字，刷新时数字不会左右跳动。
- 状态位三个尺寸共有：右上角 `● 已连接` / `● 示例`，`WidgetFormat.statusBadge()` 一处写、三处用。

## 新增的文件

| 文件 | 作用 |
|---|---|
| `lib/services/widget_bridge.dart` | 组快照 JSON、写 SharedPreferences、把解析好的接口地址交给平台、经 `deepseek_monitor/widget` 通道请求重绘 |
| `android/.../DeepSeekWidgetProvider.kt` | 4×2：读快照、填 RemoteViews、用 Canvas 画七天柱图 |
| `android/.../DeepSeekWidgetSmallProvider.kt` | 2×2 |
| `android/.../DeepSeekWidgetMiniProvider.kt` | 2×1 |
| `android/.../WidgetFormat.kt` | 三个尺寸共用：读快照、金额与千分位格式、状态位文案、更新时间、今天花得凶不凶的着色判断 |
| `android/.../WidgetRegistry.kt` | 三个尺寸的登记册：重绘覆盖全部，只有最后一个被删时才停后台任务 |
| `android/.../WidgetRefreshWorker.kt` | 后台取数：余额、本月用量与费用、今日费用，算好日均与可用天数后写回快照 |
| `android/.../MainActivity.kt` | 挂 MethodChannel，收到 `refresh` 时重绘并同步后台任务的启用状态 |
| `res/layout/widget_dashboard.xml` | 4×2 布局（只能用 RemoteViews 支持的控件） |
| `res/layout/widget_small.xml` | 2×2 布局 |
| `res/layout/widget_mini.xml` | 2×1 布局 |
| `res/xml/widget_{info,small_info,mini_info}.xml` | 三个尺寸各自的格子数、刷新周期、预览布局 |

后台任务只跑一个：三个尺寸共用一个 `WorkManager` 唯一任务和一个快照，删掉其中一个不会停掉另一个的刷新——`WidgetRegistry.anyPlaced()` 问的是"还有没有任何一个在桌面上"。

四个坑：

1. RemoteViews 里不能用 `<View>` 或 `<Space>` 当占位（会直接 "Can't load widget"），要用空 `TextView` + `layout_weight`；
2. `shared_preferences` 在平台侧给键加了 `flutter.` 前缀，所以 Kotlin 读的是 `flutter.widget_snapshot`；
3. 平台接口要求浏览器请求头：缺少 `x-client-platform: web` 这几个头，`platform.deepseek.com` 会返回一张写着 "Request Blocked" 的 HTML 页面，而不是 JSON 错误；
4. `WidgetRegistry` 的两个方法（`classes()` 与 `refreshAll()`）都要登记新尺寸，只加一个会出现"某个尺寸不刷新"这种只在特定组合下暴露的 bug。

## iOS 与 macOS

环境已就位（Xcode 26.3 + iOS 26.3 模拟器），主应用已在 iPhone 16 模拟器上真实运行并通过 OCR 逐字验证界面。**桌面小组件已接入**：iOS 和 macOS 均有 Widget Extension（`DeepSeekWidget`，WidgetKit + SwiftUI），主应用与扩展共用同一个 **App Group**（`group.com.deepseekmonitor.deepseekMonitor`），Flutter 侧把快照写进 App Group 容器，扩展通过 `UserDefaults(suiteName:)` 读取同一份 JSON。

支持尺寸：`.systemSmall`（余额 + 今日）、`.systemMedium`（余额 + 今日 + 本月请求）、`.systemLarge`（四列概览 + 更新时间）。每 30 分钟自动刷新，应用拉完数据后也会调用 `WidgetCenter.reloadAllTimelines()` 触发重绘。

数据契约不用改：`widgetSnapshotJson()` 产出的字段（`balance` / `monthCost` / `requests` / `cacheHitRate` / `dailyAvg` / `daysLeft` / `trend[]` / `updatedAt`）是平台无关的，Swift 侧解同一个 JSON。
