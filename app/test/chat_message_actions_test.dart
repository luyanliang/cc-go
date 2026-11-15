/// task 1.3：消息复制 —— 用户气泡可选中文本；助手消息整条复制写入剪贴板
/// （Markdown 原文）；流式中不出现复制按钮。
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:cc_go/state/transcript.dart';
import 'package:cc_go/ui/chat/chat_rows.dart';
import 'package:cc_go/ui/chat/render/copy_button.dart';

TranscriptItem userItem(String text) => TranscriptItem(
      id: 'u1',
      kind: ItemKind.user,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1),
      text: text,
    );

TranscriptItem assistantItem(String text, {bool streaming = false}) => TranscriptItem(
      id: 'a1',
      kind: ItemKind.assistant,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1),
      text: text,
      status: streaming ? 'streaming' : 'done',
    );

Widget harness(List<TranscriptItem> items) => MaterialApp(
      home: Scaffold(
        body: TranscriptListView(
          items: items,
          queuedTexts: const [],
          loaded: true,
          scrollController: ScrollController(),
        ),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String? clipboard;

  setUp(() {
    clipboard = null;
    Future<Object?>? handler(MethodCall call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard = (call.arguments as Map)['text'] as String?;
      }
      return null;
    }

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, handler);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('用户气泡：长按菜单 → 选择文字（SelectionArea）', (tester) async {
    await tester.pumpWidget(harness([userItem('帮我看看这个问题')]));
    // 选择文字走菜单对话框（SelectableText 会吞掉气泡长按手势）。
    await tester.longPress(find.text('帮我看看这个问题'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择文字'));
    await tester.pumpAndSettle();
    expect(find.byType(SelectionArea), findsOneWidget);
    expect(find.textContaining('帮我看看这个问题'), findsWidgets);
  });

  testWidgets('助手消息复制按钮把 Markdown 原文写入剪贴板', (tester) async {
    await tester.pumpWidget(harness([assistantItem('# 标题\n\n正文 **加粗**')]));
    expect(find.byType(CopyIconButton), findsOneWidget);
    await tester.tap(find.byTooltip('复制消息'));
    await tester.pump();
    expect(clipboard, '# 标题\n\n正文 **加粗**');
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('流式中的助手消息不出现复制按钮', (tester) async {
    await tester.pumpWidget(harness([assistantItem('生成中', streaming: true)]));
    expect(find.byType(CopyIconButton), findsNothing);
  });
}
