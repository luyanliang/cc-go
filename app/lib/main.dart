import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'state/providers.dart';
import 'theme/motion.dart';
import 'theme/tokens.dart';
import 'ui/lifecycle_host.dart';
import 'ui/pair_screen.dart';
import 'ui/session_list_screen.dart';

void main() {
  runApp(const ProviderScope(child: CcGoApp()));
}

class CcGoApp extends StatelessWidget {
  const CcGoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return LifecycleHost(
      child: MaterialApp(
        title: 'cc-go',
        navigatorKey: rootNavigatorKey,
        // 雾蓝玻璃主题（调色板 + 玻璃/动效 token，见 lib/theme/）。
        theme: CcTheme.light(),
        darkTheme: CcTheme.dark(),
        // 页面竖向渐变（mist/night Top→Bottom）全局铺底；BackdropGroup：
        // 互不重叠的玻璃件（grouped: true）共享一次背景采样；
        // AppMotionScope：灵动档动效分级（树上没有即标准档）。
        builder: (context, child) {
          final tokens = Theme.of(context).extension<CcTokens>();
          return AppMotionScope(
            fluid: true,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: tokens?.pageGradient ?? const LinearGradient(
                  colors: [Color(0xFFEBF1FE), Color(0xFFF6F7FC)],
                ),
              ),
              child: BackdropGroup(child: child ?? const SizedBox.shrink()),
            ),
          );
        },
        home: const RootGate(),
      ),
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
