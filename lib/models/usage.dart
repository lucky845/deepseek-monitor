import 'balance.dart';

/// Token usage and cost for one (API key x model) pair, already merged across
/// every day bucket in the selected window.
class ModelUsage {
  final String model;
  final int cacheHitTokens;
  final int cacheMissTokens;
  final int outputTokens;
  final int requests;
  final double cost;

  ModelUsage({
    required this.model,
    this.cacheHitTokens = 0,
    this.cacheMissTokens = 0,
    this.outputTokens = 0,
    this.requests = 0,
    this.cost = 0,
  });

  int get totalTokens => cacheHitTokens + cacheMissTokens + outputTokens;

  double get cacheHitRate {
    final total = cacheHitTokens + cacheMissTokens;
    if (total == 0) return 0;
    return cacheHitTokens / total * 100;
  }

  /// Blended price per million tokens, including DeepSeek's peak/off-peak
  /// tiers — the API already returns the billed amount, so this is exact.
  double get costPerMillion {
    if (totalTokens == 0) return 0;
    return cost / (totalTokens / 1000000);
  }

  ModelUsage operator +(ModelUsage o) => ModelUsage(
        model: model,
        cacheHitTokens: cacheHitTokens + o.cacheHitTokens,
        cacheMissTokens: cacheMissTokens + o.cacheMissTokens,
        outputTokens: outputTokens + o.outputTokens,
        requests: requests + o.requests,
        cost: cost + o.cost,
      );

  Map<String, dynamic> toJson() => {
        'model': model,
        'cacheHitTokens': cacheHitTokens,
        'cacheMissTokens': cacheMissTokens,
        'outputTokens': outputTokens,
        'requests': requests,
        'cost': cost,
      };

  factory ModelUsage.fromJson(Map<String, dynamic> j) => ModelUsage(
        model: j['model'] ?? '',
        cacheHitTokens: j['cacheHitTokens'] ?? 0,
        cacheMissTokens: j['cacheMissTokens'] ?? 0,
        outputTokens: j['outputTokens'] ?? 0,
        requests: j['requests'] ?? 0,
        cost: (j['cost'] as num?)?.toDouble() ?? 0,
      );
}

/// Everything one DeepSeek API key consumed in the window. The platform reports
/// usage per (key x model), so this is the finest breakdown the API offers.
class ApiKeyUsage {
  final String trackingId;
  final String name;
  final List<ModelUsage> models;

  ApiKeyUsage({
    required this.trackingId,
    required this.name,
    required this.models,
  });

  /// What to show in the UI: a real key name if the user set one, otherwise the
  /// platform's tracking id.
  String get label {
    if (name.isNotEmpty) return name;
    if (trackingId.isNotEmpty) return trackingId;
    return '未命名 API Key';
  }

  int get totalTokens => models.fold(0, (s, m) => s + m.totalTokens);
  int get requests => models.fold(0, (s, m) => s + m.requests);
  int get cacheHitTokens => models.fold(0, (s, m) => s + m.cacheHitTokens);
  int get cacheMissTokens => models.fold(0, (s, m) => s + m.cacheMissTokens);
  int get outputTokens => models.fold(0, (s, m) => s + m.outputTokens);
  double get cost => models.fold(0.0, (s, m) => s + m.cost);

  double get cacheHitRate {
    final t = cacheHitTokens + cacheMissTokens;
    if (t == 0) return 0;
    return cacheHitTokens / t * 100;
  }

  double get costPerMillion =>
      totalTokens == 0 ? 0 : cost / (totalTokens / 1000000);
}

/// One bucket in the trend chart.
///
/// The platform picks the resolution from the window: a single day comes back
/// as 24 hourly buckets, anything longer as one per day. The bucket size is
/// carried on [UsageData.trendIsHourly] so the chart can label a bucket as a
/// time of day or a date instead of guessing.
class TrendPoint {
  final DateTime at;
  final int tokens;
  final double cost;
  final int requests;
  const TrendPoint({
    required this.at,
    required this.tokens,
    this.cost = 0,
    this.requests = 0,
  });
}

class UsageData {
  final UserSummary? summary;

  /// Per-API-key breakdown — the single source of truth. [models] is the
  /// cross-key aggregate derived from it, so the two can never disagree.
  final List<ApiKeyUsage> apiKeys;

  final List<TrendPoint> trend;

  /// True when each trend point is one hour rather than one day.
  final bool trendIsHourly;
  final double rangeCost;
  final double todayCost;
  final double monthlyCost;
  final DateTime updatedAt;

  UsageData({
    this.summary,
    this.apiKeys = const [],
    this.trend = const [],
    this.trendIsHourly = false,
    required this.rangeCost,
    required this.todayCost,
    required this.monthlyCost,
    required this.updatedAt,
  });

  /// Widest-to-narrowest view of the same window: model totals merged across
  /// every key that was used.
  late final List<ModelUsage> models = _mergeModels(apiKeys);

  static List<ModelUsage> _mergeModels(List<ApiKeyUsage> keys) {
    final merged = <String, ModelUsage>{};
    for (final k in keys) {
      for (final m in k.models) {
        merged[m.model] = merged.containsKey(m.model)
            ? merged[m.model]! + m
            : ModelUsage(
                model: m.model,
                cacheHitTokens: m.cacheHitTokens,
                cacheMissTokens: m.cacheMissTokens,
                outputTokens: m.outputTokens,
                requests: m.requests,
                cost: m.cost,
              );
      }
    }
    final list = merged.values.toList()
      ..sort((a, b) => b.totalTokens.compareTo(a.totalTokens));
    return list;
  }

  /// Keys ordered by spend, so the biggest consumer is always first.
  List<ApiKeyUsage> get apiKeysBySpend {
    final list = [...apiKeys];
    list.sort((a, b) {
      final c = b.cost.compareTo(a.cost);
      return c != 0 ? c : b.totalTokens.compareTo(a.totalTokens);
    });
    return list;
  }

  int get totalTokens => models.fold(0, (s, m) => s + m.totalTokens);
  int get totalRequests => models.fold(0, (s, m) => s + m.requests);
  int get cacheHitTokens => models.fold(0, (s, m) => s + m.cacheHitTokens);
  int get cacheMissTokens => models.fold(0, (s, m) => s + m.cacheMissTokens);
  int get outputTokens => models.fold(0, (s, m) => s + m.outputTokens);

  double get cacheHitRate {
    final t = cacheHitTokens + cacheMissTokens;
    if (t == 0) return 0;
    return cacheHitTokens / t * 100;
  }

  double get avgCostPerMillion =>
      totalTokens == 0 ? 0 : rangeCost / (totalTokens / 1000000);
}
