import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'state/providers.dart';
import 'ui/pair_screen.dart';
import 'ui/session_list_screen.dart';

void main() {
  runApp(const ProviderScope(child: CcGoApp()));
}

class CcGoApp extends StatelessWidget {
  const CcGoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'cc-go',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo)),
      home: const RootGate(),
    );
  }
}

/// 未配对 → 配对屏；已配对 → 主页（5.x 前为占位壳）。
class RootGate extends ConsumerWidget {
  const RootGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final credentials = ref.watch(credentialsProvider);
    return credentials.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (_, _) => const PairScreen(),
      data: (creds) => creds == null ? const PairScreen() : const SessionListScreen(),
    );
  }
}
