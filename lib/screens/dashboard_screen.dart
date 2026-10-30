import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import '../models/balance.dart';
import '../models/usage.dart';
import '../providers/auth_provider.dart';
import '../providers/usage_provider.dart';
import '../services/token_capture.dart' show runsInBrowser;
import '../theme.dart';
import '../widgets/connect_sheet.dart';
import '../widgets/glass_card.dart';
import '../widgets/ledger.dart';
import '../widgets/range_picker.dart';
import '../widgets/liquid.dart';
import '../widgets/privacy_card.dart';

enum TimeRange { today, week, month, custom }

/// Which number the trend chart is drawing.
enum TrendMetric { tokens, requests, cost }

/// Half-open local window [start, end) for each range.
({DateTime start, DateTime end}) windowFor(TimeRange r,
    {DateTime? customStart, DateTime? customEnd}) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  switch (r) {
    case TimeRange.today:
      return (start: today, end: today.add(const Duration(days: 1)));
    case TimeRange.week:
      final monday = today.subtract(Duration(days: today.weekday - 1));
      return (start: monday, end: today.add(const Duration(days: 1)));
    case TimeRange.month:
      return (
        start: DateTime(now.year, now.month, 1),
        end: DateTime(now.year, now.month + 1, 1)
      );
    case TimeRange.custom:
      final s = customStart ?? today.subtract(const Duration(days: 6));
      final e = customEnd ?? today;
      return (
        start: DateTime(s.year, s.month, s.day),
        end: DateTime(e.year, e.month, e.day).add(const Duration(days: 1))
      );
  }
}

UsageData mockData({
  TimeRange range = TimeRange.month,
  DateTimeRange? custom,
}) {
  final now = DateTime.now();
  final window = windowFor(
    range,
    customStart: custom?.start,
    customEnd: custom?.end,
  );
  final hourly = range == TimeRange.today;
  final trend = <TrendPoint>[];
  if (hourly) {
    // A working day: quiet at night, a morning ramp, a dip after lunch.
    for (int i = 0; i < 24; i++) {
      final awake = i >= 8 && i <= 23 ? 1.0 : 0.18;
      final hump = switch (i) {
        10 || 11 || 15 || 16 => 1.0,
        9 || 14 || 17 => 0.72,
        _ => 0.34,
      };
      final tokens = (3.2 * awake * hump * 1000000).round();
      trend.add(TrendPoint(
        at: window.start.add(Duration(hours: i)),
        tokens: tokens,
        cost: tokens * 0.0000009,
        requests: (14 * awake * hump).round(),
      ));
    }
  } else {
    final days = window.end.difference(window.start).inDays.clamp(1, 60);
    for (int i = 0; i < days; i++) {
      final base = 8 + (i * 3) % 11;
      trend.add(TrendPoint(
        at: window.start.add(Duration(days: i)),
        tokens: base * 1000000,
        cost: base * 0.24,
        requests: (base * 0.55).round(),
      ));
    }
  }
  return UsageData(
    summary: UserSummary(
      balances: [
        BalanceInfo(
          currency: 'CNY',
          totalBalance: 40.41,
          grantedBalance: 5.00,
          toppedUpBalance: 35.41,
        ),
      ],
      totalAvailableTokenEstimation: '1500000',
      currentToken: 0,
      totalCosts: 79.59,
    ),
    apiKeys: [
      ApiKeyUsage(trackingId: 'tr_9f3c1a2b', name: '生产环境', models: [
        ModelUsage(
            model: 'deepseek-v4-flash',
            cacheHitTokens: 150000000,
            cacheMissTokens: 36000000,
            outputTokens: 42000000,
            requests: 104,
            cost: 48.20),
        ModelUsage(
            model: 'deepseek-v4-pro',
            cacheHitTokens: 24000000,
            cacheMissTokens: 6000000,
            outputTokens: 10000000,
            requests: 34,
            cost: 17.19),
      ]),
      ApiKeyUsage(trackingId: 'tr_2b7d4e8c', name: '本地调试', models: [
        ModelUsage(
            model: 'deepseek-v4-flash',
            cacheHitTokens: 30000000,
            cacheMissTokens: 6600000,
            outputTokens: 8000000,
            requests: 24,
            cost: 9.30),
        ModelUsage(
            model: 'deepseek-v4-pro',
            cacheHitTokens: 6000000,
            cacheMissTokens: 2000000,
            outputTokens: 2000000,
            requests: 8,
            cost: 4.90),
      ]),
    ],
    trend: trend,
    trendIsHourly: hourly,
    rangeCost: 79.59,
    todayCost: 2.15,
    monthlyCost: 79.59,
    updatedAt: now,
  );
}

/// Zeroed payload used when we genuinely have no usage data. Never reuse the
/// sample numbers here — showing them as real would be a lie.
UsageData emptyData() => UsageData(
      apiKeys: const [],
      trend: const [],
      rangeCost: 0,
      todayCost: 0,
      monthlyCost: 0,
      updatedAt: DateTime.now(),
    );

