/// task 4.4：斜杠指令面板 —— `/` 前缀触发、过滤、点选补全、空目录不弹、
/// 发送路径不变。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:cc_go/state/chat_controller.dart';
import 'package:cc_go/ui/chat/composer.dart';

const commands = [
  SlashCommand(name: 'compact', description: '压缩上下文'),
  SlashCommand(name: 'clear', description: '清空会话'),
  SlashCommand(name: 'resume'),
];

Widget harness({
  List<SlashCommand> slashCommands = commands,
  required Future<void> Function(String, List<dynamic>) onSend,
}) =>
    MaterialApp(
      home: Scaffold(
        body: Composer(
          running: false,
          busy: false,
          slashCommands: slashCommands,
          onSend: (text, attachments) => onSend(text, attachments),
          onCancel: () {},
        ),
      ),
    );

Future<void> type(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('`/` 触发面板显示全部指令', (tester) async {
    await tester.pumpWidget(harness(onSend: (t, a) async {}));
    await type(tester, '/');
    expect(find.text('/compact'), findsOneWidget);
    expect(find.text('/clear'), findsOneWidget);
    expect(find.text('/resume'), findsOneWidget);
  });

  testWidgets('前缀过滤', (tester) async {
    await tester.pumpWidget(harness(onSend: (t, a) async {}));
    await type(tester, '/com');
    expect(find.text('/compact'), findsOneWidget);
    expect(find.text('/clear'), findsNothing);
    expect(find.text('/resume'), findsNothing);
  });

  testWidgets('点选补全指令名', (tester) async {
    await tester.pumpWidget(harness(onSend: (t, a) async {}));
    await type(tester, '/com');
    await tester.tap(find.text('/compact'));
    await tester.pump();
    expect(find.widgetWithText(TextField, '/compact '), findsOneWidget);
  });

  testWidgets('空目录永不弹面板，输入与发送不受影响', (tester) async {
    String? sent;
    await tester.pumpWidget(
      harness(slashCommands: const [], onSend: (t, a) async => sent = t),
    );
    await type(tester, '/compact');
    expect(find.byType(ListTile), findsNothing, reason: '无目录不出面板');
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    expect(sent, '/compact', reason: '指令就是普通 prompt 文本');
  });

  testWidgets('指令名后有空格时不再过滤（进入参数输入）', (tester) async {
    await tester.pumpWidget(harness(onSend: (t, a) async {}));
    await type(tester, '/compact ');
    expect(find.byType(ListTile), findsNothing, reason: '首个空格后面板收起');
  });

  testWidgets('普通文本不出面板', (tester) async {
    await tester.pumpWidget(harness(onSend: (t, a) async {}));
    await type(tester, '普通消息');
    expect(find.byType(ListTile), findsNothing);
  });
}
