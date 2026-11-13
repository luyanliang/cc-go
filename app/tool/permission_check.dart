// ignore_for_file: avoid_print
// 权限卡片端到端（task 7.1/7.2）：真实工具权限三场景。
//   A 允许 → 工具行完成 + 文件落盘；B 拒绝+免问 → 工具行已拒绝、文件未建；
//   C 同类工具再试 → 不再弹卡（条目直接 denied）。
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

Future<void> main() async {
  final dir = Directory('/tmp/ccgo-test');
  await dir.create(recursive: true);
  for (final name in ['perma.txt', 'permb.txt']) {
    final f = File('${dir.path}/$name');
    if (f.existsSync()) f.deleteSync();
  }

  final paired = await pairWithDaemon(
    host: InternetAddress(host), port: port, code: '654321', policy: TofuPolicy(),
  );
  final appLink = AppLink.fromCredentials(HostCredentials(
    host: host, port: port,
    token: paired.token, fingerprint: paired.fingerprint, hostName: 'x',
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

  TranscriptItem? pendingTool() {
    for (final item in chat.transcript.items) {
      if (item.kind == ItemKind.tool && item.status == 'awaiting-permission') {
        return item;
      }
    }
    return null;
  }

  // --- A：允许 ---
  await chat.send(
      'Create a file named perma.txt in the current directory containing exactly the text ok. Then reply DONE-A.');
  final toolA = (await _waitFor(pendingTool, const Duration(seconds: 180)))!;
  print('[pc] A 权限卡片出现：${toolA.toolName} ✓');
  await chat.respondPermission(toolA.id, true);
  await _until(
    () => chat.transcript.items.any((i) => i.id == toolA.id && i.status == 'done'),
    const Duration(seconds: 180),
  );
  final contentA = File('/tmp/ccgo-test/perma.txt').readAsStringSync().trim();
  if (contentA != 'ok') throw StateError('perma.txt 内容异常: $contentA');
  print('[pc] A 允许 → 工具行完成，文件落盘 ✓');
  await _until(() => !chat.running, const Duration(seconds: 60));

  // --- B：拒绝 + 本次会话不再询问 ---
  await chat.send(
      'Create a file named permb.txt in the current directory containing exactly the text no. Then reply DONE-B.');
  final toolB = (await _waitFor(pendingTool, const Duration(seconds: 180)))!;
  await chat.respondPermission(toolB.id, false, allowToolForSession: true);
  await _until(
    () => chat.transcript.items.any((i) => i.id == toolB.id && i.status == 'denied'),
    const Duration(seconds: 60),
  );
  if (File('/tmp/ccgo-test/permb.txt').existsSync()) {
    throw StateError('拒绝后文件不应存在');
  }
  print('[pc] B 拒绝+免问 → 工具行已拒绝、文件未建 ✓');
  await _until(() => !chat.running, const Duration(seconds: 60));

  // --- C：同类工具再试 → 不再弹卡 ---
  await chat.send(
      'Use the Write tool (specifically Write, not Bash or anything else) to create a file named permb.txt in the current directory with the text no.');
  final toolC = (await _waitFor(() {
    for (final i in chat.transcript.items) {
      if (i.kind == ItemKind.tool && i.status == 'denied' && i.id != toolB.id) {
        return i;
      }
    }
    return null;
  }, const Duration(seconds: 180)))!;
  print('[pc] C 同类工具直接 denied（无新卡片）✓ itemId=${toolC.id}');
  if (File('/tmp/ccgo-test/permb.txt').existsSync()) {
    throw StateError('免问拒绝后文件不应被创建');
  }

  chat.dispose();
  await appLink.stop();
  print('[pc] ALL PERMISSION CHECKS PASSED');
  exit(0);
}

Future<T?> _waitFor<T>(T? Function() probe, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    final hit = probe();
    if (hit != null) return hit;
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

Future<void> _until(bool Function() test, Duration timeout) async {
  await _waitFor<bool?>(() => test() ? true : null, timeout);
}