/// Decides what the dashboard actually shows.
///
/// A platform token unlocks balance, usage, trend and cost. An API key unlocks
/// **balance only** — DeepSeek does not hand usage or cost to API keys — so in
/// that mode the balance is real while the usage panels keep the sample set,
/// and the UI is responsible for labelling which is which.
UsageData displayData({
  required bool hasPlatformToken,
  required bool hasApiKey,
  required UsageData? fetched,
  TimeRange range = TimeRange.month,
  DateTimeRange? custom,
}) {
  if (hasPlatformToken) return fetched ?? emptyData();
  final sample = mockData(range: range, custom: custom);
  final balance = fetched?.summary;
  if (balance != null) {
    return UsageData(
      summary: balance,
      apiKeys: sample.apiKeys,
      trend: sample.trend,
      trendIsHourly: sample.trendIsHourly,
      rangeCost: sample.rangeCost,
      todayCost: sample.todayCost,
      monthlyCost: sample.monthlyCost,
      updatedAt: fetched!.updatedAt,
    );
  }
  // A key is connected but its balance never arrived. Hand back the sample
  // ledger with no summary at all, so no caller can print a sample balance
  // beside a real connection — and the balance cell reads as unknown, not 40.41.
  if (hasApiKey) {
    return UsageData(
      apiKeys: sample.apiKeys,
      trend: sample.trend,
      trendIsHourly: sample.trendIsHourly,
      rangeCost: sample.rangeCost,
      todayCost: sample.todayCost,
      monthlyCost: sample.monthlyCost,
      updatedAt: sample.updatedAt,
    );
  }
  // Nothing connected at all: the page is one labelled example, balance included.
  return sample;
}

/// The label that separates real numbers from sample ones. It is a pure
/// function of what we actually hold, because the balance can be missing even
/// when an API key is saved — the first sentence must never claim otherwise.
({String text, String? action}) sampleNoticeCopy({
  required bool hasRealBalance,
  required bool hasApiKey,
  required bool browser,
}) {
  // Both credential paths stay on offer everywhere. In a browser the token
  // one cannot complete (the platform sends no CORS headers), so the sentence
  // says which door opens on which machine instead of hiding a door.
  final where = browser
      ? '浏览器会拦下网页对 platform.deepseek.com 的跨域请求，所以用量要在桌面或手机客户端里看。'
      : 'DeepSeek 只允许 API Key 读取余额，模型级用量和花费需要平台令牌。';
  if (hasRealBalance) {
    return (
      text: '余额已经换成你账户里的真实数字。用量、费用和趋势还是她编的示例 —— $where',
      action: '解锁用量',
    );
  }
  if (hasApiKey) {
    return (
      text: 'API Key 收好了，余额却还没取回来（多半是网络打了个盹）。下面全是示例数据 —— $where',
      action: '解锁用量',
    );
  }
  return (
    text: '这些是大肥鱼随手编的示例数据，不是你的。点「连接账号」给她一个令牌或 API Key，她就去看你真实的账单。',
    action: '去连接',
  );
}

/// The balance we are allowed to print. With no summary in hand we show a dash:
/// falling back to a sample figure would put an invented number on a dashboard
/// whose other panels are showing real usage.
String balanceLabel(double? total) =>
    total == null ? '—' : '¥${total.toStringAsFixed(2)}';

/// What a screen is allowed to be. A phone gets one slice at a time; a desktop
/// gets the whole ledger, because there is room to compare panels side by side.
class DashboardLayout {
  const DashboardLayout({required this.isMobile, required this.twoColumn});

  final bool isMobile;
  final bool twoColumn;

  factory DashboardLayout.of(Size size) => DashboardLayout(
        isMobile: size.width < 600,
        twoColumn: size.width >= 1000,
      );
}

enum DashboardTab { overview, usage, cost, settings }

String tabLabel(DashboardTab t) => switch (t) {
      DashboardTab.overview => '概览',
      DashboardTab.usage => '用量',
      DashboardTab.cost => '花费',
      DashboardTab.settings => '设置',
    };

