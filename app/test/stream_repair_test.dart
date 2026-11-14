/// task 2.1：流式残缺 Markdown 补全纯函数单测 —— 未闭合围栏、半表格、
/// 正常文本，以及幂等性。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:cc_go/ui/chat/render/stream_repair.dart';

void main() {
  group('未闭合代码围栏', () {
    test('反引号围栏补闭合', () {
      expect(
        repairStreamingMarkdown('```dart\nvoid main() {}'),
        '```dart\nvoid main() {}\n```',
      );
    });

    test('波浪线围栏补闭合', () {
      expect(repairStreamingMarkdown('~~~\na'), '~~~\na\n~~~');
    });

    test('围栏内的围栏样行不误闭', () {
      // 围栏信息串含反引号的开栏行按 GFM 不是围栏 → 无需补全。
      expect(repairStreamingMarkdown('`` `code` ``\nx'), '`` `code` ``\nx');
    });

    test('已闭合不动', () {
      const text = '```dart\nvoid main() {}\n```';
      expect(repairStreamingMarkdown(text), text);
    });
  });

  group('截断表格', () {
    test('缺尾部竖线的行补齐到表头列数', () {
      expect(
        repairStreamingMarkdown('| a | b |\n| --- | --- |\n| 1'),
        '| a | b |\n| --- | --- |\n| 1 | |',
      );
    });

    test('缺一个单元格边界的行补齐', () {
      expect(
        repairStreamingMarkdown('| a | b |\n| --- | --- |\n| 1 | 2'),
        '| a | b |\n| --- | --- |\n| 1 | 2 |',
      );
    });

    test('完整表格不动', () {
      const text = '| a | b |\n| --- | --- |\n| 1 | 2 |';
      expect(repairStreamingMarkdown(text), text);
    });

    test('非表格段落不动', () {
      const text = '| 修饰符 | 含义\n这是普通文本 | 带竖线';
      // 第二行不是分隔行 → 不是表格 → 不修。
      expect(repairStreamingMarkdown(text), text);
    });

    test('不以竖线开头的行不猜', () {
      const text = '| a | b |\n| --- | --- |\n1';
      expect(repairStreamingMarkdown(text), text);
    });
  });

  group('正常文本与幂等', () {
    test('普通文本原样返回', () {
      const text = '一句话，没有 Markdown。';
      expect(repairStreamingMarkdown(text), text);
    });

    test('空文本原样返回', () {
      expect(repairStreamingMarkdown(''), '');
    });

    test('补全结果幂等', () {
      const cases = [
        '```dart\nvoid main() {}',
        '| a | b |\n| --- | --- |\n| 1',
        '| a | b | c |\n| --- | --- | --- |\n| 1 | 2',
      ];
      for (final text in cases) {
        final once = repairStreamingMarkdown(text);
        expect(repairStreamingMarkdown(once), once, reason: '输入：$text');
      }
    });
  });
}
