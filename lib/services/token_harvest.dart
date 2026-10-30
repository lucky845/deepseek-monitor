/// Pure logic for lifting a DeepSeek platform session token out of a dump of a
/// webview's `localStorage` / `sessionStorage`.
///
/// Kept free of Flutter and `dart:io` so it can be unit tested directly.
library;

import 'dart:convert';

/// Keys DeepSeek (or a future version of it) is most likely to use.
const List<String> _preferredKeys = [
  'usertoken',
  'user_token',
  'token',
  'accesstoken',
  'access_token',
  'authtoken',
  'auth_token',
  'ds_token',
  'dstoken',
];

/// Anything shorter than this is not a session token.
const int _minLength = 16;

class _Candidate {
  _Candidate(this.priority, this.value);
  final int priority;
  final String value;
}

/// Pulls the most token-shaped value out of [rawStorageDump], the JSON string
/// produced by the webview script: `{"local": {...}, "session": {...}}`.
///
/// Returns null when nothing plausible is found — the caller then falls back to
/// asking the user to paste the token, and in every case verifies whatever it
/// gets against the platform API before storing it.
String? extractTokenFromStorage(String rawStorageDump) {
  final all = extractTokenCandidates(rawStorageDump);
  return all.isEmpty ? null : all.first;
}

/// Every plausible token in [rawStorageDump], best first.
///
/// The caller must try them in order rather than trusting the first: the page
/// keeps plenty of token-shaped values around (`userToken` among them is a
/// short id, not the credential), and picking one of those silently shadows the
/// real token that the request headers carry.
List<String> extractTokenCandidates(String rawStorageDump) {
  final dynamic decoded;
  try {
    decoded = jsonDecode(rawStorageDump);
  } catch (_) {
    return const <String>[];
  }
  if (decoded is! Map) return const <String>[];

  final candidates = <_Candidate>[];
  for (final store in decoded.values) {
    if (store is Map) {
      _collect(store, candidates);
    }
  }
  if (candidates.isEmpty) return const <String>[];

  candidates.sort((a, b) {
    final byPriority = a.priority.compareTo(b.priority);
    if (byPriority != 0) return byPriority;
    return b.value.length.compareTo(a.value.length);
  });
  final seen = <String>{};
  return [
    for (final c in candidates)
      if (seen.add(c.value)) c.value,
  ];
}

void _collect(Map<dynamic, dynamic> store, List<_Candidate> out) {
  store.forEach((rawKey, rawValue) {
    if (rawKey is! String || rawValue is! String) return;
    final key = rawKey.toLowerCase();

    // A value that is itself JSON often wraps the token, e.g.
    // `{"token":"...","expires":123}`. Look inside before judging the blob.
    final trimmed = rawValue.trim();
    if (trimmed.startsWith('{')) {
      try {
        final nested = jsonDecode(trimmed);
        if (nested is Map) {
          _collect(nested, out);
          return;
        }
      } catch (_) {
        // Not JSON after all; fall through and treat it as a plain value.
      }
    }

    if (!_looksLikeToken(trimmed)) return;
    final priority = _priorityOf(key);
    // A key that says nothing about credentials earns a look only when the
    // value is shaped like one. Without this guard every build id, feature flag
    // and analytics id in the page's storage became a "candidate", so the app
    // went off to validate junk before the user had even logged in.
    if (priority == 3 && !_looksLikeOpaqueToken(trimmed)) return;
    out.add(_Candidate(priority, trimmed));
  });
}

/// A JWT, or a long base64 blob carrying the tell-tale `+ / =` alphabet.
/// A hex build id or a flag value never matches: it is either too plain or
/// lacks those characters.
bool _looksLikeOpaqueToken(String value) {
  if (RegExp(r'^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$')
      .hasMatch(value)) {
    return true;
  }
  if (!RegExp(r'^[A-Za-z0-9+/=_-]+$').hasMatch(value)) return false;
  return value.length >= 40 && RegExp(r'[+/=]').hasMatch(value);
}

int _priorityOf(String lowerKey) {
  if (_preferredKeys.contains(lowerKey)) return 0;
  if (lowerKey.contains('token')) return 1;
  if (lowerKey.contains('auth') || lowerKey.contains('session')) return 2;
  return 3;
}

bool _looksLikeToken(String value) {
  if (value.length < _minLength) return false;
  if (value.startsWith('{') || value.startsWith('[')) return false;
  // Purely numeric or boolean-looking values are configuration, not tokens.
  if (num.tryParse(value) != null) return false;
  if (value == 'true' || value == 'false' || value == 'null') return false;
  return true;
}

/// The credential the injected page script managed to capture, if any.
///
/// On iOS and macOS the webview is a WKWebView, and its request interceptor is
/// never called for ordinary http/https traffic — so the only way to see the
/// `Authorization` header there is to hook the page's own `fetch` and
/// `XMLHttpRequest` from inside. That script parks the value under `auth`, and
/// this reads it back out of the same dump the storages come from.
///
/// The value is a request header, exactly like the one Android hands us, so it
/// earns the same trust: it is tried before anything storage contains.
String? extractTappedAuth(String rawStorageDump) {
  final dynamic decoded;
  try {
    decoded = jsonDecode(rawStorageDump);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;
  final dynamic raw = decoded['auth'];
  if (raw is! String) return null;
  final withScheme = extractBearerToken(raw);
  if (withScheme != null) return withScheme;
  final plain = raw.trim();
  return plain.length >= _minLength ? plain : null;
}

/// The key names this module considers. Exposed so the UI can explain itself.
List<String> get preferredTokenKeys => List.unmodifiable(_preferredKeys);

/// The platform does not keep the session token in a field called `userToken`
/// (there is no such field). What it sends on every authenticated request is
/// `Authorization: Bearer <token>` — so the header value *is* the credential.
///
/// Accepts the whole header value with or without the scheme, because people
/// copy either form out of devtools, and returns null when nothing usable is
/// left after trimming.
String? extractBearerToken(String? headerValue) {
  if (headerValue == null) return null;
  var v = headerValue.trim();
  if (v.isEmpty) return null;
  // devtools renders the scheme with whatever whitespace fits: space, tab, or
  // a line break when the value wraps onto several rows.
  final scheme =
      RegExp(r'^bearer[\s\u00a0]+', caseSensitive: false).firstMatch(v);
  if (scheme != null) {
    v = v.substring(scheme.end).trim();
  } else if (v.toLowerCase() == 'bearer') {
    return null;
  }
  // Quoted values show up when devtools renders the header as a JSON snippet.
  if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
    v = v.substring(1, v.length - 1).trim();
  }
  if (v.length < _minLength) return null;
  // A space in the middle means this is not a single token.
  if (RegExp(r'\s').hasMatch(v)) return null;
  return v;
}
