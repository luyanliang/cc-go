/// task 4.3：模型选择面板 —— 目录列表选择、当前模型高亮、空目录自由
/// 输入回退。loader 注入。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:cc_go/ui/chat/model_sheet.dart';

const catalog = ModelCatalog(
  models: [
    ModelEntry(id: 'claude-opus-5', displayName: 'Opus 5'),
    ModelEntry(id: 'claude-sonnet-5', displayName: 'Sonnet 5'),
  ],
  current: 'claude-sonnet-5',
);

Future<void> openSheet(
  WidgetTester tester, {
  required ModelCatalog catalog,
  String? currentModel,
  required Future<void> Function(String) onApply,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: FilledButton(
            onPressed: () => showModelSheet(
              context,
              loader: () async => catalog,
              currentModel: currentModel,
              onApply: onApply,
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('目录列表渲染，点选即应用', (tester) async {
    String? applied;
    await openSheet(
      tester,
      catalog: catalog,
      currentModel: 'claude-sonnet-5',
      onApply: (m) async => applied = m,
    );
    expect(find.text('Opus 5'), findsOneWidget);
    expect(find.text('Sonnet 5'), findsOneWidget);

    await tester.tap(find.text('Opus 5'));
    await tester.pumpAndSettle();
    expect(applied, 'claude-opus-5');
    expect(find.text('选择模型'), findsNothing, reason: '应用后面板关闭');
  });

  testWidgets('当前模型在列表中高亮', (tester) async {
    await openSheet(
      tester,
      catalog: catalog,
      currentModel: 'claude-opus-5',
      onApply: (m) async {},
    );
    // RadioGroup 的 groupValue 即当前模型；选中态画在对应 tile 上。
    final group = tester.widget<RadioGroup<String>>(find.byType(RadioGroup<String>));
    expect(group.groupValue, 'claude-opus-5');
    final checked = tester
        .widgetList<RadioListTile<String>>(find.byType(RadioListTile<String>))
        .where((r) => r.value == 'claude-opus-5')
        .toList();
    expect(checked, hasLength(1));
  });

  testWidgets('空目录显示提示并可自由输入应用', (tester) async {
    String? applied;
    await openSheet(
      tester,
      catalog: const ModelCatalog(models: []),
      currentModel: null,
      onApply: (m) async => applied = m,
    );
    expect(find.textContaining('未获取到模型目录'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'claude-haiku-5');
    await tester.pump();
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    expect(applied, 'claude-haiku-5');
  });
}
