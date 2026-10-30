import 'dart:convert';
import 'package:http/http.dart' as http;

import 'api_base.dart';
import '../models/balance.dart';
import '../models/usage.dart';
import 'platform_flags.dart';

/// Shown when the request never reached DeepSeek. A browser page cannot call
/// platform.deepseek.com at all (the endpoint sends no CORS headers), while on
/// a native build the same failure means the network is genuinely down.
const String kUnreachableInBrowser =
    '请求被浏览器拦下了：platform.deepseek.com 不返回跨域许可（CORS）头，'
    '网页读不到它的响应。本地调试请用 tool/dev_proxy.py 起反代，然后直接打开它的地址'
    '（代理会告诉应用怎么走，不用再带 ?api_base=）；打包部署用 --dart-define=PLATFORM_API_BASE=。'
    '正式使用请用桌面或手机客户端。';
const String kUnreachableOnDevice = '连不上 platform.deepseek.com，请检查网络或代理后重试。';

class DeepSeekException implements Exception {
  final String message;
  DeepSeekException(this.message);
  @override
  String toString() => message;
}

/// Mutable accumulator for one (API key x model) pair. The platform reports
/// usage and cost in two separate endpoints, so we join them on this key.
class _KeyModel {
  final String trackingId;
  String name;
  final String model;
  int hit = 0, miss = 0, out = 0, requests = 0;
  double cost = 0;

  _KeyModel(this.trackingId, this.name, this.model);
}

class DeepSeekService {
  /// Overridable so a local dev proxy can stand in for the real hosts on the
  /// web, where the browser refuses to read platform.deepseek.com's responses.
  final String _platformBase;
  final String _apiBase;

  final String? token;
  final String? apiKey;
  final int tzOffsetSeconds;

  /// Injectable so the parsing of DeepSeek's responses can be tested against
  /// the documented payload shapes instead of the live network.
  final http.Client _client;

  DeepSeekService({
    this.token,
    this.apiKey,
    this.tzOffsetSeconds = 28800,
    http.Client? client,
    String? platformBase,
    String? apiBase,
  })  : _client = client ?? http.Client(),
        _platformBase = platformBase ?? resolvePlatformBase(),
        _apiBase = apiBase ?? resolveApiBase();

  /// Always decode as UTF-8. `http`'s `.body` falls back to latin1 when the
  /// response omits a charset, which would turn Chinese API-key names into
  /// mojibake.
  static Map<String, dynamic> _decode(http.Response r) =>
      jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;

  /// A request that never got an answer is not an HTTP status: it is the
  /// browser blocking a cross-origin call, or a dead network. Both deserve
  /// their own sentence rather than "Failed to fetch".
  Future<http.Response> _get(Uri uri, {Map<String, String>? headers}) async {
    try {
      return await _client.get(uri, headers: headers ?? _headers);
    } on http.ClientException {
      throw DeepSeekException(
          runsInBrowser ? kUnreachableInBrowser : kUnreachableOnDevice);
    }
  }

