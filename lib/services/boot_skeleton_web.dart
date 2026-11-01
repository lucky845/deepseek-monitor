/// 调用 `web/index.html` 里定义的骨架移除函数。
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

void hideBootSkeleton() {
  final fn = globalContext.getProperty<JSAny?>('__dropBootSkeleton'.toJS);
  if (fn == null) return; // 页面被替换过 / 骨架已被兜底定时器摘掉
  final callable = fn as JSFunction;
  callable.callAsFunction(globalContext);
}
