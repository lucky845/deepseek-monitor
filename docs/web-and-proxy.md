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

**线上（monitor.lucky845.top）已经这么配了**：CI 构建带 `--dart-define=PLATFORM_API_BASE=https://monitor.lucky845.top/platform-api`，反代是一个 Cloudflare Worker（`platform-api-proxy`），zone `lucky845.top` 上的 route `monitor.lucky845.top/platform-api/*` 把请求转发到 `platform.deepseek.com`，并补上 `Access-Control-Allow-Origin`。Worker 源码在 [tool/cloudflare_worker/platform-api-proxy.js](../tool/cloudflare_worker/platform-api-proxy.js)；改动用 API Token 调 `PUT /accounts/{id}/workers/scripts/platform-api-proxy`（multipart，注意 `Content-Disposition` 必须带 `form-data;` 前缀）+ `POST /zones/{id}/workers/routes`。平台对无 User-Agent 的请求回 429，所以反代必须透传浏览器 UA。

`?api_base=` 只认本机回环（`127.0.0.1` / `localhost` / `::1`）和私有网段（`10.x`、`172.16–31.x`、`192.168.x`，含模拟器的 `10.0.2.2`）：这个值来自 URL，随便谁都能构造一个链接，若允许任意公网主机，就等于允许别人把你的令牌发到自己的服务器。要换公网域名请用 `--dart-define`（构建者自己决定）或部署自己的反代。逻辑在 `lib/services/api_base.dart`，有单测覆盖（回环放行、私有网段放行、公网与伪装域名拒绝、非 http 拒绝、尾斜杠归一、优先级顺序）。

## 中文字体是自托管的子集

Web 版的 `FontManifest.json` 里只有图标字体（MaterialIcons、CupertinoIcons），正文汉字靠 `fontFallbackBaseUrl` 兜底：引擎画到某个字发现没有字形，才去 `web/fonts/` 取 Noto Sans SC。这个地址默认指向 `fonts.gstatic.com`，原始 ttf 10.5MB（gzip 后仍有 6MB），国内打开就是长时间没有字。

所以两个 ttf 都随仓库托管，并按 `lib/` 的真实用字裁成子集：

| 产物 | 负责 | 母本 | 子集 | gzip |
| --- | --- | --- | --- | --- |
| `web/fonts/notosanssc/v36/<hash>.ttf` | 汉字与中文标点 | 2064 KB | 149 KB | 93 KB |
| `web/fonts/roboto/v20/<hash>.ttf` | Latin 与 ASCII | 167 KB | 54 KB | 36 KB |

```bash
# 按 lib/ 的当前用字重新裁 —— 改了中文文案就跑这个
uv run --no-project --with fonttools python tool/subset_web_fonts.py
# 只校验不写文件（连产物 sha256 一起核对）
uv run --no-project --with fonttools python tool/subset_web_fonts.py --check
# 换母本：给一个完整的 Noto Sans SC 变量字体，脚本会实例化到 wght=400 再存进素材区
uv run --no-project --with fonttools python tool/subset_web_fonts.py --refresh-master 'NotoSansSC[wght].ttf'
```

**改了中文文案不重跑，新字就渲染成豆腐块。** `test/web_font_subset_test.dart` 直接解析产物的 cmap 表和 `lib/` 的源码来比对，CI 会拦住这种提交。

两个坑值得记住：

1. **文件名不能改。** `notosanssc/v36/<hash>.ttf` 里的 hash 是引擎构建时写死的，`--no-web-resources-cdn` 之下引擎只认这一个名字；换子集是**原地替换文件内容**，不是加一个新文件。
2. **旧的「GB2312 子集」版本是坏的。** 它只取 `U+4E00–U+9FA0`，整个标点区（`，。、：；「」（）→…`）都不在里面——界面上每个逗号句号都被吃掉，`不是你的。点「连接账号」` 显示成 `不是你的 点 连接账号`。现在的字符集是脚本扫 `lib/` 得到的真实用字，再用 `tool/font_src/` 两个母本 cmap 的**并集**过滤掉两个母本都没有的码位（比如 `✔✗✘`，避免留下一个永远满足不了的红灯）。

字符集和产物哈希记录在 `web/fonts/SUBSET_INFO.txt`，由脚本生成，不要手工编辑。

### 换完字体要清一次 CDN 缓存

两个 ttf 的文件名（`v36/<hash>.ttf`）由引擎写死，**内容换了名字也不会变**，而它们带着 `max-age=14400` 的头，Cloudflare 也照此缓存。所以换完子集直接部署，**回访用户最长 4 小时看到的还是旧字体**——修标点缺失那次正好踩在这里。

部署后到 Cloudflare 面板清一次（Caching → Configuration → Purge Cache），改动面广就直接 Purge Everything：

- `/`
- `/main.dart.js`
- `/flutter_bootstrap.js`
- `/fonts/notosanssc/v36/<hash>.ttf`
- `/fonts/roboto/v20/<hash>.ttf`

`tool/subset_web_fonts.py` 每次重建完会把这份清单打出来。浏览器自己那份缓存（`max-age=600`，最长 10 分钟）删不掉，可以接受。

### `/canvaskit/` 不在 Cloudflare 的默认缓存里

`.wasm` 不在 Cloudflare 的默认缓存扩展名列表内，所以 `chromium/canvaskit.wasm` 的响应一直是 `cf-cache-status: DYNAMIC`（从不进边缘缓存，每次回源 GitHub Pages）。**代价比看起来小得多**：回访用户发的是条件请求，拿到的是 **304，不重传那 2MB**；实测路径耗时 0.315s，对比命中缓存的 0.308s——差的是边缘回源那一次往返。

想消掉这一次往返，加一条 Cache Rule：匹配 `URI Path starts with /canvaskit/`，设 `Cache eligibility: Eligible for cache`，**Edge TTL 保持默认（跟随源站）**。别把 Edge TTL 调长：`canvaskit.wasm` 这个名字不带 hash，Flutter 升级换了引擎之后，长 TTL 会让边缘一直把旧 wasm 发给新的 `main.dart.js`。

结论：**Web 版只要前面有一个反代，就是完整功能**（余额 + 用量 + 费用 + 趋势 + 多 Key 对比）；直连静态托管的 Web 只能读余额，那就用客户端。
