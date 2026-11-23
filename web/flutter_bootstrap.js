{{flutter_js}}
{{flutter_build_config}}

/*
 * 国内可用的 Flutter Web 启动配置。
 *
 * 默认配置有两个致命问题，会把首屏拖成白屏：
 *   1. fontFallbackBaseUrl 指向 fonts.gstatic.com（中文字体 Noto Sans SC
 *      原始 ttf 10.5MB，gzip 后仍有 6MB）—— 这里改成从本站取，见下；
 *   2. canvasKitBaseUrl 指向 www.gstatic.com —— 这一条**不是**问题，反而是收益，
 *      见下面「引擎 wasm 的来源」。
 *
 * 字体随仓库托管在 web/fonts/ 下，CI 构建直接带上，不依赖任何外部域名。
 *   · Flutter 3.45+ 把 Noto Sans SC 从「单文件 v36 ttf」换成了「v37 分片 woff2」：
 *     引擎按字符按需请求 notosanssc/v37/<hash>.<N>.woff2。我们把 lib/ 真实用到的
 *     32 片按原文件名子集化后提交在 web/fonts/notosanssc/v37/（合计 217KB，
 *     一次会话浏览器实际只取其中几片）。
 *   · 旧的 v36 单文件 ttf（94KB, gzip 93KB）仍保留，供 3.24 及更早的 web 构建使用。
 *   · roboto 管 Latin 与 ASCII（167KB → 54KB，gzip 36KB）。
 * 注意这不是"GB2312 子集"那么粗：旧的 2MB 版本只取 U+4E00–U+9FA0，
 * 整个标点区都没有，界面上每个逗号句号都被吃掉。
 * 改了中文文案就要重跑那个脚本，否则新字渲染成豆腐块 ——
 * test/web_font_subset_test.dart 会拦住这种提交。
 *
 * ---- 引擎 wasm 的来源：改回 gstatic ----
 *
 * 历史上这里靠构建参数 --no-web-resources-cdn 把引擎 wasm 留在本站，理由是
 * 「gstatic 国内不可达」。实测（国内节点，无代理直连）这个理由不成立：
 *   www.gstatic.com → 120.253.253.226（国内 CDN 节点），DNS 50ms，
 *   TCP 26–46ms，TLS 95–117ms，TTFB 161–188ms。
 * 真正的问题是**压缩质量**：
 *   · 本站（Cloudflare）skwasm.wasm = gzip 1,551,371B —— 而且是「对源站已 gzip
 *     的流再压一遍」，本地 zlib 复现 br11(gzip9)=1,535,137B，与实测 1,540,088B
 *     只差 0.3%，说明 CF 拿不到原始流；
 *   · gstatic 同一份产物（identity 都是 3,593,715B，sha 相同）br q11 = 1,225,993B。
 *   差 325KB / −21%。本地 brotli 质量阶梯证明这 21% 只有 q11 能给：
 *     raw skwasm → br q4 −0.7%、q5 −7.6%、q9 −10.4%、q11 −21.3%。
 *   CF 免费版只到 q4 水平，所以「让 CF 改压原始流」这条也不通。
 *
 * gstatic 的响应头满足本项目 COEP require-corp 的要求：
 *   access-control-allow-origin: *、cross-origin-resource-policy: cross-origin、
 *   content-type: application/wasm —— 不需要 preflight，不会被 COEP 拦。
 * gstatic 上 10 个引擎变体（skwasm / skwasm_heavy / wimp / canvaskit / chromium /
 * webparagraph，js 与 wasm）全部有 br 版本，所以 js 回退分支不会 404。
 *
 * 端到端实测（本地 HTTP/2，两臂同一份 build/web，同轮配对相减）：
 *   Fast 4G (9Mbps/40ms)    2525 → 2263ms   -261ms   cdn 更快 6/6
 *   宽带    (40Mbps/20ms)    716 →  814ms    +77ms   cdn 更慢 0/6
 *   Slow 3G (1.6Mbps/100ms) 13159 → 11678ms -1482ms   cdn 更快 4/4
 * 分界点约在 25–30Mbps：带宽低于它，省下的 325KB 传输时间大于跨源 TLS 的
 * 95–117ms；高于它则反过来。首屏基线在宽带下只有 ~700ms，+77ms 是 11%；
 * 而 Fast 4G 的 −261ms 是 10%、Slow 3G 的 −1482ms 是 11%。目标用户以移动/
 * 受限带宽为主，取这个交换。
 *
 * 注意 canvasKitBaseUrl 是**唯一的注入点**，同一个 base 同时供 skwasm 与
 * canvaskit 两条路径（loader 里 function _(n,e){return n.canvasKitBaseUrl?...}），
 * 用户 config 的优先级高于 buildConfig。所以不能只把 .wasm 指走而 .js 留本地。
 * URL 里的引擎版本从 buildConfig.engineRevision 现算，不写死 —— 写死会在
 * Flutter 升级后指向不存在的目录。web/index.html 的预取清单里那个版本号是
 * 静态的，test/web_boot_assets_test.dart 会拿 SDK 的 engine.version 校验它。
 */
_flutter.loader.load({
  serviceWorkerSettings: {
    serviceWorkerVersion: {{flutter_service_worker_version}}
  },
  config: (function () {
    var cfg = _flutter.buildConfig || {};
    var rev = cfg.engineRevision;
    var config = {
      // 引擎拼成 <base> + notosanssc/v37/<hash>.<N>.woff2（3.45+）
      // 或 <base> + notosanssc/v36/<hash>.ttf（3.24），两者都与 web/fonts 目录结构一致。
      // 注意不能用 canvaskit/ 前缀：那个目录由引擎构建时整体生成，源码里的内容会被覆盖。
      fontFallbackBaseUrl: 'fonts/',
    };
    // 取不到 engineRevision 就退回本站（--no-web-resources-cdn 打出来的本地副本），
    // 宁可多下 325KB 也不能把首屏指到一个拼不出来的地址上。
    if (rev) {
      config.canvasKitBaseUrl =
          'https://www.gstatic.com/flutter-canvaskit/' + rev + '/';
    }
    return config;
  })(),
});