IconData tabIcon(DashboardTab t) => switch (t) {
      DashboardTab.overview => Icons.donut_small_outlined,
      DashboardTab.usage => Icons.show_chart,
      DashboardTab.cost => Icons.receipt_long_outlined,
      DashboardTab.settings => Icons.tune_outlined,
    };

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  TimeRange _range = TimeRange.month;
  TrendMetric _metric = TrendMetric.tokens;
  DateTime? _customStart;
  DateTime? _customEnd;
  DashboardTab _tab = DashboardTab.overview;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await context.read<AuthProvider>().load();
      await _refresh();
    });
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    final auth = context.read<AuthProvider>();
    final usage = context.read<UsageProvider>();
    if (!auth.isLoggedIn) {
      usage.clear();
      return;
    }
    if (auth.hasApiKey && !auth.hasPlatformToken) {
      await usage.fetchBalance(auth.apiKey!);
      return;
    }
    final w =
        windowFor(_range, customStart: _customStart, customEnd: _customEnd);
    await usage.fetchRange(auth.token!, w.start, w.end);
  }

  void _selectRange(TimeRange r) {
    setState(() => _range = r);
    _refresh();
  }

  Future<void> _pickCustomRange(BuildContext anchor) async {
    final now = DateTime.now();
    final picked = await showRangePopover(
      anchor,
      initial: DateTimeRange(
          start: _customStart ?? now.subtract(const Duration(days: 6)),
          end: _customEnd ?? now),
    );
    if (picked != null && mounted) {
      _customStart = picked.start;
      _customEnd = picked.end;
      _selectRange(TimeRange.custom);
    }
  }

  Future<void> _openConnectSheet() async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: kSurface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => const ConnectSheet(),
    );
    if (mounted) _refresh();
  }

  String get _rangeText {
    if (_range == TimeRange.custom && _customStart != null) {
      final f = DateFormat('MM/dd');
      return '${f.format(_customStart!)} – ${f.format(_customEnd!)}';
    }
    return switch (_range) {
      TimeRange.today => '今日',
      TimeRange.week => '本周',
      TimeRange.month => '本月',
      TimeRange.custom => '自定义',
    };
  }

  String _rangeChip(TimeRange r) => switch (r) {
        TimeRange.today => '今日',
        TimeRange.week => '本周',
        TimeRange.month => '本月',
        TimeRange.custom => (_range == TimeRange.custom && _customStart != null)
            ? _rangeText
            : '自定义',
      };

  @override
  Widget build(BuildContext context) {
    final usage = context.watch<UsageProvider>();
    final auth = context.watch<AuthProvider>();
    // Without a platform token the usage panels have no real numbers to show,
    // so they stay on the sample set — always behind a visible label.
    final sampleUsage = !auth.hasPlatformToken;
    final data = displayData(
      hasPlatformToken: auth.hasPlatformToken,
      hasApiKey: auth.hasApiKey,
      fetched: usage.data,
      range: _range,
      custom: (_customStart != null && _customEnd != null)
          ? DateTimeRange(start: _customStart!, end: _customEnd!)
          : null,
    );
    // A saved API key whose balance request failed means the balance is
    // unknown, not that the sample figure is ours to print.
    final balanceUnknown =
        auth.hasApiKey && !auth.hasPlatformToken && usage.data?.summary == null;
    final layout = DashboardLayout.of(MediaQuery.sizeOf(context));

    final page = RefreshIndicator(
      onRefresh: _refresh,
      color: kAccent,
      backgroundColor: kSurface,
      child: layout.isMobile
          ? _mobilePage(auth, usage, data, sampleUsage, balanceUnknown)
          : _widePage(auth, usage, data, sampleUsage, balanceUnknown, layout),
    );

    return Scaffold(
      backgroundColor: kBg,
      floatingActionButton: layout.isMobile ? null : _refreshFab(usage),
      // The dock floats: it is a Stack layer, not a bottomNavigationBar, so the
      // page keeps scrolling underneath it the way iOS' floating bar does.
      body: WaterBackdrop(
        // She is lit when the numbers around her are real.
        mascotLive: auth.hasPlatformToken,
        child: SafeArea(
          child: Stack(
            children: [
              // One orchestrated entrance for the whole page; nothing else
              // animates — except the dock, and that answers a tap.
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.0, end: 1.0),
                duration: const Duration(milliseconds: 420),
                curve: Curves.easeOutCubic,
                builder: (_, t, child) => Opacity(opacity: t, child: child),
                child: page,
              ),
              if (layout.isMobile)
                Positioned(
                  left: 14,
                  right: 14,
                  bottom: 12,
                  child: _dock(),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _refreshFab(UsageProvider usage) {
    return FloatingActionButton.extended(
      onPressed: usage.loading ? null : _refresh,
      backgroundColor: kAccent,
      foregroundColor: Colors.white,
      icon: usage.loading
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white))
          : const Icon(Icons.refresh),
      label: Text(usage.loading ? '同步中' : '刷新'),
    );
  }

  /// A floating glass dock, in the spirit of the system bars on iOS and
  /// visionOS: inset from every edge, pill-shaped, sitting over the content
  /// rather than stealing a strip from it. Tapping animates the highlight —
  /// motion that answers an action, which is the only kind worth having.
  Widget _dock() {
    return GlassSurface(
      radius: 28,
      blur: 26,
      padding: const EdgeInsets.all(6),
      child: Row(
        children: [
          for (final t in DashboardTab.values)
            Expanded(
              child: _dockItem(
                tab: t,
                selected: _tab == t,
                onTap: () => setState(() => _tab = t),
              ),
            ),
        ],
      ),
    );
  }

  Widget _dockItem({
    required DashboardTab tab,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final Color fg = selected ? Colors.white : kMuted;
    return Semantics(
      selected: selected,
      button: true,
      label: tabLabel(tab),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color:
                selected ? Colors.white.withOpacity(0.16) : Colors.transparent,
            borderRadius: BorderRadius.circular(22),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(tabIcon(tab), size: 20, color: fg),
              const SizedBox(height: 3),
              Text(
                tabLabel(tab),
                style: TextStyle(
                  fontSize: 11,
                  height: 1.1,
                  color: fg,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Phone: one slice at a time behind a bottom bar. The range control stays
  /// shared across the three data slices, because it filters all of them.
  Widget _mobilePage(AuthProvider auth, UsageProvider usage, UsageData data,
      bool sampleUsage, bool balanceUnknown) {
    final sections = <Widget>[];
    void add(Widget w) {
      if (sections.isNotEmpty) sections.add(const SizedBox(height: 16));
      sections.add(w);
    }

    switch (_tab) {
      case DashboardTab.overview:
        add(_kpiRow(data,
            balanceUnknown: balanceUnknown,
            usageIsSample: sampleUsage,
            balanceIsSample: sampleUsage && !auth.hasApiKey));
        if (sampleUsage) {
          add(_sampleNotice(auth, usage.data?.summary != null));
        }
        if (usage.error != null) add(_errorBanner(usage.error!));
        add(_rangeBar());
        add(_tokenBreakdown(data, sampleUsage));
      case DashboardTab.usage:
        add(_rangeBar());
        add(_trendCard(data, sampleUsage));
        add(_modelSection(data, sampleUsage));
        add(_modelBarChart(data, sampleUsage));
      case DashboardTab.cost:
        add(_rangeBar());
        add(_costSection(data, sampleUsage));
        add(_apiKeySection(data, sampleUsage));
      case DashboardTab.settings:
        add(_connectionSection(auth, usage));
        add(const GlassCard());
        add(const PrivacyCard());
    }

    return ListView(
      // Bottom padding clears the floating dock.
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 104),
      children: [
        _header(auth, usage, compact: true),
        const SizedBox(height: 16),
        ...sections,
      ],
    );
  }

  /// Tablet and desktop: the whole ledger on one page. Wide screens split it
  /// into breakdowns (left) and time series (right) so the two can be read
  /// against each other without scrolling.
  /// Desktop: the same four slices the phone shows. A 700px window that makes
  /// you scroll past three panels to reach the cost table is the slow way to
  /// read a ledger, so the wide layout gets tabs too — a rail instead of the
  /// floating dock, because a mouse has room for the label a thumb does not,
  /// and the eye starts on the left. Wide windows still split a slice into two
  /// columns wherever reading the two halves against each other helps.
  Widget _widePage(AuthProvider auth, UsageProvider usage, UsageData data,
      bool sampleUsage, bool balanceUnknown, DashboardLayout layout) {
    final sections = <Widget>[];
    void add(Widget w) {
      if (sections.isNotEmpty) sections.add(const SizedBox(height: 18));
      sections.add(w);
    }

    switch (_tab) {
      case DashboardTab.overview:
        add(_kpiRow(data,
            balanceUnknown: balanceUnknown,
            usageIsSample: sampleUsage,
            balanceIsSample: sampleUsage && !auth.hasApiKey));
        if (sampleUsage) {
          add(_sampleNotice(auth, usage.data?.summary != null));
        }
        if (usage.error != null) add(_errorBanner(usage.error!));
        add(_rangeBar());
        add(_tokenBreakdown(data, sampleUsage));
      case DashboardTab.usage:
        add(_rangeBar());
        if (layout.twoColumn) {
          add(Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _trendCard(data, sampleUsage)),
              const SizedBox(width: 18),
              Expanded(child: _modelSection(data, sampleUsage)),
            ],
          ));
          add(_modelBarChart(data, sampleUsage));
        } else {
          add(_trendCard(data, sampleUsage));
          add(_modelSection(data, sampleUsage));
          add(_modelBarChart(data, sampleUsage));
        }
      case DashboardTab.cost:
        add(_rangeBar());
        if (layout.twoColumn) {
          add(Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _costSection(data, sampleUsage)),
              const SizedBox(width: 18),
              Expanded(child: _apiKeySection(data, sampleUsage)),
            ],
          ));
        } else {
          add(_costSection(data, sampleUsage));
          add(_apiKeySection(data, sampleUsage));
        }
      case DashboardTab.settings:
        add(_connectionSection(auth, usage));
        add(const GlassCard());
        add(const PrivacyCard());
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _rail(),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
            children: [
              _header(auth, usage, compact: false),
              const SizedBox(height: 18),
              ...sections,
            ],
          ),
        ),
      ],
    );
  }

  /// The dock's four destinations, named and parked on the left. Same tabs, same
  /// order, same icons as the phone — only the affording differs.
  Widget _rail() {
    final index = DashboardTab.values.indexOf(_tab);
    return NavigationRail(
      backgroundColor: kSurface,
      selectedIndex: index,
      onDestinationSelected: (i) =>
          setState(() => _tab = DashboardTab.values[i]),
      labelType: NavigationRailLabelType.all,
      indicatorColor: kAccent.withOpacity(0.18),
      selectedIconTheme: const IconThemeData(color: kAccent, size: 22),
      unselectedIconTheme: const IconThemeData(color: kMuted, size: 22),
      selectedLabelTextStyle: const TextStyle(
          color: kAccent, fontSize: 12, fontWeight: FontWeight.w600),
      unselectedLabelTextStyle: const TextStyle(color: kMuted, fontSize: 12),
      destinations: [
        for (final t in DashboardTab.values)
          NavigationRailDestination(
            icon: Icon(tabIcon(t)),
            label: Text(tabLabel(t)),
          ),
      ],
    );
  }

  Widget _header(AuthProvider auth, UsageProvider usage,
      {required bool compact}) {
    String subtitle;
    if (!auth.isLoggedIn) {
      subtitle = '这些数字是她编的，连上就换成真的';
    } else if (auth.hasPlatformToken) {
      final t = usage.data?.updatedAt ?? DateTime.now();
      subtitle = '已连接平台令牌，更新于 ${DateFormat('HH:mm:ss').format(t)}';
    } else if (usage.data?.summary != null) {
      subtitle = '已连接 API Key，余额已同步，用量仍是示例';
    } else {
      subtitle = '已连接 API Key，余额未取到';
    }

    // The mascot is the page's one loud element, and it is not decoration: it is
    // lit with bubbles only when the figures beside it are really yours.
    final live = auth.hasPlatformToken;
    return Row(
      children: [
        Mascot(size: 46, live: live, head: true),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'DeepSeek 用量监控',
                style: TextStyle(
                  color: kText,
                  fontSize: 16.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: labelStyle(color: kMuted, size: 11.5),
              ),
            ],
          ),
        ),
        if (compact) ...[
          IconButton(
            onPressed: usage.loading ? null : _refresh,
            tooltip: '刷新',
            icon: const Icon(Icons.refresh, size: 20, color: kMuted),
          ),
          IconButton(
            onPressed: _openConnectSheet,
            tooltip: auth.isLoggedIn ? '管理连接' : '连接账号',
            icon: Icon(
                auth.isLoggedIn ? Icons.manage_accounts_outlined : Icons.login,
                size: 20,
                color: kAccent),
          ),
        ] else ...[
          if (auth.isLoggedIn)
            TextButton(
              onPressed: () async {
                await context.read<AuthProvider>().logout();
                await _refresh();
              },
              child: Text('断开', style: labelStyle(color: kMuted, size: 12.5)),
            ),
          const SizedBox(width: 6),
          ElevatedButton.icon(
            onPressed: _openConnectSheet,
            style: ElevatedButton.styleFrom(
              backgroundColor: kAccent,
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(9)),
            ),
            icon: Icon(
                auth.isLoggedIn ? Icons.manage_accounts_outlined : Icons.login,
                size: 16),
            // Once a credential is in place the button has a different job:
            // replace or drop it, not "connect" something already connected.
            label: Text(auth.isLoggedIn ? '管理连接' : '连接账号',
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ),
        ],
      ],
    );
  }

  Widget _rangeBar() {
    return GlassSurface(
      radius: 15,
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          for (final r in TimeRange.values)
            Expanded(
              // Builder so the calendar can drop out of the chip you tapped
              // rather than out of the middle of the screen.
              child: Builder(
                builder: (chipContext) => Semantics(
                  button: true,
                  selected: _range == r,
                  label: _rangeChip(r),
                  // The label already carries the visible text; without this a
                  // screen reader reads the chip twice.
                  excludeSemantics: true,
                  child: GestureDetector(
                    onTap: () => r == TimeRange.custom
                        ? _pickCustomRange(chipContext)
                        : _selectRange(r),
                    behavior: HitTestBehavior.opaque,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      padding: const EdgeInsets.symmetric(vertical: 9),
                      decoration: BoxDecoration(
                        color: _range == r ? kAccent : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _rangeChip(r),
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _range == r ? Colors.white : kMuted,
                          fontSize: 12.5,
                          fontWeight:
                              _range == r ? FontWeight.w600 : FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _errorBanner(String msg) {
    return GlassSurface(
      radius: 14,
      tint: kDanger,
      tintStrength: 0.12,
      padding: const EdgeInsets.all(13),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: kDanger, size: 17),
          const SizedBox(width: 10),
          Expanded(
            child: Text(msg,
                style:
                    const TextStyle(color: kText, fontSize: 12, height: 1.45)),
          ),
          TextButton(
            onPressed: _refresh,
            child: Text('重试', style: labelStyle(color: kDanger, size: 12.5)),
          ),
        ],
      ),
    );
  }

  /// Four counters, each with the one fact that explains it. No icon chrome:
  /// the label and the figure already say everything.
  Widget _kpiRow(UsageData data,
      {required bool balanceUnknown,
      required bool usageIsSample,
      required bool balanceIsSample}) {
    final b = (data.summary?.balances.isNotEmpty ?? false)
        ? data.summary!.balances.first
        : null;
    final tokenEst = data.summary?.totalAvailableTokenEstimation;
    final bool balanceSample = balanceIsSample && !balanceUnknown;
    final cells = <Widget>[
      _kpiCell(
        label: '总余额',
        value:
            balanceUnknown ? balanceLabel(null) : balanceLabel(b?.totalBalance),
        note: balanceUnknown
            ? '余额暂时取不到'
            : (tokenEst != null && tokenEst != '0')
                ? '可用 ${fmtTokens(int.tryParse(tokenEst) ?? 0)} Token'
                : '账户可用余额',
        sample: balanceSample,
      ),
      // The two halves of the total, because "how much of this is mine" is the
      // question a topped-up balance answers and a single number cannot.
      _kpiCell(
        label: '充值余额',
        value: balanceLabel(b?.toppedUpBalance),
        note: '自己充入',
        sample: balanceSample,
      ),
      _kpiCell(
        label: '赠送余额',
        value: balanceLabel(b?.grantedBalance),
        note: '平台赠送',
        sample: balanceSample,
      ),
      _kpiCell(
        label: '区间花费',
        value: '¥${data.rangeCost.toStringAsFixed(2)}',
        note: '$_rangeText合计',
        sample: usageIsSample,
      ),
      _kpiCell(
        label: '今日花费',
        value: '¥${data.todayCost.toStringAsFixed(2)}',
        note: '自 0 点起',
        sample: usageIsSample,
      ),
      _kpiCell(
        label: '请求数',
        value: '${data.totalRequests}',
        note: '$_rangeText内',
        sample: usageIsSample,
      ),
      _kpiCell(
        label: '缓存命中率',
        value: '${data.cacheHitRate.toStringAsFixed(1)}%',
        note: '命中 ${fmtTokens(data.cacheHitTokens)}',
        sample: usageIsSample,
      ),
      _kpiCell(
        label: '单 M 成本',
        value: '¥${data.avgCostPerMillion.toStringAsFixed(2)}',
        note: '每百万 Token',
        sample: usageIsSample,
      ),
    ];

    return LayoutBuilder(builder: (ctx, c) {
      // Eight cells divide evenly by 4 and by 2, never by 3.
      final cols = c.maxWidth >= 900 ? 4 : 2;
      final rows = <Widget>[];
      for (var i = 0; i < cells.length; i += cols) {
        final slice = cells.sublist(i, (i + cols).clamp(0, cells.length));
        rows.add(IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var j = 0; j < slice.length; j++) ...[
                if (j > 0) const SizedBox(width: 12),
                Expanded(child: slice[j]),
              ],
            ],
          ),
        ));
        if (i + cols < cells.length) rows.add(const SizedBox(height: 12));
      }
      return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
    });
  }

  Widget _kpiCell(
      {required String label,
      required String value,
      required String note,
      bool sample = false}) {
    return GlassSurface(
      radius: 15,
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(label, style: labelStyle(color: kFaint, size: 11)),
              if (sample) ...[
                const SizedBox(width: 6),
                const SampleTag(),
              ],
            ],
          ),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, style: figureStyle(23)),
          ),
          const SizedBox(height: 5),
          Text(note,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: labelStyle(color: kMuted, size: 11)),
        ],
      ),
    );
  }

  Widget _tokenBreakdown(UsageData data, bool sample) {
    final total = data.totalTokens;
    return Panel(
      title: 'Token 使用分析',
      hint: '区间 $_rangeText',
      sample: sample,
      child: total == 0
          ? const _EmptyLine('该区间没有产生用量')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ProportionBar(
                    label: '缓存命中',
                    value: data.cacheHitTokens,
                    total: total,
                    color: kChartHit),
                ProportionBar(
                    label: '缓存未命中',
                    value: data.cacheMissTokens,
                    total: total,
                    color: kChartMiss),
                ProportionBar(
                    label: '输出 Token',
                    value: data.outputTokens,
                    total: total,
                    color: kChartOut),
                const SizedBox(height: 2),
                StatStrip(cells: [
                  (
                    label: '总 Token',
                    value: fmtTokens(data.totalTokens),
                    unit: null
                  ),
                  (label: '请求次数', value: '${data.totalRequests}', unit: null),
                  (
                    label: '缓存命中率',
                    value: '${data.cacheHitRate.toStringAsFixed(1)}%',
                    unit: null
                  ),
                  (
                    label: '单 M 成本',
                    value: '¥${data.avgCostPerMillion.toStringAsFixed(2)}',
                    unit: null
                  ),
                ]),
              ],
            ),
    );
  }

  Widget _trendCard(UsageData data, bool sample) {
    final trend = data.trend;
    final hourly = data.trendIsHourly;
    final metric = _metric;
    double valueOf(TrendPoint p) => switch (metric) {
          TrendMetric.tokens => p.tokens.toDouble(),
          TrendMetric.requests => p.requests.toDouble(),
          TrendMetric.cost => p.cost,
        };
    String Function(double) formatAxis = switch (metric) {
      TrendMetric.tokens => (v) => fmtTokens(v.round()),
      TrendMetric.requests => (v) => v.round().toString(),
      TrendMetric.cost => (v) => '¥${v.toStringAsFixed(v >= 10 ? 0 : 1)}',
    };
    String Function(DateTime) formatAt = hourly
        ? (t) => DateFormat('HH:00').format(t)
        : (t) => DateFormat('MM/dd').format(t);
    final interval = _niceInterval([for (final p in trend) valueOf(p)]);
    final color = switch (metric) {
      TrendMetric.tokens => kAccent,
      TrendMetric.requests => kChartOut,
      TrendMetric.cost => kWarn,
    };

    return Panel(
      title: hourly ? '分时趋势' : '每日趋势',
      hint: trend.isEmpty ? '暂无数据' : '${trend.length} ${hourly ? '小时' : '天'}',
      sample: sample,
      trailing: _metricSwitch(),
      child: trend.isEmpty
          ? const SizedBox(
              height: 120, child: Center(child: _EmptyLine('该区间没有产生用量')))
          : SizedBox(
              height: 200,
              child: LineChart(
                LineChartData(
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    horizontalInterval: interval,
                    getDrawingHorizontalLine: (_) =>
                        const FlLine(color: kSurface2, strokeWidth: 1),
                  ),
                  borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 52,
                        interval: interval,
                        getTitlesWidget: (v, _) => Text(
                          formatAxis(v),
                          style: const TextStyle(color: kMuted, fontSize: 10),
                        ),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 26,
                        interval:
                            (trend.length / 5).ceilToDouble().clamp(1, 30),
                        getTitlesWidget: (v, _) {
                          final i = v.toInt();
                          if (i < 0 || i >= trend.length) {
                            return const SizedBox();
                          }
                          return Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              formatAt(trend[i].at),
                              style:
                                  const TextStyle(color: kMuted, fontSize: 10),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  lineTouchData: LineTouchData(
                    touchTooltipData: LineTouchTooltipData(
                      getTooltipColor: (_) => kSurface2,
                      getTooltipItems: (spots) => spots.map((s) {
                        final p = trend[s.x.toInt()];
                        return LineTooltipItem(
                          '${formatAt(p.at)}\n'
                          '${fmtTokens(p.tokens)} Token · ${p.requests} 次请求\n'
                          '¥${p.cost.toStringAsFixed(2)}',
                          const TextStyle(
                              color: kText, fontSize: 11, height: 1.4),
                        );
                      }).toList(),
                    ),
                  ),
                  lineBarsData: [
                    LineChartBarData(
                      spots: [
                        for (int i = 0; i < trend.length; i++)
                          FlSpot(i.toDouble(), valueOf(trend[i])),
                      ],
                      isCurved: true,
                      curveSmoothness: 0.28,
                      color: color,
                      barWidth: 2.4,
                      dotData: const FlDotData(show: false),
                      belowBarData: BarAreaData(
                        show: true,
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            color.withOpacity(0.32),
                            color.withOpacity(0.0),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  /// One chart, three lenses — instead of three charts that all say the same
  /// shape.
  Widget _metricSwitch() {
    Widget chip(String label, TrendMetric value) {
      final on = _metric == value;
      return Semantics(
        button: true,
        selected: on,
        label: '趋势视角 $label',
        excludeSemantics: true,
        child: GestureDetector(
          onTap: () => setState(() => _metric = value),
          behavior: HitTestBehavior.opaque,
          child: Container(
            margin: const EdgeInsets.only(left: 6),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              color: on ? Colors.white.withOpacity(0.14) : Colors.transparent,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: on ? kText : kMuted,
                fontSize: 11,
                fontWeight: on ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ),
      );
    }

    return Row(mainAxisSize: MainAxisSize.min, children: [
      chip('Token', TrendMetric.tokens),
      chip('请求', TrendMetric.requests),
      chip('金额', TrendMetric.cost),
    ]);
  }

  double _niceInterval(List<double> values) {
    if (values.isEmpty) return 1;
    final max = values.reduce((a, b) => a > b ? a : b);
    if (max <= 0) return 1;
    return max / 4;
  }

  Widget _modelSection(UsageData data, bool sample) {
    final total = data.totalTokens;
    final models = [...data.models]
      ..sort((a, b) => b.totalTokens.compareTo(a.totalTokens));
    return Panel(
      title: '模型明细',
      hint: models.isEmpty ? '暂无数据' : '${models.length} 个模型',
      sample: sample,
      child: models.isEmpty
          ? const _EmptyLine('该区间没有产生用量')
          : Column(
              children: [
                for (final m in models)
                  LedgerRow(
                    title: m.model,
                    subtitle: '${m.requests} 次请求',
                    value: fmtTokens(m.totalTokens),
                    unit: 'Token',
                    progress: total == 0 ? 0 : m.totalTokens / total,
                    progressColor: kAccent,
                    footnote: RowFootnotes(
                      left:
                          '占本区间 ${(total == 0 ? 0 : m.totalTokens / total * 100).toStringAsFixed(1)}%',
                      right: '缓存命中 ${m.cacheHitRate.toStringAsFixed(1)}%',
                    ),
                  ),
              ],
            ),
    );
  }

  /// Cost attributed per model. The range total comes from the cost endpoint
  /// and the rows are the per-model split of it; if the two ever disagree we
  /// say so rather than quietly showing a partial picture.
  Widget _costSection(UsageData data, bool sample) {
    final models = [...data.models]..sort((a, b) => b.cost.compareTo(a.cost));
    final attributed = models.fold<double>(0, (s, m) => s + m.cost);
    final unattributed = data.rangeCost - attributed;
    final showUnattributed = unattributed.abs() > 0.005;

    return Panel(
      title: '模型级费用拆分',
      hint: '区间合计 ¥${data.rangeCost.toStringAsFixed(2)}',
      sample: sample,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showUnattributed)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, color: kWarn, size: 15),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '另有 ¥${unattributed.toStringAsFixed(2)} 未归属到具体模型',
                      style: labelStyle(color: kWarn, size: 11.5),
                    ),
                  ),
                ],
              ),
            ),
          if (models.isEmpty)
            const _EmptyLine('该区间没有产生费用')
          else
            for (final m in models)
              LedgerRow(
                title: m.model,
                subtitle: '${fmtTokens(m.totalTokens)} Token',
                value: '¥${m.cost.toStringAsFixed(2)}',
                progress: data.rangeCost == 0 ? 0 : m.cost / data.rangeCost,
                progressColor: kWarn,
                footnote: RowFootnotes(
                  left:
                      '费用占比 ${(data.rangeCost == 0 ? 0 : m.cost / data.rangeCost * 100).toStringAsFixed(1)}%',
                  right: '单价 ¥${m.costPerMillion.toStringAsFixed(2)}/M',
                ),
              ),
        ],
      ),
    );
  }

  Widget _apiKeySection(UsageData data, bool sample) {
    final keys = data.apiKeysBySpend;
    if (keys.isEmpty) return const SizedBox.shrink();
    final top = keys.first.cost;
    return Panel(
      title: 'API Key 对比',
      hint: keys.length == 1 ? '仅 1 个 Key 在用' : '${keys.length} 个 Key',
      sample: sample,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final k in keys)
            LedgerRow(
              title: k.label,
              subtitle: '${k.requests} 次请求',
              value: '¥${k.cost.toStringAsFixed(2)}',
              progress: top == 0 ? 0 : k.cost / top,
              progressColor: kChartOut,
              footnote: RowFootnotes(
                left: '主力 ${_leadModel(k)}',
                right: '单价 ¥${k.costPerMillion.toStringAsFixed(2)}/M',
              ),
            ),
          if (keys.length == 1)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '再接入更多 API Key 后，这里会横向对比各自的花费与用量。',
                style: labelStyle(color: kFaint, size: 11.5),
              ),
            ),
        ],
      ),
    );
  }

  String _leadModel(ApiKeyUsage k) {
    if (k.models.isEmpty) return '—';
    final m = [...k.models]
      ..sort((a, b) => b.totalTokens.compareTo(a.totalTokens));
    return m.first.model.replaceAll('deepseek-', '');
  }

  Widget _modelBarChart(UsageData data, bool sample) {
    if (data.models.isEmpty) return const SizedBox.shrink();
    return Panel(
      title: 'Token 构成对比',
      hint: '按模型分组',
      sample: sample,
      child: Column(
        children: [
          SizedBox(
            height: 220,
            child: BarChart(
              BarChartData(
                alignment: BarChartAlignment.spaceAround,
                barGroups: data.models.asMap().entries.map((e) {
                  return BarChartGroupData(x: e.key, barsSpace: 4, barRods: [
                    BarChartRodData(
                        toY: e.value.cacheHitTokens.toDouble(),
                        color: kChartHit,
                        width: 13,
                        borderRadius: BorderRadius.circular(3)),
                    BarChartRodData(
                        toY: e.value.cacheMissTokens.toDouble(),
                        color: kChartMiss,
                        width: 13,
                        borderRadius: BorderRadius.circular(3)),
                    BarChartRodData(
                        toY: e.value.outputTokens.toDouble(),
                        color: kChartOut,
                        width: 13,
                        borderRadius: BorderRadius.circular(3)),
                  ]);
                }).toList(),
                titlesData: FlTitlesData(
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 28,
                      getTitlesWidget: (v, _) {
                        final i = v.toInt();
                        if (i < 0 || i >= data.models.length) {
                          return const SizedBox();
                        }
                        return Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            data.models[i].model.replaceAll('deepseek-', ''),
                            style: const TextStyle(color: kMuted, fontSize: 10),
                          ),
                        );
                      },
                    ),
                  ),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 48,
                      getTitlesWidget: (v, _) => Text(fmtTokens(v.toInt()),
                          style: const TextStyle(color: kMuted, fontSize: 10)),
                    ),
                  ),
                  topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                ),
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  getDrawingHorizontalLine: (_) =>
                      const FlLine(color: kSurface2, strokeWidth: 1),
                ),
                borderData: FlBorderData(show: false),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _legend(kChartHit, '缓存命中'),
              const SizedBox(width: 18),
              _legend(kChartMiss, '缓存未命中'),
              const SizedBox(width: 18),
              _legend(kChartOut, '输出'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _legend(Color c, String label) {
    return Row(
      children: [
        Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
                color: c, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 6),
        Text(label, style: labelStyle(color: kMuted, size: 11)),
      ],
    );
  }

  /// Phone settings slice: what the app currently holds, in plain words.
  Widget _connectionSection(AuthProvider auth, UsageProvider usage) {
    final (status, detail) = switch (auth.mode) {
      AuthMode.platformToken => ('已连接平台令牌', '可以读取余额、模型级用量、每日趋势和费用。'),
      AuthMode.apiKey => ('已连接 API Key', '只能读取余额。模型级用量、趋势和费用需要平台令牌。'),
      AuthMode.none => ('还没连上 DeepSeek', '大肥鱼现在报给你的数字全是编的。'),
    };
    return Panel(
      title: '连接',
      hint: auth.isLoggedIn ? '已连接' : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(status,
              style: const TextStyle(
                  color: kText, fontSize: 13.5, fontWeight: FontWeight.w600)),
          const SizedBox(height: 5),
          Text(detail, style: bodyStyle()),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: _openConnectSheet,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kAccent,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(9)),
                  ),
                  child: const Text('连接账号',
                      style:
                          TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                ),
              ),
              if (auth.isLoggedIn) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () async {
                      await context.read<AuthProvider>().logout();
                      await _refresh();
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: kMuted,
                      side: const BorderSide(color: kLine),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(9)),
                    ),
                    child: const Text('断开连接', style: TextStyle(fontSize: 13)),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// One label for both states: nothing connected, or API key only. The wording
  /// never lets a sample number pass for a real one, including the case where
  /// the key is saved but the balance request failed.
  Widget _sampleNotice(AuthProvider auth, bool hasRealBalance) {
    final copy = sampleNoticeCopy(
      hasRealBalance: hasRealBalance,
      hasApiKey: auth.hasApiKey,
      browser: runsInBrowser,
    );
    return GlassSurface(
      radius: 15,
      tint: kWarn,
      tintStrength: 0.13,
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(Icons.info_outline, color: kWarn, size: 17),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SampleTag(label: '示例数据'),
                const SizedBox(height: 7),
                Text(
                  copy.text,
                  style:
                      const TextStyle(color: kText, fontSize: 12, height: 1.5),
                ),
              ],
            ),
          ),
          if (copy.action != null)
            TextButton(
              onPressed: _openConnectSheet,
              child: Text(copy.action!,
                  style: labelStyle(color: kWarn, size: 12.5)),
            ),
        ],
      ),
    );
  }
}

class _EmptyLine extends StatelessWidget {
  const _EmptyLine(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Text(text, style: labelStyle(color: kMuted, size: 12)),
      );
}
