// What `web/index.html` is allowed to preload decides how long the user stares
// at the boot skeleton. Preloading the wrong thing does not just fail to help —
// it costs a full extra download on the critical path, which is exactly what
// happened when `canvaskit.wasm` was preloaded from the wrong directory.
//
// These assertions are cheap (they read two files) and they fail loudly at
// review time instead of quietly adding seconds to the first paint.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Where the engine's own runtime assets are served from when the app opts
/// back into the CDN. See the comment in `web/flutter_bootstrap.js`.
const String engineCdnPrefix =
    'https://www.gstatic.com/flutter-canvaskit/';

Directory projectRoot() {
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('no pubspec.yaml above ${Directory.current.path}');
    }
    dir = parent;
  }
  return dir;
}

/// The `href` of every `<link rel="preload">` in the page.
List<String> preloadHrefs(String html) {
  final out = <String>[];
  final link = RegExp(r'<link\b[^>]*>', caseSensitive: false);
  for (final m in link.allMatches(html)) {
    final tag = m.group(0)!;
    if (!RegExp(r'rel\s*=\s*"preload"', caseSensitive: false).hasMatch(tag)) {
      continue;
    }
    final href = RegExp(r'href\s*=\s*"([^"]+)"').firstMatch(tag);
    if (href != null) out.add(href.group(1)!);
  }
  return out;
}

/// The [rel, as, href] triples of the links the page injects from script.
///
/// The wasm boot chain is injected via JS rather than written as static
/// `<link>` tags, because the injection has to be conditional on WasmGC
/// support. That makes it invisible to [preloadHrefs], so it needs its own
/// parser — otherwise a typo there would ship a 404 on the critical path with
/// every test still green.
List<List<String?>> injectedLinks(String html) {
  final listStart = html.indexOf('var links = [');
  if (listStart < 0) return const [];
  final listEnd = html.indexOf('];', listStart);
  if (listEnd < 0) return const [];
  final body = html.substring(html.indexOf('[', listStart) + 1, listEnd);
  final out = <List<String?>>[];
  for (final m in RegExp(r"\[([^\]]*)\]").allMatches(body)) {
    final cells = m
        .group(1)!
        .split(',')
        .map((c) => c.trim())
        .map((c) => c == 'null' ? null : c.replaceAll("'", ''))
        .toList();
    if (cells.length >= 3) out.add(cells);
  }
  return out;
}

/// The WasmGC probe bytes the engine itself uses to pick between the wasm and
/// the js build. The page must ask the exact same question: a *different*
/// probe means the page can preload for a build the engine will not take.
///
/// Anchored on the wasm magic number (0, 97, 115, 109 = "\\0asm") so it cannot
/// latch onto some unrelated numeric array in the minified engine bundle.
List<int> wasmGcProbe(String source) {
  final m = RegExp(r"\[\s*0\s*,\s*97\s*,\s*115\s*,\s*109\b[^\]]*\]")
      .firstMatch(source);
  if (m == null) return const [];
  final body = m.group(0)!.substring(1, m.group(0)!.length - 1);
  return body.split(',').map((s) => int.parse(s.trim())).toList();
}

