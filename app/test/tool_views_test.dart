/// task 4.2/4.3：工具定制视图 —— 注册表分发与未知工具回退；Bash/Read/
/// Grep/Edit/Write/TodoWrite 各视图关键内容渲染。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:cc_go/state/transcript.dart';
import 'package:cc_go/ui/chat/chat_rows.dart';
import 'package:cc_go/ui/chat/tool_views.dart';

TranscriptItem tool(
  String name,
  Map<String, dynamic> input, {
  String status = 'done',
  String? summary,
}) =>
    TranscriptItem(
      id: 't1',
      kind: ItemKind.tool,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1),
      status: status,
      toolName: name,
      toolInput: input,
      summary: summary,
    );

Widget harness(TranscriptItem item) => MaterialApp(
      home: Scaffold(
        body: TranscriptListView(
          items: [item],
          queuedTexts: const [],
          loaded: true,
          scrollController: ScrollController(),
        ),
      ),
    );

Future<void> expand(WidgetTester tester, String title) async {
  await tester.tap(find.textContaining(title));
  await tester.pumpAndSettle();
}

void main() {
  test('注册表：未知工具返回 null（回退通用折叠行）', () {
    expect(toolDetailFor(tool('SomeMcpTool', {'x': 1})), isNull);
    expect(toolSubtitleFor(tool('SomeMcpTool', {'x': 1})), isNull);
  });

  test('注册表：已知工具返回视图与一行概览', () {
    expect(toolDetailFor(tool('Bash', {'command': 'ls'})), isNotNull);
    expect(toolSubtitleFor(tool('Bash', {'command': 'ls -la'})), 'ls -la');
    expect(toolSubtitleFor(tool('Read', {'file_path': '/tmp/a.dart'})), '/tmp/a.dart');
    expect(toolSubtitleFor(tool('Grep', {'pattern': 'TODO', 'path': 'lib'})), 'lib · TODO');
  });

  testWidgets('Bash：展开显示命令与输出摘要', (tester) async {
    await tester.pumpWidget(harness(tool(
      'Bash',
      {'command': 'npm test'},
      summary: '3 passed',
    )));
    expect(find.textContaining('npm test'), findsOneWidget, reason: '副标题命令概览');
    await expand(tester, 'Bash · 完成');
    expect(find.text('命令'), findsOneWidget);
    // 副标题与命令块各出现一次。
    expect(find.text('npm test'), findsNWidgets(2));
    expect(find.text('输出'), findsOneWidget);
    expect(find.text('3 passed'), findsOneWidget);
  });

  testWidgets('Edit：展开显示路径与 +/- diff', (tester) async {
    await tester.pumpWidget(harness(tool(
      'Edit',
      {
        'file_path': '/tmp/a.dart',
        'old_string': 'var a = 1;',
        'new_string': 'var a = 2;',
      },
    )));
    await expand(tester, 'Edit · 完成');
    expect(find.textContaining('/tmp/a.dart'), findsWidgets);
    expect(find.textContaining('+1 −1'), findsOneWidget, reason: 'diff 统计');
    expect(find.textContaining('− var a = 1;'), findsOneWidget);
    expect(find.textContaining('+ var a = 2;'), findsOneWidget);
  });

  testWidgets('Write：整文件按新增渲染', (tester) async {
    await tester.pumpWidget(harness(tool(
      'Write',
      {'file_path': '/tmp/new.md', 'content': '# 标题\n正文'},
    )));
    await expand(tester, 'Write · 完成');
    expect(find.textContaining('+2 −0'), findsOneWidget);
    expect(find.textContaining('+ # 标题'), findsOneWidget);
  });

  testWidgets('Read：展开显示路径与内容摘要', (tester) async {
    await tester.pumpWidget(harness(tool(
      'Read',
      {'file_path': '/tmp/a.dart', 'offset': 10, 'limit': 50},
      summary: 'void main() …',
    )));
    await expand(tester, 'Read · 完成');
    expect(find.text('/tmp/a.dart'), findsWidgets);
    expect(find.text('10'), findsOneWidget, reason: '起始行');
    expect(find.text('50'), findsOneWidget, reason: '行数');
    expect(find.textContaining('void main()'), findsOneWidget);
  });

  testWidgets('Grep：展开显示模式与范围', (tester) async {
    await tester.pumpWidget(harness(tool(
      'Grep',
      {'pattern': 'TODO', 'path': 'lib/', 'output_mode': 'content'},
      summary: '2 处命中',
    )));
    await expand(tester, 'Grep · 完成');
    expect(find.text('TODO'), findsWidgets);
    expect(find.text('lib/'), findsWidgets);
    expect(find.text('2 处命中'), findsOneWidget);
  });

  testWidgets('TodoWrite：清单按状态渲染图标', (tester) async {
    await tester.pumpWidget(harness(tool(
      'TodoWrite',
      {
        'todos': [
          {'content': '调研方案', 'status': 'completed'},
          {'content': '写实现', 'status': 'in_progress'},
          {'content': '补测试', 'status': 'pending'},
        ],
      },
    )));
    await expand(tester, 'TodoWrite · 完成');
    expect(find.text('调研方案'), findsOneWidget);
    expect(find.text('写实现'), findsOneWidget);
    expect(find.text('补测试'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.byIcon(Icons.play_circle), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_unchecked), findsOneWidget);
  });

  testWidgets('TodoWrite 输入畸形时回退通用 JSON 展示', (tester) async {
    await tester.pumpWidget(harness(tool('TodoWrite', {'todos': 'not-a-list'})));
    await expand(tester, 'TodoWrite · 完成');
    expect(find.text('输入'), findsOneWidget, reason: '畸形输入回退通用块，不出空白展开');
    expect(find.textContaining('"todos"'), findsOneWidget);
  });

  testWidgets('未知工具回退通用 JSON 折叠行', (tester) async {
    await tester.pumpWidget(harness(tool('WebFetch', {'url': 'https://x'}, summary: 'ok')));
    await expand(tester, 'WebFetch · 完成');
    expect(find.text('输入'), findsOneWidget, reason: '通用 JSON 输入块');
    expect(find.textContaining('"url"'), findsOneWidget);
    expect(find.text('结果'), findsOneWidget);
    // 'ok' 同时出现在副标题与结果块。
    expect(find.text('ok'), findsNWidgets(2));
  });
}
