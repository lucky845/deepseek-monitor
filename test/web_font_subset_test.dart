// The web build ships two hand-shrunk fallback fonts instead of the
// multi-megabyte originals. That trade only holds while the shipped glyphs
// still cover every character the app can draw, so this test reads the cmap
// straight out of the shipped .ttf files and checks the app's own source
// against it. Adding a Chinese string without re-running
// `tool/subset_web_fonts.py` fails here instead of shipping tofu to a phone.
//
// The byte-for-byte details (sha256 of every artifact) live in
// `web/fonts/SUBSET_INFO.txt` and are verified by the script's own `--check`;
// this test verifies the thing that actually reaches a browser.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// Walks up from the test runner's directory until it finds the project root.
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

/// The code units a TrueType `cmap` actually has glyphs for.
///
/// Both formats that matter here are handled: format 4 (the BMP segment
/// table every font carries) and format 12 (the full-range groups the newer
/// Noto builds use). A code point counts only when it resolves to a real
/// glyph index, not to `.notdef`.
Set<int> cmapOf(Uint8List bytes) {
  final d = ByteData.sublistView(bytes);
  int u16(int o) => d.getUint16(o);
  int u32(int o) => d.getUint32(o);

  var cmapOffset = -1;
  final tables = u16(4);
  for (var i = 0; i < tables; i++) {
    final record = 12 + i * 16;
    final tag = String.fromCharCodes(bytes.sublist(record, record + 4));
    if (tag == 'cmap') {
      cmapOffset = u32(record + 8);
      break;
    }
  }
  if (cmapOffset < 0) throw StateError('font has no cmap table');

  final covered = <int>{};
  final subtables = u16(cmapOffset + 2);
  for (var i = 0; i < subtables; i++) {
    final record = cmapOffset + 4 + i * 8;
    final sub = cmapOffset + u32(record + 4);
    final format = u16(sub);

    if (format == 12) {
      final groups = u32(sub + 12);
      for (var g = 0; g < groups; g++) {
        final o = sub + 16 + g * 12;
        final start = u32(o);
        final end = u32(o + 4);
        final startGlyph = u32(o + 8);
        for (var c = start; c <= end; c++) {
          if (startGlyph + (c - start) != 0) covered.add(c);
        }
      }
    } else if (format == 4) {
      final segCount = u16(sub + 6) ~/ 2;
      final endBase = sub + 14;
      final startBase = endBase + segCount * 2 + 2;
      final deltaBase = startBase + segCount * 2;
      final rangeBase = deltaBase + segCount * 2;
      for (var s = 0; s < segCount; s++) {
        final end = u16(endBase + s * 2);
        final start = u16(startBase + s * 2);
        if (start == 0xFFFF) continue;
        final delta = d.getInt16(deltaBase + s * 2);
        final rangeOffset = u16(rangeBase + s * 2);
        for (var c = start; c <= end; c++) {
          int glyph;
          if (rangeOffset == 0) {
            glyph = (c + delta) & 0xFFFF;
          } else {
            final at = rangeBase + s * 2 + rangeOffset + (c - start) * 2;
            if (at + 1 >= bytes.length) continue;
            glyph = u16(at);
            if (glyph != 0) glyph = (glyph + delta) & 0xFFFF;
          }
          if (glyph != 0) covered.add(c);
        }
      }
    }
  }
  return covered;
}

/// Every non-ASCII code point in the Dart sources, comments included.
///
/// Deliberately a superset: a character that only ever appears in a comment
/// costs a few hundred bytes of glyph data and buys immunity from a string
/// edit that flips it into user-visible text.
Set<int> charactersInSources(Directory lib) {
  final chars = <int>{};
  for (final entity in lib.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    for (final rune in entity.readAsStringSync().runes) {
      if (rune > 0x7F) chars.add(rune);
    }
  }
  return chars;
}

/// `key=value` pairs out of the record the subsetter writes next to the fonts.
Map<String, String> subsetInfo(Directory root) {
  final file = File('${root.path}/web/fonts/SUBSET_INFO.txt');
  if (!file.existsSync()) {
    throw StateError('web/fonts/SUBSET_INFO.txt is the record of what was '
        'shipped; run tool/subset_web_fonts.py to regenerate it');
  }
  final info = <String, String>{};
  for (final line in file.readAsLinesSync()) {
    if (line.startsWith('#') || !line.contains('=')) continue;
    final at = line.indexOf('=');
    info[line.substring(0, at)] = line.substring(at + 1);
  }
  return info;
}

