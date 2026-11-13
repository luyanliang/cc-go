/// 每会话聊天控制器的 Riverpod 装配（autoDispose.family）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_link_provider.dart';
import 'chat_controller.dart';

final chatControllerProvider =
    Provider.autoDispose.family<ChatController, String>((ref, sessionId) {
  final appLink = ref.watch(appLinkProvider).value;
  final controller = ChatController(sessionId: sessionId, link: appLink?.link);
  ref.onDispose(controller.dispose);
  return controller;
});
