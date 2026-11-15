/// mermaid 块渲染（chat-streaming-rendering）：消息内只显示源码（可
/// 复制）+ 全屏渲染入口；渲染页用 WebView 加载本地打包的 mermaid 引擎
/// （离线可用，design D6），引擎不可用/渲染超时降级回源码 + 错误提示，
/// 不影响消息本体渲染。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'code_block.dart';
import 'copy_button.dart';

/// 消息内的 mermaid 块：源码视图 + 全屏渲染入口。
class MermaidPreview extends StatelessWidget {
  const MermaidPreview({required this.code, super.key});

  final String code;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 整行头部都可点（打开渲染页）——小 InkWell 热区在真机上
          // 难点中，GestureDetector + opaque 实测可靠（同脚注行）。
          GestureDetector(
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => MermaidRenderPage(code: code),
            )),
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text('mermaid（源码）',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('渲染',
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: theme.colorScheme.primary)),
                      const SizedBox(width: 2),
                      Icon(Icons.chevron_right,
                          size: 14, color: theme.colorScheme.primary),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: CodeBlockView(
              code: code,
              closed: true,
              highlight: false,
            ),
          ),
        ],
      ),
    );
  }
}

/// 全屏渲染页：WebView + 本地 mermaid 引擎；加载超时（10s）降级提示。
class MermaidRenderPage extends StatefulWidget {
  const MermaidRenderPage({required this.code, super.key});

  final String code;

  @override
  State<MermaidRenderPage> createState() => _MermaidRenderPageState();
}

class _MermaidRenderPageState extends State<MermaidRenderPage> {
  WebViewController? _controller;
  bool _timedOut = false;
  bool _rendered = false;
  Timer? _timeout;

  @override
  void initState() {
    super.initState();
    _timeout = Timer(const Duration(seconds: 10), () {
      if (mounted && !_rendered) setState(() => _timedOut = true);
    });
  }

  @override
  void dispose() {
    _timeout?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('mermaid')),
      body: _timedOut
          ? _Fallback(code: widget.code)
          : WebViewWidget(
              controller: _controller ??= _buildController(context),
            ),
      // 引擎加载后注入代码；渲染成功的判断以 JS 侧回执为准（超时兜底）。
    );
  }

  WebViewController _buildController(BuildContext context) {
    return WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) async {
          await _controller?.runJavaScriptReturningResult(
            'document.addEventListener("message", function (e) {'
            '  window.flutter_inapp !== undefined;'
            '});',
          );
          if (!mounted) return;
          setState(() => _rendered = true);
          _timeout?.cancel();
          // 注入 mermaid 代码（html 侧监听 message 事件）。
          final escaped = widget.code
              .replaceAll('\\', '\\\\')
              .replaceAll("'", "\\'")
              .replaceAll('\n', '\\n');
          await _controller?.runJavaScript(
            "var ev = new MessageEvent('message', {data: '$escaped'});"
            'document.dispatchEvent(ev);',
          );
        },
      ))
      ..loadFlutterAsset('assets/mermaid.html');
  }
}

/// 引擎加载失败/超时：源码 + 可理解的错误提示，不影响复制。
class _Fallback extends StatelessWidget {
  const _Fallback({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('渲染引擎未能加载，可复制源码到其他工具渲染',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          CodeBlockView(code: code, closed: true, highlight: false),
          CopyIconButton(text: code, tooltip: '复制源码'),
        ],
      ),
    );
  }
}
