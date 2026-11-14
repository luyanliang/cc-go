/// task 1.2：Markdown 渲染组件 widget 测试 —— 代码块（高亮 + 复制入剪贴板）、
/// 表格、列表、链接；未知语言回退纯等宽。
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:cc_go/state/transcript.dart';
import 'package:cc_go/ui/chat/chat_rows.dart';
import 'package:cc_go/ui/chat/render/assistant_markdown.dart';
import 'package:cc_go/ui/chat/render/code_block.dart';

/// 拦截剪贴板平台通道，记录写入并返回成功（widget 测试环境无真剪贴板）。
String? lastClipboardData;
void mockClipboard(BinaryMessenger messenger) {
  Future<Object?>? handler(MethodCall call) async {
    if (call.method == 'Clipboard.setData') {
      lastClipboardData = (call.arguments as Map)['text'] as String?;
    }
    return null;
  }

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, handler);
}

Widget harness(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    lastClipboardData = null;
    mockClipboard(TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('代码块渲染语言标签与高亮文本', (tester) async {
    await tester.pumpWidget(harness(const CodeBlockView(
      code: 'void main() {}',
      language: 'dart',
    )));
    expect(find.text('dart'), findsOneWidget, reason: '语言标签');
    expect(find.byIcon(Icons.copy), findsOneWidget, reason: '复制按钮');
    expect(find.textContaining('void main'), findsOneWidget, reason: '代码体');
  });

  testWidgets('复制按钮把整块代码写入剪贴板', (tester) async {
    await tester.pumpWidget(harness(const CodeBlockView(
      code: 'echo hi',
      language: 'bash',
    )));
    await tester.tap(find.byIcon(Icons.copy));
    await tester.pump();
    expect(lastClipboardData, 'echo hi');
    expect(find.byIcon(Icons.check), findsOneWidget, reason: '复制成功态');
    // 走完 2 秒复位计时，避免测试结束时留下未决 Timer。
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('未知语言回退纯文本仍可展示与复制', (tester) async {
    await tester.pumpWidget(harness(const CodeBlockView(
      code: 'some unknown text',
      language: 'brainfuck-x',
    )));
    expect(find.textContaining('some unknown text'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.copy));
    await tester.pump();
    expect(lastClipboardData, 'some unknown text');
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('别名归一：内建别名与补充映射', (tester) async {
    // 内建（re_highlight 语法注册表自带，返回原名即可高亮）。
    expect(normalizeLanguage('ts'), isNotNull);
    expect(normalizeLanguage('Python'), isNotNull);
    expect(normalizeLanguage('sh'), isNotNull);
    expect(normalizeLanguage('yml'), isNotNull);
    // 本表补充映射到注册语言名。
    expect(normalizeLanguage('tsx'), 'typescript');
    expect(normalizeLanguage('html'), 'xml');
    expect(normalizeLanguage('console'), 'bash');
    // 未注册。
    expect(normalizeLanguage('brainfuck'), isNull);
  });

  testWidgets('AssistantMarkdown 渲染代码块、表格、列表', (tester) async {
    await tester.pumpWidget(harness(const AssistantMarkdown(text: '''
```dart
void main() {}
```

| 列A | 列B |
| --- | --- |
| 1 | 2 |

- 项目一
- 项目二
''')));
    await tester.pumpAndSettle();
    expect(find.byType(CodeBlockView), findsOneWidget, reason: '代码块');
    expect(find.text('列A'), findsOneWidget, reason: '表格表头');
    expect(find.text('列B'), findsOneWidget, reason: '表格表头');
    expect(find.textContaining('项目一'), findsOneWidget, reason: '列表项');
    expect(find.textContaining('项目二'), findsOneWidget, reason: '列表项');
  });

  testWidgets('链接点击回调收到 URL', (tester) async {
    String? tapped;
    await tester.pumpWidget(harness(AssistantMarkdown(
      // 链接占满整行，点击 RichText 中心即命中链接 span。
      text: '[文档](https://example.com/docs)',
      onLinkTap: (url) => tapped = url,
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('文档', findRichText: true));
    await tester.pumpAndSettle();
    expect(tapped, 'https://example.com/docs');
  });

  testWidgets('空文本流式时显示占位', (tester) async {
    await tester.pumpWidget(harness(const AssistantMarkdown(text: '', streaming: true)));
    expect(find.text('…'), findsOneWidget);
  });

  testWidgets('流式未闭合围栏容错渲染，完成后以原始全文整体替换', (tester) async {
    // 通过 TranscriptListView 走完整路径：item.status 驱动流式/完成。
    final partial = TranscriptItem(
      id: 'a1',
      kind: ItemKind.assistant,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1),
      text: '分析中：\n\n```dart\nvoid mai',
      status: 'streaming',
    );
    final controller = ScrollController();
    Widget screen(TranscriptItem item) => MaterialApp(
          home: Scaffold(
            body: TranscriptListView(
              items: [item],
              queuedTexts: const [],
              loaded: true,
              scrollController: controller,
            ),
          ),
        );

    await tester.pumpWidget(screen(partial));
    await tester.pumpAndSettle();
    // 未闭合围栏被补全后仍渲染为代码块，不撕裂布局、不抛异常。
    expect(find.byType(CodeBlockView), findsOneWidget);
    expect(find.textContaining('void mai'), findsOneWidget);

    final done = TranscriptItem(
      id: 'a1',
      kind: ItemKind.assistant,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1),
      text: '分析中：\n\n```dart\nvoid main() {}\n```\n\n结论如上。',
      status: 'done',
    );
    await tester.pumpWidget(screen(done));
    await tester.pumpAndSettle();
    // 完成后是原始全文的渲染：最终代码完整、正文收尾。
    expect(find.byType(CodeBlockView), findsOneWidget);
    expect(find.textContaining('void main() {}'), findsOneWidget);
    expect(find.textContaining('结论如上'), findsOneWidget);
  });
}
