// The page can only be as small as the build that produced it, and the build
// flags live in .github/workflows/build.yml — a file nobody watches until the
// first paint regresses by 100ms. These assertions put the flag under the same
// test run as the rest of the boot path.
//
// The flag in question is -O4. flutter_tools deliberately compiles wasm at
// -O2 in release (only sound optimizations), so raising it is a *decision*
// with a cost, not a default that was forgotten. The test checks that the
// decision is still in place and that the comment explaining it survives.
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

String workflow() =>
    File('${projectRoot().path}/.github/workflows/build.yml').readAsStringSync();

void main() {
  test('the web build compiles wasm at -O4', () {
    // Measured on the real build (local HTTP/2, paired, same server):
    //   main.dart.wasm 2,457,614 -> 2,383,758 B (gzip 911,115 -> 887,280, -2.6%)
    //   main.dart.js   3,062,049 -> 2,926,070 B (gzip 901,266 -> 861,135, -4.5%)
    //   first frame Fast4G -23ms (8/8 runs), Slow3G -112ms (5/5), broadband
    //   inside the noise (-1ms). Total 1,186,506 -> 1,162,671 B.
    // Without -O4 the first-paint gains silently revert, so this is checked.
    final yml = workflow();
    final buildLine = yml
        .split('\n')
        .where((l) => l.contains('flutter build web'))
        .toList();
    expect(buildLine, isNotEmpty, reason: 'build.yml 里找不到 flutter build web');

    // The command is a folded YAML scalar spread over several lines, so the
    // flag is not on the same line as `flutter build web`.
    final start = yml.indexOf('flutter build web');
    final end = yml.indexOf('--dart-define', start);
    expect(end, greaterThan(start), reason: '构建命令的结尾被改动了，请同步更新本测试');
    final command = yml.substring(start, end);

    expect(command, contains('-O4'),
        reason: '-O4 掉了，wasm 会退回 -O2：多 23,835B gzip，Fast4G 首帧 +23ms');
    expect(command, contains('--wasm'),
        reason: '--wasm 决定了走 dart2wasm，去掉会改为纯 js 构建');
  });

  test('the -O4 flag ships with the reason it is not the default', () {
    // Someone reading this in six months has to be able to tell that -O4 is a
    // deliberate trade (wasm soundness checks dropped for size) and how to
    // undo it. A bare flag with no explanation reads like a copy-paste.
    final yml = workflow();
    final lines = yml.split('\n');
    final runLine = lines.indexWhere((l) => l.contains('flutter build web'));
    expect(runLine, greaterThan(0), reason: 'build.yml 里找不到 flutter build web');

    // The command is a folded scalar: `- run: >-` on one line, the flags on
    // the ones after it. Find the step header, then walk up its # block.
    var step = runLine;
    while (step > 0 && !lines[step].trimLeft().startsWith('- run:')) {
      step--;
    }
    expect(lines[step].trimLeft(), startsWith('- run:'),
        reason: 'flutter build web 不在一个 run 步骤里，构建命令被改写了');

    var top = step;
    while (top > 0 && lines[top - 1].trimLeft().startsWith('#')) {
      top--;
    }
    expect(top, lessThan(step), reason: '-O4 那一行上面缺注释');
    final comment = lines.sublist(top, step).join('\n');
    expect(comment, contains('sound'),
        reason: '-O2 是 flutter_tools 有意选的声音性级别，注释必须说明 -O4 放弃了什么');
    expect(comment, contains('2,457,614'),
        reason: '注释里要留 before/after 的字节数，否则没法判断这个取舍还值不值');
  });
}
