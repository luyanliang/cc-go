/// task 3.4：工具结果图片 —— 有图渲染并可放大、无图不出块、超量裁剪
/// 由 daemon 保证（app 侧模型透传 ≤ 上限数量照单全收）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';

import 'package:cc_go/state/transcript.dart';
import 'package:cc_go/ui/chat/chat_rows.dart';

String tinyJpegBase64 = () {
  final image = img.Image(width: 24, height: 24);
  img.fill(image, color: img.ColorRgb8(200, 60, 60));
  return base64Encode(img.encodeJpg(image));
}();

Uint8List get tinyJpegBytes => base64Decode(tinyJpegBase64);

TranscriptItem toolWithImages(int count) => TranscriptItem.fromJson({
      'kind': 'tool',
      'id': 't1',
      'name': 'Read',
      'status': 'done',
      'createdAt': 1,
      'input': {'file_path': '/tmp/pic.png'},
      'resultImages': [
        for (var i = 0; i < count; i++)
          {'mimeType': 'image/jpeg', 'dataBase64': tinyJpegBase64},
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

  testWidgets('结果图片在展开区渲染，点开全屏', (tester) async {
    await tester.pumpWidget(harness(toolWithImages(1)));
    await tester.tap(find.text('Read').first);
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);

    await tester.tap(find.byType(Image));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
  });

  testWidgets('多张结果图片全部渲染', (tester) async {
    await tester.pumpWidget(harness(toolWithImages(2)));
    await tester.tap(find.text('Read').first);
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNWidgets(2));
  });

  testWidgets('无结果图片不出图片区', (tester) async {
    await tester.pumpWidget(harness(TranscriptItem.fromJson({
      'kind': 'tool',
      'id': 't1',
      'name': 'Read',
      'status': 'done',
      'createdAt': 1,
      'input': {'file_path': '/tmp/a.dart'},
      'summary': '文本结果',
    })));
    await tester.tap(find.text('Read').first);
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
