/// Reads the globals a dev proxy injects into the page it serves.
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

String? _read(String key) {
  final value = globalContext.getProperty<JSAny?>(key.toJS);
  if (value == null) return null;
  final text = value.dartify();
  if (text is! String || text.isEmpty) return null;
  return text;
}

String? injectedPlatformBase() => _read('__DS_PLATFORM_API_BASE__');

String? injectedApiBase() => _read('__DS_API_BASE__');
