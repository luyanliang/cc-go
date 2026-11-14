/// 只读历史控制器的 Riverpod 装配（multi-project-history 4.4）。
/// family key = (claudeSessionId, cwd)——同一个 Claude 会话只回放一份。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'history_api.dart';
import 'history_controller.dart';

final historyControllerProvider =
    Provider.autoDispose.family<HistoryController, (String, String)>((ref, key) {
  final (claudeSessionId, cwd) = key;
  final api = ref.watch(historyApiProvider);
  if (api == null) {
    throw StateError('连接未就绪，无法回放历史');
  }
  final controller = HistoryController(
    claudeSessionId: claudeSessionId,
    cwd: cwd,
    api: api,
  );
  ref.onDispose(controller.dispose);
  return controller;
});
