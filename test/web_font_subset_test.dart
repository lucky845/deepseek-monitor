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

    // web/index.html preloads the CJK fallback because the engine only asks for
    // it after the first frame. The hint names the font by the hash the engine
    // generated, so a Flutter upgrade that changes that hash would turn the
    // hint into a 404 and quietly put the font back on the slow path.
    test('the preload hint points at the font the browser will fetch', () {
      final html = File('${root.path}/web/index.html').readAsStringSync();
      final hint = RegExp(r'<link[^>]*rel="preload"[^>]*>').firstMatch(html);
      expect(hint, isNotNull,
          reason: 'without this hint the CJK fallback starts downloading only '
              'after the first frame — ~3.4s later on 4G, and the swap reflows '
              'the page once it lands');
      final href =
          RegExp(r'href="([^"]+)"').firstMatch(hint!.group(0)!)!.group(1)!;
      expect('web/$href', info['noto.dst'],
          reason: 'the hint preloads $href but the build ships '
              '${info['noto.dst']} — the hashed filename changed, so the hint '
              'now 404s. Point web/index.html at the shipped font');
      expect(File('${root.path}/web/$href').existsSync(), isTrue,
          reason: 'web/$href is what every visitor preloads');
    });
  });
}
