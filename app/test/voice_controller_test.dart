/// VoiceInputController 状态机单测（voice-dictation）：fake bridge +
/// fake link 覆盖 spec 全部场景 —— 成功落草稿、空结果提示、系统服务
/// 失败自动降级、不可靠记忆、blocked 权限引导、daemon 未配置。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:cc_go/voice/voice_bridge.dart';
import 'package:cc_go/voice/voice_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 可脚本化的假 bridge：注入 capabilities 与事件序列，记录调用。
class _FakeBridge implements VoiceBridge {
  _FakeBridge({VoiceCapabilities? caps}) : caps = caps ?? const VoiceCapabilities(recognizer: true, recorder: true);

  VoiceCapabilities caps;
  VoicePermission permissionResult = VoicePermission.granted;
  bool openSettingsCalled = false;
  int startRecognizerCalls = 0;
  int startRecorderCalls = 0;
  int cancelCalls = 0;

  /// start 后由测试手动发射的事件序列。
  final eventsController = StreamController<VoiceEvent>.broadcast();
  Uint8List? stopResult;

  @override
  Future<VoiceCapabilities> capabilities() async => caps;

  @override
  Future<VoicePermission> requestPermission() async => permissionResult;

  @override
  Future<void> openSettings() async => openSettingsCalled = true;

  @override
  Stream<VoiceEvent> get events => eventsController.stream;

  @override
  Future<void> startRecognizer({String? language}) async {
    startRecognizerCalls++;
  }

  @override
  Future<void> startRecorder({required int maxSeconds}) async {
    startRecorderCalls++;
  }

  @override
  Future<Uint8List?> stop() async => stopResult;

  @override
  Future<void> cancel() async {
    cancelCalls++;
  }
}

class _FakeLink implements VoiceLink {
  _FakeLink({List<Map<String, dynamic>>? providers})
      : transcript = 'daemon 文本',
        providers = providers ?? const [];

  List<Map<String, dynamic>> providers;
  String transcript;
  int transcribeCalls = 0;

  @override
  Future<Map<String, dynamic>> speechCatalog() async => {
        'providers': providers,
        'providerId': providers.isEmpty ? null : 'openai:whisper-1',
        'language': 'zh',
        'maxAudioBytes': 10485760,
        'maxDurationSeconds': 600,
      };

  @override
  Future<String> speechTranscribe(
    Uint8List wav, {
    String? providerId,
    String? language,
  }) async {
    transcribeCalls++;
    return transcript;
  }
}

