/// 全屏图片查看器（task 2.4/3.4 共用）：黑底、双指/滚轮缩放、右上关闭。
library;

import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../../state/transcript.dart';

Future<void> showAttachmentFullScreen(BuildContext context, TranscriptAttachment attachment) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog.fullscreen(
      backgroundColor: Colors.black87,
      child: Stack(
        children: [
          Center(
            child: InteractiveViewer(
              maxScale: 4,
              child: Image.memory(base64Decode(attachment.dataBase64)),
            ),
          ),
          Positioned(
            top: MediaQuery.of(dialogContext).padding.top + 4,
            right: 4,
            child: IconButton(
              tooltip: '关闭',
              onPressed: () => Navigator.of(dialogContext).pop(),
              icon: const Icon(Icons.close, color: Colors.white),
            ),
          ),
        ],
      ),
    ),
  );
}