  Map<String, String> get _headers => {
        'Accept': 'application/json',
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36',
        'x-client-platform': 'web',
        'x-client-version': '1.0.0',
        'x-app-version': '1.0.0',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  /// Unwraps a platform response and refuses anything that is not a successful
  /// account call.
  ///
  /// The platform answers **HTTP 200 even when it rejected the request**: a dead
  /// token comes back as `{"code":40003,"msg":"Authorization Failed (invalid
  /// token)","data":null}`. Checking only the status code therefore declares any
  /// junk "verified" — which is how a stray localStorage value got saved as a
  /// credential. The envelope is checked here, once, for every platform call.
  static Map<String, dynamic> _platformEnvelope(http.Response r, String what) {
    if (r.statusCode == 401 || r.statusCode == 403) {
      throw DeepSeekException('令牌无效或已过期，请重新登录 DeepSeek 获取');
    }
    if (r.statusCode != 200) {
      throw DeepSeekException('$what返回 HTTP ${r.statusCode}，接口可能已变更');
    }
    final Map<String, dynamic> j;
    try {
      j = _decode(r);
    } catch (_) {
      throw DeepSeekException('$what返回的不是 JSON，接口可能已变更');
    }
    final code = j['code'];
    if (code is num && code != 0) {
      if (code == 40003) {
        throw DeepSeekException('令牌无效或已过期，请重新登录 DeepSeek 获取');
      }
      final msg = j['msg']?.toString() ?? '';
      throw DeepSeekException(
          '$what被平台拒绝（code $code）${msg.isEmpty ? '' : '：$msg'}');
    }
    if (j['data'] is! Map) {
      throw DeepSeekException('$what没有返回账号数据，这不像一个有效的会话');
    }
    return j;
  }

  /// Verify a platform token against the usage endpoint.
  ///
  /// The platform reports a bad token inside a 200 response body, not through
  /// the status code, so the body decides.
  Future<void> verifyToken(String candidate) async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, 1);
    final end = now.month == 12
        ? DateTime(now.year + 1)
        : DateTime(now.year, now.month + 1);
    final uri = Uri.parse(
        '$_platformBase/api/v0/usage/by_api_key/amount?start=${start.millisecondsSinceEpoch ~/ 1000}'
        '&end=${end.millisecondsSinceEpoch ~/ 1000}&tz=$tzOffsetSeconds');
    final r = await _get(uri, headers: {
      ..._headers,
      'Authorization': 'Bearer $candidate',
    });
    _platformEnvelope(r, '令牌校验');
  }

  Future<UserSummary> fetchSummary() async {
    if (token == null) {
      final r = await _get(Uri.parse('$_apiBase/user/balance'), headers: {
        'Authorization': 'Bearer $apiKey',
        'Accept': 'application/json'
      });
      if (r.statusCode != 200) {
        throw DeepSeekException('余额接口返回 HTTP ${r.statusCode}');
      }
      final j = _decode(r);
      final infos = (j['balance_infos'] as List? ?? [])
          .map((e) => BalanceInfo.fromJson(e as Map<String, dynamic>))
          .toList();
      return UserSummary(
          balances: infos,
          totalAvailableTokenEstimation: '0',
          currentToken: 0,
          totalCosts: 0);
    }
    final r =
        await _get(Uri.parse('$_platformBase/api/v0/users/get_user_summary'));
    return UserSummary.fromJson(_platformEnvelope(r, '用户信息接口'));
  }

  /// Fetch usage for [start, end) with daily buckets, split by API key and by
  /// model. Both platform endpoints report the same (key x model) shape, so we
  /// join them on it and keep the finest granularity the API offers.
  Future<UsageData> fetchUsage(
      {required DateTime start, required DateTime end}) async {
    if (token == null) {
      return UsageData(
        apiKeys: const [],
        trend: const [],
        rangeCost: 0,
        todayCost: 0,
        monthlyCost: 0,
        updatedAt: DateTime.now(),
      );
    }
    final startSec = start.millisecondsSinceEpoch ~/ 1000;
    final endSec = end.millisecondsSinceEpoch ~/ 1000;
    final amountUri = Uri.parse(
        '$_platformBase/api/v0/usage/by_api_key/amount?start=$startSec&end=$endSec&tz=$tzOffsetSeconds');
    final costUri = Uri.parse(
        '$_platformBase/api/v0/usage/by_api_key/cost?start=$startSec&end=$endSec&tz=$tzOffsetSeconds');

    final responses = await Future.wait([
      _get(amountUri),
      _get(costUri),
    ]);
    final amountJson = _platformEnvelope(responses[0], '用量接口');
    Map<String, dynamic> costJson = <String, dynamic>{};
    if (responses[1].statusCode == 200) {
      try {
        costJson = _platformEnvelope(responses[1], '费用接口');
      } on DeepSeekException {
        // A missing price breakdown should not fail the whole page: the token
        // counts are still worth showing.
        costJson = <String, dynamic>{};
      }
    }

    final bizAmount = amountJson['data']?['biz_data'] ?? {};
    // The platform picks the resolution from the window: one day comes back as
    // hourly buckets, anything longer as daily ones. Read it instead of assuming
    // a day per point, or a 24-hour window renders as 24 "days".
    final rawBucket = int.tryParse('${bizAmount['bucket'] ?? ''}') ?? 86400;
    final hourly =
        rawBucket > 0 && rawBucket < 86400 && endSec - startSec <= 86400;
    int trendKey(int t) {
      if (hourly) return t;
      // Roll a sub-day bucket up to its local day when the window is longer
      // than a day, so a week never renders as 168 slivers.
      final local = DateTime.fromMillisecondsSinceEpoch(t * 1000);
      return DateTime(local.year, local.month, local.day)
              .millisecondsSinceEpoch ~/
          1000;
    }

    final Map<int, int> trendTokens = {};
    final Map<int, double> trendCost = {};
    final Map<int, int> trendRequests = {};
    final Map<String, _KeyModel> pairs = {};

    _KeyModel pairFor(Map<String, dynamic>? rawKey, String model) {
      final apiKey = rawKey ?? const <String, dynamic>{};
      final id = apiKey['tracking_id']?.toString() ?? '';
      final name = apiKey['name']?.toString() ?? '';
      final pair = pairs.putIfAbsent(
          '$id\u0000$model', () => _KeyModel(id, name, model));
      // Whichever response carries the human-readable name wins.
      if (pair.name.isEmpty && name.isNotEmpty) pair.name = name;
      return pair;
    }

    // --- tokens -------------------------------------------------------------
    for (final ser in (bizAmount['series'] as List? ?? [])) {
      final model = ser['model']?.toString() ?? '';
      final pair = pairFor(ser['api_key'] as Map<String, dynamic>?, model);
      for (final b in (ser['buckets'] as List? ?? [])) {
        final t = (b['time'] as num?)?.toInt() ?? 0;
        if (t < startSec || t >= endSec) continue;
        final u = b['usage'] as Map<String, dynamic>? ?? {};
        final h =
            int.tryParse(u['PROMPT_CACHE_HIT_TOKEN']?.toString() ?? '0') ?? 0;
        final m =
            int.tryParse(u['PROMPT_CACHE_MISS_TOKEN']?.toString() ?? '0') ?? 0;
        final o = int.tryParse(u['RESPONSE_TOKEN']?.toString() ?? '0') ?? 0;
        pair.hit += h;
        pair.miss += m;
        pair.out += o;
        final req = int.tryParse(u['REQUEST']?.toString() ?? '0') ?? 0;
        pair.requests += req;
        final key = trendKey(t);
        trendTokens[key] = (trendTokens[key] ?? 0) + h + m + o;
        trendRequests[key] = (trendRequests[key] ?? 0) + req;
      }
    }

    // --- cost ---------------------------------------------------------------
    final costBiz = costJson['data']?['biz_data'] ?? {};
    final costData = (costBiz['data'] as List? ?? []);
    final currencyData = costData.isNotEmpty ? costData.first : null;
    double totalCost = 0;
    for (final ser in (currencyData?['series'] as List? ?? [])) {
      final model = ser['model']?.toString() ?? '';
      final pair = pairFor(ser['api_key'] as Map<String, dynamic>?, model);
      for (final b in (ser['buckets'] as List? ?? [])) {
        final t = (b['time'] as num?)?.toInt() ?? 0;
        if (t < startSec || t >= endSec) continue;
        final c = double.tryParse(b['cost']?.toString() ?? '0') ?? 0;
        pair.cost += c;
        totalCost += c;
        final key = trendKey(t);
        trendCost[key] = (trendCost[key] ?? 0) + c;
      }
    }

    // --- roll up into API keys ---------------------------------------------
    // Only key/model pairs that actually appear in the window are kept, so an
    // unused model never shows up as a zero row.
    final Map<String, List<_KeyModel>> byKey = {};
    for (final p in pairs.values) {
      // A pair is created as soon as a series is seen, before its buckets are
      // filtered. Anything with no activity left in the window carries no
      // information and must not surface as a zero row.
      if (p.hit == 0 &&
          p.miss == 0 &&
          p.out == 0 &&
          p.requests == 0 &&
          p.cost == 0) {
        continue;
      }
      final key = '${p.trackingId}\u0000${p.name}';
      byKey.putIfAbsent(key, () => []).add(p);
    }
    final apiKeys = byKey.values
        .map((group) => ApiKeyUsage(
              trackingId: group.first.trackingId,
              name: group.first.name,
              models: group
                  .map((p) => ModelUsage(
                        model: p.model,
                        cacheHitTokens: p.hit,
                        cacheMissTokens: p.miss,
                        outputTokens: p.out,
                        requests: p.requests,
                        cost: p.cost,
                      ))
                  .toList()
                ..sort((a, b) => b.totalTokens.compareTo(a.totalTokens)),
            ))
        .toList();

    final trend = (trendTokens.keys.toSet()
          ..addAll(trendCost.keys)
          ..addAll(trendRequests.keys))
        .map((t) => TrendPoint(
              at: DateTime.fromMillisecondsSinceEpoch(t * 1000),
              tokens: trendTokens[t] ?? 0,
              cost: trendCost[t] ?? 0,
              requests: trendRequests[t] ?? 0,
            ))
        .toList()
      ..sort((a, b) => a.at.compareTo(b.at));

    // Today + month figures always come from their own windows so the KPIs stay
    // meaningful regardless of the selected range.
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final monthStart = DateTime(now.year, now.month, 1);
    final monthEnd = DateTime(now.year, now.month + 1, 1);
    final todayCost =
        await _costOf(todayStart, todayStart.add(const Duration(days: 1)));
    final monthlyCost = await _costOf(monthStart, monthEnd);
    // The balance is decoration on top of the usage report. If that single call
    // fails, still show the usage rather than blanking the whole screen.
    UserSummary? summary;
    try {
      summary = await fetchSummary();
    } on DeepSeekException {
      summary = null;
    }

    return UsageData(
      summary: summary,
      apiKeys: apiKeys,
      trend: trend,
      trendIsHourly: hourly,
      rangeCost: totalCost,
      todayCost: todayCost,
      monthlyCost: monthlyCost,
      updatedAt: DateTime.now(),
    );
  }

  Future<double> _costOf(DateTime start, DateTime end) async {
    final uri = Uri.parse(
        '$_platformBase/api/v0/usage/by_api_key/cost?start=${start.millisecondsSinceEpoch ~/ 1000}'
        '&end=${end.millisecondsSinceEpoch ~/ 1000}&tz=$tzOffsetSeconds');
    try {
      final r = await _client.get(uri, headers: _headers);
      final j = _platformEnvelope(r, '费用接口');
      final data = (j['data']?['biz_data']?['data'] as List? ?? []);
      if (data.isEmpty) return 0;
      double sum = 0;
      for (final ser in (data.first['series'] as List? ?? [])) {
        for (final b in (ser['buckets'] as List? ?? [])) {
          sum += double.tryParse(b['cost']?.toString() ?? '0') ?? 0;
        }
      }
      return sum;
    } catch (_) {
      return 0;
    }
  }

  Future<String?> login(String email, String password) async {
    final body = jsonEncode({
      'email': email,
      'mobile': '',
      'password': password,
      'area_code': '',
      'device_id': 'd2ViLWZpbmdlcnByaW50LWJhc2U2NA==',
      'os': 'web',
    });
    final r =
        await _client.post(Uri.parse('$_platformBase/auth-api/v0/users/login'),
            headers: {
              'Content-Type': 'application/json',
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36',
              'x-client-platform': 'web',
              'x-client-version': '1.0.0',
              'x-app-version': '1.0.0',
            },
            body: body);
    final j = _decode(r);
    final bizCode = j['data']?['biz_code'];
    if (bizCode == 0) {
      return j['data']?['biz_data']?['user']?['token']?.toString();
    }
    return null;
  }
}