/// 44 字节头 + 足量静音的最小 WAV。
Uint8List fakeWav() => Uint8List(44 + 16000);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late _FakeBridge bridge;
  late _FakeLink link;
  late TextEditingController input;
  late VoiceInputController controller;
  final messages = <VoiceMessage>[];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    bridge = _FakeBridge();
    link = _FakeLink();
    input = TextEditingController();
    messages.clear();
    controller = VoiceInputController(
      input: input,
      bridge: bridge,
      link: () => link,
      observeLifecycle: false,
    );
    controller.onMessage = messages.add;
  });

  tearDown(() {
    controller.dispose();
  });

  /// 等 start 的异步链走完（权限 → 模式 → 探测 → 启动）。
  Future<void> pumpStart(WidgetTester tester) async {
    unawaited(controller.start());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();
  }

  testWidgets('系统识别成功：partial→final 按锚点插入草稿，中英拼接补空格', (tester) async {
    input.text = 'Hello,';
    await pumpStart(tester);
    expect(controller.phase, VoicePhase.listening);
    expect(bridge.startRecognizerCalls, 1);

    bridge.eventsController.add(const VoicePartial('world'));
    await tester.pump();
    expect(input.text, 'Hello, world');

    bridge.eventsController.add(const VoiceFinal('world!'));
    await tester.pump();
    expect(controller.phase, VoicePhase.idle);
    expect(input.text, 'Hello, world!');
  });

  testWidgets('CJK 接缝不补空格', (tester) async {
    input.text = '今天天气';
    await pumpStart(tester);
    bridge.eventsController.add(const VoiceFinal('不错'));
    await tester.pump();
    expect(input.text, '今天天气不错');
  });

  testWidgets('空结果：恢复草稿并提示', (tester) async {
    input.text = '保留原文';
    await pumpStart(tester);
    bridge.eventsController.add(const VoiceFinal(''));
    await tester.pump();
    expect(controller.phase, VoicePhase.idle);
    expect(input.text, '保留原文');
    expect(messages.last.text, contains('未识别到语音内容'));
  });

  testWidgets('系统服务失败 → 自动降级引擎转录 → 文本落草稿', (tester) async {
    // 起始无 catalog → 走系统路径；失败前 daemon 转录服务就绪。
    bridge.stopResult = fakeWav();
    await pumpStart(tester);
    expect(bridge.startRecognizerCalls, 1);

    // 服务类失败（network）→ 一次性降级到录音路径（此时 catalog 已就绪）。
    link.providers = [
      {'id': 'openai:whisper-1', 'usable': true},
    ];
    bridge.eventsController.add(const VoiceError(2));
    await tester.pump();
    await tester.pump();
    expect(bridge.startRecorderCalls, 1);
    expect(controller.engine, VoiceEngine.engine);

    // 停止 → 上传 daemon → 转录文本落草稿。
    await controller.stop();
    await tester.pump();
    expect(input.text, 'daemon 文本');
    expect(link.transcribeCalls, 1);
    expect(messages.any((m) => m.text.contains('已切换')), isTrue);
  });

  testWidgets('no-match 失败不降级，直接提示', (tester) async {
    // 显式 system 模式：auto + catalog 就绪时设计上引擎优先，到不了这里。
    await VoiceInputController.saveMode(VoiceMode.system);
    link.providers = [
      {'id': 'openai:whisper-1', 'usable': true},
    ];
    await pumpStart(tester);
    bridge.eventsController.add(const VoiceError(7));
    await tester.pump();
    await tester.pump();
    expect(bridge.startRecorderCalls, 0);
    expect(messages.last.text, contains('没听清'));
  });

  testWidgets('systemUnreliable 记忆：自动模式跳过系统服务直接录音', (tester) async {
    link.providers = [
      {'id': 'openai:whisper-1', 'usable': true},
    ];
    bridge.caps = const VoiceCapabilities(
        recognizer: true, recorder: true, systemUnreliable: true);
    bridge.stopResult = fakeWav();
    await pumpStart(tester);
    await tester.pump();
    expect(bridge.startRecognizerCalls, 0);
    expect(bridge.startRecorderCalls, 1);
  });

  testWidgets('仅引擎模式且 daemon 未配置 → 提示配置', (tester) async {
    await VoiceInputController.saveMode(VoiceMode.engine);
    await pumpStart(tester);
    expect(bridge.startRecognizerCalls, 0);
    expect(bridge.startRecorderCalls, 0);
    expect(messages.last.change, isTrue);
    expect(messages.last.text, contains('daemon'));
  });

  testWidgets('权限 blocked → 提示 + 打开系统设置入口', (tester) async {
    bridge.permissionResult = VoicePermission.blocked;
    await pumpStart(tester);
    expect(messages.last.openSettings, isTrue);
    expect(messages.last.text, contains('麦克风权限被拒'));
  });

  testWidgets('取消：恢复草稿并释放麦克风', (tester) async {
    await pumpStart(tester);
    bridge.eventsController.add(const VoicePartial('未定稿'));
    await tester.pump();
    await controller.cancel();
    await tester.pump();
    expect(input.text, '');
    expect(bridge.cancelCalls, greaterThan(0));
    expect(controller.phase, VoicePhase.idle);
  });

  testWidgets('引擎录音超时上限：limit 事件自动停止转写', (tester) async {
    link.providers = [
      {'id': 'openai:whisper-1', 'usable': true},
    ];
    bridge.caps = const VoiceCapabilities(recognizer: false, recorder: true);
    bridge.stopResult = fakeWav();
    await pumpStart(tester);
    expect(controller.phase, VoicePhase.listening);
    bridge.eventsController.add(const VoiceLimit());
    await tester.pump();
    // limit → stop → 转录同步完成（fake 链路即时返回）→ 直接到终态。
    expect(input.text, 'daemon 文本');
    expect(controller.phase, VoicePhase.idle);
  });

  testWidgets('后台化取消听写（生命周期）', (tester) async {
    final observing = VoiceInputController(
      input: input,
      bridge: bridge,
      link: () => link,
      observeLifecycle: true,
    );
    observing.onMessage = messages.add;
    controller.dispose();
    controller = observing;
    await pumpStart(tester);
    // 模拟 AppLifecycleState.paused（控制器观察生命周期）。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(controller.phase, VoicePhase.idle);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
}
