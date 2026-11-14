/// 图片附件（task 2.3）：发送前的缩放压缩（image 包，纯 Dart）与线上
/// 形态。压缩目标：长边 ≤1568px、JPEG 体积 ≤1MiB（质量迭代降到 40，
/// 仍超则减半分辨率再试）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

const kAttachmentMaxBytes = 1024 * 1024;
const kAttachmentMaxLongSide = 1568;
const kAttachmentMaxCount = 4;

class PendingAttachment {
  const PendingAttachment({
    required this.name,
    required this.mimeType,
    required this.bytes,
  });

  final String name;
  final String mimeType;
  final Uint8List bytes;

  int get sizeBytes => bytes.length;

  /// session.prompt 的 attachments 数组成员。
  Map<String, dynamic> toWire() => {
        'name': name,
        'mimeType': mimeType,
        'dataBase64': base64Encode(bytes),
      };
}

/// 压缩为可发送的附件；解码失败（非图片/损坏）返回 null。
Future<PendingAttachment?> compressAttachment(
  Uint8List raw, {
  String name = 'image.jpg',
}) async {
  final decoded = img.findDecoderForData(raw)?.decode(raw);
  if (decoded == null) return null;

  var image = decoded;
  // 长边超限先等比缩小。
  final longSide = image.width >= image.height ? image.width : image.height;
  if (longSide > kAttachmentMaxLongSide) {
    image = img.copyResize(
      image,
      width: image.width >= image.height ? kAttachmentMaxLongSide : null,
      height: image.height > image.width ? kAttachmentMaxLongSide : null,
    );
  }

  // 质量迭代，仍超限则减半分辨率再试一轮。
  for (var round = 0; round < 3; round++) {
    for (final quality in [82, 70, 55, 40]) {
      final encoded = img.encodeJpg(image, quality: quality);
      if (encoded.length <= kAttachmentMaxBytes) {
        return PendingAttachment(
          name: name,
          mimeType: 'image/jpeg',
          bytes: Uint8List.fromList(encoded),
        );
      }
    }
    image = img.copyResize(image, width: image.width ~/ 2, height: image.height ~/ 2);
  }
  return null; // 极端情形（极噪点图）：压不进 1MiB，宁可不发
}
