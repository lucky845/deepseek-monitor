{{flutter_js}}
{{flutter_build_config}}

/*
 * 国内可用的 Flutter Web 启动配置。
 *
 * 默认配置有两个致命问题，会把首屏拖成白屏：
 *   1. canvasKitBaseUrl 指向 www.gstatic.com（6.4MB wasm，国内基本不可达）
 *      —— 已通过构建参数 --no-web-resources-cdn 解决；
 *   2. fontFallbackBaseUrl 指向 fonts.gstatic.com（中文字体 Noto Sans SC
 *      原始 ttf 10.5MB，gzip 后仍有 6MB）
 *      —— 这里改成图片本站字体，并用 GB2312 子集把体积压到 2MB。
 *
 * 字体已随仓库托管在 canvaskit/fonts/ 下，CI 构建直接带上，不依赖任何外部域名。
 */
_flutter.loader.load({
  serviceWorkerSettings: {
    serviceWorkerVersion: {{flutter_service_worker_version}}
  },
  config: {
    // 引擎会拼成 <base>notosanssc/v36/<hash>.ttf，与 web/fonts 目录结构一致。
    // 注意不能用 canvaskit/ 前缀：那个目录由引擎构建时整体生成，源码里的内容会被覆盖。
    fontFallbackBaseUrl: 'fonts/',
  },
});
