/// 玻璃胶囊顶栏测试（chat-visual-system）：宽度协商纯函数逐级让出、
/// 模型入口与新对话键始终可见、状态行随阶段切换（点 + 文字，不单靠色）。
library;

import 'package:cc_go/state/session_models.dart';
import 'package:cc_go/theme/tokens.dart';
import 'package:cc_go/ui/chat/chat_header.dart';
import 'package:cc_go/ui/widgets/glass.dart';
import 'package:cc_go/ui/widgets/status_dot.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

SessionSummary _summary({String? model}) => SessionSummary(
      id: 's1',
      title: '标题',
      cwd: '/tmp',
      phase: SessionPhase.idle,
      createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
      model: model,
    );

final _usage = SessionUsage(
  inputTokens: 1,
  outputTokens: 1,
  cacheReadTokens: 0,
  cacheCreationTokens: 0,
  contextTokens: 43000,
  costUsd: 1.2,
);

Widget _host(Widget child) =>
    ProviderScope(child: MaterialApp(theme: CcTheme.light(), home: Scaffold(body: child)));

void main() {
  group('planHeaderSpace 纯函数', () {
    const fixed = 40.0 + 40.0 + 12 * 3;

    test('宽屏：全展示', () {
      final plan = planHeaderSpace(
        maxWidth: 800,
        titleWidth: 100,
        modelWidth: 60,
        usageWidth: 72,
        fixedWidth: fixed,
        minTitleWidth: 72,
      );
      expect(plan.step, HeaderSpaceStep.full);
      expect(plan.maxModelWidth, isNull);
    });

    test('中等：先收用量 chip，标题与模型名完整', () {
      final plan = planHeaderSpace(
        maxWidth: fixed + 100 + 24 + 60 + 16 + 5, // 差一点放不下用量
        titleWidth: 100,
        modelWidth: 60,
        usageWidth: 72,
        fixedWidth: fixed,
        minTitleWidth: 72,
      );
      expect(plan.step, HeaderSpaceStep.hideUsage);
    });

    test('更窄：模型名截短到计划宽度，且不低于胶囊下限', () {
      final plan = planHeaderSpace(
        maxWidth: fixed + 72 + 24 + 10, // 只够标题下限 + 一点
        titleWidth: 300,
        modelWidth: 200,
        usageWidth: 72,
        fixedWidth: fixed,
        minTitleWidth: 72,
      );
      expect(plan.step, HeaderSpaceStep.shrinkModel);
      expect(plan.maxModelWidth, isNotNull);
      expect(plan.maxModelWidth! >= 64, isTrue); // 40 文字 + 24 padding 下限
    });
  });

  group('ChatHeader widget', () {
    testWidgets('模型胶囊与新对话键始终可见；用量 chip 宽屏展示', (tester) async {
      await tester.pumpWidget(_host(ChatHeader(
        title: '我的会话',
        phase: SessionPhase.idle,
        summary: _summary(model: 'opus-5-5').copyWithUsage(_usage),
        onPickModel: () {},
      )));
      // 800px 默认测试视口放得下全部：用量 chip 可见（'ctx' 文案）。
      expect(find.textContaining('ctx'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_drop_down), findsOneWidget); // 模型胶囊
      expect(find.byIcon(Icons.edit_square), findsOneWidget); // 新对话键（compose）
      expect(find.byIcon(Icons.arrow_back_ios_new), findsOneWidget); // 返回键
    });

    testWidgets('极窄视口：用量 chip 收起，模型/新对话键保留', (tester) async {
      await tester.pumpWidget(_host(
        SizedBox(
          width: 240,
          child: ChatHeader(
            title: '一个相当长的会话标题超出可用空间',
            phase: SessionPhase.idle,
            summary: _summary(model: 'claude-opus-5-5-20260101')
                .copyWithUsage(_usage),
            onPickModel: () {},
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.arrow_drop_down), findsOneWidget);
      expect(find.byIcon(Icons.edit_square), findsOneWidget);
      // 用量 chip 已收起（找不到 'ctx' 文案）。
      expect(find.textContaining('ctx'), findsNothing);
    });

    testWidgets('状态行随阶段切换：点与文字同时变化，不单靠颜色', (tester) async {
      Widget header(SessionPhase phase) => _host(ChatHeader(
            title: '标题',
            phase: phase,
            summary: null,
            onPickModel: () {},
          ));

      await tester.pumpWidget(header(SessionPhase.idle));
      expect(find.text('已就绪'), findsOneWidget);
      expect(find.byType(StatusDot), findsOneWidget);

      await tester.pumpWidget(header(SessionPhase.running));
      expect(find.text('生成中'), findsOneWidget);

      await tester.pumpWidget(header(SessionPhase.awaitingPermission));
      expect(find.text('等待权限'), findsOneWidget);
      // 状态点仍是纯 widget（点+文字成对出现，颜色不单独表达状态）。
      expect(find.byType(StatusDot), findsOneWidget);
    });

    testWidgets('标题胶囊为玻璃表面（GlassPill）', (tester) async {
      await tester.pumpWidget(_host(ChatHeader(
        title: '标题',
        phase: SessionPhase.idle,
        summary: null,
        onPickModel: () {},
      )));
      expect(find.byType(GlassPill), findsNWidgets(3)); // 返回键+标题+新对话
    });
  });
}

extension on SessionSummary {
  /// 测试辅助：带上用量（SessionSummary 的 usage 字段 final，拷贝构造）。
  SessionSummary copyWithUsage(SessionUsage usage) => SessionSummary(
        id: id,
        title: title,
        cwd: cwd,
        phase: phase,
        createdAt: createdAt,
        updatedAt: updatedAt,
        claudeSessionId: claudeSessionId,
        model: model,
        permissionMode: permissionMode,
        origin: origin,
        usage: usage,
      );
}
