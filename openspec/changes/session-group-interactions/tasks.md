# Tasks

## 1. daemon：projects.unregister RPC

- [x] 1.1 `protocol.ts` 新增 `ProjectsUnregisterParams = { path }` 并导出；`npm run typecheck` 通过
- [x] 1.2 `server.ts` 新增 `projects.unregister` handler：canonicalize 后 `store.removeProject`，返回 `{ removed }`（幂等，未注册返回 `removed:false`）；单测覆盖注销后 `projects.list` 不含、重复注销不报错、未认证被拒

## 2. app：分组交互

- [x] 2.1 `history_api.dart` 加 `unregisterProject(path)`；单测覆盖方法调用参数
- [x] 2.2 `project_models.dart` 分组纯函数过滤"未注册且无会话"的组；单测覆盖（有会话的未注册组保留、注册空组保留、未注册空组隐藏）
- [x] 2.3 `session_list_screen.dart`：分组行点击折叠/展开（`StatefulWidget` 局部折叠集合 + 展开状态箭头）；`flutter analyze` 零告警
- [x] 2.4 分组行长按注销流：仅已注册组响应长按 → 确认对话框（说明重启复活语义）→ `unregisterProject` → 刷新列表；`flutter analyze` 零告警

## 3. 验收

- [ ] 3.1 `bash scripts/check.sh` 全绿；真机验证：点击折叠/展开、空未注册组隐藏、长按注销后组态变化与既有会话保留
