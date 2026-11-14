/// 主机管理屏（task 4.2）：已配对主机列表（直连/SSH 徽标）、切换当前
/// 主机、忘记单台主机、入口进添加主机表单。当前主机名加粗并带勾标。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../state/host_entry.dart';
import '../state/providers.dart';
import '../transport/ssh/ssh_host_key.dart';
import 'add_host_screen.dart';

class HostListScreen extends ConsumerWidget {
  const HostListScreen({super.key});

  Future<void> _forget(BuildContext context, WidgetRef ref, HostEntry entry) async {
    await ref.read(hostEntryStoreProvider).remove(entry.id);
    await ref.read(sshSecretsStoreProvider).remove(entry.id);
    final ssh = entry.ssh;
    if (entry.mode == ConnectionMode.ssh && ssh != null) {
      // 忘记 SSH 主机指纹 → 下次连接重新 TOFU。
      await ref
          .read(sshHostKeyStoreProvider)
          .remove(sshHostKeyStoreKey(ssh.host, ssh.port));
    }
    ref.invalidate(hostEntriesProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(hostEntriesProvider);
    final activeId = ref.watch(activeEntryIdProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('主机')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const AddHostScreen()),
        ),
        icon: const Icon(Icons.add),
        label: const Text('添加主机'),
      ),
      body: entries.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('读取主机失败：$e')),
        data: (list) => list.isEmpty
            ? const Center(child: Text('还没有已配对的主机'))
            : ListView(
                children: [
                  for (final entry in list)
                    ListTile(
                      leading: Icon(
                        entry.mode == ConnectionMode.ssh
                            ? Icons.vpn_key_outlined
                            : Icons.lan_outlined,
                      ),
                      title: Row(
                        children: [
                          Flexible(child: Text(entry.hostName)),
                          if (entry.id == (activeId ?? list.first.id)) ...[
                            const SizedBox(width: 6),
                            const Icon(Icons.check_circle,
                                size: 16, color: Colors.green),
                          ],
                        ],
                      ),
                      subtitle: Text(
                        entry.mode == ConnectionMode.ssh
                            ? 'SSH ${entry.ssh?.host}:${entry.ssh?.port}'
                            : entry.displayHost,
                      ),
                      trailing: PopupMenuButton<String>(
                        onSelected: (value) async {
                          if (value == 'use') {
                            ref.read(activeEntryIdProvider.notifier).set(entry.id);
                            ref.invalidate(hostEntriesProvider);
                            if (context.mounted) Navigator.of(context).pop();
                          } else if (value == 'forget') {
                            await _forget(context, ref, entry);
                          }
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(value: 'use', child: Text('切换到这台')),
                          const PopupMenuItem(value: 'forget', child: Text('忘记该主机')),
                        ],
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}