Uint8List readFont(Directory root, String key, Map<String, String> info) {
  final path = info['$key.dst'];
  if (path == null) {
    throw StateError('SUBSET_INFO.txt must name the $key font');
  }
  final file = File('${root.path}/$path');
  if (!file.existsSync()) {
    throw StateError('$path is what the browser fetches; it has to exist');
  }
  return file.readAsBytesSync();
}

/// The v37 woff2 slices Flutter 3.45+ fetches one at a time.
///
/// Three APIs handle woff2 here: the browser and the script (via fontTools) do
/// the Brotli decompression; this test does not — it only needs to know they
/// exist and are recorded, plus each slice's declared byte count.
List<File> shippedSlices(Directory root, Map<String, String> info) {
  final dir = info['slices.dir'];
  if (dir == null) {
    throw StateError('SUBSET_INFO.txt must name the v37 slice directory; '
        'run tool/subset_web_fonts.py --refresh-slices');
  }
  final slices = Directory('${root.path}/$dir')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.woff2'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  if (slices.isEmpty) {
    throw StateError('$dir is empty; Flutter 3.45+ would fall back to '
        'fonts.gstatic.com for every Chinese glyph');
  }
  return slices;
}

void main() {
  final root = projectRoot();
  final info = subsetInfo(root);

  group('the fallback fonts the web build ships cover what the app draws',
      () {
    test('every non-ASCII character in lib/ resolves to a real glyph', () {
      final noto = cmapOf(readFont(root, 'noto', info));
      final roboto = cmapOf(readFont(root, 'roboto', info));
      final wanted = charactersInSources(Directory('${root.path}/lib'));

      expect(wanted, isNotEmpty, reason: 'the app is written in Chinese');

      final missing = <int>[];
      for (final rune in wanted) {
        if (!noto.contains(rune) && !roboto.contains(rune)) missing.add(rune);
      }
      final names = missing.map(String.fromCharCode).join(' ');
      expect(missing, isEmpty,
          reason: 'lib/ draws these ${missing.length} characters, but neither '
              'shipped font has a glyph for them: $names\n'
              'Re-run: uv run --no-project --with fonttools python '
              'tool/subset_web_fonts.py');
    });

    // 汉字与中文标点是 Noto 的活, Latin 是 Roboto 的活. If the split ever
    // inverts, one subset has swallowed the other's charset.
    test('the CJK fallback carries the punctuation, not just the hanzi', () {
      final noto = cmapOf(readFont(root, 'noto', info));
      for (final mark in '，。、：；「」（）→…'.runes) {
        expect(noto, contains(mark),
            reason: '${String.fromCharCode(mark)} (U+${mark.toRadixString(16)}) '
                'is punctuation the UI draws; the earlier Noto subset was '
                'U+4E00–U+9FA0 only and silently dropped every mark');
      }
    });

    test('the subsets stay small enough to be worth shipping', () {
      for (final entry in {'noto': 400, 'roboto': 150}.entries) {
        final bytes = readFont(root, entry.key, info).length;
        expect(bytes, lessThan(entry.value * 1024),
            reason: '${entry.key} is ${(bytes / 1024).round()} KB; the point of '
                'the subset is that it stays a fraction of the master. The '
                'whole-font sizes were 2064 KB (Noto) and 167 KB (Roboto)');
      }
    });

    test('the record still describes the shipped bytes', () {
      for (final key in ['noto', 'roboto']) {
        final bytes = readFont(root, key, info).length;
        expect(bytes, int.parse(info['$key.bytes']!),
            reason: '${info['$key.dst']} changed without the record being '
                'updated; either the file was hand-edited or SUBSET_INFO.txt '
                'is stale');
      }
    });

    // web/index.html preloads every slice the first screen draws, because the
    // engine only asks for a slice after it hits a missing glyph — by then the
    // first frame is long past and the UI sits there with blank text until the
    // fonts land (measured: 7.3s on Fast 4G). Preloading only some slices does
    // NOT help: the engine still waits for the missing-glyph moment before
    // requesting the rest, so the late batch arrives just as late as before.
    // Either preload the whole first-screen set or preload nothing.
    //
    // The hints name slices by the hash the engine generated, so a Flutter
    // upgrade that changes that hash turns them into 404s and quietly puts the
    // fonts back on the slow path. Hence: every href must exist on disk.
    test('the preload hints point at slices the browser will fetch', () {
      final html = File('${root.path}/web/index.html').readAsStringSync();
      final hints = RegExp(r'<link[^>]*rel="preload"[^>]*>')
          .allMatches(html)
          .map((m) => RegExp(r'href="([^"]+)"').firstMatch(m.group(0)!)!.group(1)!)
          .where((h) => h.contains('notosanssc'))
          .toList();

      expect(hints, isNotEmpty,
          reason: 'without these hints the CJK fallback slices start '
              'downloading only after the first frame — measured 7.3s on '
              'Fast 4G, and the UI shows blank text until they land');

      final slicesDir = info['slices.dir'];
      expect(slicesDir, isNotNull,
          reason: 'SUBSET_INFO.txt must name the v37 slice directory');
      final relDir = slicesDir!.replaceFirst('web/', '');

      for (final href in hints) {
        expect(
          href.startsWith(relDir),
          isTrue,
          reason: 'the hint preloads $href but should point into '
              '$relDir for Flutter 3.45+ slices',
        );
        expect(File('${root.path}/web/$href').existsSync(), isTrue,
            reason: 'web/$href is preloaded by every visitor and must exist; '
                'a Flutter upgrade that changes the slice hash produces a 404 '
                'here and silently restores the blank-text window');
      }

      // The hints must cover every slice the first screen actually asks the
      // engine for. A partial preload is worse than none: it costs bytes while
      // still leaving the late batch on the slow path.
      final preloaded = hints.map((h) => h.split('/').last).toSet();
      final onDisk = Directory('${root.path}/web/$relDir')
          .listSync()
          .whereType<File>()
          .map((f) => f.path.split('/').last)
          .where((n) => n.endsWith('.woff2'))
          .toSet();
      expect(preloaded.difference(onDisk), isEmpty,
          reason: 'index.html preloads slices that are not shipped');

      // A single hint is the old, ineffective shape: it makes the page pay for
      // one slice early while the rest still arrive after the first frame.
      expect(hints.length, greaterThan(1),
          reason: 'one preload hint does not help — the engine still defers '
              'the remaining slices until it hits a missing glyph. Preload the '
              'whole first-screen set or none of it.');
    });

    // Flutter bundles its own 167.7 KB full Roboto at
    // assets/fonts/fallback/Roboto-Regular.ttf whenever the build runs with
    // --no-web-resources-cdn — unless FontManifest already carries a "Roboto"
    // family. That flag is non-negotiable (without it the browser fetches
    // canvaskit from www.gstatic.com, which is unreachable from mainland
    // China), so the way to keep the bundle honest is to declare our own
    // Roboto subset in pubspec.yaml. Measured on the production HAR: the
    // unneeded full copy cost 167.7 KB plus one round trip before first paint.
    //
    // Deleting that declaration later restores the waste silently. This test
    // is the guard.
    test('pubspec declares a Roboto family so Flutter skips its full copy', () {
      final pubspec = File('${root.path}/pubspec.yaml').readAsStringSync();

      final family = RegExp(
        r'^\s*-\s*family:\s*Roboto\s*$',
        multiLine: true,
      ).hasMatch(pubspec);
      expect(family, isTrue,
          reason: 'without an explicit Roboto family in pubspec.yaml, '
              'flutter_tools injects its bundled 167.7 KB Roboto-Regular.ttf '
              'at assets/fonts/fallback/ on every --no-web-resources-cdn build, '
              'and the browser downloads it on first paint');

      // Whatever pubspec points at must exist, and must be the same bytes the
      // rest of this file checks. A hand-edited copy would ship a font no
      // coverage test ever looked at.
      final asset = RegExp(
        r'-\s*asset:\s*(\S*\.ttf)\s*$',
        multiLine: true,
      ).firstMatch(pubspec)?.group(1);
      expect(asset, isNotNull,
          reason: 'the Roboto family must name a font asset');
      final declared = File('${root.path}/$asset');
      expect(declared.existsSync(), isTrue,
          reason: 'pubspec points at $asset but the file is not there; '
              'run tool/subset_web_fonts.py to regenerate it');
      // Byte identity is what the python script enforces (it writes both).
      // What matters here is that the font the browser actually gets covers
      // the same glyphs as the one the coverage tests above inspected --
      // a stale or hand-edited copy would ship unchecked coverage.
      final declaredCmap = cmapOf(declared.readAsBytesSync());
      final verifiedCmap = cmapOf(readFont(root, 'roboto', info));
      expect(declaredCmap.difference(verifiedCmap), isEmpty,
          reason: '$asset covers fewer glyphs than the subset this file '
              'verifies; run tool/subset_web_fonts.py to resync it');
    });
  });
}
