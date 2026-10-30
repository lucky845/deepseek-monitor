/// The origins the service talks to.
///
/// Normally these are the real DeepSeek hosts. A local dev proxy can stand in
/// for them, which is the only way to exercise the platform endpoints from a
/// browser: `platform.deepseek.com` answers without a single `access-control-*`
/// header, so a page is not allowed to read its responses at all.
///
/// Two ways to point the app at a proxy:
///
/// ```text
/// flutter run -d chrome --dart-define=PLATFORM_API_BASE=http://127.0.0.1:8787/platform-api
/// http://127.0.0.1:8787/?api_base=http://127.0.0.1:8787/platform-api
/// ```
///
/// The query parameter is only honoured for loopback and private-network hosts.
/// It arrives from a URL, and a link crafted by someone else must never be able
/// to point the app — and the token it holds — at a public host that person
/// controls. Private addresses are allowed because that is exactly how you
/// debug the web build from a phone or an emulator on your own LAN.
library;

import 'bootstrap_base.dart';

const String _platformBaseFromEnv = String.fromEnvironment('PLATFORM_API_BASE');
const String _apiBaseFromEnv = String.fromEnvironment('DEEPSEEK_API_BASE');

const String kDefaultPlatformBase = 'https://platform.deepseek.com';
const String kDefaultApiBase = 'https://api.deepseek.com';

/// Where platform endpoints live (`/api/v0/...`, `/auth-api/v0/...`).
String resolvePlatformBase(
        {Map<String, String>? queryParams, String? injected}) =>
    resolveBase(
      queryKey: 'api_base',
      injected: injected ?? injectedPlatformBase(),
      fromEnv: _platformBaseFromEnv,
      fallback: kDefaultPlatformBase,
      queryParams: queryParams,
    );

/// Where the public API lives (`/user/balance`).
String resolveApiBase({Map<String, String>? queryParams, String? injected}) =>
    resolveBase(
      queryKey: 'deepseek_api_base',
      injected: injected ?? injectedApiBase(),
      fromEnv: _apiBaseFromEnv,
      fallback: kDefaultApiBase,
      queryParams: queryParams,
    );

/// Resolution order: what the page injected, then a loopback query override,
/// then the compile-time value, then the real host. `queryParams` defaults to
/// the page's own query.
///
/// The injected value comes first because it is the one the caller cannot get
/// wrong: a dev proxy puts it in the page it serves, so opening the proxy's
/// address is enough — no `?api_base=` to remember on a phone keyboard.
String resolveBase({
  required String queryKey,
  required String fromEnv,
  required String fallback,
  Map<String, String>? queryParams,
  String? injected,
}) {
  final fromPage =
      injected == null ? null : devOverrideFrom({queryKey: injected}, queryKey);
  if (fromPage != null) return fromPage;
  final fromUrl =
      devOverrideFrom(queryParams ?? Uri.base.queryParameters, queryKey);
  if (fromUrl != null) return fromUrl;
  if (fromEnv.isNotEmpty) return _stripTrailingSlash(fromEnv);
  return fallback;
}

/// A base URL from the query string, but only when it stays on this machine or
/// the network it sits on.
///
/// The value arrives in a URL, so anyone can craft one. Honouring a public host
/// would let a link ship the stored token to a server the sender owns. Loopback
/// and RFC 1918 addresses are a different matter: they are only reachable from
/// inside your own network, and they are how a phone or an Android emulator
/// (`10.0.2.2`) reaches a dev server running on your machine.
String? devOverrideFrom(Map<String, String> params, String key) {
  final raw = params[key];
  if (raw == null || raw.isEmpty) return null;
  // A same-origin path can only ever point back at the server that served the
  // page, so it needs no address check — and it is what a dev proxy injects,
  // which keeps working whatever host the page was opened on (127.0.0.1,
  // 192.168.x.x, 10.0.2.2).
  if (raw.startsWith('/')) {
    final base = Uri.base;
    final path = _stripTrailingSlash(raw);
    if (base.scheme == 'http' || base.scheme == 'https') {
      return '${base.origin}$path';
    }
    return path;
  }
  final uri = Uri.tryParse(raw);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  if (!_isLocalOrPrivate(uri.host)) return null;
  return _stripTrailingSlash(raw);
}

bool _isLocalOrPrivate(String host) {
  if (host == 'localhost' || host == '::1') return true;
  final address = Uri.tryParse('http://$host')?.host ?? host;
  final parts = address.split('.');
  if (parts.length != 4) return false;
  final octets = <int>[];
  for (final part in parts) {
    final value = int.tryParse(part);
    if (value == null || value < 0 || value > 255) return false;
    octets.add(value);
  }
  if (octets[0] == 127) return true; // loopback
  if (octets[0] == 10) {
    return true; // private, includes the 10.0.2.2 emulator host
  }
  if (octets[0] == 192 && octets[1] == 168) return true; // private
  if (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) {
    return true; // private
  }
  return false;
}

String _stripTrailingSlash(String value) =>
    value.endsWith('/') ? value.substring(0, value.length - 1) : value;
