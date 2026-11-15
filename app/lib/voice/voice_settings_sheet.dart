/// 语音输入设置（voice-dictation）：听写模式三选 + 各模式的前置条件说明。
/// 入口在会话列表的 ⋮ 菜单。
library;

import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'voice_controller.dart';

/// 打开语音输入设置，返回用户选定的模式（未更改返回 null）。
Future<VoiceMode?> showVoiceSettingsSheet(BuildContext context) async {
  final current = await VoiceInputController.loadMode();
  if (!context.mounted) return null;
  final selected = await showModalBottomSheet<VoiceMode>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      final theme = Theme.of(sheetContext);
      String describe(VoiceMode mode) => switch (mode) {
            VoiceMode.auto => '自动（推荐）：优先 daemon 转录，其次系统识别',
            VoiceMode.system => '仅系统识别：使用手机的语音识别服务',
            VoiceMode.engine => '仅 daemon 转录：录音发到电脑转写',
          };
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('语音输入', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              // RadioGroup 管理组值（material_ui 的 RadioListTile 约定）。
              RadioGroup<VoiceMode>(
                groupValue: current,
                onChanged: (value) =>
                    Navigator.of(sheetContext).pop(value ?? current),
                child: Column(
                  children: [
                    for (final mode in VoiceMode.values)
                      RadioListTile<VoiceMode>(
                        value: mode,
                        title: Text(mode.label),
                        subtitle: Text(
                          describe(mode),
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'daemon 转录需在电脑侧启动时配置 --speech-provider openai '
                '与转录服务；系统识别在部分无 GMS 的 ROM（荣耀/华为）上不可用。',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    },
  );
  if (selected != null && selected != current) {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('voice.mode', selected.name);
    return selected;
  }
  return null;
}
