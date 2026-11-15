/// 语音平台通道的 Dart 侧（voice-dictation，移植自 dsh-Go 的
/// VoiceBridge）：原生插件 `cc_go/voice` + `cc_go/voice/events`。
///
/// 两种监听：
/// - `startRecognizer`：系统 `SpeechRecognizer`（Google 或厂商服务），
///   partial 结果以事件送达；
/// - `startRecorder`：16kHz 单声道 PCM16 录音，`stop` 返回完整 WAV
///   bytes，交给 daemon 转录。
library;

import 'dart:async';

import 'package:flutter/services.dart';

/// 手机侧能力。
class VoiceCapabilities {
  const VoiceCapabilities({
    required this.recognizer,
    required this.recorder,
    this.systemUnreliable = false,
    this.environmentId,
  });

  static const none = VoiceCapabilities(recognizer: false, recorder: false);

  /// `SpeechRecognizer.isRecognitionAvailable`：装了识别服务（Google 或厂商）。
  final bool recognizer;

  /// 麦克风可为引擎转录录音。
  final bool recorder;

  /// 该识别环境曾被标记服务失败（本 OS build + 服务版本内有效）。
  final bool systemUnreliable;
  final String? environmentId;
}

enum VoicePermission { granted, denied, blocked }

/// 听写中的事件。
sealed class VoiceEvent {
  const VoiceEvent();
}

/// 输入电平 0..1。
final class VoiceLevel extends VoiceEvent {
  const VoiceLevel(this.value);
  final double value;
}

/// 系统识别的当前最优猜测。
final class VoicePartial extends VoiceEvent {
  const VoicePartial(this.text);
  final String text;
}

/// 系统识别的最终文本。
final class VoiceFinal extends VoiceEvent {
  const VoiceFinal(this.text);
  final String text;
}

/// `SpeechRecognizer.ERROR_*` 码；100+ 是录音器自己的。
final class VoiceError extends VoiceEvent {
  const VoiceError(this.code);
  final int code;

  static const network = {1, 2, 4, 11};
  static const noSpeech = {6, 7};
  static const audio = 3;
  static const busy = 8;
  static const permission = 9;
  static const language = {12, 13};

  /// 显式取消先退订监听再 cancel，ERROR_CLIENT 不会进到这里。
  static bool canFallback(int code) => !{6, 7, 9}.contains(code);

  /// 录音器打不开麦克风。
  static const recorderFailed = 100;
}

/// 录音到达时长上限自行停止。
final class VoiceLimit extends VoiceEvent {
  const VoiceLimit();
}

/// 会话结束（final 结果或错误之后）。
final class VoiceEnd extends VoiceEvent {
  const VoiceEnd();
}

abstract class VoiceBridge {
  Future<VoiceCapabilities> capabilities();
  Future<VoicePermission> requestPermission();
  Future<void> openSettings();

  /// 当前会话的事件流。
  Stream<VoiceEvent> get events;

  /// 系统识别器（partial 结果）；[language] 为 BCP-47，空 = 跟随识别器。
  Future<void> startRecognizer({String? language});

  /// 为 daemon 转录录音，最长 [maxSeconds]。
  Future<void> startRecorder({required int maxSeconds});

  /// 结束：识别器以 final 事件给最终文本；录音器返回 WAV（16kHz mono
  /// PCM16），没有内容时为 null。
  Future<Uint8List?> stop();

  /// 结束并丢弃一切。
  Future<void> cancel();
}


/// 可取消的超时包装：原生调用正常完成时取消 Timer（flutter_tester 上
/// 未 mock 的通道永不返回 —— 不能用 `Future.timeout`，其 Timer 取消不了，
/// 会把 pending timer 留给测试的 invariant 检查）。
Future<T> _withFallback<T>(Future<T> future, T fallback, Duration timeout) {
  final completer = Completer<T>();
  late final Timer timer;
  timer = Timer(timeout, () {
    if (!completer.isCompleted) completer.complete(fallback);
  });
  future.then(
    (value) {
      timer.cancel();
      if (!completer.isCompleted) completer.complete(value);
    },
    onError: (Object error, StackTrace stack) {
      timer.cancel();
      if (!completer.isCompleted) completer.completeError(error, stack);
    },
  );
  return completer.future;
}

