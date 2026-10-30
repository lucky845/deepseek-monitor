# 数据来源与平台接口事实

应用只读三个端点，下面是它们的形状，以及几个会让人写出 bug 的平台行为。回到 [README](../README.md)。

## 三个端点

- 余额：`GET https://api.deepseek.com/user/balance`（API Key）或平台 `/api/v0/users/get_user_summary`
- 用量：`GET https://platform.deepseek.com/api/v0/usage/by_api_key/amount?start=&end=&tz=`
- 费用：`GET https://platform.deepseek.com/api/v0/usage/by_api_key/cost?start=&end=&tz=`

时间参数为 Unix 秒、左闭右开，`tz` 必须是 900 的倍数（默认 28800，即东八区）。费用已包含 DeepSeek 的峰谷计价。

**认证失败不会改变 HTTP 状态码。** 平台对无效令牌返回 `200 OK` 加一个 `{"code":40003,"msg":"Authorization Failed (invalid token)","data":null}` 响应体（三个端点都一样）。只看状态码会把任何字符串判成有效令牌。所以 `DeepSeekService` 一律走 `_platformEnvelope`：`code != 0` / `data` 不是对象 / 非 JSON 都算失败，状态码只用来区分 401/403 与 5xx。

**`userToken` 不是凭据。** 登录后的页面里确实有一个叫 `userToken` 的 localStorage 键，但它的值只有三十几个字符——那是短 id，不是令牌。同一份存储里还躺着另外两个"看起来像令牌"的值（实测长度分别是 36、88、64）。真正的凭据（64 字符）只出现在发往 `platform.deepseek.com/api/...` 的 `Authorization` 请求头上。

所以自动获取令牌必须**先**信任请求头，再逐个向平台验证，第一个通过的就是答案。只取 storage 里排序最靠前的那一个，那串 36 字符的 id 会永远挡在真令牌前面。

请求头怎么拿到，两个平台两条路，因为底层 webview 的能力不同：

| 平台 | 机制 | 为什么 |
|---|---|---|
| Android | `shouldInterceptRequest` | `WebViewClient` 会把每个请求连头一起交出来 |
| iOS / macOS | 注入 `UserScript` 钩住 `fetch` 与 `XMLHttpRequest.prototype.setRequestHeader`，把 `authorization` 存进 `window.__dsAuth` | WKWebView 的请求拦截不为普通 http/https 流量回调 |

两条路拿到的是同一种东西（真实请求上的头），所以 `_harvest` 里它们并列在 storage 之前：`extractBearerToken(_headerToken) ?? extractTappedAuth(dump)`。

**平台是单页应用，换路由不会再触发一次加载。** 登录成功后地址从 `/sign_in` 变成 `/usage` 走的是 `history.pushState`，WebView 的 `onLoadStop` 不会再触发。拿"最后一次加载时看到的地址"判断还在不在登录页，会把已经登录成功的用户挡在门外。所以自动读取前先用 `getUrl()` 问一次当前地址，而且**手动点击永远不做这层拦截**。
