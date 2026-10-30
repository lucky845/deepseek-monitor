import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:deepseek_monitor/services/token_harvest.dart';

String _dump(
        {Map<String, String> local = const {},
        Map<String, String> session = const {}}) =>
    jsonEncode({'local': local, 'session': session});

void main() {
  group('the credential is the Authorization header value', () {
    test('a Bearer value is unwrapped', () {
      expect(extractBearerToken('Bearer abcdefghijklmnopqrst'),
          'abcdefghijklmnopqrst');
      expect(extractBearerToken('bearer abcdefghijklmnopqrst'),
          'abcdefghijklmnopqrst');
    });

    test('a bare token passes through unchanged', () {
      expect(
          extractBearerToken('abcdefghijklmnopqrst'), 'abcdefghijklmnopqrst');
    });

    test('quotes and padding from a devtools copy are trimmed', () {
      expect(extractBearerToken('  "abcdefghijklmnopqrst"  '),
          'abcdefghijklmnopqrst');
      expect(extractBearerToken('Bearer\tabcdefghijklmnopqrst'),
          'abcdefghijklmnopqrst');
    });

    test('nothing usable is rejected instead of guessed', () {
      expect(extractBearerToken(null), isNull);
      expect(extractBearerToken('   '), isNull);
      expect(extractBearerToken('Bearer'), isNull);
      expect(extractBearerToken('Bearer   '), isNull);
      // Too short to be a session token.
      expect(extractBearerToken('Bearer short'), isNull);
      // Two values on the header would be a copy mistake, not a token.
      expect(extractBearerToken('Bearer aaaa bbbb cccc dddd'), isNull);
    });
  });
  group('extractTokenFromStorage', () {
    test('finds the token under its documented key', () {
      final raw = _dump(local: {
        'userToken': 'eyJhbGciOiJIUzI1NiJ9.abcdefghijklmnop',
        'theme': 'dark',
      });
      expect(extractTokenFromStorage(raw),
          'eyJhbGciOiJIUzI1NiJ9.abcdefghijklmnop');
    });

    test('prefers a token key over an unrelated long value', () {
      final raw = _dump(local: {
        'someLongAnalyticsId': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        'userToken': 'bbbbbbbbbbbbbbbbbbbbbbbb',
      });
      expect(extractTokenFromStorage(raw), 'bbbbbbbbbbbbbbbbbbbbbbbb');
    });

    test('never returns configuration values as a token', () {
      final raw = _dump(local: {
        'lang': 'zh-CN',
        'sidebar': 'true',
        'count': '12345678',
        'layout': '{"panel":"left","width":280}',
      });
      expect(extractTokenFromStorage(raw), isNull);
    });

    test('digs a wrapped token out of a nested JSON value', () {
      final raw = _dump(local: {
        'userInfo':
            jsonEncode({'name': 'lucky', 'token': 'nested-token-0123456789'}),
      });
      expect(extractTokenFromStorage(raw), 'nested-token-0123456789');
    });

    test('accepts a token kept in sessionStorage', () {
      final raw = _dump(session: {'access_token': 'session-token-0123456789'});
      expect(extractTokenFromStorage(raw), 'session-token-0123456789');
    });

    test('an unknown key still works when the value is unmistakably a token',
        () {
      const jwt =
          'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.c2lnbmF0dXJlLXZhbHVl';
      final raw = _dump(local: {'ds.auth.v2': jwt});
      expect(extractTokenFromStorage(raw), jwt);
    });

    test('an unknown key holding a plain value is not a candidate', () {
      // The sign-in page seeds its storage with build ids, flags and group
      // tags. Those used to be offered up as "tokens" and — because the platform
      // reports a bad token inside an HTTP 200 — got saved as one.
      final raw = _dump(local: {
        'buildId': '8f3ac21bd0e4477b9c1e5a2d3b4c5d6e7f809a1b',
        'featureFlag': 'sidebar-collapsed',
        'groupId': '7',
        'lastRoute': '/sign_in?redirect=%2Fusage',
      });
      expect(extractTokenFromStorage(raw), isNull);
    });

    test('every candidate is offered, best first, not just the top one', () {
      // Measured on a signed-in page: `userToken` holds a short id (36 chars)
      // while the real 64-char credential only ever appears on the wire. Taking
      // the single best storage value therefore handed back the id and the
      // session never worked.
      final raw = _dump(local: {
        'userToken': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        'token': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      });
      final all = extractTokenCandidates(raw);
      expect(all, hasLength(2));
      expect(all.first, 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb');
    });

    test('survives junk instead of throwing', () {
      expect(extractTokenFromStorage('not json at all'), isNull);
      expect(extractTokenFromStorage('[]'), isNull);
      expect(extractTokenFromStorage('null'), isNull);
      expect(extractTokenFromStorage('{}'), isNull);
    });
  });

  group('extractTappedAuth', () {
    // The page-side hook (used on iOS and macOS, where the webview reports no
    // request headers) parks the value under `auth`. It is a header, so it is
    // read back exactly like one.
    test('reads the hooked header value back out of the dump', () {
      const dump =
          '{"local":{},"session":{},"auth":"Bearer abcdefghijklmnopqrst"}';
      expect(extractTappedAuth(dump), 'abcdefghijklmnopqrst');
    });

    test('a bare value passes through unchanged', () {
      const dump = '{"auth":"abcdefghijklmnopqrst"}';
      expect(extractTappedAuth(dump), 'abcdefghijklmnopqrst');
    });

    test('nothing hooked yet is not a credential', () {
      expect(extractTappedAuth('{"local":{},"session":{},"auth":null}'), isNull);
      expect(extractTappedAuth('{"local":{},"session":{}}'), isNull);
      expect(extractTappedAuth('not json at all'), isNull);
      expect(extractTappedAuth('[]'), isNull);
    });

    test('a value too short to be a session token is refused', () {
      expect(extractTappedAuth('{"auth":"short"}'), isNull);
      expect(extractTappedAuth('{"auth":"Bearer short"}'), isNull);
    });
  });
}
