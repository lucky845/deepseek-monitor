# 开发与本地验证

跑起来、在模拟器上验证客户端链路、确认平台返回的形状还没变。回到 [README](../README.md)。

## 在 Android 模拟器上调试

原生端没有浏览器同源策略，令牌直连 `platform.deepseek.com` 就能读到模型级用量。前置条件：Android SDK 里要有 `cmdline-tools`（提供 `sdkmanager`/`avdmanager`）、一个 arm64 的 system image，以及一份 JDK 17。

```bash
# 一次性准备（Apple Silicon）
curl -L -o /tmp/cmdline.zip https://dl.google.com/android/repository/commandlinetools-mac-11076708_latest.zip
unzip -q /tmp/cmdline.zip -d /tmp/x && mv /tmp/x/cmdline-tools "$HOME/Library/Android/sdk/cmdline-tools/latest"

export JAVA_HOME=<JDK17 路径>
S="$HOME/Library/Android/sdk/cmdline-tools/latest/bin"
yes | "$S/sdkmanager" --licenses
yes | "$S/sdkmanager" --install "system-images;android-34;google_apis;arm64-v8a"
echo no | "$S/avdmanager" create avd -n dsmonitor -k "system-images;android-34;google_apis;arm64-v8a" -d pixel_6

# 每次调试
emulator -avd dsmonitor &          # 冷启动约 1 分钟
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb shell am start -n com.deepseekmonitor.deepseek_monitor/.MainActivity
```

两个坑：

- 必须用 JDK 17 跑 Gradle。用 JDK 21 会在 AGP 的 `jlink` 步骤炸掉。
- `monkey -p <pkg> -c android.intent.category.LAUNCHER 1` 在部分 system image 上返回 251，用 `am start -n <pkg>/.MainActivity` 更稳。

## 在 macOS 上调试

```bash
# 一次性准备：CocoaPods（系统 ruby 2.6 只能装 1.11.x，依赖要逐个降级）
gem install --user-install ffi -v 1.16.3 --no-document
gem install --user-install cocoapods -v 1.11.3 --no-document

# 每次调试（$HOME/.gem/ruby/2.6.0/bin 必须在 PATH 里，否则 flutter 找不到 pod）
export PATH="$HOME/.gem/ruby/2.6.0/bin:/tmp/flutter/bin:$PATH"
flutter run -d macos --debug
```

- `xcode-select -p` 必须是 `/Applications/Xcode.app/Contents/Developer`。指向 `/Library/Developer/CommandLineTools` 时，gem 的原生扩展编译不出来。
- 不要用管道判断 gem 是否成功：`gem install ... 2>&1 | tail -40` 的退出码是 `tail` 的，失败也会显示 0。
- `flutter doctor` 会报 `CocoaPods 1.11.3 out of date (1.13.0 is recommended)`，可以忽略。

## 在 iOS 模拟器上调试

```bash
# 一次性准备
export PATH="/tmp/flutter/bin:$HOME/.gem/ruby/2.6.0/bin:$PATH"
flutter doctor   # 确认没有 CocoaPods 缺失

# 每次调试：先 build 再装到模拟器
flutter build ios --simulator --debug
xcrun simctl boot F2EF2B2A-2D63-4309-9D86-876AB4E690EA   # iPhone 16，iOS 18.3
xcrun simctl install F2EF2B2A-2D63-4309-9D86-876AB4E690EA build/ios/iphonesimulator/Runner.app
xcrun simctl launch F2EF2B2A-2D63-4309-9D86-876AB4E690EA com.deepseekmonitor.deepseekMonitor

# 截图与录屏
xcrun simctl io F2EF2B2A-2D63-4309-9D86-876AB4E690EA screenshot /tmp/ios_shot.png
xcrun simctl io F2EF2B2A-2D63-4309-9D86-876AB4E690EA recordVideo --codec=h264 --force /tmp/ios_demo.mp4
```