class MethodChannelVoiceBridge implements VoiceBridge {
  static const _methods = MethodChannel('cc_go/voice');
  static const _events = EventChannel('cc_go/voice/events');

  Stream<VoiceEvent>? _stream;
  static int _nextSession = 0;
  int _session = 0;

  @override
  Future<VoiceCapabilities> capabilities() async {
    try {
      final map = await _withFallback(
        _methods.invokeMapMethod<String, Object?>('capabilities'),
        null,
        const Duration(seconds: 3),
      );
      return VoiceCapabilities(
        recognizer: map?['recognizer'] == true,
        recorder: map?['recorder'] == true,
        systemUnreliable: map?['systemUnreliable'] == true,
        environmentId: map?['environmentId'] as String?,
      );
    } on MissingPluginException {
      return VoiceCapabilities.none;
    } on PlatformException {
      return VoiceCapabilities.none;
    } on TimeoutException {
      return VoiceCapabilities.none;
    }
  }

  @override
  Future<VoicePermission> requestPermission() async {
    String? result;
    try {
      // 3s 超时守卫：无平台线程的环境（flutter_tester）或 ROM 异常下，
      // 未应答的通道调用永不返回 —— 绝不能让文字输入跟着挂起。
      result = await _withFallback(
        _methods.invokeMethod<String>('requestPermission'),
        null,
        const Duration(seconds: 3),
      );
    } on MissingPluginException {
      // 测试环境或插件未注册：按拒绝处理（不阻塞文字输入）。
      return VoicePermission.denied;
    } on TimeoutException {
      return VoicePermission.denied;
    }
    return switch (result) {
      'granted' => VoicePermission.granted,
      'blocked' => VoicePermission.blocked,
      _ => VoicePermission.denied,
    };
  }

  @override
  Future<void> openSettings() async {
    try {
      await _methods.invokeMethod<void>('openSettings');
    } on PlatformException {
      // 该 ROM 没有可打开的设置页。
    }
  }

  @override
  Stream<VoiceEvent> get events => _stream ??= _events
      .receiveBroadcastStream()
      .map(_decode)
      .where((e) => e != null)
      .cast<VoiceEvent>()
      .asBroadcastStream();

  VoiceEvent? _decode(Object? raw) {
    if (raw is! Map || raw['sessionId'] != _session) return null;
    return switch (raw['type']) {
      'level' => VoiceLevel(((raw['value'] as num?) ?? 0).toDouble()),
      'partial' => VoicePartial(raw['text'] as String? ?? ''),
      'final' => VoiceFinal(raw['text'] as String? ?? ''),
      'error' => VoiceError((raw['code'] as num?)?.toInt() ?? 0),
      'limit' => const VoiceLimit(),
      'end' => const VoiceEnd(),
      _ => null,
    };
  }

  @override
  Future<void> startRecognizer({String? language}) {
    _session = ++_nextSession;
    return _methods.invokeMethod<void>('startRecognizer', {
      'language': ?language,
      'sessionId': _session,
    });
  }

  @override
  Future<void> startRecorder({required int maxSeconds}) {
    _session = ++_nextSession;
    return _methods.invokeMethod<void>('startRecorder', {
      'maxSeconds': maxSeconds,
      'sessionId': _session,
    });
  }

  @override
  Future<Uint8List?> stop() => _methods.invokeMethod<Uint8List>('stop');

  @override
  Future<void> cancel() async {
    _session = ++_nextSession;
    try {
      await _methods.invokeMethod<void>('cancel');
    } on PlatformException {
      // 已经停了。
    }
  }
}
