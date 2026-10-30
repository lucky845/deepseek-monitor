import 'dart:collection' show UnmodifiableListView;
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../theme.dart';
import 'deepseek_service.dart';
import 'token_harvest.dart';

/// Desktop and mobile builds can host the official sign-in page in a webview
/// and read the session token it stores. The browser cannot: the token lives in
/// another origin's storage, which the same-origin policy keeps out of reach.
/// Running in the browser?

bool get canCaptureTokenInApp =>
    Platform.isAndroid ||
    Platform.isIOS ||
    Platform.isMacOS ||
    Platform.isWindows;

/// Opens the official DeepSeek sign-in page in an in-app webview, waits for the
/// user to log in *on DeepSeek's own page*, then harvests the session token from
/// that webview's storage.
///
/// The password never passes through this app. The harvested value is verified
/// against the platform API before it is returned, so a wrong guess can never
/// be handed back as a working credential. Resolves to null if the user closes
/// the page without logging in.
Future<String?> capturePlatformToken(BuildContext context) async {
  if (!canCaptureTokenInApp) return null;
  return Navigator.of(context).push<String>(
    MaterialPageRoute<String>(
      builder: (_) => const _PlatformLoginPage(),
      fullscreenDialog: true,
    ),
  );
}

const String _signInUrl = 'https://platform.deepseek.com/sign_in';

/// Hooks the page's own network calls so the `Authorization` header can be read
/// on platforms whose webview will not tell us about requests.
///
/// Android's WebViewClient hands us every request, so `shouldInterceptRequest`
/// is enough there. A WKWebView (iOS/macOS) never calls that back for plain
/// http/https traffic, which left the automatic path reading storage alone —
/// and storage holds a short id under `userToken` that merely looks like a
/// token. This runs before any page script, records the header the app itself
/// sends, and never modifies a request.
const String _credentialTapScript = r'''
(function () {
  if (window.__dsTokenTap) { return; }
  window.__dsTokenTap = true;
  window.__dsAuth = null;

  var remember = function (value) {
    try {
      if (typeof value === 'string' && value.length > 0) { window.__dsAuth = value; }
    } catch (e) {}
  };

  // Only an authenticated account call counts. The sign-in handshake carries
  // its own anonymous credentials and static assets carry none.
  var counts = function (url) {
    try {
      var s = String(url || '');
      return s.indexOf('deepseek.com') >= 0 && s.indexOf('/auth-api') < 0;
    } catch (e) { return false; }
  };

  var pickHeader = function (init) {
    try {
      var h = init && init.headers;
      if (!h) { return; }
      if (typeof h.get === 'function') {
        remember(h.get('authorization') || h.get('Authorization'));
        return;
      }
      if (h instanceof Array) {
        for (var i = 0; i < h.length; i++) {
          if (String(h[i][0]).toLowerCase() === 'authorization') { remember(h[i][1]); }
        }
        return;
      }
      for (var k in h) {
        if (String(k).toLowerCase() === 'authorization') { remember(h[k]); }
      }
    } catch (e) {}
  };

  var originalFetch = window.fetch;
  if (originalFetch) {
    window.fetch = function (input, init) {
      try {
        var url = (input && input.url) ? input.url : input;
        if (counts(url)) { pickHeader(init); }
      } catch (e) {}
      return originalFetch.apply(this, arguments);
    };
  }

  var originalSet = XMLHttpRequest.prototype.setRequestHeader;
  XMLHttpRequest.prototype.setRequestHeader = function (name, value) {
    try {
      if (String(name).toLowerCase() === 'authorization') { remember(value); }
    } catch (e) {}
    return originalSet.apply(this, arguments);
  };
})();
''';