- iOS Release 模式不支持模拟器：`flutter build ios --simulator --release` 会报错，只能用 `--debug`。
- `xcrun simctl` 的部分子命令（`spawn` / `listapps` / `get_app_container`）在 CoreSimulator 繁忙时会卡死超时，`screenshot` / `recordVideo` / `install` / `launch` 更稳。
- 如果模拟器 GUI（Simulator.app）启动即崩，多为 Xcode 与系统级 CoreSimulator 版本不匹配；升级 Xcode 到最新版通常能自愈。

## 各平台能力差异

| 平台 | 应用内登录自动取令牌 | 说明 |
|---|---|---|
| Android / iOS / macOS / Windows | ✅ | 内嵌 WebView + 条件导入的 `token_capture_io.dart` |
| Web | ❌ | 浏览器内没有可内嵌的官方登录页可控存储；直连又被 CORS 拦。接了反代（`tool/dev_proxy.py` 或自建）后可用平台令牌 |
| Linux | ❌ | `flutter_inappwebview` 无 Linux 实现，回退手动粘贴 |

不支持自动取令牌的平台隐藏主按钮、显示手动步骤（`token_capture_stub.dart` 与 `token_capture_io.dart` 通过 `if (dart.library.io)` 条件导入切换）。

桌面小组件已同时实现 Android、iOS、macOS（见 [widgets.md](widgets.md)），均通过 App Group/SharedPreferences 共享快照，30 分钟自动刷新并在应用更新数据后即时重绘。iOS 主应用已在 iPhone 16 模拟器（iOS 26.3）上真实运行并验证界面。

## 真接口自检

服务层可以脱离 UI 直接打真接口，用来确认今天平台返回的形状还被正确解析（需要自己的令牌，脚本不会打印令牌）：

```bash
DS_TOKEN=你的平台令牌 dart run tool/live_check.dart
```

逐项打印验证结果、钱包拆分、每个 API Key 的 Token/请求/费用、每个模型的花费、区间/今日/本月费用与缓存命中率。最近一次真实运行：`keys=2 models=1 trend=31d`，两个 Key 的费用相加 `3.1274 + 0.5954 = 3.7228` 恰好等于 `rangeCost`——这条等式是 (API Key × 模型) 拼接正确的证据。

## 测试覆盖

100 个测试，按它们保护的东西分组：

**接口解析**

- 平台真实钱包 JSON（`normal_wallets` 充值 / `bonus_wallets` 赠送 / 总额为两者之和，键名是 `balance` 而非 `total_balance`）
- (API Key × 模型) join、窗口过滤、端点失败降级、UTF-8 中文 Key 名
- 令牌嗅探（键名优先级、拒绝把配置值当令牌、嵌套 JSON）
- Authorization 头取值（带/不带 `Bearer `、制表符与引号、过短与多值一律拒绝而不是猜）
- 区间数学（半开窗口）

**不用示例数据冒充真实数据**

- 余额未知时渲染 `—` 而不是示例数字
- API Key 连上后余额是真的，用量仍带「示例」标签
- 余额没取到时横幅不许声称「已同步」

**凭据手感**

- 输入框默认遮蔽、眼睛按字段独立切换、已保存的只显示后四位而不回填明文
- 按平台推导的凭据说明（浏览器 / 原生可内嵌登录 / 原生无 WebView 三种组合各自的说法）
- 存储开关真的不写盘

**界面与布局**

- 反代把地址注入页面后裸地址即可用（注入值优先于查询串、同源相对路径免地址校验）
- API 基址解析（loopback 允许 / 外部主机拒绝 / 尾斜杠归一 / 查询串优先于编译期值）
- 今日区间画 24 个小时点而不是「24 天」，且三个镜头能切
- 自定义区间从 chip 下方弹出（选完 chip 显示区间、页面标题还在）
- 跨域被拦时给「浏览器拦下了跨域请求」和一条反代出路，而不是 `Failed to fetch`
- 响应式布局（390×844 手机底部 tab 只构建当前切片、1400 宽桌面一页全展示）
- 玻璃透明度（越界钳制、跨次启动记住选择、存了脏值也钳制、拖滑杆真的写盘、无 scope 时只读）

**桌面小组件**

- 快照自洽（钱包三项与总额、没有钱包时余额是 `null` 而不是 `0`、只取最后七天趋势、可用天数按真实日均算且没有花费时不编造）
- 未来日期不进柱图
