/// task 3.5：用量/成本 chip —— 数值格式化与渲染；无数据由调用方不渲染。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:cc_go/state/session_models.dart';
import 'package:cc_go/ui/chat/usage_chip.dart';

SessionUsage usageOf({required int contextTokens, required double costUsd}) => SessionUsage(
      inputTokens: 100,
      outputTokens: 40,
      cacheReadTokens: 900,
      cacheCreationTokens: 10,
      contextTokens: contextTokens,
      costUsd: costUsd,
    );

Widget harness(SessionUsage usage) =>
    MaterialApp(home: Scaffold(body: Center(child: UsageChip(usage: usage))));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('格式化', () {
    test('token 数量级', () {
      expect(formatTokens(123), '123');
      expect(formatTokens(1200), '1.2k');
      expect(formatTokens(43200), '43k');
      expect(formatTokens(1050000), '1.05m');
    });

    test('成本', () {
      expect(formatCost(0.004), r'$0.004');
      expect(formatCost(0.25), r'$0.25');
      expect(formatCost(3.5), r'$3.50');
    });
  });

  testWidgets('chip 渲染成本与上下文量级', (tester) async {
    await tester.pumpWidget(harness(usageOf(contextTokens: 1234, costUsd: 0.25)));
    expect(find.text(r'$0.25 · 1.2k ctx'), findsOneWidget);
  });

  testWidgets('usage 更新后刷新为新值', (tester) async {
    await tester.pumpWidget(harness(usageOf(contextTokens: 1234, costUsd: 0.25)));
    await tester.pumpWidget(harness(usageOf(contextTokens: 105000, costUsd: 3.5)));
    expect(find.text(r'$3.50 · 105k ctx'), findsOneWidget);
    expect(find.text(r'$0.25 · 1.2k ctx'), findsNothing);
  });
}