/// Dumps both web storages of the loaded page. We do not hardcode the key name:
/// the page may rename it, so we harvest everything and score it afterwards.
const String _harvestScript = r'''
(function () {
  var dump = function (store) {
    var out = {};
    try {
      for (var i = 0; i < store.length; i++) {
        var k = store.key(i);
        if (k) { out[k] = store.getItem(k); }
      }
    } catch (e) {}
    return out;
  };
  var tapped = null;
  try { tapped = window.__dsAuth || null; } catch (e) {}
  return JSON.stringify({
    local: dump(localStorage), session: dump(sessionStorage), auth: tapped
  });
})();
''';

class _PlatformLoginPage extends StatefulWidget {
  const _PlatformLoginPage();

  @override
  State<_PlatformLoginPage> createState() => _PlatformLoginPageState();
}

class _PlatformLoginPageState extends State<_PlatformLoginPage> {
  InAppWebViewController? _controller;
  double _progress = 0;
  bool _busy = false;

  /// Values already sent to the platform once. A rejected candidate must not
  /// shadow the ones behind it, but it does not deserve a second API call
  /// either — so the whole set is remembered, not just the last attempt.
  final Set<String> _triedTokens = <String>{};
  String? _headerToken;
  WebUri? _currentUrl;
  String _status = '正在打开 DeepSeek 官方登录页…';

  /// True while the webview still sits on the sign-in form. Nothing may be
  /// harvested there: the page is anonymous, so anything the storage or the
  /// network hands over belongs to someone else — not to this user.
  static bool _onSignInPage(WebUri? url) {
    if (url == null) return false;
    final path = url.path.toLowerCase();
    return path.contains('sign_in') ||
        path.contains('signin') ||
        path.contains('login');
  }

  /// Only calls that carry an authenticated *account* session count. The
  /// sign-in handshake has its own anonymous credentials, and static assets
  /// have none, so both are refused.
  static bool _isCredentialRequest(WebUri? url) {
    if (url == null) return false;
    if (!url.host.toLowerCase().endsWith('deepseek.com')) return false;
    final path = url.path.toLowerCase();
    if (path.startsWith('/auth-api')) return false;
    return path.contains('/api/');
  }

