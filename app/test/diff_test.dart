/// task 4.1：行级 LCS diff 单测 —— 空输入、全同、全改、首尾差异、超限退化。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:cc_go/ui/chat/render/diff.dart';

void main() {
  test('旧输入为空：全部为新增', () {
    final result = diffLines([], ['a', 'b']);
    expect(result.map((l) => l.kind), everyElement(DiffLineKind.add));
    expect(result.map((l) => l.text), ['a', 'b']);
  });

  test('新输入为空：全部为删除', () {
    final result = diffLines(['a'], []);
    expect(result.map((l) => l.kind), everyElement(DiffLineKind.remove));
  });

  test('完全相同：全部 same 且保序', () {
    final result = diffLines(['a', 'b', 'c'], ['a', 'b', 'c']);
    expect(result.map((l) => l.kind), everyElement(DiffLineKind.same));
    expect(result.map((l) => l.text), ['a', 'b', 'c']);
  });

  test('完全不同：先删后增', () {
    final result = diffLines(['x', 'y'], ['p', 'q']);
    expect(result.map((l) => l.kind).toList(), [
      DiffLineKind.remove,
      DiffLineKind.remove,
      DiffLineKind.add,
      DiffLineKind.add,
    ]);
  });

  test('首尾相同、中间修改', () {
    final result = diffLines(
      ['void main() {', '  print(1);', '}'],
      ['void main() {', '  print(2);', '}'],
    );
    expect(result.map((l) => (l.kind, l.text)).toList(), [
      (DiffLineKind.same, 'void main() {'),
      (DiffLineKind.remove, '  print(1);'),
      (DiffLineKind.add, '  print(2);'),
      (DiffLineKind.same, '}'),
    ]);
  });

  test('纯新增若干行', () {
    final result = diffLines(['a', 'd'], ['a', 'b', 'c', 'd']);
    expect(result.map((l) => (l.kind, l.text)).toList(), [
      (DiffLineKind.same, 'a'),
      (DiffLineKind.add, 'b'),
      (DiffLineKind.add, 'c'),
      (DiffLineKind.same, 'd'),
    ]);
  });

  test('超限退化：全删 + 全增', () {
    final old = List.generate(kDiffMaxLines + 1, (i) => 'o$i');
    final fresh = List.generate(kDiffMaxLines + 1, (i) => 'n$i');
    final result = diffLines(old, fresh);
    expect(result.length, old.length + fresh.length);
    expect(result.first.kind, DiffLineKind.remove);
    expect(result.last.kind, DiffLineKind.add);
  });

  test('五百行以内仍走 LCS（上限不误伤正常编辑）', () {
    final result = diffLines(['a'], ['a']);
    expect(result.single.kind, DiffLineKind.same);
  });
}
