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
}