  /// The token does not live in a `userToken` storage key — it rides on every
  /// authenticated request as `Authorization: Bearer …`. Storage is still the
  /// first place we look (it is cheap and platform-agnostic), but a page that
  /// keeps the token in memory only would never show up there, so we also keep
  /// the last header value we saw go past.
  void _rememberHeader(WebUri? url, Map<String, String>? headers) {
    if (headers == null) return;
    if (!_isCredentialRequest(url)) return;
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() != 'authorization') continue;
      final token = extractBearerToken(entry.value);
      if (token != null) _headerToken = token;
    }
  }

  Future<void> _harvest({required bool manual}) async {
    final controller = _controller;
    if (controller == null || _busy) return;
    // The platform is a single-page app: it moves between routes with
    // pushState, which never fires another load. Asking the webview where it is
    // now is the only reliable answer; the last URL we saw can still be the
    // sign-in page long after the user has logged in.
    final liveUrl = await controller.getUrl();
    if (liveUrl != null) _currentUrl = liveUrl;
    // An explicit tap means "read it now", so it is never refused on the
    // strength of an address we may have read a beat too early — verifying a
    // candidate that turns out to be garbage is a recoverable failure, while
    // refusing a signed-in user is not. The automatic pass stays quiet on the
    // sign-in page so it does not burn a request on every keystroke.
    if (!manual && _onSignInPage(_currentUrl)) return;
    _busy = true;
    try {
      final raw = await controller.evaluateJavascript(source: _harvestScript);
      final dump = raw?.toString() ?? '';
      // Both sources are request headers seen in flight: Android's
      // interceptor, or the injected hook where the webview gives us
      // nothing. Either way it outranks storage.
      final headerToken =
          extractBearerToken(_headerToken) ?? extractTappedAuth(dump);
      final fromStorage = extractTokenCandidates(dump);
      // Order matters. The header value is not a guess — it was lifted off a
      // real authenticated request — so it outranks every value the page's
      // storage happens to contain. Trusting storage first is what made the
      // session carry on with a short id that merely looked like a token.
      final ordered = <String>[
        if (headerToken != null) headerToken,
        ...fromStorage,
      ];
      final fresh = <String>[];
      for (final c in ordered) {
        if (!_triedTokens.contains(c) && !fresh.contains(c)) fresh.add(c);
      }
      assert(() {
        // Lengths only, never values. This line is what tells a future reader
        // which store the real credential came out of.
        debugPrint('[harvest] url=$_currentUrl '
            'storage=${fromStorage.map((c) => c.length).toList()} '
            'header=${headerToken?.length} fresh=${fresh.length}');
        return true;
      }());
      if (ordered.isEmpty) {
        if (manual && mounted) {
          setState(() => _status = '还没读到令牌。请确认已在页面里完成登录，再试一次。');
        }
        return;
      }
      // Every candidate gets one shot: a failed attempt is remembered so the
      // next tap moves on to the next candidate instead of retrying the same
      // value, but it never blocks the values behind it.
      if (fresh.isEmpty) {
        if (manual && mounted) {
          setState(() => _status = '令牌还没更新。请完成登录，或改用手动粘贴。');
        }
        return;
      }
      for (final candidate in fresh) {
        _triedTokens.add(candidate);
        if (mounted) setState(() => _status = '已读到登录令牌，正在向 DeepSeek 验证…');
        final ok = await _verify(candidate);
        if (!mounted) return;
        if (ok) {
          setState(() => _status = '验证通过，正在返回…');
          Navigator.of(context).pop(candidate);
          return;
        }
      }
      if (mounted) {
        setState(() => _status = '读到候选令牌但验证未通过。请重试，或关闭后改用手动粘贴。');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _status = '读取令牌失败：$e。可以关闭后改用手动粘贴。');
      }
    } finally {
      _busy = false;
    }
  }

  Future<bool> _verify(String candidate) async {
    try {
      await DeepSeekService(token: candidate).verifyToken(candidate);
      return true;
    } on DeepSeekException {
      return false;
    } catch (_) {
      // Network trouble is not proof of a bad token, but we still refuse to
      // hand back something unverified.
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kSurface,
        title: const Text('登录 DeepSeek'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: '取消',
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          TextButton(
            onPressed: () => _harvest(manual: true),
            child: const Text('我已登录，读取令牌'),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_progress < 1)
            LinearProgressIndicator(
              value: _progress == 0 ? null : _progress,
              minHeight: 2,
              backgroundColor: kSurface2,
              color: kAccent,
            ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(_signInUrl)),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                transparentBackground: false,
              ),
              // Runs before any page script on every navigation, so the hook
              // is already in place when the page sends its first request.
              initialUserScripts: UnmodifiableListView<UserScript>([
                UserScript(
                  source: _credentialTapScript,
                  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                ),
              ]),
              onWebViewCreated: (controller) => _controller = controller,
              // Not every page keeps the token in web storage; the header it
              // sends is the credential itself, so keep the last one we see.
              shouldInterceptRequest: (controller, request) async {
                _rememberHeader(request.url, request.headers);
                return null;
              },
              onProgressChanged: (controller, progress) {
                if (mounted) setState(() => _progress = progress / 100);
              },
              onLoadStop: (controller, url) async {
                _currentUrl = url;
                // Runs after every navigation, so the token is picked up as soon
                // as the page settles post-login — but never while the sign-in
                // form is still on screen.
                await _harvest(manual: false);
              },
            ),
          ),
          Container(
            width: double.infinity,
            color: kSurface,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_status,
                    style: const TextStyle(color: kText, fontSize: 13)),
                const SizedBox(height: 4),
                const Text(
                  '账号密码只输入在 DeepSeek 官方页面上，本应用不接触凭据。',
                  style: TextStyle(color: kMuted, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
