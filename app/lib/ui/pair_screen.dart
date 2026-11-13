/// 配对屏（task 4.1）：地址/端口/配对码表单，错误反馈（码错/网络不通/
/// 指纹不符），成功后 invalidate 路由凭据 → 进会话列表（5.x 前为占位）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../state/pairing.dart';
import '../state/providers.dart';
import 'debug_events_screen.dart';

class PairScreen extends ConsumerStatefulWidget {
  const PairScreen({super.key});

  @override
  ConsumerState<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends ConsumerState<PairScreen> {
  final _hostController = TextEditingController();
  final _portController = TextEditingController(text: '8747');
  final _codeController = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await runPairing(
        store: ref.read(credentialStoreProvider),
        host: _hostController.text,
        portText: _portController.text,
        code: _codeController.text,
      );
      ref.invalidate(credentialsProvider); // → RootGate 切换到会话侧
    } on PairingError catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('连接到电脑'),
        actions: [
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
                  '在电脑上运行 cc-go daemon，启动横幅会显示\n6 位配对码与证书指纹。',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 24),
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}