/// Root of the Flutter SDK that owns the runner executing this test.
Directory? engineSdkRoot() {
  var dir = Directory(Platform.resolvedExecutable).parent;
  for (var i = 0; i < 8; i++) {
    if (File('${dir.path}/bin/internal/engine.version').existsSync()) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

/// `flutter_js/flutter.js` inside the Flutter SDK running this test. The
/// source-tree `web/flutter_bootstrap.js` only carries a `{{flutter_js}}`
/// placeholder, so the probe bytes live here, in the SDK.
File? engineFlutterJs() {
  final sdk = engineSdkRoot();
  if (sdk == null) return null;
  final candidate = File('${sdk.path}/bin/cache/flutter_web_sdk/flutter_js/flutter.js');
  return candidate.existsSync() ? candidate : null;
}

void main() {
  late String html;

  setUpAll(() {
    html = File('${projectRoot().path}/web/index.html').readAsStringSync();
  });

  test('the page never preloads canvaskit.wasm', () {
    // The engine picks a variant by browser: Chromium gets
    // canvaskit/chromium/canvaskit.wasm (5.4MB), TextCluster-capable builds get
    // canvaskit/webparagraph/. Preloading the root canvaskit/canvaskit.wasm
    // downloads 7.3MB that nothing reads, then the engine downloads its own
    // copy on top — measured as +1.28s on the first paint.
    final offending =
        preloadHrefs(html).where((h) => h.contains('canvaskit')).toList();
    expect(
      offending,
      isEmpty,
      reason: 'canvaskit 由引擎按变体自己取，页面预取会白下一份完整 wasm。'
          '详见 web/index.html 里的注释。',
    );
  });

  test('every preloaded file actually exists in the source tree', () {
    // A typo'd or stale hash in a preload href is a silent 404 plus a wasted
    // connection, and the font hash is engine-generated so it can drift when
    // Flutter upgrades.
    final root = projectRoot();
    for (final href in preloadHrefs(html)) {
      if (href.startsWith('http://') || href.startsWith('https://')) continue;
      final path = '${root.path}/web/${href.replaceFirst(RegExp(r'^/+'), '')}';
      expect(File(path).existsSync(), isTrue,
          reason: 'preload 指向的 $href 在 web/ 下不存在，浏览器会 404');
    }
  });

  test('the font fallback stays same-origin', () {
    // fonts.gstatic.com is unreachable from mainland China, and the engine
    // would silently fall back to it if this line ever lost the override.
    final boot =
        File('${projectRoot().path}/web/flutter_bootstrap.js').readAsStringSync();
    expect(boot, contains("fontFallbackBaseUrl: 'fonts/'"),
        reason: '中文字体兜底必须从本站取，否则国内打开是长时间没有字');
  });
  test('the wasm boot chain is preloaded as one shot, not hop by hop', () {
    // The engine discovers its own boot chain serially: bootstrap -> main.dart.mjs
    // -> skwasm.js/wasm + main.dart.wasm. Each hop costs a round trip while the
    // 2.5MB of payload sits idle. Preloading all five at parse time measured
    // -316ms on Fast 4G and -339ms on broadband (paired, same HTTP/2 server).
    final links = injectedLinks(html);
    expect(links, hasLength(10), reason: '预取清单被改动，请同步更新注释与实测数据');

    final byHref = {for (final l in links) l[2]!: l};
    // The two engine files carry an absolute gstatic URL, so look them up by
    // suffix; the rest are same-origin literals.
    List<String?>? find(String suffix) {
      for (final e in byHref.entries) {
        if (e.key == suffix || e.key.endsWith('/$suffix')) return e.value;
      }
      return null;
    }

    for (final href in <String>[
      'flutter_bootstrap.js',
      'main.dart.mjs',
      'main.dart.wasm',
    ]) {
      expect(byHref.containsKey(href), isTrue, reason: '$href 掉出了预取清单');
    }
    for (final suffix in <String>['skwasm.js', 'skwasm.wasm']) {
      expect(find(suffix), isNotNull, reason: '$suffix 掉出了预取清单');
    }

    // ES modules must use modulepreload; preload as=script leaves a second,
    // uncached copy behind — measured as +17,354 bytes and a slower first frame.
    expect(byHref['main.dart.mjs']![0], 'modulepreload');
    expect(find('skwasm.js')![0], 'modulepreload');
    for (final suffix in <String>['skwasm.wasm', 'main.dart.wasm']) {
      final l = byHref[suffix] ?? find(suffix)!;
      expect(l[0], 'preload');
      expect(l[1], 'fetch');
      // crossOrigin is mandatory for a fetch preload, cross-origin or not:
      // the engine fetches wasm in CORS mode, and a no-cors preload is a
      // different cache entry — it would download twice.
      expect(l[3], 'true', reason: '$suffix 的预取必须带 crossorigin');
    }

    // Everything except the two engine files must stay same-origin: a third
    // party preload costs an extra connection setup on the critical path.
    for (final href in byHref.keys) {
      if (href.startsWith(engineCdnPrefix)) continue;
      expect(href.startsWith('http'), isFalse, reason: '$href 必须是同源路径');
    }

    // The two engine files come from gstatic because Cloudflare cannot serve
    // brotli of the original stream: on this domain skwasm.wasm is gzip
    // 1,551,371B (CF re-compresses the origin's gzip at ~q4), while gstatic
    // serves br q11 1,225,993B — the same bytes, 21% smaller. Measured end to
    // end: -261ms on Fast 4G, -1482ms on Slow 3G, +77ms on broadband.
    //
    // The URL embeds the engine revision, so it must be the revision the SDK
    // running this test would build against; a stale hash is a 404 sitting on
    // the critical path (the page would still render, from a much slower path).
    for (final name in <String>['skwasm.js', 'skwasm.wasm']) {
      final href = byHref.keys.firstWhere((h) => h.startsWith(engineCdnPrefix) && h.endsWith('/$name'),
          orElse: () => '');
      expect(href, isNotEmpty, reason: '$name 没有指向 gstatic，会退回 gzip 那份（多 325KB）');
    }

    final engineRev = File(
            '${engineSdkRoot()?.path}/bin/internal/engine.version')
        .existsSync()
        ? File('${engineSdkRoot()!.path}/bin/internal/engine.version')
            .readAsStringSync()
            .trim()
        : null;
    if (engineRev != null && engineRev.isNotEmpty) {
      for (final href in byHref.keys.where((h) => h.startsWith(engineCdnPrefix))) {
        expect(href, contains('/$engineRev/'),
            reason: 'gstatic 地址里的引擎版本与 SDK 的 engine.version 不一致，'
                'Flutter 升级后会 404');
      }
    }
  });

  test('the font and manifest tail is preloaded too, aft of the wasm chain', () {
    // Once the engine has its wasm it still walks a serial chain of tiny
    // requests — FontManifest.json (298B) -> the three font files ->
    // AssetManifest.bin.json — each waiting for the previous round trip. On the
    // production page the manifest only completed at 1542->1781ms, after every
    // wasm had already arrived. Preloading the five measured -86ms on Fast 4G,
    // -45ms on broadband and -193ms on Slow 3G with zero extra bytes.
    final links = injectedLinks(html);
    final byHref = {for (final l in links) l[2]!: l};

    const tail = <String>[
      'assets/FontManifest.json',
      'assets/AssetManifest.bin.json',
      'assets/fonts/MaterialIcons-Regular.otf',
      'assets/fonts/roboto/v20/KFOmCnqEu92Fr1Me5WZLCzYlKw.ttf',
      'assets/packages/cupertino_icons/assets/CupertinoIcons.ttf',
    ];

    for (final href in tail) {
      expect(byHref.containsKey(href), isTrue,
          reason: '$href 掉出了预取清单，后段会退回串行 RTT');
      // JSON/font payloads are not scripts: preload as=fetch is the only rel
      // that both warms the HTTP cache and stays invisible to the module graph.
      expect(byHref[href]![0], 'preload', reason: '$href 必须用 preload');
      expect(byHref[href]![1], 'fetch', reason: '$href 必须以 fetch 预取');
      // CanvasKit fetches fonts in CORS mode; a preload without crossorigin
      // is no-cors and therefore a *different* cache entry, which would make
      // the engine download the file a second time. Measured: keeping it gives
      // 23 requests / 2,739,484B in both arms -- no duplicate fetch.
      expect(byHref[href]![3], 'true',
          reason: '$href 必须带 crossorigin，否则与引擎的 CORS 抓取不是同一条缓存项');
    }
  });

  test('the loader config sends the engine wasm to gstatic, by engineRevision', () {
    // Hard-coding the revision in the loader config would 404 on the next
    // Flutter upgrade, so it is derived from buildConfig.engineRevision at
    // runtime — and when that is missing the config must fall back to the
    // same-origin copy rather than point at a half-built URL.
    final boot = File('${projectRoot().path}/web/flutter_bootstrap.js')
        .readAsStringSync();
    expect(boot, contains('canvasKitBaseUrl'),
        reason: 'canvasKitBaseUrl 丢了，引擎 wasm 会退回本站的 gzip 那份（多 325KB）');
    expect(boot, contains('engineRevision'),
        reason: 'canvasKitBaseUrl 必须由 buildConfig.engineRevision 现算，不能写死版本号');
    expect(boot, contains('https://www.gstatic.com/flutter-canvaskit/'),
        reason: 'canvasKitBaseUrl 必须指向 gstatic 的 frankenstein 目录');
    // The fallback is the absence of the key, not a broken URL: if the
    // revision is unknown the loader keeps using canvaskit/ next to the app.
    expect(boot, isNot(contains("canvasKitBaseUrl = 'canvaskit")),
        reason: '缺副本时的兜底应当靠「不设这个 key」，而不是写一个本地绝对路径');
  });

  test('the boot shell is a real dashboard replica that stays off the network', () {
    // The shell covers the ~2s while both wasms download+compile. It used to be
    // a centered logo on a plain gradient, so the canvas swap was a visible jump.
    // It now mirrors the real dashboard layout. But it is a *transient* layer:
    // any web font or mascot image it references would duplicate a download the
    // engine already makes (preload as=fetch vs CSS as=font are different cache
    // entries) — measured +42KB and +100ms on Fast 4G. So it must stay fully
    // self-contained: system fonts, geometric glyphs, CSS-drawn avatar.
    expect(html, contains('<div id="boot-skeleton"'),
        reason: '真壳 DOM 消失了，首屏会退回白屏');
    for (final marker in <String>[
      'class="kpi pane', // the eight KPI cards
      'class="notice pane', // the sample-data notice
      'class="chip', // the four range chips
      'class="panel pane', // the Token breakdown
      'Token 使用分析',
    ]) {
      expect(html, contains(marker),
          reason: '真壳缺少 $marker，画布接管时会跳变');
    }
    expect(html, isNot(contains('@font-face')),
        reason: '真壳不能引 web 字体：与引擎的 as=fetch 预取不是同一缓存项，会重复下载 +42KB');
    expect(html, isNot(contains('mascot.webp')),
        reason: '真壳不能引 mascot 图：它本是首帧后才异步加载，提前引用会挤占 wasm 带宽');
    // The fade-out MUST be a compositor animation, not a JS setTimeout +
    // transition: the main thread is blocked by wasm compilation when the first
    // frame arrives, and a style-recalc-driven fade would leave the shell
    // covering the app for hundreds of ms.
    expect(html, contains('@keyframes bs-out'),
        reason: '合成线程淡出动画丢了，wasm 编译长任务会卡住骨架淡出');
    expect(html, contains('#boot-skeleton[data-done="1"]'),
        reason: '首帧回调设置 data-done=1 后必须有对应的淡出规则');
  });

  test('the page gates the wasm preloads on the same WasmGC probe as the engine',
      () {
    // index.html is shared by the js and the wasm build. A browser without
    // WasmGC falls back to main.dart.js + canvaskit.wasm (3.2MB) and reads none
    // of the five preloaded files — so an ungated page would waste 2.5MB on
    // exactly the browsers that are already slowest. Verified both ways: with
    // the gate the fallback path transfers byte-for-byte what it did before.
    final page = wasmGcProbe(html);
    expect(page, isNotEmpty, reason: 'WasmGC 探针消失了，预取会在回退分支白下 2.5MB');

    final engine = engineFlutterJs();
    if (engine == null) {
      // Unusual layout (no SDK next to the test runner). Fall back to the
      // known engine probe so a mangled page still fails loudly.
      expect(page, equals(<int>[0, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 95, 1, 120, 0]),
          reason: '页面探针与引擎已知的 WasmGC 探针不一致');
      return;
    }
    final boot = wasmGcProbe(engine.readAsStringSync());
    expect(boot, isNotEmpty, reason: '引擎侧的探针格式变了，页面这份需要跟着改');
    expect(page, equals(boot),
        reason: '页面探针必须与 flutter.js 里 B() 的字节逐字节一致，'
            '否则会出现「页面预取了 wasm 构建、引擎却走 js 回退」');
  });

}