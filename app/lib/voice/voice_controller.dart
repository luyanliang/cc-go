/// 听写控制器（voice-dictation，移植自 dsh-Go 的 VoiceInputController）。
///
/// 自动模式：daemon 端转录服务就绪（catalog 有可用 provider）→ 直接引擎
/// 录音；否则系统识别（可用且未被标记不可靠）。系统服务发生非"无语音/
/// 权限"类失败 → 本次操作内一次性降级到引擎转录（重新录音——系统服务
/// 之前的音频不声称可找回）。中国 ROM 的系统服务常自报可用然后失败，
/// 健康诊断（systemUnreliable）让这类环境被记住并被跳过。
///
/// 识别文本按听写起点的光标锚点插入草稿；中英文拼接处补空格，CJK 不补。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'voice_bridge.dart';

/// 听写需要的连接能力（ReconnectingHostLink / HostLinkBase 均可适配）。
abstract interface class VoiceLink {
  /// daemon 的转录服务目录；未配置时 providers 为空（不是错误）。
  Future<Map<String, dynamic>> speechCatalog();

  /// 上传一段 16kHz mono PCM16 WAV，返回转录文本。
  Future<String> speechTranscribe(
    Uint8List wav, {
    String? providerId,
    String? language,
  });
}

enum VoicePhase { idle, starting, listening, transcribing }

enum VoiceEngine { system, engine }

enum VoiceMode { auto, system, engine }

/// 提给 UI 的人话消息；[openSettings] = 需要打开系统应用设置（麦克风权限），
/// [change] = 提示用户更换听写方式（去设置里改语音模式）。
class VoiceMessage {
  const VoiceMessage(this.text, {this.openSettings = false, this.change = false});
  final String text;
  final bool openSettings;
  final bool change;
}

/// `SpeechRecognizer.ERROR_*` 全表 → 人话；未知/厂商码保留原始码。
String voiceErrorText(int code) => switch (code) {
      1 => '网络超时，请检查网络后重试',
      2 => '网络不可用',
      3 => '录音音频出错，请重试',
      4 => '识别服务出错，请稍后再试',
      5 => '识别服务内部错误，请稍后再试',
      6 => '没有检测到语音，请靠近麦克风再试',
      7 => '没听清你说的话，请靠近麦克风再试一次',
      8 => '识别服务忙，请稍后再试',
      9 => '麦克风权限不足，请在系统设置中允许',
      10 => '请求过多，请稍后再试',
      11 => '识别服务连接中断',
      12 => '该语言不被识别服务支持',
      13 => '识别服务缺少该语言包',
      14 => '无法确认识别服务是否支持当前语言',
      15 => '无法监听识别结果',
      VoiceError.recorderFailed => '麦克风打开失败',
      _ => '识别出错（码 $code）',
    };

/// 语音模式持久化键。
const _modeKey = 'voice.mode';

/// 模式的短标签（设置页用）。
extension VoiceModeLabel on VoiceMode {
  String get label => switch (this) {
        VoiceMode.auto => '自动',
        VoiceMode.system => '仅系统识别',
        VoiceMode.engine => '仅 daemon 转录',
      };
}

class VoiceInputController extends ChangeNotifier with WidgetsBindingObserver {
  VoiceInputController({
    required this.input,
    required this.bridge,
    required this.link,
    this.onRecognized,
    bool observeLifecycle = true,
  }) : _observing = observeLifecycle {
    if (_observing) WidgetsBinding.instance.addObserver(this);
    // 能力探测惰性：start() 时才做（构造不碰平台通道 —— flutter_tester
    // 上未 mock 的通道调用永不返回，急切探测会挂测试并留下 pending timer）。
  }

  final TextEditingController input;
  final VoiceBridge bridge;

  /// 当前活跃的语音连接（null = 未连接）；请求发往它。
  final VoiceLink? Function() link;

  /// 一次成功听写落草稿（供统计）。
  final VoidCallback? onRecognized;
  final bool _observing;
  void Function(VoiceMessage message)? onMessage;

