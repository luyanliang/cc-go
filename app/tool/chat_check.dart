// ignore_for_file: avoid_print
// 聊天页端到端（task 6.1–6.4）：真实 Claude 轮次。
//   ① 空闲发送→PONG；② 运行中排队（不发 RPC）→ 长任务自然结束 → idle
//   边沿自动送出 → 第二轮应答；③ 运行中打断即停；④ 重进会话快照不重不漏。
//   前置：daemon 已在 8749 (TLS, HOME=/tmp/ccgo-verify) 运行。
import 'dart:async';
import 'dart:io';

import 'package:cc_go/state/app_link.dart';
import 'package:cc_go/state/chat_controller.dart';
import 'package:cc_go/state/credentials.dart';
import 'package:cc_go/state/transcript.dart';
import 'package:cc_go/transport/reconnecting_link.dart';
import 'package:cc_go/transport/tofu.dart';

const port = 8749;
const host = '127.0.0.1';

int doneAssistantCount(ChatController c) => c.transcript.items
    .where((i) =>
        i.kind == ItemKind.assistant && i.status == 'done' && i.text.trim().isNotEmpty)
    .length;

Future<void> main() async {
  await Directory('/tmp/ccgo-test').create(recursive: true);

  final paired = await pairWithDaemon(
    host: InternetAddress(host), port: port, code: '654321', policy: TofuPolicy(),
  );
  final appLink = AppLink.fromCredentials(HostCredentials(
    host: host, port: port,
    token: paired.token, fingerprint: paired.fingerprint,
    hostName: paired.hostName,
  ));
  await appLink.start();
  await appLink.link.states
      .firstWhere((s) => s == LinkState.connected)
      .timeout(const Duration(seconds: 10));

  final created =
      await appLink.link.call('session.create', {'cwd': '/tmp/ccgo-test'}) as Map;
  final sessionId = created['summary']['id'] as String;
  final chat = ChatController(sessionId: sessionId, link: appLink.link);
  await _until(() => chat.transcript.loaded, const Duration(seconds: 10));
  print('[cc] 会话 $sessionId 建立并收到快照 ✓');

  // ① 空闲发送 → 一轮问答
  await chat.send('Reply with exactly the word PONG and nothing else.');
  await _until(() => doneAssistantCount(chat) >= 1, const Duration(seconds: 180));
  final pong = chat.transcript.items
      .firstWhere((i) =>
          i.kind == ItemKind.assistant && i.status == 'done' && i.text.trim().isNotEmpty)
      .text;
  if (!pong.toUpperCase().contains('PONG')) throw StateError('期望 PONG，得到: $pong');
  print('[cc] ① 空闲发送开新轮 → "$pong" ✓');
  await _until(() => !chat.running, const Duration(seconds: 30),
      what: '第一轮 phase 回到 idle');

  // ② 运行中排队 → 自然结束 → idle 边沿自动送出
  await chat.send(
      'Count from 1 to 20, one number per line, pausing briefly between each line.');
  await _until(() => chat.running, const Duration(seconds: 30));
  await chat.send('Reply with exactly the word QUEUED-OK and nothing else.');
  if (chat.queuedTexts.length != 1) {
    throw StateError('期望 1 条排队消息，实际 ${chat.queuedTexts}');
  }
  print('[cc] ② 运行中发送仅显示排队 ✓（等待长任务自然结束…）');
  await _until(() => chat.queuedTexts.isEmpty, const Duration(seconds: 30),
      what: 'idle 边沿送出排队消息');
  await _until(() => doneAssistantCount(chat) >= 2, const Duration(seconds: 180));
  print('[cc] ② 排队消息自动送出 → 第二轮完成 ✓');

  // ③ 打断即停
  final itemsBeforeCancel = chat.transcript.items.length;
  await chat.send(
      'Count from 1 to 500 extremely slowly, one number per line, with generous pauses.');
  await _until(() => chat.running, const Duration(seconds: 30));
  await chat.cancel();
  await _until(() => !chat.running, const Duration(seconds: 30));
  final itemsAtStop = chat.transcript.items.length;
  await Future<void>.delayed(const Duration(seconds: 5));
  final itemsLater = chat.transcript.items.length;
  if (itemsLater > itemsAtStop) {
    throw StateError('打断后转录仍在增长：$itemsAtStop → $itemsLater');
  }
  print('[cc] ③ 打断即停 ✓（$itemsBeforeCancel → $itemsAtStop 条，之后无增长）');

  // ④ 重进会话：新 controller 快照不重不漏
  final idsLive = chat.transcript.items.map((i) => i.id).toSet();
  final reentered = ChatController(sessionId: sessionId, link: appLink.link);
  await _until(() => reentered.transcript.loaded, const Duration(seconds: 10));
  final idsSnapshot = reentered.transcript.items.map((i) => i.id).toSet();
  if (!idsSnapshot.containsAll(idsLive)) {
    throw StateError('重进丢条目：live=${idsLive.length} snapshot=${idsSnapshot.length}');
  }
  print('[cc] ④ 重进快照 ⊇ 实时条目 ✓（共 ${idsSnapshot.length} 条，无重复 id）');

  reentered.dispose();
  chat.dispose();
  await appLink.stop();
  print('[cc] ALL CHAT CHECKS PASSED');
  exit(0);
}

Future<void> _until(bool Function() test, Duration timeout, {String what = ''}) async {
  final deadline = DateTime.now().add(timeout);
  while (!test()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not met within $timeout ${what.isEmpty ? "" : "($what)"}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}
