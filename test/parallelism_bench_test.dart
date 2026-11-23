import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:deepseek_monitor/services/deepseek_service.dart';

/// Web-side benchmark for the request-scheduling optimization.
///
/// The only thing that changed is *when* the five independent HTTP calls are
/// issued: before, the range pair was parallel but the three KPI calls were
/// serial (4 RTT stages); after, the three KPI calls are parallel too (2 RTT
/// stages). Everything else -- parsing, payloads, bytes -- is identical, so we
/// inject a fixed per-request latency and time the two schedules against the
/// same client. That isolates the RTT stacking the optimization removes.
void main() {
  const latencyMs = 120;
  const rounds = 7;

  http.Response envelope(String body) => http.Response.bytes(
        utf8.encode(body),
        200,
        headers: {'content-type': 'application/json'},
      );

  final amount = envelope(jsonEncode({
        'code': 0,
        'data': {'biz_data': {'series': [], 'bucket': '1d'}}
      }));
  final cost = envelope(jsonEncode({
        'code': 0,
        'data': {'biz_data': {'data': []}}
      }));
  final summary = envelope(jsonEncode({
        'code': 0,
        'data': {
          'biz_data': {
            'normal_wallets': [],
            'bonus_wallets': [],
            'total_costs': []
          }
        }
      }));

  int requests = 0;
  final client = MockClient((req) async {
    requests++;
    await Future<void>.delayed(const Duration(milliseconds: latencyMs));
    final p = req.url.path;
    if (p.endsWith('/amount')) return amount;
    if (p.endsWith('/get_user_summary')) return summary;
    if (p.endsWith('/cost')) return cost;
    return envelope('{}');
  });

  final now = DateTime.now();
  final start = DateTime(now.year, now.month, 1);
  final end = DateTime(now.year, now.month + 1, 1);
  final svc = DeepSeekService(token: 'tok', client: client);

  final amountUri = Uri.parse('https://x/api/v0/usage/by_api_key/amount?start=1&end=2');
  final rangeCostUri = Uri.parse('https://x/api/v0/usage/by_api_key/cost?start=1&end=2');
  final todayCostUri = Uri.parse('https://x/api/v0/usage/by_api_key/cost?start=3&end=4');
  final monthCostUri = Uri.parse('https://x/api/v0/usage/by_api_key/cost?start=5&end=6');
  final summaryUri = Uri.parse('https://x/api/v0/users/get_user_summary');

  Future<double> timeIt(Future<void> Function() body) async {
    final sw = Stopwatch()..start();
    await body();
    sw.stop();
    return sw.elapsedMilliseconds.toDouble();
  }

  double median(List<double> xs) {
    final s = [...xs]..sort();
    return s[s.length ~/ 2];
  }

  test('scheduling benchmark: serial KPI vs parallel KPI', () async {
    // Warm-up so JIT / socket setup does not skew the first sample.
    await svc.fetchUsage(start: start, end: end);

    final after = <double>[];
    final before = <double>[];
    for (var i = 0; i < rounds; i++) {
      // AFTER: real, optimized code. Two parallel stages -> ~2 RTT.
      after.add(await timeIt(() => svc.fetchUsage(start: start, end: end)));

      // BEFORE: replicate the old schedule on the same delayed client.
      // Stage 1 (amount + cost) was already parallel; stage 2 (today, month,
      // balance) was three serial awaits -> ~4 RTT total.
      before.add(await timeIt(() async {
        await Future.wait([client.get(amountUri), client.get(rangeCostUri)]);
        await client.get(todayCostUri);
        await client.get(monthCostUri);
        await client.get(summaryUri);
      }));
    }

    final ma = median(after);
    final mb = median(before);
    stdout.writeln('--- scheduling benchmark (${latencyMs}ms/request, $rounds rounds) ---');
    stdout.writeln('BEFORE serial KPI : ${mb.toStringAsFixed(0)}ms  (~4 RTT)');
    stdout.writeln('AFTER  parallel   : ${ma.toStringAsFixed(0)}ms  (~2 RTT)');
    stdout.writeln('SPEEDUP           : ${(mb / ma).toStringAsFixed(2)}x');
    stdout.writeln('requests observed : $requests');

    expect(requests, greaterThan(0));
    expect(ma, lessThan(mb), reason: 'parallel schedule must beat serial');
  });

  // The KPI extras (today/month cost, account summary) take a full extra round
  // trip after the window pair. onMainReady exists so the dashboard can paint
  // the window's own numbers during that gap instead of holding a spinner.
  // If it ever fires after the extras resolve, or carries filled-in extras, the
  // optimisation is silently gone and nobody would notice from the UI.
  test('onMainReady fires before the KPI extras resolve, with them unknown',
      () async {
    // Distinct latencies so the ordering is unambiguous rather than a tie.
    final slowKpi = MockClient((req) async {
      final p = req.url.path;
      final isKpi = p.endsWith('/get_user_summary') || p.endsWith('/cost');
      final isWindowAmount = p.endsWith('/amount');
      await Future<void>.delayed(
          Duration(milliseconds: isWindowAmount ? 20 : (isKpi ? 200 : 20)));
      if (isWindowAmount) return amount;
      if (p.endsWith('/get_user_summary')) return summary;
      return cost;
    });

    final svc2 = DeepSeekService(token: 'tok', client: slowKpi);
    final now = DateTime.now();
    final sw = Stopwatch()..start();
    DateTime? readyAt;
    double? readyToday;
    double? readyMonth;
    var readyRangeCost = -1.0;
    var readyTrendLen = -1;

    final done = await svc2.fetchUsage(
      start: DateTime(now.year, now.month, 1),
      end: DateTime(now.year, now.month + 1, 1),
      onMainReady: (partial) {
        readyAt = DateTime.now();
        readyToday = partial.todayCost;
        readyMonth = partial.monthlyCost;
        readyRangeCost = partial.rangeCost;
        readyTrendLen = partial.trend.length;
      },
    );
    sw.stop();

    expect(readyAt, isNotNull,
        reason: 'onMainReady must fire — the dashboard depends on it for the '
            'first paint');
    // Extras are unknown at that moment: a dash, not a fabricated ¥0.00.
    expect(readyToday, isNull,
        reason: 'the partial payload must carry null extras, so the KPI row '
            'prints a dash instead of claiming a measurement it never took');
    expect(readyMonth, isNull, reason: 'same as todayCost');
    // The window data must already be there — that is the whole point.
    expect(readyRangeCost, greaterThanOrEqualTo(0));
    expect(readyTrendLen, greaterThanOrEqualTo(0));

    // And the settled payload does carry them.
    expect(done.todayCost, isNotNull);
    expect(done.monthlyCost, isNotNull);
    expect(sw.elapsedMilliseconds, greaterThan(0));
  });
}