  /// 听写中输入框的音量电平。
  final level = ValueNotifier<double>(0);

  VoiceCapabilities _caps = VoiceCapabilities.none;
  Map<String, dynamic>? _catalog;
  VoiceLink? _probedLink;
  Future<void>? _refreshing;
  int _catalogProbe = 0;
  bool _disposed = false;
  bool _foreground = true;

  VoicePhase _phase = VoicePhase.idle;
  VoiceEngine? _engine;
  VoiceMode _runMode = VoiceMode.auto;
  bool _systemSelected = false;
  int _operation = 0;
  bool _fallbackTried = false;
  VoiceLink? _runLink;
  StreamSubscription<VoiceEvent>? _events;
  Timer? _finalTimeout;

  TextEditingValue? _base;
  int _anchorStart = 0;
  int _anchorEnd = 0;
  String _heard = '';

  VoicePhase get phase => _phase;
  bool get active => _phase != VoicePhase.idle;
  VoiceEngine? get engine => _engine;
  bool get engineReady => _caps.recorder && _catalog != null;
  bool get available => _caps.recognizer || engineReady;

  bool _current(int operation) => !_disposed && active && operation == _operation;

  // 手机侧识别属于草稿；引擎录音属于当前连接。开始后换了连接 → 取消。
  bool get _hostCurrent =>
      _engine == VoiceEngine.system ? true : identical(_runLink, link());

  /// 读取持久化的语音模式（无记录 = auto）。静态入口供设置页使用。
  static Future<VoiceMode> loadMode() async {
    final prefs = await SharedPreferences.getInstance();
    return VoiceMode.values.asNameMap()[prefs.getString(_modeKey)] ??
        VoiceMode.auto;
  }

