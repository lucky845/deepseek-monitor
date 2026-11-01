/// 摘掉 web/index.html 里的首屏骨架。
///
/// 只在 web 构建里做实事：调用页面里的 `window.__dropBootSkeleton()`。
/// 原生平台没有那段 HTML，直接空实现，调用点不需要任何条件判断。
library;

import 'boot_skeleton_stub.dart'
    if (dart.library.js_interop) 'boot_skeleton_web.dart' as impl;

/// 引擎画出第一帧后调用，让 HTML 骨架淡出并被移除。
/// 重复调用安全（页面侧用 id 判空），所以宁可多调也别漏调。
void hideBootSkeleton() => impl.hideBootSkeleton();
