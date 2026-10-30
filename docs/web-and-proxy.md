# Web 端与反向代理

浏览器为什么读不到平台的用量接口，以及本地调试与自建部署该怎么绕开。回到 [README](../README.md)。

浏览器不允许网页直接读 `platform.deepseek.com` 的响应，两条独立的墙：

1. **同源策略**：网页读不到 `platform.deepseek.com` 的 localStorage，官方也没有 OAuth 回调地址；
2. **CORS**：即便把令牌手动粘进来，`platform.deepseek.com` 的响应里**没有任何 `access-control-*` 头**（实测：带 `Origin` 请求它是 `HTTP 200` 但响应头里一个 `access-control-*` 都没有；preflight `OPTIONS` 直接 429），浏览器因此丢弃整个响应，令牌永远验证不了。对照之下 `api.deepseek.com` 会回 `access-control-allow-origin`，所以 **API Key 读余额在网页端直接可用**。

Node 项目遇到这个问题的做法是 dev server proxy，这里同理——**起一个同源的反向代理就能绕开**，前端所有请求都发给自己，由代理转发到平台并把响应带回来：

```bash
flutter build web --release
python3 tool/dev_proxy.py --port 8788 --root build/web
# 电脑浏览器直接打开（不用带任何参数）
# http://127.0.0.1:8788/
```

代理会在它自己返回的 `index.html` 里注入 `window.__DS_PLATFORM_API_BASE__ = '/platform-api'`，应用优先读这个值——所以**打开代理地址就等于连上反代**，不用再记 `?api_base=`。注入的值是同源相对路径，页面开在 `127.0.0.1`、`192.168.x.x` 还是 `10.0.2.2` 上都自动正确。手动带 `?api_base=` 仍然有效（命令行调试、`flutter run -d chrome` 时用得上）。

手机 / 平板 / 安卓模拟器要连同一台机器的反代，让代理监听局域网（`--host 0.0.0.0`）后直接打开局域网地址即可：

```bash
python3 tool/dev_proxy.py --port 8788 --host 0.0.0.0 --root build/web
# 手机浏览器打开（把 192.168.1.20 换成本机局域网 IP）—— 不用带参数
# http://192.168.1.20:8788/
# Android 模拟器访问宿主机用 10.0.2.2
# http://10.0.2.2:8788/
```

代理会在收到请求时补上浏览器 User-Agent（平台对无 UA 的请求直接 429 "Request Blocked"），`--force-token-file 令牌文件` 还能把客户端发来的 Authorization 换成文件里的真令牌——这样浏览器里不必输入真实凭据（**仅限本地调试**：它会把任何客户端令牌替换掉，正常使用时不要加这个参数）。

也可以把地址编译进产物，适合长期自建的部署：

```bash
flutter build web --release --dart-define=PLATFORM_API_BASE=https://你的反代域名/platform-api
```

`?api_base=` 只认本机回环（`127.0.0.1` / `localhost` / `::1`）和私有网段（`10.x`、`172.16–31.x`、`192.168.x`，含模拟器的 `10.0.2.2`）：这个值来自 URL，随便谁都能构造一个链接，若允许任意公网主机，就等于允许别人把你的令牌发到自己的服务器。要换公网域名请用 `--dart-define`（构建者自己决定）或部署自己的反代。逻辑在 `lib/services/api_base.dart`，有单测覆盖（回环放行、私有网段放行、公网与伪装域名拒绝、非 http 拒绝、尾斜杠归一、优先级顺序）。

结论：**Web 版只要前面有一个反代，就是完整功能**（余额 + 用量 + 费用 + 趋势 + 多 Key 对比）；直连静态托管的 Web 只能读余额，那就用客户端。
