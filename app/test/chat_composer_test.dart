/// 输入区测试（chat-composer）：草稿按会话持久化（隔离/清除/恢复）、
/// 语音不可用降级、斜杠面板中文说明与选中提示。
library;

import 'package:cc_go/state/chat_controller.dart' show SlashCommand;
import 'package:cc_go/state/draft_store.dart';

import 'package:cc_go/ui/chat/composer.dart';
import 'package:cc_go/voice/voice_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 空 provider 的假连接：引擎路径不可用（daemon 未配置转录服务）。
class _FakeVoiceLink implements VoiceLink {
  @override
  Future<Map<String, dynamic>> speechCatalog() async => {
        'providers': <dynamic>[],
        'providerId': null,
        'language': 'zh',
        'maxAudioBytes': 10485760,
        'maxDurationSeconds': 600,
      };

  @override
  Future<String> speechTranscribe(
    Uint8List wav, {
    String? providerId,
    String? language,
  }) async =>
      '';
}

Widget _composer({
  ValueNotifier<String?>? quoteSink,
  ValueChanged<String>? onDraftChanged,
  List<SlashCommand> slashCommands = const [],
  VoiceLink? voiceLink,
}) =>
    MaterialApp(
      home: Scaffold(
        body: Composer(
          running: false,
          busy: false,
          quoteSink: quoteSink,
          onDraftChanged: onDraftChanged,
          slashCommands: slashCommands,
          voiceLink: voiceLink == null ? null : () => voiceLink,
          onSend: (_, _) async {},
          onCancel: () {},
        ),
      ),
    );

void main() {
  group('DraftStore', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('保存后读取一致；按会话隔离', () async {
      await DraftStore.save('s1', const ChatDraft(text: '半段文字', quote: '引文'));
      await DraftStore.save('s2', const ChatDraft(text: '另一会话'));

      final d1 = await DraftStore.load('s1');
      expect(d1.text, '半段文字');
      expect(d1.quote, '引文');
      final d2 = await DraftStore.load('s2');
      expect(d2.text, '另一会话');
      expect(d2.quote, isNull);
    });

    test('发送后 clear：草稿为空', () async {
      await DraftStore.save('s1', const ChatDraft(text: '草稿'));
      await DraftStore.clear('s1');
      expect((await DraftStore.load('s1')).isEmpty, isTrue);
    });

    test('保存空草稿 = 清除', () async {
      await DraftStore.save('s1', const ChatDraft(text: '草稿'));
      await DraftStore.save('s1', const ChatDraft());
      expect((await DraftStore.load('s1')).isEmpty, isTrue);
    });
  });

  testWidgets('草稿变更回调触发（持久化通路）', (tester) async {
    final drafts = <String>[];
    await tester.pumpWidget(_composer(onDraftChanged: drafts.add));
    await tester.enterText(find.byType(TextField), '输入中');
    await tester.pumpAndSettle();
    expect(drafts.last, '输入中');
  });

  testWidgets('未接语音连接（voiceLink null）→ 无语音入口', (tester) async {
    await tester.pumpWidget(_composer());
    await tester.pumpAndSettle();
    // 无语音能力时入口直接不存在，而不是点了才失败。
    expect(find.byIcon(Icons.mic_none_outlined), findsNothing);
  });

  testWidgets('语音入口：插件缺失环境点按给出人话原因且不进入听写态', (tester) async {
    // flutter_tester 无平台线程，未 mock 的通道调用永不返回 —— mock 成拒绝。
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('cc_go/voice'),
      (call) async {
        switch (call.method) {
          case 'capabilities':
            return {'recognizer': false, 'recorder': true, 'systemUnreliable': false};
          case 'requestPermission':
            return 'denied';
          default:
            return null;
        }
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('cc_go/voice'), null));
    await tester.pumpWidget(_composer(voiceLink: _FakeVoiceLink()));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.mic_none_outlined), findsOneWidget);

    await tester.tap(find.byIcon(Icons.mic_none_outlined));
    await tester.pumpAndSettle();
    expect(find.textContaining('麦克风权限'), findsOneWidget);
    expect(find.textContaining('听写中'), findsNothing);
  });

  group('斜杠面板', () {
    testWidgets('候选带中文说明；正在敲指令名时显示选中提示', (tester) async {
      const commands = [
        SlashCommand(name: 'compact', description: 'Compact history'),
        SlashCommand(name: 'custom-x'),
      ];
      await tester.pumpWidget(_composer(slashCommands: commands));
      await tester.pumpAndSettle();

      // 输入 "/" → 全量候选，中文说明优先。
      await tester.enterText(find.byType(TextField), '/');
      await tester.pumpAndSettle();
      expect(find.text('压缩对话历史，节省上下文'), findsOneWidget);
      expect(find.textContaining('发送会选中'), findsNothing); // 还没敲名字

      // 敲指令名 → 选中提示出现。
      await tester.enterText(find.byType(TextField), '/comp');
      await tester.pumpAndSettle();
      expect(find.textContaining('发送会选中'), findsOneWidget);
      expect(find.textContaining('压缩对话历史'), findsOneWidget);
    });
  });
}
