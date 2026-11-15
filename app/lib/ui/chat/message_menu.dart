/// 消息长按菜单（chat-message-interactions）：复制 / 选择文字 / 引用。
/// 只作用于被长按的那条消息；复制/引用拿的都是 Markdown 原文（密钥
/// 遮罩只改屏显，不改数据）。
library;

import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:material_ui/material_ui.dart';

import '../../state/secret_mask.dart';
import '../widgets/glass.dart';
import 'render/copy_button.dart';

/// 弹出消息菜单。[onQuote] null 时不显示引用项。
Future<void> showMessageMenu(
  BuildContext context, {
  required String text,
  VoidCallback? onQuote,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: GlassCard(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _MenuTile(
                icon: Icons.copy_outlined,
                label: '复制',
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  Clipboard.setData(ClipboardData(text: text));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已复制')),
                  );
                },
              ),
              _MenuTile(
                icon: Icons.select_all_outlined,
                label: '选择文字',
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _showTextSelectionDialog(context, text);
                },
              ),
              if (onQuote != null)
                _MenuTile(
                  icon: Icons.format_quote_outlined,
                  label: '引用',
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    onQuote();
                  },
                ),
            ],
          ),
          ),
        ),
      ),
    ),
  );
}

/// 选择文字：全文进对话框，系统选择手势可用（只影响查看，不改消息）。
void _showTextSelectionDialog(BuildContext context, String text) {
  showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('选择文字'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: SelectionArea(
            child: Text(text),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('关闭'),
        ),
        TextButton(
          onPressed: () {
            Navigator.of(dialogContext).pop();
          },
          child: const Text('复制所选'),
        ),
      ],
    ),
  );
}

class _MenuTile extends StatelessWidget {
  const _MenuTile({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, size: 20),
      title: Text(label, style: Theme.of(context).textTheme.bodyMedium),
      onTap: onTap,
    );
  }
}

/// 密钥遮罩文本（chat-message-interactions）：疑似凭据段渲染为等宽
/// chip（默认遮罩，点开逐段显示原文）；纯显示层 —— 复制/引用拿到的是
/// [CopyIconButton] 用的原文，不经此组件。
class SecretMaskedText extends StatefulWidget {
  const SecretMaskedText(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  @override
  State<SecretMaskedText> createState() => _SecretMaskedTextState();
}

class _SecretMaskedTextState extends State<SecretMaskedText> {
  final _revealed = <int>{}; // 已点开遮罩段的 start 集合

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = widget.style ?? theme.textTheme.bodyMedium ?? const TextStyle();
    final secrets = scanSecrets(widget.text);
    // 普通文本（非可选）：长按留给外层菜单（选择文字走菜单里的
    // SelectionArea 对话框）——SelectableText 会吞掉长按手势。
    if (secrets.isEmpty) return Text(widget.text, style: style);

    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final secret in secrets) {
      if (secret.start > cursor) {
        spans.add(TextSpan(text: widget.text.substring(cursor, secret.start)));
      }
      final revealed = _revealed.contains(secret.start);
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: InkWell(
          onTap: () => setState(() => revealed
              ? _revealed.remove(secret.start)
              : _revealed.add(secret.start)),
          borderRadius: BorderRadius.circular(6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              revealed ? secret.text : secret.label,
              style: style.copyWith(
                fontFamily: revealed ? null : 'monospace',
                fontSize: (style.fontSize ?? 14) - 1,
              ),
            ),
          ),
        ),
      ));
      cursor = secret.end;
    }
    if (cursor < widget.text.length) {
      spans.add(TextSpan(text: widget.text.substring(cursor)));
    }
    return Text.rich(
      TextSpan(style: style, children: spans),
    );
  }
}
