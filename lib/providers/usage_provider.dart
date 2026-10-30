import 'dart:async';
import 'package:flutter/material.dart';
import '../models/usage.dart';
import '../services/deepseek_service.dart';
import '../services/widget_bridge.dart';

class UsageProvider extends ChangeNotifier {
  UsageData? _data;
  bool _loading = false;
  String? _error;
  DateTime? _start;
  DateTime? _end;

  UsageData? get data => _data;
  bool get loading => _loading;
  String? get error => _error;
  DateTime? get start => _start;
  DateTime? get end => _end;

  /// Fetch usage for an explicit window. Callers (the dashboard) own range
  /// selection so switching the chips re-queries the API instead of just
  /// repainting the same month.
  Future<void> fetchRange(String token, DateTime start, DateTime end,
      {int tzOffset = 28800}) async {
    _loading = true;
    _error = null;
    _start = start;
    _end = end;
    notifyListeners();
    try {
      final svc = DeepSeekService(token: token, tzOffsetSeconds: tzOffset);
      _data = await svc.fetchUsage(start: start, end: end);
      await publishWidgetSnapshot(_data, connected: true);
    } catch (e) {
      _error = e is DeepSeekException ? e.message : e.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Convenience wrapper for "this month".
  Future<void> fetch(String token, {int tzOffset = 28800}) {
    final now = DateTime.now();
    return fetchRange(token, DateTime(now.year, now.month, 1),
        DateTime(now.year, now.month + 1, 1),
        tzOffset: tzOffset);
  }

  /// API-key mode: the official endpoint only exposes balance, so build a
  /// summary-only payload instead of silently reusing sample usage numbers.
  Future<void> fetchBalance(String apiKey, {int tzOffset = 28800}) async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final svc = DeepSeekService(apiKey: apiKey, tzOffsetSeconds: tzOffset);
      final summary = await svc.fetchSummary();
      _data = UsageData(
        summary: summary,
        apiKeys: const [],
        trend: const [],
        rangeCost: 0,
        todayCost: 0,
        monthlyCost: 0,
        updatedAt: DateTime.now(),
      );
      await publishWidgetSnapshot(_data, connected: true);
    } catch (e) {
      _error = e is DeepSeekException ? e.message : e.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  void clear() {
    _data = null;
    _error = null;
    notifyListeners();
    // The widget reads the same numbers, so it has to forget them at the same
    // moment the app does.
    unawaited(publishWidgetSnapshot(null, connected: false));
  }
}
