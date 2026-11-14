/// 配对屏（task 4.1/5.1/5.2）：地址/端口/配对码表单 + mDNS 发现列表
/// （点选自动填参）+ 扫码入口；错误反馈（码错/网络不通/指纹不符）。
/// 发现为空呈空态提示，手动表单始终可用（host-discovery spec「降级」）。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../state/pairing.dart';
import '../state/providers.dart';
import '../transport/discovery.dart';
import '../transport/pair_qr.dart';
import 'add_host_screen.dart';
import 'debug_events_screen.dart';
import 'scan_pair_qr_screen.dart';

class PairScreen extends ConsumerStatefulWidget {
  const PairScreen({super.key});

  @override
  ConsumerState<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends ConsumerState<PairScreen> {
  final _hostController = TextEditingController();
  final _portController = TextEditingController(text: '8747');
  final _codeController = TextEditingController();
  String? _expectedFingerprint;
  String? _error;
  bool _busy = false;
  bool _scanFailed = false;

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  void _fill({required String host, required int port, String? code, String? fingerprint}) {
    setState(() {
      _hostController.text = host;
      _portController.text = '$port';
      if (code != null) _codeController.text = code;
      _expectedFingerprint = fingerprint;
    });
  }

  Future<void> _scan() async {
    final payload = await Navigator.of(context).push<PairQrPayload>(
      MaterialPageRoute(builder: (_) => const ScanPairQrScreen()),
    );
    if (!mounted) return;
    if (payload == null) {
      setState(() => _scanFailed = true);
      return;
    }
    setState(() => _scanFailed = false);
    _fill(
      host: payload.host,
      port: payload.port,
      code: payload.code,
      fingerprint: payload.fingerprint,
    );
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await runPairing(
        store: ref.read(hostEntryStoreProvider),
        host: _hostController.text,
        portText: _portController.text,
        code: _codeController.text,
        expectedFingerprint: _expectedFingerprint,
      );
      ref.invalidate(hostEntriesProvider); // → RootGate 切换到会话侧
    } on PairingError catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final discovered = ref.watch(discoveredDaemonsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('连接到电脑'),
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code_scanner),
            tooltip: '扫描二维码配对',
            onPressed: _busy ? null : _scan,
          ),
          IconButton(
            icon: const Icon(Icons.bug_report_outlined),
            tooltip: '原始事件调试页',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const DebugEventsScreen()),
            ),
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'cc-go',
                  style: Theme.of(context).textTheme.headlineMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  '在电脑上运行 cc-go daemon，启动横幅会显示\n6 位配对码、二维码与证书指纹。',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                discovered.when(
                  loading: () => const SizedBox.shrink(),
                  error: (_, _) => const SizedBox.shrink(),
                  data: (list) {
                    if (list.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          '局域网内未发现 cc-go 主机（或 mDNS 被路由器抑制），可手动输入。',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      );
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '局域网内发现：',
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                        for (final daemon in list)
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.computer),
                            title: Text(daemon.name),
                            subtitle: Text('${daemon.host}:${daemon.port}'),
                            trailing: const Icon(Icons.chevron_right),
                            enabled: !_busy,
                            onTap: () => _fill(
                              host: daemon.host,
                              port: daemon.port,
                              fingerprint: daemon.fingerprint,
                            ),
                          ),
                        const SizedBox(height: 8),
                      ],
                    );
                  },
                ),
                TextField(
                  controller: _hostController,
                  decoration: const InputDecoration(
                    labelText: '服务器地址',
                    hintText: '如 203.0.113.7',
                  ),
                  keyboardType: TextInputType.url,
                  enabled: !_busy,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _portController,
                  decoration: const InputDecoration(labelText: '端口'),
                  keyboardType: TextInputType.number,
                  enabled: !_busy,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _codeController,
                  decoration: const InputDecoration(
                    labelText: '6 位配对码',
                    counterText: '',
                  ),
                  maxLength: 6,
                  keyboardType: TextInputType.number,
                  enabled: !_busy,
                  onSubmitted: (_) => _busy ? null : _submit(),
                ),
                const SizedBox(height: 16),
                if (_error != null) ...[
                  Text(
                    _error!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                ],
                if (_scanFailed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      '未识别到有效的配对二维码（需为 ccgo://pair 格式），表单未改动。',
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                      textAlign: TextAlign.center,
                    ),
                  ),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: _busy
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('配对'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                                builder: (_) => const AddHostScreen()),
                          ),
                  child: const Text('或添加直连 / SSH 隧道主机'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
