# 多账号支持 — 最终实施状态

完成于：2026-07-26

## 结论

多账号支持的 Task 1–13 已全部实施完成，代码、测试、设置 UI、凭证隔离、迁移逻辑、README 和最终清理均已落在隔离分支 `worktree-multi-account-support`。

- 隔离 worktree：`/Users/noah/Work/idea/quota-peek/.claude/worktrees/multi-account-support`
- 分支：`worktree-multi-account-support`
- 本状态文档提交前的最终集成 HEAD：`a1e8eb8e284e6be2ddc12a1262d3500a7c2eb066`
- 设计文档：`docs/superpowers/specs/2026-07-25-multi-account-support-design.md`
- 实施计划：`docs/superpowers/plans/2026-07-25-multi-account-support.md`
- 执行账本：`.superpowers/sdd/2026-07-25-multi-account-support/progress.md`

## 最终验证

- `swift build`：通过。
- `swift test`：49 个测试，0 失败，1 个跳过。跳过项是需要显式设置 `QUOTAPEEK_LIVE_TESTS=1` 的 `LiveProbeTests`，本次未运行真实 CLI 探测。
- `./scripts/build-app.sh`：Release 构建通过。
- `codesign --verify --deep --strict`：通过。
- `git diff --check origin/main..HEAD`：通过。
- TODO/FIXME/TBD、旧单账号运行时字段和最终 review 指出的无调用适配器：静态检查无残留。
- 隔离 worktree 构建出的 App 已重启并保持运行。

由于 QuotaPeek 是 `LSUIElement` 菜单栏应用，Computer Use 无法附着到它的界面，因此没有自动完成视觉验收和真实账号端到端操作。真实 Claude/Codex/Kimi 登录、GLM/Grok 凭证、通知等验收仍需由用户在菜单栏 UI 中手工确认；这不影响上述构建、测试和静态验收结论。

## 任务状态

| Task | 内容 | 状态 |
|---|---|---|
| 1 | `ProviderAccount` 账号数据模型 | ✅ 完成 |
| 2 | `ProviderSnapshot` 按账号 UUID 建立身份 | ✅ 完成 |
| 3 | 推荐算法切换到账号级纯函数 | ✅ 完成 |
| 4 | `AppPreferences.accounts` 与旧配置幂等迁移 | ✅ 完成 |
| 5 | Kimi 网页会话按账号 data store 隔离 | ✅ 完成 |
| 6 | CLI 探针支持隔离登录目录 | ✅ 完成 |
| 7 | `TerminalLauncher` 登录流程 | ✅ 完成 |
| 8 | `ProviderFactory` 按账号创建探针 | ✅ 完成 |
| 9 | `AppModel` 核心刷新、缓存、推荐与通知切换到账号身份 | ✅ 完成 |
| 10 | 账号增删改、凭证迁移与安全清理 | ✅ 完成 |
| 11 | 设置页账号列表 UI | ✅ 完成 |
| 12 | 清理 `AppPreferences` 旧运行时字段 | ✅ 完成 |
| 13 | 最终集成验证与 README | ✅ 完成 |

## 已解决的实施问题

1. **Task 4 计划字段矛盾**：原计划一度同时要求删除旧字段和维持阶段性可编译。已在 `25fe8b8` 修正规划，并实现为“旧字段仅参与解码迁移，新格式不再编码”，保留禁用账号的迁移状态。
2. **Task 5 遗漏 `@MainActor`**：`KimiWebSession.isLoggedIn` 实例化后要求 `ProviderFactory` 运行在主 actor。计划与实现均已修正。
3. **Task 6 提交落错目录**：实现曾误提交到主仓库真实 `main`。正确改动已进入隔离分支；主仓库 `main` 已恢复到 `dd2763e7d82e937b687e37f8d1285f6487ddafff`，误创建在主仓库的 `.superpowers` 目录已移入废纸篓。该问题已完全解决，不再需要 cherry-pick 或 reset。
4. **最终静态清理**：已删除 Task 11 后遗留的无参凭证/Kimi 适配器、`AppPreferences.isEnabled(_:)` 和未闭环的 `addKimiWebAccount(label:)`；README 也已按当前账号行 UI、凭证与删除语义校准。

## 手工验收提示

如需发布前补齐真实账号验收，重点确认：

- 升级前已有 Provider 无需重新登录，迁移出的默认账号正常出数据。
- 同一 Provider 的多个账号分别刷新、排序和触发低额度通知。
- Kimi 每个账号可独立“追加网页登录”与“退出网页登录”。
- GLM/Grok 多账号凭证互不影响。
- 删除账号后，其卡片、缓存及 QuotaPeek 管理的账号数据被清理，其他账号继续工作。
