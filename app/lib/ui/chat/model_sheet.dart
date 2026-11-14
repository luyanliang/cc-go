/// 模型选择面板（task 4.3）：目录列表单选（当前模型高亮）+ 自由输入
/// 回退（旧 CLI 空目录时唯一入口）。loader 注入，widget 测试不碰网络。
library;

import 'package:material_ui/material_ui.dart';

class ModelEntry {
  const ModelEntry({required this.id, required this.displayName});

  final String id;
  final String displayName;
}

class ModelCatalog {
  const ModelCatalog({required this.models, this.current});

  final List<ModelEntry> models;

  /// 当前模型（会话摘要或目录里带回）。
  final String? current;
}

Future<void> showModelSheet(
  BuildContext context, {
  required Future<ModelCatalog> Function() loader,
  required String? currentModel,
  required Future<void> Function(String model) onApply,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
      child: _ModelSheet(
        loader: loader,
        currentModel: currentModel,
        onApply: (model) async {
          Navigator.of(sheetContext).pop();
          await onApply(model);
        },
      ),
    ),
  );
}

class _ModelSheet extends StatefulWidget {
  const _ModelSheet({
    required this.loader,
    required this.currentModel,
    required this.onApply,
  });

  final Future<ModelCatalog> Function() loader;
  final String? currentModel;
  final Future<void> Function(String model) onApply;

  @override
  State<_ModelSheet> createState() => _ModelSheetState();
}

class _ModelSheetState extends State<_ModelSheet> {
  late Future<ModelCatalog> _future;
  String? _custom;

  @override
  void initState() {
    super.initState();
    _future = widget.loader();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('选择模型', style: Theme.of(context).textTheme.titleMedium),
          ),
          Flexible(
            child: FutureBuilder<ModelCatalog>(
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final catalog = snapshot.data ?? const ModelCatalog(models: []);
                final current = widget.currentModel ?? catalog.current;
                return RadioGroup<String>(
                  groupValue: current,
                  onChanged: (value) {
                    if (value != null) widget.onApply(value);
                  },
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final model in catalog.models)
                        RadioListTile<String>(
                          value: model.id,
                          title: Text(model.displayName),
                          subtitle: Text(model.id, style: const TextStyle(fontSize: 12)),
                        ),
                    if (catalog.models.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          '未获取到模型目录（旧版 CLI？），可直接输入模型标识：',
                          style: TextStyle(fontSize: 13),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              decoration: const InputDecoration(
                                labelText: '自定义模型标识',
                                isDense: true,
                                border: OutlineInputBorder(),
                              ),
                              onChanged: (v) => setState(() => _custom = v),
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: _custom == null || _custom!.trim().isEmpty
                                ? null
                                : () => widget.onApply(_custom!.trim()),
                            child: const Text('应用'),
                          ),
                        ],
                      ),
                    ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