  /// 持久化语音模式。
  static Future<void> saveMode(VoiceMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_modeKey, mode.name);
  }

  Future<VoiceMode> _readMode() => loadMode();

  Future<void> refresh() {
    if (_disposed) return Future.value();
    return _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  }

  Future<void> _refresh() async {
    final caps = await bridge.capabilities();
    if (_disposed) return;
    _caps = caps;
    final current = link();
    _probedLink = current;
    if ((_catalog?.isEmpty ?? true) || !identical(_catalogLink, current)) _catalog = null;
    // 系统服务可用时不等慢的 catalog 探测；降级与显式引擎模式按需探测
    // （有些 ROM 自报可用但一调就挂）。
    if (!caps.recognizer && caps.recorder) await _readCatalog(current);
    if (!_disposed) notifyListeners();
  }

  VoiceLink? _catalogLink;

  Future<Map<String, dynamic>?> _readCatalog(VoiceLink? current) async {
    if (current == null || !_caps.recorder || !identical(link(), current)) return null;
    final probe = ++_catalogProbe;
    Map<String, dynamic>? catalog;
    try {
      catalog = await current.speechCatalog().timeout(const Duration(seconds: 4));
      final providers = catalog['providers'] as List<dynamic>? ?? const [];
      if (providers.isEmpty) catalog = null;
    } catch (_) {
      // daemon 未配置、断连或超时。
      catalog = null;
    }
    if (_disposed || !identical(link(), current)) return null;
    if (probe == _catalogProbe) {
      _catalog = catalog;
      _catalogLink = catalog == null ? null : current;
    }
    return catalog;
  }

  void ensureFresh() {
    if (_disposed) return;
    if (active && !_hostCurrent) {
      final operation = _operation;
      scheduleMicrotask(() {
        if (_current(operation) && !_hostCurrent) unawaited(cancel());
      });
    }
    final current = link();
    if (_refreshing != null || identical(current, _probedLink)) return;
    scheduleMicrotask(() => unawaited(refresh()));
  }

  Future<void> start() async {
    if (active || _disposed || !_foreground) return;
    final operation = ++_operation;
    _fallbackTried = false;
    _runLink = link();
    _setPhase(VoicePhase.starting);
    final VoicePermission permission;
    try {
      permission = await bridge.requestPermission();
    } on Object {      if (_current(operation)) {
        _finish();
        _say(const VoiceMessage('麦克风打开失败'));
      }
      return;
    }
    if (!_current(operation)) return;
    if (!_foreground || !_hostCurrent) {
      debugPrint('[voice] cancel at host/foreground gate');
      await cancel();
      return;
    }
    if (permission != VoicePermission.granted) {
      _finish();
      _say(
        permission == VoicePermission.blocked
            ? const VoiceMessage('麦克风权限被拒，请在系统设置中允许', openSettings: true)
            : const VoiceMessage('需要麦克风权限才能使用语音输入'),
      );
      return;
    }
    try {
      _runMode = await _readMode();
    } catch (_) {
      if (_current(operation)) {
        _finish();
        _say(const VoiceMessage('读取语音设置失败'));
      }
      return;
    }
    if (!_current(operation)) return;
    await refresh();
    if (!_current(operation)) return;
    if (!_hostCurrent) {
      await cancel();
      return;
    }
    final system = _runMode == VoiceMode.system ||
        (_runMode == VoiceMode.auto && _caps.recognizer && !_caps.systemUnreliable);
    _systemSelected = system;
    if (system && !_caps.recognizer) {
      _finish();
      _say(const VoiceMessage('系统没有可用的语音识别服务，请在设置中更换听写方式', change: true));
      return;
    }
    final value = input.value;
    _base = value;
    _anchorStart = value.selection.isValid ? value.selection.start : value.text.length;
    _anchorEnd = value.selection.isValid ? value.selection.end : value.text.length;
    _heard = '';
    // 引擎路径条件：显式 engine 模式，或自动模式下系统不可用/被标记不可靠
    // （中国 ROM 的系统服务常自报可用然后失败 —— 可靠性记忆让我们不再尝试）。
    final useEngine = _runMode == VoiceMode.engine ||
        (_runMode == VoiceMode.auto && !_systemSelected);
    if (system && _runMode == VoiceMode.auto && _caps.recorder) {
      // 引擎优先：catalog 就绪时它说了算；未就绪则维持系统服务原状。
      final target = await _readCatalog(_runLink);
      if (!_current(operation)) return;
      if (target != null) {
        await _startRecorder(operation, target);
        return;
      }
    }
    if (useEngine) {
      final target = await _readCatalog(_runLink);
      if (!_current(operation)) return;
      if (target == null) {
        _finish();
        _say(const VoiceMessage('daemon 未配置转录服务（--speech-provider openai ...）', change: true));
        return;
      }
      await _startRecorder(operation, target);
      return;
    }
    _engine = VoiceEngine.system;
    _listen(operation);
    try {
      await bridge.startRecognizer();
    } on PlatformException catch (error) {
      if (_current(operation) && _engine == VoiceEngine.system) _error(operation, _platformCode(error));
      return;
    }
    if (!_current(operation) || _engine != VoiceEngine.system || _phase != VoicePhase.starting) return;
    HapticFeedback.lightImpact();
    _setPhase(VoicePhase.listening);
  }

  void _listen(int operation) {
    unawaited(_events?.cancel());
    _events = bridge.events.listen((event) => _onEvent(operation, event));
  }

  static int _platformCode(PlatformException error) {
    final details = error.details;
    if (details is Map && details['code'] is num) return (details['code'] as num).toInt();
    return switch (error.code) {
      'permission' => 9,
      'audio' => VoiceError.recorderFailed,
      _ => 5,
    };
  }

  Future<void> _startRecorder(int operation, Map<String, dynamic> catalog, {bool fallback = false}) async {
    debugPrint('[voice] _startRecorder op=$operation current=${_current(operation)}');
    if (!_current(operation)) return;
    _engine = VoiceEngine.engine;
    _listen(operation);
    final maxSeconds = ((catalog['maxDurationSeconds'] as num?)?.toInt() ?? 60).clamp(1, 600);
    try {
      await bridge.startRecorder(maxSeconds: maxSeconds);
    } on PlatformException catch (error) {
      if (_current(operation)) {
        _finish();
        _say(VoiceMessage(voiceErrorText(_platformCode(error))));
      }
      return;
    }
    if (!_current(operation) || _phase != VoicePhase.starting) return;
    if (!identical(_runLink, link())) {
      await cancel();
      return;
    }
    HapticFeedback.lightImpact();
    _setPhase(VoicePhase.listening);
    if (fallback) _say(const VoiceMessage('系统识别失败，已切换为 daemon 转录'));
  }

  Future<void> _fallback(int operation) async {
    debugPrint('[voice] _fallback entered op=$operation');
    _fallbackTried = true;
    _engine = null;
    _finalTimeout?.cancel();
    _finalTimeout = null;
    unawaited(_events?.cancel());
    _events = null;
    _restoreDraft();
    _heard = '';
    _setPhase(VoicePhase.starting);
    try {
      await bridge.cancel();
    } catch (_) {}
    if (!_current(operation)) return;
    if (!_hostCurrent) {
      _finish();
      _say(const VoiceMessage('连接不可用，无法使用 daemon 转录'));
      return;
    }
    final target = await _readCatalog(_runLink);
    if (!_current(operation)) return;
    if (target == null) {
      _finish();
      _say(const VoiceMessage('系统识别失败且 daemon 未配置转录服务，可在设置中更换听写方式', change: true));
      return;
    }
    await _startRecorder(operation, target, fallback: true);
  }

  Future<void> stop() async {
    if (_phase != VoicePhase.listening) return;
    final operation = _operation;
    HapticFeedback.lightImpact();
    _setPhase(VoicePhase.transcribing);
    if (_engine == VoiceEngine.system) {
      // 部分引擎 stop 后不发结果：6 秒兜底用已听到的 partial 收尾。
      _finalTimeout = Timer(const Duration(seconds: 6), () {
        if (!_current(operation) || _engine != VoiceEngine.system) return;
        unawaited(bridge.cancel());
        _completeSystem(_heard);
      });
      try {
        await bridge.stop();
      } on PlatformException catch (error) {
        if (_current(operation) && _engine == VoiceEngine.system) _error(operation, _platformCode(error));
      }
      return;
    }
    await _transcribe(operation);
  }

  Future<void> _transcribe(int operation) async {
    Uint8List? wav;
    try {
      wav = await bridge.stop();
    } on PlatformException catch (error) {
      if (_current(operation)) {
        _finish();
        _say(VoiceMessage(voiceErrorText(_platformCode(error))));
      }
      return;
    }
    if (!_current(operation)) return;
    if (wav == null || wav.length < 44 + 9600) {
      _finish();
      _say(const VoiceMessage('未识别到语音内容，请靠近麦克风再试'));
      return;
    }
    final host = link();
    if (host == null || !identical(_runLink, host)) {
      _finish();
      _say(const VoiceMessage('连接不可用，无法转录'));
      return;
    }
    try {
      final text = await host.speechTranscribe(
        wav,
        providerId: _catalog?['providerId'] as String?,
        language: _catalog?['language'] as String?,
      );
      if (!_current(operation)) return;
      if (text.isEmpty) {
        _finish();
        _say(const VoiceMessage('未识别到语音内容'));
        return;
      }
      _apply(text, provisional: false);
      onRecognized?.call();
      _finish();
    } catch (_) {
      if (!_current(operation)) return;
      _finish();
      _say(const VoiceMessage('转录失败，请稍后再试', change: true));
    }
  }

  void _restoreDraft() {
    final base = _base;
    if (base != null) input.value = base;
  }

  Future<void> cancel() async {
    if (!active) return;
    _restoreDraft();
    _finish();
    try {
      await bridge.cancel();
    } catch (_) {}
  }

  void _error(int operation, int code) {
    // App 已持有麦克风权限，这里的 INSUFFICIENT_PERMISSIONS 是识别服务自己的
    // （厂商服务拒其他应用）。自动模式下一次性降级。
    if (_engine == VoiceEngine.system && _runMode == VoiceMode.auto && !_fallbackTried && VoiceError.canFallback(code)) {
      unawaited(_fallback(operation));
      return;
    }
    final heard = _heard;
    if (heard.trim().isEmpty) {
      _restoreDraft();
    } else {
      _apply(heard, provisional: false);
      onRecognized?.call();
    }
    _finish();
    if (!VoiceError.noSpeech.contains(code) || heard.trim().isEmpty) {
      _say(VoiceMessage(voiceErrorText(code)));
    }
  }

  void _onEvent(int operation, VoiceEvent event) {
    if (!_current(operation)) return;
    switch (event) {
      case VoiceLevel(:final value):
        level.value = value.clamp(0.0, 1.0);
      case VoicePartial(:final text):
        if (_engine != VoiceEngine.system) return;
        _heard = text;
        _apply(text, provisional: true);
      case VoiceFinal(:final text):
        if (_engine != VoiceEngine.system) return;
        _completeSystem(text.isEmpty ? _heard : text);
      case VoiceError(:final code):
        _error(operation, code);
      case VoiceLimit():
        if (_engine == VoiceEngine.engine && _phase == VoicePhase.listening) unawaited(stop());
      case VoiceEnd():
        if (_engine == VoiceEngine.system) {
          _completeSystem(_heard);
        }
    }
  }

  void _completeSystem(String text) {
    if (text.trim().isEmpty) {
      _restoreDraft();
      _finish();
      _say(const VoiceMessage('未识别到语音内容，请靠近麦克风再试'));
    } else {
      _apply(text, provisional: false);
      onRecognized?.call();
      _finish();
    }
  }

  /// 把 [heard] 插到听写起点的锚点处。
  void _apply(String heard, {required bool provisional}) {
    final base = _base;
    if (base == null) return;
    final text = base.text;
    final spoken = heard.trim();
    final before = text.substring(0, _anchorStart);
    final after = text.substring(_anchorEnd);
    final lead = spoken.isNotEmpty && _needsSpace(before, spoken) ? ' ' : '';
    final trail = spoken.isNotEmpty && _needsSpace(spoken, after) ? ' ' : '';
    final inserted = '$lead$spoken$trail';
    final caret = _anchorStart + inserted.length;
    input.value = TextEditingValue(
      text: '$before$inserted$after',
      selection: TextSelection.collapsed(offset: caret - trail.length),
    );
  }

  /// 接缝两侧都是拉丁词才补空格；CJK 不补。
  static bool _needsSpace(String left, String right) {
    if (left.isEmpty || right.isEmpty) return false;
    final a = left.codeUnitAt(left.length - 1);
    final b = right.codeUnitAt(0);
    bool word(int u) => (u >= 0x30 && u <= 0x39) || (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A);
    final leftEnds = word(a) || ',.!?;:'.codeUnits.contains(a);
    return leftEnds && word(b);
  }

  void _finish() {
    _operation++;
    _finalTimeout?.cancel();
    _finalTimeout = null;
    unawaited(_events?.cancel());
    _events = null;
    _base = null;
    _engine = null;
    level.value = 0;
    _setPhase(VoicePhase.idle);
  }

  void _setPhase(VoicePhase phase) {
    if (_phase == phase || _disposed) return;
    _phase = phase;
    notifyListeners();
  }

  void _say(VoiceMessage message) {
    if (!_disposed) onMessage?.call(message);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused || AppLifecycleState.hidden:
        _foreground = false;
        if (active) unawaited(cancel());
      case AppLifecycleState.resumed:
        _foreground = true;
        unawaited(refresh());
      default:
        break;
    }
  }

  @override
  void dispose() {
    if (active) {
      unawaited(bridge.cancel().catchError((_) {}));
    }
    _operation++;
    _disposed = true;
    _finalTimeout?.cancel();
    unawaited(_events?.cancel());
    if (_observing) WidgetsBinding.instance.removeObserver(this);
    level.dispose();
    super.dispose();
  }
}
