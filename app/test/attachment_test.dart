/// task 2.3：附件压缩单测 + Composer 附件预览/移除/发送参数 widget 测试
/// （选图经 pickAttachment 注入，不碰平台通道）。
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';

import 'package:cc_go/state/attachment.dart';
import 'package:cc_go/ui/chat/composer.dart';

Uint8List pngOf({int width = 64, int height = 64, bool noise = false}) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      // 高频图案提高 JPEG 压缩难度（伪噪声）或纯色（容易压）。
      final color = noise
          ? img.ColorRgb8((x * 7) % 256, (y * 13) % 256, ((x + y) * 3) % 256)
          : img.ColorRgb8(200, 30, 30);
      image.setPixel(x, y, color);
    }
  }
  return Uint8List.fromList(img.encodePng(image));
}

PendingAttachment fakeAttachment(String tag) => PendingAttachment(
      name: '$tag.jpg',
      mimeType: 'image/jpeg',
      bytes: pngOf(width: 8, height: 8),
    );

Widget harness({
  required Future<void> Function(String, List<PendingAttachment>) onSend,
  required Future<PendingAttachment?> Function() pick,
}) =>
    MaterialApp(
      home: Scaffold(
        body: Composer(
          running: false,
          busy: false,
          onSend: onSend,
          onCancel: () {},
          pickAttachment: pick,
        ),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('compressAttachment', () {
    test('压缩为 JPEG 且体积在上限内', () async {
      final raw = pngOf(width: 1600, height: 900, noise: true);
      final result = await compressAttachment(raw, name: 'photo.png');
      expect(result, isNotNull);
      expect(result!.mimeType, 'image/jpeg');
      expect(result.sizeBytes, lessThan(kAttachmentMaxBytes));
      // 结果仍是可解码图片。
      expect(img.findDecoderForData(result.bytes)?.decode(result.bytes), isNotNull);
    });

    test('超长边先缩小', () async {
      final raw = pngOf(width: 3000, height: 1000);
      final result = await compressAttachment(raw);
      final decoded = img.findDecoderForData(result!.bytes)!.decode(result.bytes)!;
      expect(decoded.width, lessThanOrEqualTo(kAttachmentMaxLongSide));
    });

    test('非图片数据返回 null', () async {
      final result = await compressAttachment(Uint8List.fromList([1, 2, 3, 4]));
      expect(result, isNull);
    });

    test('toWire 形态', () async {
      final a = PendingAttachment(
        name: 'x.jpg',
        mimeType: 'image/jpeg',
        bytes: Uint8List.fromList([104, 105]),
      );
      expect(a.toWire(), {
        'name': 'x.jpg',
        'mimeType': 'image/jpeg',
        'dataBase64': 'aGk=', // "hi"
      });
    });
  });

  group('Composer 附件交互', () {
    testWidgets('选图后出现预览，随消息发送附件', (tester) async {
      final sent = <(String, List<PendingAttachment>)>[];
      await tester.pumpWidget(harness(
        onSend: (text, attachments) async => sent.add((text, attachments)),
        pick: () async => fakeAttachment('a'),
      ));

      await tester.enterText(find.byType(TextField), '看这张图');
      await tester.tap(find.byTooltip('添加图片'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('移除附件'), findsOneWidget, reason: '预览条出现');

      await tester.tap(find.byTooltip('发送'));
      await tester.pumpAndSettle();
      expect(sent, hasLength(1));
      expect(sent.single.$1, '看这张图');
      expect(sent.single.$2, hasLength(1));
      expect(sent.single.$2.single.name, 'a.jpg');
      // 发送后清空预览。
      expect(find.byTooltip('移除附件'), findsNothing);
    });

    testWidgets('移除后发送不含该附件', (tester) async {
      final sent = <(String, List<PendingAttachment>)>[];
      await tester.pumpWidget(harness(
        onSend: (text, attachments) async => sent.add((text, attachments)),
        pick: () async => fakeAttachment('a'),
      ));

      await tester.enterText(find.byType(TextField), '文本');
      await tester.tap(find.byTooltip('添加图片'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('移除附件'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('移除附件'), findsNothing);

      await tester.tap(find.byTooltip('发送'));
      await tester.pumpAndSettle();
      expect(sent.single.$2, isEmpty);
    });

    testWidgets('无选图回调时隐藏附件按钮', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Composer(
            running: false,
            busy: false,
            onSend: (text, attachments) async {},
            onCancel: () {},
          ),
        ),
      ));
      expect(find.byTooltip('添加图片'), findsNothing);
    });

    testWidgets('发送失败保留文本与附件（评审回归）', (tester) async {
      await tester.pumpWidget(harness(
        onSend: (text, attachments) async => throw StateError('offline'),
        pick: () async => fakeAttachment('a'),
      ));

      await tester.enterText(find.byType(TextField), '看这张图');
      await tester.tap(find.byTooltip('添加图片'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('发送'));
      await tester.pumpAndSettle();
      // 文本与附件都保留在输入区，可重试。
      expect(find.widgetWithText(TextField, '看这张图'), findsOneWidget);
      expect(find.byTooltip('移除附件'), findsOneWidget);
    });
  });
}
