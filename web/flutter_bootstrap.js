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
 *      —— 这里改成从本站取，见下。
 *
 * 字体随仓库托管在 web/fonts/ 下，CI 构建直接带上，不依赖任何外部域名。
 * 两个 ttf 都是 tool/subset_web_fonts.py 按 lib/ 的真实用字裁出来的子集：
 *   notosanssc 管汉字与中文标点（2064KB → 149KB，gzip 93KB）
 *   roboto     管 Latin 与 ASCII（ 167KB →  54KB，gzip 36KB）
 * 注意这不是"GB2312 子集"那么粗：旧的 2MB 版本只取 U+4E00–U+9FA0，
 * 整个标点区都没有，界面上每个逗号句号都被吃掉。
 * 改了中文文案就要重跑那个脚本，否则新字渲染成豆腐块 ——
 * test/web_font_subset_test.dart 会拦住这种提交。
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
