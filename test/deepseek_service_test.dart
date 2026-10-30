import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:deepseek_monitor/models/balance.dart';
import 'package:deepseek_monitor/services/deepseek_service.dart';
import 'package:deepseek_monitor/services/platform_flags.dart';

/// The exact shapes documented for the platform's two usage endpoints.
String _amountBody() => jsonEncode({
      'code': 0,
      'data': {
        'biz_code': 0,
        'biz_data': {
          'start': 1000,
          'end': 2000,
          'bucket': '1d',
          'models': ['deepseek-v4-flash', 'deepseek-v4-pro'],
          'series': [
            {
              'api_key': {
                'tracking_id': 'tr_prod',
                'name': '生产环境',
                'sensitive_id': 'sk-***'
              },
              'model': 'deepseek-v4-flash',
              'buckets': [
                {
                  'time': 1200,
                  'usage': {
                    'PROMPT_CACHE_HIT_TOKEN': '1000',
                    'PROMPT_CACHE_MISS_TOKEN': '200',
                    'RESPONSE_TOKEN': '300',
                    'REQUEST': '7'
                  }
                }
              ]
            },
            {
              'api_key': {
                'tracking_id': 'tr_dev',
                'name': '本地调试',
                'sensitive_id': 'sk-***'
              },
              'model': 'deepseek-v4-flash',
              'buckets': [
                {
                  'time': 1300,
                  'usage': {
                    'PROMPT_CACHE_HIT_TOKEN': '40',
                    'PROMPT_CACHE_MISS_TOKEN': '10',
                    'RESPONSE_TOKEN': '5',
                    'REQUEST': '2'
                  }
                }
              ]
            },
            {
              'api_key': {'tracking_id': 'tr_prod', 'name': '生产环境'},
              'model': 'deepseek-v4-pro',
              'buckets': [
                {
                  'time': 1400,
                  'usage': {
                    'PROMPT_CACHE_HIT_TOKEN': '8',
                    'PROMPT_CACHE_MISS_TOKEN': '0',
                    'RESPONSE_TOKEN': '2',
                    'REQUEST': '1'
                  }
                }
              ]
            }
          ]
        }
      }
    });

/// Cost arrives from a different endpoint in the same (key x model) shape.
String _costBody(List<Map<String, dynamic>> series) => jsonEncode({
      'code': 0,
      'data': {
        'biz_code': 0,
        'biz_data': {
          'models': ['deepseek-v4-flash'],
          'data': [
            {'currency': 'CNY', 'series': series}
          ]
        }
      }
    });

/// UTF-8 response with no charset declared — what the platform actually sends.
http.Response _json(String body) => http.Response.bytes(
      utf8.encode(body),
      200,
      headers: {'content-type': 'application/json'},
    );

http.Response _jsonCost(List<Map<String, dynamic>> series) =>
    _json(_costBody(series));

DeepSeekService _service(MockClient client) =>
    DeepSeekService(token: 'tok', client: client);

