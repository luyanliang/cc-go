/// 添加主机（task 4.2）：直连 / SSH 两套表单。SSH 流程走 runSshPairing
/// （建隧道 → 经隧道配对）；SSH 主机指纹被拒时弹确认对话框，用户显式
/// 确认后覆写指纹重试一次（ssh-tunnel spec「SSH 主机指纹 TOFU」）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../state/host_entry.dart';
import '../state/pairing.dart';
import '../state/providers.dart';
import '../transport/ssh/ssh_secrets.dart';
import '../transport/ssh/ssh_tunnel_link.dart';

class AddHostScreen extends ConsumerStatefulWidget {
  const AddHostScreen({super.key});

  @override
  ConsumerState<AddHostScreen> createState() => _AddHostScreenState();
}

class _AddHostScreenState extends ConsumerState<AddHostScreen> {
  ConnectionMode _mode = ConnectionMode.direct;
  final _host = TextEditingController();
  final _port = TextEditingController(text: '8747');
  final _code = TextEditingController();
  // SSH 表单。
  final _sshHost = TextEditingController();
  final _sshPort = TextEditingController(text: '22');
  final _sshUser = TextEditingController();
  final _sshDaemonPort = TextEditingController(text: '8747');
  final _sshPassword = TextEditingController();
  final _sshKeyPem = TextEditingController();
  var _sshUseKey = false;

  String? _error;
  var _busy = false;

  @override
  void dispose() {
    for (final c in [
      _host,
      _port,
      _code,
      _sshHost,
      _sshPort,
      _sshUser,
      _sshDaemonPort,
      _sshPassword,
      _sshKeyPem,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  SshSecrets get _secrets => _sshUseKey
      ? SshSecrets(privateKeyPem: _sshKeyPem.text)
      : SshSecrets(password: _sshPassword.text);

  Future<bool> _confirmHostKeyReplacement() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('SSH 主机指纹变化'),
        content: const Text(
            '这台电脑的 SSH 主机指纹与之前记录的不一致。\n'
            '如果服务器确实重装过，可以选择信任新指纹；'
            '否则请先确认网络环境是否安全。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('信任新指纹'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _submitSsh() async {
    final ssh = SshHostConfig(
      host: _sshHost.text.trim(),
      port: int.tryParse(_sshPort.text.trim()) ?? 0,
      username: _sshUser.text.trim(),
      authMethod: _sshUseKey ? SshAuthMethod.privateKey : SshAuthMethod.password,
      daemonPort: int.tryParse(_sshDaemonPort.text.trim()) ?? 8747,
    );
    final daemonPort = int.tryParse(_sshDaemonPort.text.trim()) ?? 8747;
    var trustedNewKey = false;
    while (true) {
      try {
        final entry = await runSshPairing(
          store: ref.read(hostEntryStoreProvider),
          secretsStore: ref.read(sshSecretsStoreProvider),
          hostKeyStore: ref.read(sshHostKeyStoreProvider),
          ssh: ssh,
          daemonPort: daemonPort,
          code: _code.text,
          secrets: _secrets,
          trustNewHostKey: trustedNewKey,
        );
        ref.read(activeEntryIdProvider.notifier).set(entry.id);
        ref.invalidate(hostEntriesProvider);
        if (mounted) Navigator.of(context).pop();
        return;
      } on PairingError catch (e) {
        final cause = e.cause;
        final hostKeyRejected =
            cause is SshLinkError && cause.kind == SshLinkErrorKind.hostKeyRejected;
        if (hostKeyRejected && !trustedNewKey && mounted) {
          if (await _confirmHostKeyReplacement()) {
            trustedNewKey = true; // 显式确认 → 覆写指纹重试一次
            continue;
          }
          setState(() => _error = '已取消连接（主机指纹未更新）');
          return;
        }
        setState(() => _error = e.message);
        return;
      } on FormatException catch (e) {
        setState(() => _error = '输入格式不正确：${e.message}');
        return;
      }
    }
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_mode == ConnectionMode.ssh) {
        await _submitSsh();
        return;
      }
      final entry = await runPairing(
        store: ref.read(hostEntryStoreProvider),
        host: _host.text,
        portText: _port.text,
        code: _code.text,
      );
      ref.read(activeEntryIdProvider.notifier).set(entry.id);
      ref.invalidate(hostEntriesProvider);
      if (mounted) Navigator.of(context).pop();
    } on PairingError catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('添加主机')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedButton<ConnectionMode>(
                  segments: const [
                    ButtonSegment(value: ConnectionMode.direct, label: Text('直连')),
                    ButtonSegment(value: ConnectionMode.ssh, label: Text('SSH 隧道')),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (selection) =>
                      setState(() => _mode = selection.first),
                ),
                const SizedBox(height: 16),
                if (_mode == ConnectionMode.direct) ...[
                  TextField(
                    controller: _host,
                    decoration: const InputDecoration(
                      labelText: '服务器地址',
                      hintText: '如 203.0.113.7',
                    ),
                    keyboardType: TextInputType.url,
                    enabled: !_busy,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _port,
                    decoration: const InputDecoration(labelText: '端口'),
                    keyboardType: TextInputType.number,
                    enabled: !_busy,
                  ),
                ] else ...[
                  TextField(
                    controller: _sshHost,
                    decoration: const InputDecoration(
                      labelText: 'SSH 主机',
                      hintText: '域名或 IP',
                    ),
                    keyboardType: TextInputType.url,
                    enabled: !_busy,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _sshPort,
                    decoration: const InputDecoration(labelText: 'SSH 端口'),
                    keyboardType: TextInputType.number,
                    enabled: !_busy,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _sshUser,
                    decoration: const InputDecoration(labelText: 'SSH 用户名'),
                    enabled: !_busy,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _sshDaemonPort,
                    decoration: const InputDecoration(
                      labelText: 'daemon 回环端口',
                      helperText: '电脑上 cc-go --localhost 的端口',
                    ),
                    keyboardType: TextInputType.number,
                    enabled: !_busy,
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('密码')),
                      ButtonSegment(value: true, label: Text('私钥')),
                    ],
                    selected: {_sshUseKey},
                    onSelectionChanged: (s) => setState(() => _sshUseKey = s.first),
                  ),
                  const SizedBox(height: 12),
                  if (_sshUseKey)
                    TextField(
                      controller: _sshKeyPem,
                      decoration: const InputDecoration(
                        labelText: '私钥 PEM',
                        helperText: '只保存在本机安全存储；加密私钥的口令不保存',
                      ),
                      maxLines: 4,
                      enabled: !_busy,
                    )
                  else
                    TextField(
                      controller: _sshPassword,
                      decoration: const InputDecoration(labelText: 'SSH 密码'),
                      obscureText: true,
                      enabled: !_busy,
                    ),
                ],
                const SizedBox(height: 16),
                TextField(
                  controller: _code,
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
                      : const Text('连接并配对'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
