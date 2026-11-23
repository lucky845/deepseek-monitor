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
flutter build web --release --wasm -O4 \
  --dart-define=PLATFORM_API_BASE=https://你的反代域名/platform-api
```

`--wasm` 与 `-O4` 是线上在用的组合：wasm 侧编译器默认 **-O2**（flutter_tools 有意只开 sound 优化），提到 -O4 换到 gzip 后 wasm 少 2.6%、js 少 4.5%，首帧在受限带宽下明显更快；代价是放弃 wasm 编译器的 soundness 检查。理由与实测数字见 `.github/workflows/build.yml` 里那段注释，有测试盯着它（`test/web_build_flags_test.dart`）。

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

## 首帧传输字节已经到下限了

首帧（Flutter 画出第一帧）之前要下的字节，线上实测 **2,441,135B / 27 个请求**，其中：

| bytes | 占比 | 是什么 |
| --- | --- | --- |
| 1,226,791 | 50.3% | `skwasm.wasm`（gstatic，br） |
| 897,809 | 36.8% | `main.dart.wasm`（本站，gzip） |
| 181,493 | 7.4% | 字体（Roboto + 11 片 Noto） |
| 68,715 | 2.8% | 两张 mascot（异步，在首帧之后） |
| 10,871 | 0.4% | Cloudflare 自己的 beacon + rum |

两个 wasm 合计 **87%**。所以别再往业务代码上找了：按 source map 的字节归属，`lib/` 只占 wasm 可归因字节的 **2.9%（44,458B）**，97% 是 Flutter/Dart SDK；`flutter_inappwebview` 合计不到 600B、`liquid_glass_easy` 121B、`fl_chart` 3,011B——砍依赖对体积没有意义。

已经做过的、有效的：

- `-O4`（见 `.github/workflows/build.yml` 注释）：wasm gzip 911,115 → 887,280、js gzip 901,266 → 861,135。
- 引擎 wasm 走 gstatic（见 `web/flutter_bootstrap.js` 顶部）：本站 CF 只能拿到源站**已经 gzip 过**的流再压一遍，1,551,371B → gstatic 的 br11 1,225,993B。
- 11 片 Noto 预载 + 启动链 10 条预取。

已经试过、明确无效的：

- `wasm-opt --all-features -Oz`（binaryen 133）：raw −1.5%，但 **gzip 只 −0.2%**，还要多一个构建后处理步骤。不做。
- 剥 wasm 符号段：`main.dart.wasm` 只剩一个 9B 的 `name` custom 段（已 strip），`skwasm.wasm` 一个都没有。
- 按需/延迟加载 wasm：`dart compile wasm` 没有 deferred 参数。
- jsDelivr 当 wasm 托管：`curl -4` 五次全部 `size=0`（104.16.180.112 / 104.16.179.112 都连不上），IPv6 走 Fastly 能下但 total 15s。目标网络里不可用。

### 那 198KB 卡在哪：源站只发 gzip

生产 `main.dart.wasm` 的四种编码实测：

| Accept-Encoding | 返回 | 字节 |
| --- | --- | --- |
| identity | `ce=none` | 2,383,851 |
| gzip | `ce=gzip` | 896,373 |
| br | `ce=br` | 873,256 |
| zstd | `ce=zstd` | 885,697 |
| `gzip, deflate, br, zstd`（Chrome 实际发的） | **`ce=gzip`** | 896,373 |

浏览器拿到的永远是 gzip 那 896KB，而且这个 br 只比 gzip 省 2.6%——不是 br 该有的水平。原因是链路：

- GitHub Pages 源站**只发 gzip**（`curl --resolve monitor.lucky845.top:443:185.199.109.153` 直连实测：identity 200 原始字节、gzip 200、br/zstd 都不支持）。
- Cloudflare 拿到的是这条 gzip 流，只能**对它再压一遍**，br 质量实际落在 q≈4。
- 本地 zlib 精确复现：`br11(gzip9(raw))` = 881,544，与线上 873,256 只差 1.0%；而 `br11(raw)` = **698,134**（−21.3%）。差的这 21% 就是这样丢掉的。

对照组证明这不是 Cloudflare 的能力问题：`cdn.jsdelivr.net/npm/canvaskit-wasm@0.39.1/bin/canvaskit.wasm` 同一个 Cloudflare，identity 6,786,717 → gzip 2,760,302 → **br 2,157,170**（br 比 gzip 省 21.8%），因为它的源站给的是原始流。

### 拿到这 198KB 值多少

同一份 `build/web` 起两臂、只换 `main.dart.wasm` 的编码，同轮交替、配对相减（本地 HTTP/2，CDP 节流）：

| 档位 | gzip 首帧 | br11 首帧 | 配对中位 | 轮次 |
| --- | --- | --- | --- | --- |
| Fast 4G（9Mbps/40ms） | 2229ms | 2065ms | **−165ms** | 6/6 |
| Slow 3G（1.6Mbps/100ms） | 11573ms | 10625ms | **−948ms** | 4/4 |
| 宽带（40Mbps/20ms） | — | — | 落在 gstatic 网络抖动里 | 2/5 |

宽带那档测不出，是因为 gstatic 的 `skwasm.wasm` 走公网、完成时刻本身就在 ±100ms 抖，把 195KB 的差淹了。把两臂都改成同源、两个 wasm 一起走 br11 再测（隔离掉公网抖动）：

| 档位 | gzip 首帧 | br11 首帧 | 配对中位 | 轮次 |
| --- | --- | --- | --- | --- |
| 宽带 | 706ms | 665ms | **−64ms** | 6/6 |
| Fast 4G | 2509ms | 2060ms | **−447ms** | 6/6 |
| Slow 3G | 13043ms | 10547ms | **−2510ms** | 3/3 |

注意这一组 gzip 臂的 `skwasm.wasm` 是 1,536,881B，比线上（gstatic br）的 1,225,993B 更重，所以 −447 / −2510 **高估了**真实收益。真实换托管的收益就是上一张表：**Fast 4G −165ms、Slow 3G −948ms**（`skwasm` 那份已经由 gstatic 用 br11 送着了，换源站拿不到额外好处）。

### 想拿到这 198KB，只有一条路

让**源站对 CF 发原始流**，CF 的自动 br 才会按 q11 压。GitHub Pages 做不到（它强制 gzip）。可选：

1. 换到源站发 identity 的托管（Cloudflare Pages / 对象存储 + 自定义域）。CI 形状不变，Pages 的构建命令照抄 `.github/workflows/build.yml`。**这一条还没实测过 Pages 对 `.wasm` 到底给不给 br，要先做一次 spike 再决定迁不迁。**
2. 保持现状。首帧在 Fast 4G 是 2449ms、Slow 3G 是 11813ms，已经贴着「字节下限 + 编译 ~110ms」在跑（实测首帧 − 最大 wasm 完成时刻 只有 111ms），没有别的余量了。

补一条容易踩错的：`.wasm` 不带 hash，改托管/CDN 规则时别给 `.wasm` 调长 Edge TTL，否则 Flutter 升级后边缘会把旧 wasm 发给新的 `main.dart.js`。

