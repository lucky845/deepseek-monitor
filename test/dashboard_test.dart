import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:deepseek_monitor/main.dart';
import 'package:deepseek_monitor/models/balance.dart';
import 'package:deepseek_monitor/models/usage.dart';
import 'package:deepseek_monitor/providers/auth_provider.dart';
import 'package:deepseek_monitor/providers/usage_provider.dart';
import 'package:deepseek_monitor/screens/dashboard_screen.dart';
import 'package:deepseek_monitor/services/token_capture.dart';
import 'package:deepseek_monitor/widgets/connect_sheet.dart';
import 'package:deepseek_monitor/widgets/privacy_card.dart';

Widget wrap(Widget child) => MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => UsageProvider()),
      ],
      child: MaterialApp(home: child),
    );

/// The wide layout parks its four destinations on a rail, so a test that cares
/// about a panel behind one of them has to walk there the way a person would:
/// tap the label on the rail, not the one in the floating dock.
Future<void> openTab(WidgetTester tester, String label) async {
  await tester.tap(find.descendant(
    of: find.byType(NavigationRail),
    matching: find.text(label),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    debugForceTokenCapture = null;
    debugForceBrowser = null;
  });

  tearDown(() {
    debugForceTokenCapture = null;
    debugForceBrowser = null;
  });

  testWidgets('App builds', (tester) async {
    await tester.pumpWidget(const DeepSeekMonitorApp());
    await tester.pump();
    expect(find.byType(MaterialApp), findsOneWidget);
  });

  testWidgets('dashboard shows sample data without blocking on a login page',
      (tester) async {
    // Tall surface so every lazily-built panel is laid out in one pass.
    tester.view.physicalSize = const Size(1400, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrap(const DashboardScreen()));
    await tester.pump();

    expect(find.text('DeepSeek 用量监控'), findsOneWidget);
    expect(find.text('连接账号'), findsOneWidget);
    // Sample-data banner, so the user is never stuck on an empty login wall.
    expect(find.textContaining('示例数据'), findsWidgets);

    // Range chips are live controls, not decoration.
    for (final label in ['今日', '本周', '本月', '自定义']) {
      expect(find.text(label), findsOneWidget);
    }

    // The overview slice carries the KPI row and the token analysis.
    expect(find.text('Token 使用分析'), findsOneWidget);
    expect(find.text('80.6%'), findsWidgets);

    // The series and the per-model table belong to the usage slice, one over.
    await openTab(tester, '用量');
    expect(find.text('每日趋势'), findsOneWidget);
    expect(find.text('模型明细'), findsOneWidget);
    expect(find.text('deepseek-v4-flash'), findsWidgets);
  });

  testWidgets('the balance is shown whole and in its two parts',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrap(const DashboardScreen()));
    await tester.pump();

    // Three cells, because "how much of this did I pay for" is a different
    // question from "how much can I still spend".
    expect(find.text('总余额'), findsOneWidget);
    expect(find.text('充值余额'), findsOneWidget);
    expect(find.text('赠送余额'), findsOneWidget);
    expect(find.text('¥40.41'), findsOneWidget);
    expect(find.text('¥35.41'), findsOneWidget);
    expect(find.text('¥5.00'), findsOneWidget);
    // The parts still add up to the whole that is on screen.
    expect(40.41, closeTo(35.41 + 5.00, 0.001));
  });

  testWidgets('per-model cost split adds up to the range total',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 3600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrap(const DashboardScreen()));
    await tester.pump();

    await openTab(tester, '花费');
    expect(find.text('模型级费用拆分'), findsOneWidget);
    expect(find.text('区间合计 ¥79.59'), findsOneWidget);

    // Cost is merged per model across keys: flash 48.20 + 9.30, pro 17.19 +
    // 4.90. Together they must account for the whole 79.59 range total.
    expect(find.text('¥57.50'), findsOneWidget);
    expect(find.text('¥22.09'), findsOneWidget);
    expect(find.text('费用占比 72.2%'), findsOneWidget);
    expect(find.text('费用占比 27.8%'), findsOneWidget);

    // Nothing is unattributed in this sample, so no warning may be shown.
    expect(find.textContaining('未归属到具体模型'), findsNothing);
    expect(find.text('该区间没有产生费用'), findsNothing);
  });

  testWidgets('API key comparison ranks keys by spend', (tester) async {
    tester.view.physicalSize = const Size(1400, 3600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrap(const DashboardScreen()));
    await tester.pump();

    await openTab(tester, '花费');
    expect(find.text('API Key 对比'), findsOneWidget);
    expect(find.text('2 个 Key'), findsOneWidget);
    expect(find.text('生产环境'), findsOneWidget);
    expect(find.text('本地调试'), findsOneWidget);
    // 48.20 + 17.19, and 9.30 + 4.90.
    expect(find.text('¥65.39'), findsOneWidget);
    expect(find.text('¥14.20'), findsOneWidget);
    // With more than one key there is nothing to explain away.
    expect(find.textContaining('再接入更多 API Key'), findsNothing);
  });

  testWidgets('range chips re-query for the selected window', (tester) async {
    tester.view.physicalSize = const Size(1400, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap(const DashboardScreen()));
    await tester.pump();

    await tester.tap(find.text('今日'));
    await tester.pump();
    // Not logged in -> provider stays empty, dashboard keeps showing mock data.
    expect(find.textContaining('示例数据'), findsWidgets);

    await tester.tap(find.text('本周'));
    await tester.pump();
    expect(find.textContaining('示例数据'), findsWidgets);
  });

  testWidgets(
      'API-key mode labels the sample usage instead of passing it off as real',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final auth = AuthProvider()..setApiKey('sk-test');
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: auth),
        ChangeNotifierProvider(create: (_) => UsageProvider()),
      ],
      child: const MaterialApp(home: DashboardScreen()),
    ));
    await tester.pump();

    // The usage panels stay filled with examples rather than zeros, but the
    // label must be on screen. The balance fetch cannot succeed in a widget
    // test, so this is the "key saved, balance not in hand" wording.
    expect(find.textContaining('下面全是示例数据'), findsOneWidget);
    expect(find.textContaining('余额已同步为你的真实余额'), findsNothing);
    expect(find.text('解锁用量'), findsOneWidget);
    await openTab(tester, '花费');
    expect(find.text('模型级费用拆分'), findsOneWidget);
    // The header carries the same distinction as the notice.
    expect(find.textContaining('余额未取到'), findsOneWidget);
  });

  testWidgets('today plots hours, not days, and the metric lenses switch',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 3400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap(const DashboardScreen()));
    await tester.pump();

    await openTab(tester, '用量');
    // A month is a daily series.
    expect(find.text('每日趋势'), findsOneWidget);
    expect(find.text('31 天'), findsOneWidget);

    await tester.tap(find.text('今日'));
    await tester.pumpAndSettle();

    // A single day buckets by the hour, so it is NOT "24 days".
    expect(find.text('分时趋势'), findsOneWidget);
    expect(find.text('24 小时'), findsOneWidget);
    expect(find.text('每日趋势'), findsNothing);

    // The same chart carries tokens, requests and cost.
    // "Token" also appears on the analysis card, so match loosely there.
    expect(find.text('Token'), findsWidgets);
    expect(find.text('请求'), findsOneWidget);
    expect(find.text('金额'), findsOneWidget);
    await tester.tap(find.text('请求'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('金额'));
    await tester.pumpAndSettle();
    expect(find.text('分时趋势'), findsOneWidget);
  });

  testWidgets(
      'the custom range drops out of the chip instead of taking the page',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap(const DashboardScreen()));
    await tester.pump();

    await tester.tap(find.text('自定义'));
    await tester.pumpAndSettle();

    // A popover, not a takeover: the page is still behind it.
    expect(find.text('DeepSeek 用量监控'), findsOneWidget);
    expect(find.text('本月'), findsOneWidget);
    expect(find.text('确定'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);

    final now = DateTime.now();
    await tester.tap(find.byKey(ValueKey('day-${now.year}-${now.month}-3')));
    await tester.pump();
    await tester.tap(find.byKey(ValueKey('day-${now.year}-${now.month}-9')));
    await tester.pump();
    expect(find.textContaining('${now.month} 月 3 日'), findsOneWidget);

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    // The chip now carries the picked window and the calendar is gone.
    expect(find.text('确定'), findsNothing);
    // DateFormat('MM/dd') pads, so the chip reads "10/03 – 10/09"; the same
    // window also shows up in the KPI notes, hence findsWidgets.
    expect(find.textContaining('/03'), findsWidgets);
    expect(find.textContaining('/09'), findsWidgets);
    expect(find.text('自定义'), findsNothing);
  });

  testWidgets('a phone gets one slice at a time behind a bottom bar',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1300);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrap(const DashboardScreen()));
    await tester.pump();

    // The dock is our own floating pill, not the framework's full-width bar.
    expect(find.byType(NavigationBar), findsNothing);
    for (final label in ['概览', '用量', '花费', '设置']) {
      expect(find.text(label), findsOneWidget);
    }
    // Only the overview slice is built; the rest stays off the page.
    expect(find.text('Token 使用分析'), findsOneWidget);
    expect(find.text('每日趋势'), findsNothing);

    await tester.tap(find.text('用量'));
    await tester.pump();
    expect(find.text('每日趋势'), findsOneWidget);
    expect(find.text('Token 使用分析'), findsNothing);

    await tester.tap(find.text('花费'));
    await tester.pump();
    expect(find.text('模型级费用拆分'), findsOneWidget);
    expect(find.text('API Key 对比'), findsOneWidget);

    await tester.tap(find.text('设置'));
    await tester.pump();
    expect(find.text('凭据怎么用'), findsOneWidget);
    expect(find.text('不保存到本机'), findsOneWidget);
  });

  testWidgets('a wide screen keeps the same four slices as the phone',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 3600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrap(const DashboardScreen()));
    await tester.pump();

    // A wide window trades the floating dock for a rail, but the destinations
    // are the same four, and it is still one slice at a time — scrolling past
    // three panels to reach the fourth is the thing being fixed.
    for (final label in ['概览', '用量', '花费', '设置']) {
      expect(
        find.descendant(
            of: find.byType(NavigationRail), matching: find.text(label)),
        findsOneWidget,
      );
    }
    expect(find.byType(NavigationBar), findsNothing);

    // It lands on the overview, and the series is not on this slice.
    expect(find.text('Token 使用分析'), findsOneWidget);
    expect(find.text('每日趋势'), findsNothing);

    await openTab(tester, '用量');
    expect(find.text('每日趋势'), findsOneWidget);
    expect(find.text('模型级费用拆分'), findsNothing);

    await openTab(tester, '花费');
    expect(find.text('模型级费用拆分'), findsOneWidget);
    expect(find.text('API Key 对比'), findsOneWidget);
    expect(find.text('每日趋势'), findsNothing);

    await openTab(tester, '设置');
    expect(find.text('凭据怎么用'), findsOneWidget);
    expect(find.text('API Key 对比'), findsNothing);
  });

  group('the storage switch is wired to real behaviour', () {
    testWidgets('off means nothing is written, and what was written is erased',
        (tester) async {
      final auth = AuthProvider();
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: auth),
          ChangeNotifierProvider(create: (_) => UsageProvider()),
        ],
        child: const MaterialApp(home: Scaffold(body: PrivacyCard())),
      ));
      await tester.pump();

      // Default: the credential is on disk, so the copy says so.
      auth.setApiKey('sk-live');
      await tester.pumpAndSettle();
      var prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('api_key'), 'sk-live');
      expect(find.textContaining('凭据留在本机'), findsOneWidget);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('api_key'), isNull);
      expect(find.textContaining('凭据只在内存中'), findsOneWidget);
      // The key still works for this session, it just is not on disk.
      expect(auth.apiKey, 'sk-live');

      // And a later key never touches the disk either.
      auth.setApiKey('sk-second');
      await tester.pumpAndSettle();
      prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('api_key'), isNull);
      expect(auth.apiKey, 'sk-second');
    });
  });

  group('balanceLabel never invents a figure', () {
    test('no summary in hand renders a dash, not a sample number', () {
      expect(balanceLabel(null), '—');
      expect(balanceLabel(null), isNot(contains('40.41')));
    });

    test('a real balance renders as currency', () {
      expect(balanceLabel(2.27), '¥2.27');
      expect(balanceLabel(0), '¥0.00');
    });
  });

  group('sampleNoticeCopy never claims more than we hold', () {
    test('nothing connected: pure example', () {
      final c = sampleNoticeCopy(
          hasRealBalance: false, hasApiKey: false, browser: false);
      expect(c.text, contains('大肥鱼随手编的示例数据'));
      expect(c.action, '去连接');
    });

    test('key saved but balance missing: says so instead of claiming sync', () {
      final c = sampleNoticeCopy(
          hasRealBalance: false, hasApiKey: true, browser: false);
      expect(c.text, contains('还没取回来'));
      expect(c.text, contains('下面全是示例数据'));
      expect(c.text, isNot(contains('已同步')));
    });

    test('balance in hand: only the usage side is called an example', () {
      final c = sampleNoticeCopy(
          hasRealBalance: true, hasApiKey: true, browser: false);
      expect(c.text, contains('真实数字'));
      expect(c.text, contains('还是她编的示例'));
      expect(c.action, '解锁用量');
    });

    test('in a browser it names the block and where usage does work', () {
      final c = sampleNoticeCopy(
          hasRealBalance: true, hasApiKey: true, browser: true);
      // The token path is still offered in the sheet, so the honest thing is
      // to say why it will fail here rather than to hide it.
      expect(c.text, contains('跨域请求'));
      expect(c.text, contains('桌面或手机客户端'));
      expect(c.action, '解锁用量');
    });

    test('in a browser with nothing connected it offers both paths', () {
      final c = sampleNoticeCopy(
          hasRealBalance: false, hasApiKey: false, browser: true);
      expect(c.text, contains('令牌'));
      expect(c.text, contains('API Key'));
      expect(c.action, '去连接');
    });
  });

  testWidgets('header button opens the connect sheet', (tester) async {
    await tester.pumpWidget(wrap(const DashboardScreen()));
    await tester.pump();

    expect(find.byType(ConnectSheet), findsNothing);
    await tester.tap(find.text('连接账号'));
    await tester.pumpAndSettle();

    expect(find.byType(ConnectSheet), findsOneWidget);
    expect(find.text('连接 DeepSeek'), findsOneWidget);
  });

  testWidgets('connect sheet offers both credential paths and explains safety',
      (tester) async {
    await tester.pumpWidget(wrap(const Scaffold(body: ConnectSheet())));
    await tester.pump();

    // Web/Linux branch: no in-app webview, so the manual route is shown.
    debugForceTokenCapture = false;

    await tester.pumpWidget(wrap(const Scaffold(body: ConnectSheet())));
    await tester.pump();

    expect(find.text('连接 DeepSeek'), findsOneWidget);
    expect(find.textContaining('方式一 · 平台令牌'), findsOneWidget);
    expect(find.textContaining('方式二 · API Key'), findsOneWidget);
    expect(find.text('打开 DeepSeek 官方登录'), findsOneWidget);
    // The platform has no `userToken` field; the credential is the header value.
    expect(find.textContaining('Request Headers'), findsOneWidget);
    expect(find.textContaining('没有 userToken 这种字段'), findsOneWidget);
    // Trust copy: we never take the password.
    expect(find.textContaining('不碰你的账号密码'), findsOneWidget);
    expect(find.textContaining('只保存在本机'), findsOneWidget);
  });

  testWidgets('native builds offer the in-app login instead of F12 steps',
      (tester) async {
    // Android/iOS/macOS/Windows branch.
    debugForceTokenCapture = true;

    await tester.pumpWidget(wrap(const Scaffold(body: ConnectSheet())));
    await tester.pump();

    expect(find.text('在应用内登录并自动获取令牌'), findsOneWidget);
    // A native user must never be told to open devtools.
    expect(find.textContaining('Request Headers'), findsNothing);
    expect(find.text('打开 DeepSeek 官方登录'), findsNothing);
    // ...but the manual paste path stays available as a fallback.
    expect(find.text('验证并保存令牌'), findsOneWidget);
    expect(find.textContaining('账号密码只输入在官方页面上'), findsOneWidget);
  });

  testWidgets('saving an empty token reports an actionable error, no crash',
      (tester) async {
    await tester.pumpWidget(wrap(const Scaffold(body: ConnectSheet())));
    await tester.pump();

    await tester.tap(find.text('验证并保存令牌'));
    await tester.pump();

    expect(find.text('请先粘贴令牌'), findsOneWidget);
    // Nothing was persisted on a failed validation.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('token'), isNull);
  });

  testWidgets('secrets are masked by default and the eye reveals them',
      (tester) async {
    await tester.pumpWidget(wrap(const Scaffold(body: ConnectSheet())));
    await tester.pump();

    final fields = tester.widgetList<TextField>(find.byType(TextField));
    expect(fields.length, 2);
    // Both credential boxes are password-style out of the box.
    expect(fields.every((f) => f.obscureText), isTrue);
    expect(find.byTooltip('显示'), findsNWidgets(2));

    await tester.tap(find.byTooltip('显示').first);
    await tester.pump();

    final after = tester.widgetList<TextField>(find.byType(TextField)).toList();
    expect(after.first.obscureText, isFalse);
    expect(after.last.obscureText, isTrue, reason: 'the eye is per field');
    expect(find.byTooltip('隐藏'), findsOneWidget);
  });

  testWidgets('a stored token is shown as a masked tail, never echoed back',
      (tester) async {
    final auth = AuthProvider()..setToken('platform-token-abcd1234');

    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => auth),
        ChangeNotifierProvider(create: (_) => UsageProvider()),
      ],
      child: const MaterialApp(home: Scaffold(body: ConnectSheet())),
    ));
    await tester.pump();

    // The box starts empty; recognising which key is in use needs four digits.
    expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        isEmpty);
    expect(find.textContaining('••••1234'), findsOneWidget);
    expect(find.textContaining('platform-token-abcd1234'), findsNothing);
    // And the hint tells the user an empty box is not a mistake.
    expect(find.textContaining('留空则继续使用它'), findsOneWidget);
    expect(find.text('粘贴新令牌以替换'), findsOneWidget);
  });

  testWidgets('window math for each range is half-open and local',
      (tester) async {
    final today = windowFor(TimeRange.today);
    expect(today.end.difference(today.start), const Duration(days: 1));
    expect(today.start.hour, 0);

    final week = windowFor(TimeRange.week);
    expect(week.start.weekday, DateTime.monday);

    final month = windowFor(TimeRange.month);
    expect(month.start.day, 1);
    expect(month.end.day, 1);

    final custom = windowFor(TimeRange.custom,
        customStart: DateTime(2026, 3, 1), customEnd: DateTime(2026, 3, 3));
    expect(custom.start, DateTime(2026, 3, 1));
    expect(custom.end, DateTime(2026, 3, 4)); // end is exclusive
  });

  group('displayData decides what is real and what is an example', () {
    final realSummary = UserSummary(
      balances: [
        BalanceInfo(
            currency: 'CNY',
            totalBalance: 12.34,
            grantedBalance: 2.34,
            toppedUpBalance: 10),
      ],
      totalAvailableTokenEstimation: '1000000',
      currentToken: 42,
      totalCosts: 12.34,
    );

    test('with a platform token it shows exactly what was fetched', () {
      final fetched = UsageData(
        summary: realSummary,
        apiKeys: const [],
        trend: const [],
        rangeCost: 7.5,
        todayCost: 1.5,
        monthlyCost: 7.5,
        updatedAt: DateTime(2026, 10, 29),
      );
      final d = displayData(
          hasPlatformToken: true, hasApiKey: false, fetched: fetched);
      expect(d.rangeCost, 7.5);
      expect(d.summary!.balances.first.totalBalance, 12.34);
      expect(d.models, isEmpty); // no zero-padding, no sample rows
    });

    test('with a platform token but nothing fetched yet it shows zeros', () {
      final d =
          displayData(hasPlatformToken: true, hasApiKey: false, fetched: null);
      expect(d.rangeCost, 0);
      expect(d.totalTokens, 0);
      expect(d.summary, isNull);
    });

    test('API key only: real balance rides along with labelled sample usage',
        () {
      final fetched = UsageData(
        summary: realSummary,
        apiKeys: const [],
        trend: const [],
        rangeCost: 0,
        todayCost: 0,
        monthlyCost: 0,
        updatedAt: DateTime(2026, 10, 29),
      );
      final d = displayData(
          hasPlatformToken: false, hasApiKey: true, fetched: fetched);
      // Real balance survives…
      expect(d.summary!.balances.first.totalBalance, 12.34);
      // …while the usage side stays the sample set, and the numbers are the
      // documented sample ones so the label can never be wrong about what it is.
      expect(d.rangeCost, mockData().rangeCost);
      expect(d.apiKeys.length, 2);
      expect(d.cacheHitRate, closeTo(80.6, 0.05));
    });

    test('API key only with a failed fetch still shows the sample set', () {
      final d =
          displayData(hasPlatformToken: false, hasApiKey: true, fetched: null);
      // No balance, because we never got one and must not print a sample figure
      // beside a real connection.
      expect(d.summary, isNull);
      expect(d.rangeCost, mockData().rangeCost);
      expect(d.cacheHitRate, closeTo(80.6, 0.1));
    });

    test('nothing connected: the page is one labelled example, balance too',
        () {
      final d =
          displayData(hasPlatformToken: false, hasApiKey: false, fetched: null);
      expect(d.summary, isNotNull);
      expect(d.rangeCost, mockData().rangeCost);
    });
  });

  group('the credential story is told per platform, not once for everyone', () {
    test('a browser keeps credentials in the browser and copies by hand', () {
      debugForceBrowser = true;
      debugForceTokenCapture = false;
      final f = platformCredentialFacts;
      expect(f.where, '凭据保存在这个浏览器里');
      expect(f.howToken, '令牌就是 Authorization 请求头');
      expect(f.inAppLogin, isFalse);
    });

    test('an installed app keeps them on the device and can log in itself', () {
      debugForceBrowser = false;
      debugForceTokenCapture = true;
      final f = platformCredentialFacts;
      expect(f.where, '凭据保存在这台设备上');
      expect(f.howToken, '可以在应用内直接登录');
      expect(f.inAppLogin, isTrue);
    });

    test('an installed app with no webview falls back to the manual path', () {
      debugForceBrowser = false;
      debugForceTokenCapture = false;
      final f = platformCredentialFacts;
      expect(f.where, '凭据保存在这台设备上');
      expect(f.howToken, '令牌就是 Authorization 请求头');
      expect(f.inAppLogin, isFalse);
    });

    testWidgets('the settings card speaks browser on the web', (tester) async {
      debugForceBrowser = true;
      debugForceTokenCapture = false;
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wrap(const Scaffold(body: PrivacyCard())));
      await tester.pumpAndSettle();

      expect(find.text('凭据保存在这个浏览器里'), findsOneWidget);
      expect(find.text('凭据保存在这台设备上'), findsNothing);
      expect(find.text('令牌就是 Authorization 请求头'), findsOneWidget);
      expect(find.text('可以在应用内直接登录'), findsNothing);
      expect(find.textContaining('localStorage'), findsOneWidget);
      expect(find.textContaining('不会上传到任何第三方'), findsOneWidget);
    });

    testWidgets('the same card speaks device on an installed build',
        (tester) async {
      debugForceBrowser = false;
      debugForceTokenCapture = true;
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wrap(const Scaffold(body: PrivacyCard())));
      await tester.pumpAndSettle();

      expect(find.text('凭据保存在这台设备上'), findsOneWidget);
      expect(find.text('凭据保存在这个浏览器里'), findsNothing);
      expect(find.text('可以在应用内直接登录'), findsOneWidget);
      expect(find.text('令牌就是 Authorization 请求头'), findsNothing);
      // The promise that holds everywhere is still said exactly once.
      expect(find.textContaining('不会上传到任何第三方'), findsOneWidget);
    });

    testWidgets('the connect sheet footnote follows the platform too',
        (tester) async {
      debugForceBrowser = true;
      debugForceTokenCapture = false;
      await tester.pumpWidget(wrap(const Scaffold(body: ConnectSheet())));
      await tester.pump();
      expect(find.textContaining('凭据保存在这个浏览器里（localStorage）'), findsOneWidget);

      debugForceBrowser = false;
      await tester.pumpWidget(wrap(const Scaffold(body: ConnectSheet())));
      await tester.pump();
      expect(find.textContaining('凭据只保存在本机（应用数据）'), findsOneWidget);
    });
  });

  testWidgets(
      'on a device without a webview the sign-in address ships with '
      'the button', (tester) async {
    debugForceBrowser = false;
    debugForceTokenCapture = false;
    tester.view.physicalSize = const Size(1000, 2800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrap(const Scaffold(body: ConnectSheet())));
    await tester.pumpAndSettle();

    // A launch can be eaten by a popup blocker with no error anywhere, so the
    // address and a way to take it ship with the button, always.
    expect(find.text('打开 DeepSeek 官方登录'), findsOneWidget);
    expect(find.text('https://platform.deepseek.com/sign_in'), findsOneWidget);
    expect(find.text('复制地址'), findsOneWidget);
  });

  testWidgets('the web build offers both credential paths', (tester) async {
    debugForceBrowser = true;
    debugForceTokenCapture = false;
    tester.view.physicalSize = const Size(1000, 2800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrap(const Scaffold(body: ConnectSheet())));
    await tester.pumpAndSettle();

    // Both doors stay open on every platform; the browser one is explained
    // when it fails, not hidden up front.
    expect(find.text('方式一 · 平台令牌（推荐，含模型级用量）'), findsOneWidget);
    expect(find.text('粘贴平台令牌'), findsOneWidget);
    expect(find.text('验证并保存令牌'), findsOneWidget);
    expect(find.text('打开 DeepSeek 官方登录'), findsOneWidget);
    expect(find.text('https://platform.deepseek.com/sign_in'), findsOneWidget);
    expect(find.text('方式二 · API Key（只读余额）'), findsOneWidget);
    expect(find.text('验证并保存 API Key'), findsOneWidget);
  });
}
