/// task 2.4 + 3.1：用户气泡附件回显（缩略图/全屏）与转录模型新字段
/// 兼容（旧数据无附件不报错、快照/实时合并幂等）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';

import 'package:cc_go/state/transcript.dart';
import 'package:cc_go/ui/chat/chat_rows.dart';

String get tinyJpegBase64 {
  final image = img.Image(width: 24, height: 24);
  img.fill(image, color: img.ColorRgb8(60, 120, 200));
  return base64Encode(img.encodeJpg(image));
}

TranscriptItem userWithAttachment() => TranscriptItem.fromJson({
      'kind': 'user',
      'id': 'u1',
      'text': '这张图怎么回事',
      'createdAt': 1,
      'attachments': [
        {'name': 'a.jpg', 'mimeType': 'image/jpeg', 'dataBase64': tinyJpegBase64},
      ],
    });

Widget harness(TranscriptItem item) => MaterialApp(
      home: Scaffold(
        body: TranscriptListView(
          items: [item],
          queuedTexts: const [],
          loaded: true,
          scrollController: ScrollController(),
        ),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('带附件的用户消息渲染缩略图，点开全屏', (tester) async {
    await tester.pumpWidget(harness(userWithAttachment()));
    expect(find.text('这张图怎么回事'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget, reason: '附件缩略图');

    await tester.tap(find.byType(Image));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget, reason: '全屏查看');
    expect(find.byTooltip('关闭'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsNothing);
  });

  testWidgets('旧数据无附件不渲染图也不报错', (tester) async {
    await tester.pumpWidget(harness(TranscriptItem.fromJson({
      'kind': 'user',
      'id': 'u1',
      'text': '普通消息',
      'createdAt': 1,
    })));
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  });

  group('转录模型新字段兼容（task 3.1）', () {
    test('fromJson 解析工具原始输出字段', () {
      final item = TranscriptItem.fromJson({
        'kind': 'tool',
        'id': 't1',
        'name': 'Bash',
        'status': 'done',
        'createdAt': 1,
        'resultText': 'line1\nline2',
        'resultTruncated': true,
        'resultImages': [
          {'mimeType': 'image/png', 'dataBase64': 'aW1n'},
        ],
      });
      expect(item.resultText, 'line1\nline2');
      expect(item.resultTruncated, isTrue);
      expect(item.resultImages.single.dataBase64, 'aW1n');
    });

    test('旧条目无新字段全部回退默认值', () {
      final item = TranscriptItem.fromJson({
        'kind': 'tool',
        'id': 't1',
        'name': 'Bash',
        'status': 'done',
        'createdAt': 1,
      });
      expect(item.resultText, isNull);
      expect(item.resultTruncated, isFalse);
      expect(item.resultImages, isEmpty);
      expect(item.attachments, isEmpty);
    });

    test('item.updated 整体替换保持幂等（含新字段）', () {
      Map<String, dynamic> updated(Map<String, dynamic> extra) => {
            'ev': 'item.updated',
            'item': {'kind': 'tool', 'id': 't1', 'name': 'Bash', 'status': 'done', 'createdAt': 1, ...extra},
          };

      var state = const TranscriptState();
      state = state.applySessionEvent(updated({'resultText': 'v1'}));
      state = state.applySessionEvent(updated({'resultText': 'v1'}));
      expect(state.items.single.resultText, 'v1');
      expect(state.items, hasLength(1));
    });
  });
}
