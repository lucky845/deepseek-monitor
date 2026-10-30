import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/usage.dart';
import 'api_base.dart';

/// Where a home-screen widget gets its numbers.
///
/// The widget runs outside the app: it has no token of its own and no reason
/// to spend a network round trip every time the launcher redraws it. So the app
/// publishes one snapshot after each successful fetch, and the widget renders
/// exactly that — together with the time it was taken. A widget showing a
/// number from twenty minutes ago is honest as long as it says so; a widget
/// that invents a plausible figure is not.
const String kWidgetSnapshotKey = 'widget_snapshot';

/// Where the background refresher should send its requests.
///
/// The Dart side is the only place that knows how the base was resolved —
/// compiled-in `--dart-define`, a dev proxy that injected itself into the page,
/// or the real host — so it hands the answer over rather than letting Kotlin
/// guess `platform.deepseek.com` and quietly read a different account.
const String kWidgetPlatformBaseKey = 'widget_platform_base';
const String kWidgetApiBaseKey = 'widget_api_base';

/// The channel MainActivity listens on. A refresh is a nudge, not a request for
/// data: the numbers were already written by the time we call it.
const MethodChannel _channel = MethodChannel('deepseek_monitor/widget');
const MethodChannel _widgetKitChannel = MethodChannel('deepseek_monitor/widgetkit');

/// How many days of history the widget's little charts can draw.
const int kWidgetTrendDays = 7;

/// The shape handed to the platform.
///
/// Everything a widget cannot derive is computed here rather than in Kotlin:
/// two implementations of "average daily spend" would drift, and the one on the
/// launcher is the one the user sees first.
Map<String, Object?> widgetSnapshotJson(
  UsageData? data, {
  required bool connected,
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  final wallet = (data?.summary?.balances.isNotEmpty ?? false)
      ? data!.summary!.balances.first
      : null;

  // Days that have not happened yet carry a zero bucket; the chart would draw
  // them as a cliff and the "latest bar" would land on tomorrow.
  final trend = (data?.trend ?? const <TrendPoint>[])
      .where((p) => !p.at.isAfter(DateTime(at.year, at.month, at.day)))
      .toList();
  final start = trend.length > kWidgetTrendDays
      ? trend.length - kWidgetTrendDays
      : 0;
  final tail = <Map<String, Object?>>[
    for (final p in trend.skip(start))
      <String, Object?>{
        'c': double.parse(p.cost.toStringAsFixed(4)),
        'r': p.requests,
        't': p.at.millisecondsSinceEpoch,
      },
  ];

  // "About N days left" is arithmetic anyone can redo, which is why it is worth
  // showing: balance ÷ (what a day has actually been costing).
  final month = data?.monthlyCost ?? 0;
  final monthDays = at.day.toDouble();
  final daily = monthDays > 0 ? month / monthDays : 0.0;
  final daysLeft = daily > 0 ? (wallet?.totalBalance ?? 0) / daily : 0.0;

  return <String, Object?>{
    'connected': connected,
    'balance': wallet?.totalBalance,
    'granted': wallet?.grantedBalance,
    'todayCost': data?.todayCost,
    'monthCost': month,
    'requests': data?.totalRequests,
    'cacheHitRate': data?.cacheHitRate,
    'dailyAvg': double.parse(daily.toStringAsFixed(2)),
    'daysLeft': double.parse(daysLeft.toStringAsFixed(1)),
    'trend': tail,
    'updatedAt': at.millisecondsSinceEpoch,
  };
}

/// Write the snapshot and ask the platform to redraw. Safe to call on every
/// fetch and on every platform: the web build has no widget to tell.
Future<void> publishWidgetSnapshot(
  UsageData? data, {
  required bool connected,
}) async {
  if (kIsWeb) return;
  final prefs = await SharedPreferences.getInstance();
  // Losing the credential must clear the widget too: a balance that outlives
  // the token it came from is a number nobody can explain.
  if (!connected || data == null) {
    await prefs.remove(kWidgetSnapshotKey);
    await prefs.remove(kWidgetPlatformBaseKey);
    await prefs.remove(kWidgetApiBaseKey);
    if (!kIsWeb && (Platform.isIOS || Platform.isMacOS)) {
      try {
        final defaults = await SharedPreferences.getInstance();
        await defaults.remove(kWidgetSnapshotKey);
        await defaults.remove(kWidgetPlatformBaseKey);
        await defaults.remove(kWidgetApiBaseKey);
      } catch (_) {}
    }
  } else {
    final json = jsonEncode(widgetSnapshotJson(data, connected: true));
    await prefs.setString(kWidgetSnapshotKey, json);
    await prefs.setString(kWidgetPlatformBaseKey, resolvePlatformBase());
    await prefs.setString(kWidgetApiBaseKey, resolveApiBase());
    if (!kIsWeb && (Platform.isIOS || Platform.isMacOS)) {
      try {
        final defaults = await SharedPreferences.getInstance();
        await defaults.setString(kWidgetSnapshotKey, json);
        await defaults.setString(kWidgetPlatformBaseKey, resolvePlatformBase());
        await defaults.setString(kWidgetApiBaseKey, resolveApiBase());
      } catch (_) {}
    }
  }
  await refreshWidgets();
}

/// Ask the launcher to redraw from what is already stored.
Future<void> refreshWidgets() async {
  if (kIsWeb) return;
  if (defaultTargetPlatform == TargetPlatform.android) {
    try {
      await _channel.invokeMethod<void>('refresh');
    } on MissingPluginException {
      // A host that has no widget receiver (tests, desktop) is not an error.
    } on PlatformException {
      // Same: the widget is decoration, never a reason to fail a fetch.
    }
    return;
  }
  if (defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS) {
    try {
      await _widgetKitChannel.invokeMethod<void>('refresh');
    } on MissingPluginException {
      try {
        await _channel.invokeMethod<void>('refresh');
      } catch (_) {}
    } on PlatformException {
      // Same: the widget is decoration, never a reason to fail a fetch.
    }
    return;
  }
}
