import 'package:deepseek_monitor/services/api_base.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('a dev proxy may stand in, but only on this machine', () {
    test('a private-network base works for phones and emulators', () {
      // How a phone or the Android emulator reaches a dev server on this machine.
      for (final base in [
        'http://192.168.1.20:8788/platform-api',
        'http://10.0.2.2:8788/platform-api',
        'http://172.20.10.3:8788/platform-api',
      ]) {
        expect(devOverrideFrom({'api_base': base}, 'api_base'), base,
            reason: base);
      }
    });

    test('a loopback base is taken as-is', () {
      expect(
        devOverrideFrom(
          {'api_base': 'http://127.0.0.1:8787/platform-api'},
          'api_base',
        ),
        'http://127.0.0.1:8787/platform-api',
      );
      expect(
        devOverrideFrom({'api_base': 'http://localhost:8787'}, 'api_base'),
        'http://localhost:8787',
      );
    });

    test('a dev proxy can inject its own address into the page', () {
      // This is how a bare `http://192.168.1.20:8788/` works: the proxy serves
      // index.html and puts the base in a global.
      final base =
          resolvePlatformBase(injected: '/platform-api', queryParams: {});
      expect(base, endsWith('/platform-api'));
    });

    test('a same-origin path needs no address check', () {
      // It can only point back at the server that served the page.
      expect(devOverrideFrom({'api_base': '/platform-api'}, 'api_base'),
          endsWith('/platform-api'));
    });

    test('what the page injected wins over the query string', () {
      final base = resolveBase(
        queryKey: 'api_base',
        fromEnv: '',
        fallback: kDefaultPlatformBase,
        queryParams: {'api_base': 'http://127.0.0.1:8787/old'},
        injected: '/platform-api',
      );
      expect(base, endsWith('/platform-api'));
      expect(base.contains('8787'), isFalse);
    });

    test('a trailing slash is dropped so paths never double up', () {
      expect(
        devOverrideFrom(
          {'api_base': 'http://127.0.0.1:8787/platform-api/'},
          'api_base',
        ),
        'http://127.0.0.1:8787/platform-api',
      );
    });

    test('a public host someone else controls is ignored', () {
      // This is the attack the check exists for: a link that would otherwise
      // point the app — and the token it holds — at a stranger's server.
      for (final hostile in [
        'https://evil.example.com/platform-api',
        'http://127.0.0.1.evil.com',
        'https://localhost.evil.com',
        'http://8.8.8.8:8788',
      ]) {
        expect(devOverrideFrom({'api_base': hostile}, 'api_base'), isNull,
            reason: hostile);
      }
    });

    test('a non-http scheme or junk is ignored', () {
      for (final bad in [
        'file:///etc/passwd',
        'javascript:alert(1)',
        'not a url',
        '',
      ]) {
        expect(devOverrideFrom({'api_base': bad}, 'api_base'), isNull,
            reason: bad);
      }
    });

    test('an absent key changes nothing', () {
      expect(devOverrideFrom(const {}, 'api_base'), isNull);
    });
  });

  group('base resolution order', () {
    test('the query wins over the build-time value', () {
      final base = resolveBase(
        queryKey: 'api_base',
        fromEnv: 'http://127.0.0.1:9000/platform-api',
        fallback: kDefaultPlatformBase,
        queryParams: const {'api_base': 'http://127.0.0.1:8787/platform-api'},
      );
      expect(base, 'http://127.0.0.1:8787/platform-api');
    });

    test('the build-time value wins over the default', () {
      expect(
        resolveBase(
          queryKey: 'api_base',
          fromEnv: 'http://127.0.0.1:8787/platform-api',
          fallback: kDefaultPlatformBase,
          queryParams: const {},
        ),
        'http://127.0.0.1:8787/platform-api',
      );
    });

    test('nothing set means the real host', () {
      expect(
        resolveBase(
          queryKey: 'api_base',
          fromEnv: '',
          fallback: kDefaultPlatformBase,
          queryParams: const {},
        ),
        kDefaultPlatformBase,
      );
    });

    test('a hostile query falls back instead of being used', () {
      expect(
        resolveBase(
          queryKey: 'api_base',
          fromEnv: '',
          fallback: kDefaultPlatformBase,
          queryParams: const {'api_base': 'https://evil.example.com'},
        ),
        kDefaultPlatformBase,
      );
    });

    test('the shipped defaults are the real DeepSeek hosts', () {
      expect(kDefaultPlatformBase, 'https://platform.deepseek.com');
      expect(kDefaultApiBase, 'https://api.deepseek.com');
    });
  });
}
