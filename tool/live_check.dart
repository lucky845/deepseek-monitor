// A manual end-to-end check against the live DeepSeek API, using the app's own
// service layer. Not part of the test suite (it needs a real token and the
// network); run it when you want to confirm parsing on today's payloads:
//
//   DS_TOKEN=... dart run tool/live_check.dart
//   dart run tool/live_check.dart            # reads /tmp/dstoken if set
//
// It never prints the token itself.
import 'dart:io';

import 'package:deepseek_monitor/services/deepseek_service.dart';

Future<void> main(List<String> args) async {
  final token = Platform.environment['DS_TOKEN'] ??
      (args.isNotEmpty ? args.first : null) ??
      (File('/tmp/dstoken').existsSync()
          ? File('/tmp/dstoken').readAsStringSync().trim()
          : null);
  if (token == null || token.isEmpty) {
    stderr.writeln('no token: set DS_TOKEN or write one to /tmp/dstoken');
    exit(2);
  }

  final svc = DeepSeekService(token: token);

  await svc.verifyToken(token);
  stdout.writeln('verifyToken: OK');

  final summary = await svc.fetchSummary();
  for (final b in summary.balances) {
    stdout.writeln('balance ${b.currency}: total=${b.totalBalance} '
        'toppedUp=${b.toppedUpBalance} granted=${b.grantedBalance}');
  }
  stdout.writeln('tokenEstimate=${summary.totalAvailableTokenEstimation} '
      'totalCosts=${summary.totalCosts}');

  final now = DateTime.now();
  final usage = await svc.fetchUsage(
      start: DateTime(now.year, now.month, 1),
      end: DateTime(now.year, now.month + 1, 1));
  stdout.writeln('keys=${usage.apiKeys.length} models=${usage.models.length} '
      'trend=${usage.trend.length}d');
  for (final k in usage.apiKeysBySpend) {
    stdout.writeln('  key "${k.label}" tokens=${k.totalTokens} '
        'requests=${k.requests} cost=${k.cost.toStringAsFixed(4)} '
        'models=${k.models.length}');
  }
  for (final m in usage.models) {
    stdout.writeln('  model ${m.model} tokens=${m.totalTokens} '
        'cost=${m.cost.toStringAsFixed(4)}');
  }
  // todayCost/monthlyCost are null on the partial payload the dashboard paints
  // before the KPI extras land; print the dash rather than crashing the checker.
  String money(double? v) => v == null ? '—' : v.toStringAsFixed(4);
  stdout.writeln('rangeCost=${usage.rangeCost.toStringAsFixed(4)} '
      'todayCost=${money(usage.todayCost)} '
      'monthCost=${money(usage.monthlyCost)}');
  stdout.writeln('cacheHitRate=${usage.cacheHitRate.toStringAsFixed(1)}%');
}
