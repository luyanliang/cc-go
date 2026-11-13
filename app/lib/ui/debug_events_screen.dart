// ignore_for_file: avoid_print

/// 临时调试页（task 3.4）：手动输入 host/port/配对码，配对后把收到的
/// 全部事件帧原样滚动展示。第 4 节正式配对屏就位后降级为角落入口，
/// 端到端验收（9.1）时仍用它看原始帧。
library;

import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:cc_go/transport/host_link.dart';
import 'package:cc_go/transport/reconnecting_link.dart';
import 'package:cc_go/transport/tofu.dart';

class DebugEventsScreen extends StatefulWidget {
  const DebugEventsScreen({super.key});

  @override
  State<DebugEventsScreen> createState() => _DebugEventsScreenState();
}

class _DebugEventsScreenState extends State<DebugEventsScreen> {
  final _hostController = TextEditingController(text: '127.0.0.1');
  final _portController = TextEditingController(text: '8747');
  final _codeController = TextEditingController();

  ReconnectingHostLink? _link;
  String _status = '未连接';
  Color get _statusColor => switch (_status) {
        '已连接' => Colors.green,
        '连接中…' => Colors.orange,
        _ => Colors.grey,
      };
  final _frames = <String>[];
  final _scrollController = ScrollController();
  StreamSubscription<DaemonEvent>? _eventsSub;
  StreamSubscription<LinkState>? _stateSub;

  @override
  void dispose() {
    unawaited(_link?.stop());
    unawaited(_eventsSub?.cancel());
    unawaited(_stateSub?.cancel());
    _hostController.dispose();
    _portController.dispose();
    _codeController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() => _status = '连接中…');
    _addFrame('→ pairing over TLS…');
    try {
      final paired = await pairWithDaemon(
        host: InternetAddress(_hostController.text.trim()),
        port: int.parse(_portController.text.trim()),
        code: _codeController.text.trim(),
        policy: TofuPolicy(),
      );
      _addFrame('← paired: host=${paired.hostName} device=${paired.deviceId}');
      _addFrame('   cert fingerprint: ${paired.fingerprint}');

      final link = ReconnectingHostLink(
        connector: () => HostLink.connect(
          wsUri: Uri(
            scheme: 'wss',
            host: _hostController.text.trim(),
            port: int.parse(_portController.text.trim()),
            path: '/ws',
          ),
          token: paired.token,
          customClient: tofuHttpClient(
            policy: TofuPolicy(expectedFingerprint: paired.fingerprint),
          ),
        ),
      );
      _link = link;
      _eventsSub = link.events.listen((e) => _addFrame(e.toString()));
      _stateSub = link.states.listen((s) {
        setState(() => _status = s == LinkState.connected ? '已连接' : '连接中…');
      });
      await link.start();
    } on TofuRejectedException catch (e) {
      _addFrame('✗ 安全错误: $e');
      setState(() => _status = '未连接');
    } on PairingFailedException catch (e) {
      _addFrame('✗ 配对失败: $e');
      setState(() => _status = '未连接');
    } on Object catch (e) {
      _addFrame('✗ $e');
      setState(() => _status = '未连接');
    }
  }

  void _addFrame(String line) {
    setState(() => _frames.add(line));
    unawaited(_autoscroll());
  }

  Future<void> _autoscroll() async {
    await Future<void>.delayed(Duration.zero);
    if (!_scrollController.hasClients) return;
    await _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('cc-go · 原始事件调试'),
        actions: [
          IconButton(
            icon: const Icon(Icons.clear_all),
            tooltip: '清空',
            onPressed: () => setState(_frames.clear),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _hostController,
                        decoration: const InputDecoration(labelText: '主机'),
                        keyboardType: TextInputType.url,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 1,
                      child: TextField(
                        controller: _portController,
                        decoration: const InputDecoration(labelText: '端口'),
                        keyboardType: TextInputType.number,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: _codeController,
                        decoration: const InputDecoration(
                          labelText: '6 位配对码',
                          counterText: '',
                        ),
                        maxLength: 6,
                        keyboardType: TextInputType.number,
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _connect,
                      child: const Text('连接'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Container(
            width: double.infinity,
            color: _statusColor.withValues(alpha: 0.15),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(_status, style: TextStyle(color: _statusColor)),
          ),
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(8),
              itemCount: _frames.length,
              itemBuilder: (context, index) => Text(
                _frames[index],
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
