/// 代码评审修复的回归测试：GlobalKey 并存、折叠轮操作行、围栏内 ** 不
/// 计数、守卫顺序（悬空公式先闭合）、图片链接不猜、notice 不截断、草稿
/// 防抖写盘。
library;

import 'package:cc_go/state/draft_store.dart';
import 'package:cc_go/state/transcript.dart';
import 'package:cc_go/ui/chat/chat_rows.dart';
import 'package:cc_go/ui/chat/render/math_guard.dart';
import 'package:cc_go/ui/chat/render/stream_repair.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

TranscriptItem _user(String id, String text) => TranscriptItem(
      id: id,
      kind: ItemKind.user,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1),
      text: text,
    );

TranscriptItem _assistant(String id, String text, {String status = 'done'}) =>
    TranscriptItem(
      id: id,
      kind: ItemKind.assistant,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1),
      status: status,
      text: text,
    );

TranscriptItem _tool(String id, {String status = 'done'}) => TranscriptItem(
      id: id,
      kind: ItemKind.tool,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1),
      status: status,
      toolName: 'Bash',
      toolInput: const {'command': 'npm test'},
      summary: 'ok',
    );

Widget _twoLists(Widget a, Widget b) => MaterialApp(
      home: Scaffold(
        body: Column(children: [Expanded(child: a), Expanded(child: b)]),
      ),
    );

void main() {
  group('评审 #1：并存的两份转录列表不撞 GlobalKey', () {
    testWidgets('同一棵树挂两个 TranscriptListView', (tester) async {
      final items = [_user('u1', '消息')];
      await tester.pumpWidget(_twoLists(
        TranscriptListView(
          items: items,
          queuedTexts: const [],
          loaded: true,
          scrollController: ScrollController(),
        ),
        TranscriptListView(
          items: items,
          queuedTexts: const [],
          loaded: true,
          scrollController: ScrollController(),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('消息'), findsNWidgets(2));
    });
  });

  group('评审 #2：折叠轮的回合末操作行', () {
    testWidgets('带脚注的折叠轮，最终回答仍有操作行', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TranscriptListView(
            items: [
              _user('u1', '问题'),
              _tool('t1'),
              _assistant('a1', '修好了，测试全绿。'),
            ],
            queuedTexts: const [],
            loaded: true,
            scrollController: ScrollController(),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      // 折叠 + 脚注都出现，操作行（分享图标）也在最终回答下方。
      expect(find.textContaining('已收起'), findsOneWidget);
      expect(find.textContaining('次工具调用'), findsWidgets);
      expect(find.byIcon(Icons.ios_share), findsOneWidget);
    });
  });

  group('评审 #3：围栏内的 ** 不参与闭合计数', () {
    test('中部代码围栏内的奇数 ** 不追加', () {
      // 围栏外粗体成对（偶数记号），围栏内的单 ** 不参与计数。
      final text = 'A **bold**\n```\ny ** 2\n```\nend';
      expect(repairStreamingMarkdown(text), text);
    });

    test('未闭合围栏内的 ** 不追加（先补围栏）', () {
      final repaired = repairStreamingMarkdown('```\n** 未闭合的围栏');
      // 追加的是围栏闭合，不是 **。
      expect(repaired.endsWith('**'), isFalse);
      expect(repaired.contains('```'), isTrue);
    });

    test('围栏外的奇数 ** 仍补闭合', () {
      expect(repairStreamingMarkdown('这是 **加粗文本').endsWith('**'), isTrue);
    });
  });

  group('评审 #4：守卫顺序（悬空展示公式先闭合再守卫）', () {
    test(r'半截 $$ 不被转义且被占位闭合', () {
      final streaming = r'公式开头 $$E=mc';
      final repaired = guardMathDelimiters(
          closeDanglingDisplayMath(repairStreamingMarkdown(streaming)));
      // 闭合占位在尾部（守卫不得先转义掉开头的 $$）。
      expect(repaired.endsWith(r'$$'), isTrue);
      expect(repaired.contains(r'\$\$'), isFalse);
      expect(guardMathDelimiters(r'\$\$'), contains(r'\$')); // 幂等性佐证
    });

    testWidgets('流式渲染路径一致（AssistantMarkdown 集成）', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TranscriptListView(
            items: [_assistant('a1', '公式开头 \$\$E=mc', status: 'streaming')],
            queuedTexts: const [],
            loaded: true,
            scrollController: controller,
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 600));
      // 悬空公式被扣住渲染，而不是转义成字面 \$\$。
      expect(tester.takeException(), isNull);
    });
  });

  group('评审 #5：长 notice 无详情时全量换行', () {
    testWidgets('无 resultText 的长 notice 不被单行截断', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final long = '这是一条很长很长的通知消息，' * 8;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TranscriptListView(
            items: [
              TranscriptItem(
                id: 'n1',
                kind: ItemKind.notice,
                createdAt: DateTime.fromMillisecondsSinceEpoch(1),
                text: long,
              ),
            ],
            queuedTexts: const [],
            loaded: true,
            scrollController: ScrollController(),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      final textWidget =
          tester.widget<Text>(find.text(long, skipOffstage: false));
      expect(textWidget.maxLines, isNull, reason: '无详情时全量换行');
      expect(
        tester
            .getRect(find.text(long, skipOffstage: false))
            .height,
        greaterThan(40),
        reason: '实际渲染多行而非单行省略',
      );
    });
  });

  group('评审 #8：草稿防抖写盘（DraftSaver）', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('连发多次 schedule 只留最新快照，防抖后落盘', () async {
      final saver = DraftSaver(sessionId: 's1', debounce: const Duration(milliseconds: 400));
      saver.schedule(const ChatDraft(text: 'a'));
      saver.schedule(const ChatDraft(text: 'ab'));
      saver.schedule(const ChatDraft(text: 'abc'));
      expect(saver.pending?.text, 'abc'); // 最新快照待写
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect((await DraftStore.load('s1')).text, 'abc'); // 只写一次最新值
    });

    test('discard 丢弃未写快照（发送清空后不反扑）', () async {
      final saver = DraftSaver(sessionId: 's2', debounce: const Duration(milliseconds: 400));
      saver.schedule(const ChatDraft(text: '旧草稿'));
      saver.discard();
      expect(saver.pending, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect((await DraftStore.load('s2')).isEmpty, isTrue);
    });

    test('flush 立即写盘（页面销毁路径）', () async {
      final saver = DraftSaver(sessionId: 's3', debounce: const Duration(milliseconds: 400));
      saver.schedule(const ChatDraft(text: '未写完'));
      saver.flush();
      // flush 内部 save 是异步落盘，稍候再读。
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect((await DraftStore.load('s3')).text, '未写完');
    });
  });

  group('评审 #9：图片链接头不猜', () {
    test('截断的 ![alt](url 不补括号', () {
      final text = '图 ![alt](http://x';
      expect(repairStreamingMarkdown(text), text);
    });

    test('截断的普通链接仍补括号', () {
      expect(repairStreamingMarkdown('看 [文档](http://x').endsWith(')'), isTrue);
    });
  });
}
