import 'package:flutter_test/flutter_test.dart';
import 'package:deepseek_monitor/models/usage.dart';

ApiKeyUsage _key(String id, String name, List<ModelUsage> models) =>
    ApiKeyUsage(trackingId: id, name: name, models: models);

void main() {
  group('UsageData aggregation', () {
    test('models merges the same model across API keys and sums cost', () {
      final data = UsageData(
        apiKeys: [
          _key('tr_a', '生产', [
            ModelUsage(
                model: 'flash',
                cacheHitTokens: 100,
                cacheMissTokens: 50,
                outputTokens: 10,
                requests: 3,
                cost: 1.5),
          ]),
          _key('tr_b', '调试', [
            ModelUsage(
                model: 'flash',
                cacheHitTokens: 40,
                cacheMissTokens: 10,
                outputTokens: 5,
                requests: 2,
                cost: 0.5),
            ModelUsage(
                model: 'pro', cacheHitTokens: 8, outputTokens: 2, cost: 4),
          ]),
        ],
        rangeCost: 6,
        todayCost: 0,
        monthlyCost: 0,
        updatedAt: DateTime(2026, 1, 1),
      );

      // 'flash' appears under both keys and must collapse into one row.
      expect(data.models.length, 2);
      final flash = data.models.firstWhere((m) => m.model == 'flash');
      expect(flash.cacheHitTokens, 140);
      expect(flash.cacheMissTokens, 60);
      expect(flash.outputTokens, 15);
      expect(flash.requests, 5);
      expect(flash.cost, closeTo(2.0, 1e-9));
      expect(flash.totalTokens, 215);

      // Sorted by tokens desc: flash 215 > pro 10.
      expect(data.models.first.model, 'flash');
    });

    test('per-key totals and spend ordering', () {
      final data = UsageData(
        apiKeys: [
          _key('tr_small', '', [
            ModelUsage(model: 'flash', cacheHitTokens: 10, cost: 1),
          ]),
          _key('tr_big', '生产环境', [
            ModelUsage(model: 'flash', cacheHitTokens: 90, cost: 9),
          ]),
        ],
        rangeCost: 10,
        todayCost: 0,
        monthlyCost: 0,
        updatedAt: DateTime(2026, 1, 1),
      );

      final ordered = data.apiKeysBySpend;
      expect(ordered.first.label, '生产环境');
      expect(ordered.first.cost, 9);
      expect(ordered.last.cost, 1);
      // An unnamed key falls back to its tracking id, never to a blank label.
      expect(ordered.last.label, 'tr_small');
      expect(data.totalTokens, 100);
      expect(data.rangeCost, 10);
    });

    test('blended cost per million tokens and cache hit rate', () {
      final m = ModelUsage(
        model: 'flash',
        cacheHitTokens: 750,
        cacheMissTokens: 250,
        outputTokens: 0,
        cost: 2,
      );
      expect(m.totalTokens, 1000);
      expect(m.cacheHitRate, 75.0);
      // 2 CNY over 1000 tokens = 2000 CNY per million.
      expect(m.costPerMillion, closeTo(2000, 1e-6));
    });

    test('empty payloads never divide by zero', () {
      final empty = UsageData(
        apiKeys: const [],
        rangeCost: 0,
        todayCost: 0,
        monthlyCost: 0,
        updatedAt: DateTime(2026, 1, 1),
      );
      expect(empty.models, isEmpty);
      expect(empty.apiKeysBySpend, isEmpty);
      expect(empty.cacheHitRate, 0);
      expect(empty.avgCostPerMillion, 0);
      expect(empty.totalTokens, 0);

      final zero = ModelUsage(model: 'x');
      expect(zero.cacheHitRate, 0);
      expect(zero.costPerMillion, 0);
    });

    test('a key with no name and no tracking id still gets a label', () {
      final k = _key('', '', [ModelUsage(model: 'flash', cost: 1)]);
      expect(k.label, '未命名 API Key');
      expect(k.costPerMillion, 0); // no tokens -> no rate, not infinity
    });

    test('ModelUsage round-trips through JSON with cost', () {
      final m = ModelUsage(
          model: 'flash',
          cacheHitTokens: 1,
          cacheMissTokens: 2,
          outputTokens: 3,
          requests: 4,
          cost: 5.5);
      final back = ModelUsage.fromJson(m.toJson());
      expect(back.model, 'flash');
      expect(back.cacheMissTokens, 2);
      expect(back.requests, 4);
      expect(back.cost, 5.5);
    });
  });
}
