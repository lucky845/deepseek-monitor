import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_monitor/models/balance.dart';
import 'package:deepseek_monitor/models/usage.dart';
import 'package:deepseek_monitor/services/widget_bridge.dart';

UsageData _data({
  double balance = 6.57,
  double granted = 1.57,
  double month = 79.59,
  int requests = 485,
  List<TrendPoint> trend = const [],
}) =>
    UsageData(
      summary: UserSummary(
        balances: [
          BalanceInfo(
            currency: 'CNY',
            totalBalance: balance,
            grantedBalance: granted,
            toppedUpBalance: balance - granted,
          ),
        ],
        totalAvailableTokenEstimation: '0',
        currentToken: 0,
        totalCosts: 0,
      ),
      // Requests and the hit rate are derived from the keys, exactly as the
      // dashboard derives them — the widget must not recompute them its own way.
      apiKeys: [
        ApiKeyUsage(
          trackingId: 'tk-1',
          name: 'main',
          models: [
            ModelUsage(
              model: 'deepseek-v4-flash',
              cacheHitTokens: 49100000,
              cacheMissTokens: 1200000,
              outputTokens: 409800,
              requests: requests,
            ),
          ],
        ),
      ],
      trend: trend,
      rangeCost: month,
      todayCost: 3.47,
      monthlyCost: month,
      updatedAt: DateTime(2026, 10, 20, 12),
    );

void main() {
  group('the widget snapshot never invents a figure', () {
    test('carries the wallet split and the totals the app already shows', () {
      final json = widgetSnapshotJson(_data(), connected: true);
      expect(json['connected'], isTrue);
      expect(json['balance'], 6.57);
      expect(json['granted'], 1.57);
      expect(json['monthCost'], 79.59);
      expect(json['requests'], 485);
    });

    test('a summary with no wallet leaves the balance null, not zero', () {
      final data = UsageData(
        summary: null,
        apiKeys: const [],
        rangeCost: 0,
        todayCost: 0,
        monthlyCost: 0,
        updatedAt: DateTime(2026, 10, 20),
      );
      final json = widgetSnapshotJson(data, connected: false,
          now: DateTime(2026, 10, 20));
      // Zero would read as "your balance is empty" — null lets the widget
      // print a dash and say it is not connected.
      expect(json['balance'], isNull);
      expect(json['connected'], isFalse);
    });

    test('only the last seven trend points are sent', () {
      final trend = [
        for (var d = 1; d <= 12; d++)
          TrendPoint(at: DateTime(2026, 10, d), tokens: d * 10, cost: d.toDouble()),
      ];
      final json = widgetSnapshotJson(_data(trend: trend), connected: true);
      final tail = json['trend'] as List;
      expect(tail, hasLength(7));
      expect((tail.first as Map)['c'], 6.0);
      expect((tail.last as Map)['c'], 12.0);
    });

    test('days that have not happened yet are dropped', () {
      // The month window ends on the 1st, so the platform replies with a zero
      // bucket for every remaining day. Charting those would draw a cliff at the
      // end and put "the latest bar" on tomorrow.
      final trend = [
        TrendPoint(at: DateTime(2026, 10, 28), tokens: 0, cost: 1),
        TrendPoint(at: DateTime(2026, 10, 29), tokens: 0, cost: 2),
        TrendPoint(at: DateTime(2026, 10, 30), tokens: 0, cost: 3),
        TrendPoint(at: DateTime(2026, 10, 31), tokens: 0, cost: 0),
        TrendPoint(at: DateTime(2026, 11, 1), tokens: 0, cost: 0),
      ];
      final json = widgetSnapshotJson(_data(trend: trend), connected: true,
          now: DateTime(2026, 10, 30, 12));
      final tail = json['trend'] as List;
      expect(tail, hasLength(3));
      expect((tail.last as Map)['c'], 3.0);
    });

    test('days left is balance over what a day has actually been costing', () {
      // 20 October: 20 days of the month have happened, ¥100 spent → ¥5/day,
      // so a ¥50 balance buys ten more days.
      final json = widgetSnapshotJson(
        _data(balance: 50, month: 100),
        connected: true,
        now: DateTime(2026, 10, 20),
      );
      expect(json['dailyAvg'], 5.0);
      expect(json['daysLeft'], 10.0);
    });

    test('no spend means no invented runway', () {
      final json = widgetSnapshotJson(
        _data(balance: 50, month: 0),
        connected: true,
        now: DateTime(2026, 10, 20),
      );
      expect(json['dailyAvg'], 0.0);
      expect(json['daysLeft'], 0.0);
    });
  });
}
