/// 选图入口（task 2.3）：底部弹层选相册/拍照 → image_picker 取图 →
/// 压缩为可发送附件。测试经 Composer 的 pickAttachment 注入假实现，
/// 不走这里。
library;

import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../../state/attachment.dart';

Future<PendingAttachment?> pickAttachmentWithSheet(BuildContext context) async {
  final source = await showModalBottomSheet<ImageSource>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.photo_outlined),
            title: const Text('从相册选择'),
            onTap: () => Navigator.of(sheetContext).pop(ImageSource.gallery),
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('拍照'),
            onTap: () => Navigator.of(sheetContext).pop(ImageSource.camera),
          ),
        ],
      ),
    ),
  );
  if (source == null || !context.mounted) return null;

  final picked = await ImagePicker().pickImage(
    source: source,
    // 先让平台层做一轮粗压缩；最终的体积上限由 compressAttachment 保证。
    imageQuality: 85,
    maxWidth: 2048,
    maxHeight: 2048,
  );
  if (picked == null) return null;
  final raw = await picked.readAsBytes();
  return compressAttachment(Uint8List.fromList(raw), name: picked.name);
}
