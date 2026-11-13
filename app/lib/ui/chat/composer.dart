/// 输入区（task 6.3/6.4）：文本框 + 发送；运行中出现打断按钮。
library;

import 'package:material_ui/material_ui.dart';

class Composer extends StatefulWidget {
  const Composer({
    super.key,
    required this.running,
    required this.busy,
    required this.onSend,
    required this.onCancel,
  });

  final bool running;
  final bool busy;
  final ValueChanged<String> onSend;
  final VoidCallback onCancel;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty || widget.busy) return;
    widget.onSend(text);
    _controller.clear();
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                enabled: !widget.busy,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: widget.running ? '输入将排队，当前轮结束后送出' : '发消息…',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  isDense: true,
                ),
                onSubmitted: (_) => _submit(),
              ),
            ),
            const SizedBox(width: 8),
            if (widget.running)
              IconButton.filledTonal(
                tooltip: '打断当前轮',
                onPressed: widget.onCancel,
                icon: const Icon(Icons.stop_circle_outlined),
              ),
            const SizedBox(width: 4),
            IconButton.filled(
              tooltip: '发送',
              onPressed: widget.busy ? null : _submit,
              icon: const Icon(Icons.send_outlined),
            ),
          ],
        ),
      ),
    );
  }
}
