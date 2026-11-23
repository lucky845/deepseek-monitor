// What `web/index.html` is allowed to preload decides how long the user stares
// at the boot skeleton. Preloading the wrong thing does not just fail to help —
// it costs a full extra download on the critical path, which is exactly what
// happened when `canvaskit.wasm` was preloaded from the wrong directory.
//
// These assertions are cheap (they read two files) and they fail loudly at
// review time instead of quietly adding seconds to the first paint.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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

/// `flutter_js/flutter.js` inside the Flutter SDK running this test. The
/// source-tree `web/flutter_bootstrap.js` only carries a `{{flutter_js}}`
/// placeholder, so the probe bytes live here, in the SDK.
File? engineFlutterJs() {
  var dir = Directory(Platform.resolvedExecutable).parent;
  for (var i = 0; i < 6; i++) {
    final candidate = File('${dir.path}/flutter_web_sdk/flutter_js/flutter.js');
    if (candidate.existsSync()) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
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
    expect(links, hasLength(5), reason: '预取清单被改动，请同步更新注释与实测数据');

    final byHref = {for (final l in links) l[2]!: l};
    expect(byHref.keys, containsAll(<String>[
      'flutter_bootstrap.js',
      'main.dart.mjs',
      'canvaskit/skwasm.js',
      'canvaskit/skwasm.wasm',
      'main.dart.wasm',
    ]));

    // ES modules must use modulepreload; preload as=script leaves a second,
    // uncached copy behind — measured as +17,354 bytes and a slower first frame.
    expect(byHref['main.dart.mjs']![0], 'modulepreload');
    expect(byHref['canvaskit/skwasm.js']![0], 'modulepreload');
    for (final wasm in ['canvaskit/skwasm.wasm', 'main.dart.wasm']) {
      expect(byHref[wasm]![0], 'preload');
      expect(byHref[wasm]![1], 'fetch');
    }

    // Same-origin only, or the preload burns a connection to another host.
    for (final href in byHref.keys) {
      expect(href.startsWith('http'), isFalse, reason: '$href 必须是同源路径');
    }
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