void main() {
  group('fetchUsage parsing', () {
    test('joins tokens and cost per API key and per model', () async {
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/amount')) {
          return _json(_amountBody());
        }
        if (req.url.path.endsWith('/cost')) {
          return _jsonCost([
            {
              'api_key': {'tracking_id': 'tr_prod', 'name': '生产环境'},
              'model': 'deepseek-v4-flash',
              'buckets': [
                {'time': 1200, 'cost': '1.50'}
              ]
            },
            {
              'api_key': {'tracking_id': 'tr_dev', 'name': '本地调试'},
              'model': 'deepseek-v4-flash',
              'buckets': [
                {'time': 1300, 'cost': '0.50'}
              ]
            },
            {
              'api_key': {'tracking_id': 'tr_prod', 'name': '生产环境'},
              'model': 'deepseek-v4-pro',
              'buckets': [
                {'time': 1400, 'cost': '9.00'}
              ]
            },
          ]);
        }
        return http.Response('{}', 200);
      });

      final data = await _service(client).fetchUsage(
        start: DateTime.fromMillisecondsSinceEpoch(1000 * 1000),
        end: DateTime.fromMillisecondsSinceEpoch(2000 * 1000),
      );

      expect(data.apiKeys.length, 2);
      // Ordered by spend, so the biggest spender leads the comparison panel.
      final prod = data.apiKeysBySpend.first;
      expect(prod.label, '生产环境');
      expect(prod.cost, closeTo(10.50, 1e-9));
      expect(prod.models.length, 2);
      expect(prod.models.first.model, 'deepseek-v4-flash');
      expect(prod.models.first.cacheHitTokens, 1000);
      expect(prod.models.first.requests, 7);
      expect(prod.models.first.cost, closeTo(1.50, 1e-9));

      final dev = data.apiKeysBySpend.last;
      expect(dev.label, '本地调试');
      expect(dev.cost, closeTo(0.50, 1e-9));

      // Cross-key aggregate: flash tokens from both keys, cost summed.
      final flash =
          data.models.firstWhere((m) => m.model == 'deepseek-v4-flash');
      expect(flash.cacheHitTokens, 1040);
      expect(flash.cacheMissTokens, 210);
      expect(flash.outputTokens, 305);
      expect(flash.cost, closeTo(2.00, 1e-9));
      expect(data.rangeCost, closeTo(11.0, 1e-9));
      expect(data.totalTokens, 1040 + 210 + 305 + 10);
    });

    test('buckets outside [start, end) are ignored', () async {
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/amount')) {
          return _json(_amountBody());
        }
        return _jsonCost(const []);
      });

      // Window starts after the flash buckets (1200/1300) but includes 1400.
      final data = await _service(client).fetchUsage(
        start: DateTime.fromMillisecondsSinceEpoch(1350 * 1000),
        end: DateTime.fromMillisecondsSinceEpoch(2000 * 1000),
      );

      expect(data.models.length, 1);
      expect(data.models.single.model, 'deepseek-v4-pro');
      expect(data.totalTokens, 10);
      expect(data.trend.length, 1);
    });

    test('a failing cost endpoint degrades to zero cost, not a crash',
        () async {
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/amount')) {
          return _json(_amountBody());
        }
        return http.Response('upstream boom', 500);
      });

      final data = await _service(client).fetchUsage(
        start: DateTime.fromMillisecondsSinceEpoch(1000 * 1000),
        end: DateTime.fromMillisecondsSinceEpoch(2000 * 1000),
      );

      expect(data.rangeCost, 0);
      expect(data.todayCost, 0);
      expect(data.monthlyCost, 0);
      // Tokens are still real data and must survive the partial failure.
      expect(data.totalTokens, 1565);
      expect(data.models.every((m) => m.cost == 0), isTrue);
      // The balance endpoint fails here too; usage must not be blanked by it.
      expect(data.summary, isNull);
    });

    test('a zero-activity series never becomes a zero row', () async {
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/amount')) {
          return _json(_amountBody());
        }
        if (req.url.path.endsWith('/cost')) {
          return _jsonCost(const []);
        }
        return _json('{}');
      });

      // Window contains only the pro bucket at 1400.
      final data = await _service(client).fetchUsage(
        start: DateTime.fromMillisecondsSinceEpoch(1350 * 1000),
        end: DateTime.fromMillisecondsSinceEpoch(2000 * 1000),
      );

      // 'flash' has series data but nothing inside the window: it must not
      // surface as "0 Token / ¥0.00", which would read as a real finding.
      expect(data.models.map((m) => m.model), ['deepseek-v4-pro']);
      expect(data.apiKeys.single.models.length, 1);
      expect(data.apiKeys.single.cost, 0);
    });

    test('a failing amount endpoint surfaces a real error', () async {
      final client = MockClient((req) async => http.Response('nope', 401));
      expect(
        () => _service(client).fetchUsage(
          start: DateTime.fromMillisecondsSinceEpoch(1000 * 1000),
          end: DateTime.fromMillisecondsSinceEpoch(2000 * 1000),
        ),
        throwsA(isA<DeepSeekException>()),
      );
    });

    test('a series without an api_key object still parses', () async {
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/amount')) {
          return _json(jsonEncode({
            'code': 0,
            'data': {
              'biz_code': 0,
              'biz_data': {
                'models': [],
                'series': [
                  {
                    'model': 'deepseek-v4-flash',
                    'buckets': [
                      {
                        'time': 1200,
                        'usage': {'RESPONSE_TOKEN': '5', 'REQUEST': '1'}
                      }
                    ]
                  }
                ]
              }
            }
          }));
        }
        return _jsonCost(const []);
      });

      final data = await _service(client).fetchUsage(
        start: DateTime.fromMillisecondsSinceEpoch(1000 * 1000),
        end: DateTime.fromMillisecondsSinceEpoch(2000 * 1000),
      );

      expect(data.apiKeys.single.label, '未命名 API Key');
      expect(data.apiKeys.single.outputTokens, 5);
    });

    test('without a token no request is made at all', () async {
      var called = false;
      final client = MockClient((req) async {
        called = true;
        return http.Response('{}', 200);
      });
      final data = await DeepSeekService(client: client)
          .fetchUsage(start: DateTime(2026, 1, 1), end: DateTime(2026, 2, 1));
      expect(called, isFalse);
      expect(data.totalTokens, 0);
      expect(data.apiKeys, isEmpty);
    });
  });

  group('the two wallets the platform actually returns', () {
    // Captured from a live call: money the user paid for and money DeepSeek
    // gave them live in separate arrays, and the keys are `balance`, not
    // `total_balance`.
    Map<String, dynamic> liveBody() => {
          'code': 0,
          'data': {
            'biz_code': 0,
            'biz_data': {
              'normal_wallets': [
                {'currency': 'CNY', 'balance': '0E-16', 'token_estimation': '0'}
              ],
              'bonus_wallets': [
                {
                  'currency': 'CNY',
                  'balance': '2.2772246400000000',
                  'token_estimation': '0'
                }
              ],
              'total_costs': [
                {'currency': 'CNY', 'amount': '3.7227753600000000'}
              ],
            }
          }
        };

    test('paid and gifted are read as the two halves of the total', () {
      final s = UserSummary.fromJson(liveBody());
      final b = s.balances.single;
      expect(b.currency, 'CNY');
      expect(b.toppedUpBalance, 0);
      expect(b.grantedBalance, closeTo(2.27722464, 1e-9));
      expect(b.totalBalance, closeTo(2.27722464, 1e-9));
      expect(s.totalCosts, closeTo(3.72277536, 1e-9));
    });

    test('a gift-only account is not reported as three zeros', () {
      // The old parser looked for `total_balance` on normal_wallets only, so a
      // real account with a bonus balance rendered as ¥0.00 everywhere.
      final s = UserSummary.fromJson(liveBody());
      expect(s.balances.single.totalBalance, greaterThan(0));
    });

    test('a paid balance lands in topped up, not in granted', () {
      final s = UserSummary.fromJson({
        'data': {
          'biz_data': {
            'normal_wallets': [
              {'currency': 'CNY', 'balance': '12.5', 'token_estimation': '900'}
            ],
            'bonus_wallets': [
              {'currency': 'CNY', 'balance': '1.5', 'token_estimation': '100'}
            ],
            'total_costs': [],
          }
        }
      });
      final b = s.balances.single;
      expect(b.toppedUpBalance, 12.5);
      expect(b.grantedBalance, 1.5);
      expect(b.totalBalance, 14.0);
      expect(s.totalAvailableTokenEstimation, '1000');
    });
  });

  group('a blocked cross-origin call is explained, not leaked', () {
    test('in a browser it names the same-origin rule', () async {
      debugForceBrowser = true;
      addTearDown(() => debugForceBrowser = null);
      final client = MockClient(
          (req) async => throw http.ClientException('Failed to fetch'));
      await expectLater(
        DeepSeekService(token: 't', client: client).verifyToken('t'),
        throwsA(isA<DeepSeekException>()
            .having((e) => e.message, 'message', kUnreachableInBrowser)),
      );
    });

    test('on a device the same failure reads as a network problem', () async {
      debugForceBrowser = false;
      addTearDown(() => debugForceBrowser = null);
      final client = MockClient(
          (req) async => throw http.ClientException('SocketException'));
      await expectLater(
        DeepSeekService(token: 't', client: client).fetchSummary(),
        throwsA(isA<DeepSeekException>()
            .having((e) => e.message, 'message', kUnreachableOnDevice)),
      );
    });

    test('the balance fetch is guarded the same way', () async {
      debugForceBrowser = true;
      addTearDown(() => debugForceBrowser = null);
      final client = MockClient(
          (req) async => throw http.ClientException('Failed to fetch'));
      await expectLater(
        DeepSeekService(apiKey: 'sk-x', client: client).fetchSummary(),
        throwsA(isA<DeepSeekException>()
            .having((e) => e.message, 'message', kUnreachableInBrowser)),
      );
    });
  });

  group('the platform rejects a token inside an HTTP 200', () {
    // Measured against the live platform: a dead token returns **HTTP 200** with
    // {"code":40003,"msg":"Authorization Failed (invalid token)","data":null}.
    // Reading only the status code declared any junk a valid credential, and
    // the app then saved it as the user's token.
    final rejection = jsonEncode({
      'code': 40003,
      'msg': 'Authorization Failed (invalid token)',
      'data': null,
    });

    MockClient rejecting() =>
        MockClient((req) async => http.Response(rejection, 200,
            headers: {'content-type': 'application/json'}));

    test('verifyToken does not accept it', () async {
      await expectLater(
        DeepSeekService(token: 'junk', client: rejecting()).verifyToken('junk'),
        throwsA(isA<DeepSeekException>()
            .having((e) => e.message, 'message', contains('令牌无效'))),
      );
    });

    test('the usage fetch does not draw an empty dashboard over it', () async {
      await expectLater(
        DeepSeekService(token: 'junk', client: rejecting()).fetchUsage(
            start: DateTime(2026, 10, 1), end: DateTime(2026, 11, 1)),
        throwsA(isA<DeepSeekException>()),
      );
    });

    test('the summary fetch does not report a zero balance', () async {
      await expectLater(
        DeepSeekService(token: 'junk', client: rejecting()).fetchSummary(),
        throwsA(isA<DeepSeekException>()),
      );
    });

    test('a 200 with no account data is not a session either', () async {
      final body = jsonEncode({'code': 0, 'msg': '', 'data': null});
      final client = MockClient((req) async => http.Response(body, 200,
          headers: {'content-type': 'application/json'}));
      await expectLater(
        DeepSeekService(token: 'junk', client: client).verifyToken('junk'),
        throwsA(isA<DeepSeekException>()
            .having((e) => e.message, 'message', contains('没有返回账号数据'))),
      );
    });
  });
}
