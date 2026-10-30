/// Reads the base URLs a dev proxy can inject into the page.
///
/// The proxy serves `index.html` itself, so it can put
/// `window.__DS_PLATFORM_API_BASE__ = '/platform-api'` in front of the app. That
/// makes a bare `http://192.168.1.20:8788/` work — nobody has to remember to
/// append `?api_base=...`, which matters most on a phone, where the address is
/// typed with one thumb.
library;

import 'bootstrap_base_stub.dart'
    if (dart.library.js_interop) 'bootstrap_base_web.dart' as impl;

/// A base URL injected by the page the app is served from, if any.
String? injectedPlatformBase() => impl.injectedPlatformBase();

/// The same for the public API base.
String? injectedApiBase() => impl.injectedApiBase();
