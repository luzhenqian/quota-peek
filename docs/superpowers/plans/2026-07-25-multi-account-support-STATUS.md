# 多账号支持 — 执行状态交接文档

写于：2026-07-26，因当前会话额度用尽而中断，供切换模型/会话后接续执行。

## 这是什么

QuotaPeek（macOS 菜单栏额度监控 App）正在实现"多账号支持"（同一 Provider 可挂多个账号，如公司+个人两个 Claude 订阅）。这是一个已经过完整 brainstorm→设计文档→实施计划→子代理逐任务执行 流程的功能开发，用的是 superpowers 的 `subagent-driven-development` 技能。

- **设计文档**（已批准）：`docs/superpowers/specs/2026-07-25-multi-account-support-design.md`
- **实施计划**（13 个任务，含完整代码）：`docs/superpowers/plans/2026-07-25-multi-account-support.md`
- **执行账本（ledger）**：`.superpowers/sdd/2026-07-25-multi-account-support/progress.md`（下面已摘要，也可直接读原文件）

## 工作区位置（重要）

所有工作在一个隔离 git worktree 里进行，**不是**主仓库目录：

```
worktree 路径：/Users/noah/Work/idea/quota-peek/.claude/worktrees/multi-account-support
worktree 分支：worktree-multi-account-support
当前 HEAD：    167ae710aa01693d1c3418f5e8144c27c13d35b4
```

**继续执行前必须先 `cd` 到这个 worktree 目录**（或者用 EnterWorktree 工具以 `path:` 参数进入），不要在主仓库目录 `/Users/noah/Work/idea/quota-peek` 里操作——见下面"⚠️ 需要先处理的遗留问题"。

## ⚠️ 需要先处理的遗留问题

执行 Task 6（CLI 探针支持自定义登录目录）时，负责实现的子代理**没有在 worktree 里工作，而是直接在主仓库目录 `/Users/noah/Work/idea/quota-peek` 的 `main` 分支上**完成并提交了改动：

```
主仓库 main 分支当前 HEAD: fa2fd91c92171c05c177216725262416ddcac1da
                          "feat: CLI 探针支持通过环境变量重定向登录目录"
```

这个提交本身内容是对的（三个 CLI 探针加 `homeDirectory` 参数 + `environmentOverrides` 纯函数 + 测试，就是 Task 6 该做的事），但**位置错了**——它现在挂在主仓库真实的 `main` 分支上，而不是隔离 worktree 的 `worktree-multi-account-support` 分支上。同时主仓库目录下还多了一个游离的 `.superpowers/` 目录（子代理误建的 SDD 工作区文件）。

**处理建议（按优先级）**：

1. **推荐**：把 `fa2fd91` 这个提交本身的改动 cherry-pick 到 worktree 分支上（`cd` 进 worktree 后 `git cherry-pick fa2fd91`），确认编译测试通过后，再回主仓库把 `main` 分支重置回 `fa2fd91` 之前的那个提交（`dd2763e7d82e937b687e37f8d1285f6487ddafff`，即"多账号支持实施计划"那条），并删除主仓库目录下多出来的 `.superpowers/` 目录。**重置 main 分支是破坏性操作，务必先跟用户确认**，因为主仓库 `main` 是用户日常工作分支。
2. 也可以不 cherry-pick，直接在 worktree 里重新跑一遍 Task 6（子代理会重新生成同样的改动），跑完之后再处理主仓库 `main` 分支的清理（同样需要用户确认再重置）。

不管选哪种，**重置/清理主仓库 `main` 分支这一步都需要显式征得用户同意**，不要自行执行 `git reset --hard`。

**根因**：`Agent` 工具派生的子代理似乎不总是继承父会话 `EnterWorktree` 切换后的当前目录，即使 dispatch prompt 里写了"Work from: <worktree 路径>"。后续每次 dispatch 子代理后，都应该在子代理报告 DONE 后立即用 `git status`/`git log` 确认改动真的落在 worktree 分支上，而不是只看子代理自己汇报的相对路径。Task 1-5 的子代理都正确地在 worktree 里工作（已用 `git log` 核实），只有 Task 6 这一次跑偏了，原因待查（可能与该次 dispatch 未显式包含足够的目录强调有关，也可能是偶发）。

## 已完成任务（Task 1-5，全部在 worktree 分支上，review 全绿）

| Task | 内容 | 提交范围 | 状态 |
|---|---|---|---|
| 1 | `ProviderAccount` 数据类型（新文件 + 4 个测试） | dd2763e..822f1f5 | ✅ complete, review clean |
| 2 | `ProviderSnapshot` 按账号 UUID 建身份 | 822f1f5..8bd8b0a | ✅ complete, review clean |
| 3 | 推荐算法挪成独立纯函数模块 `Recommendation.swift` | 8bd8b0a..9c9e4d9 | ✅ complete, review clean |
| 4 | `AppPreferences` 新增账号数组 + 旧配置迁移 | 25fe8b8..2f18e31 | ✅ complete, review clean（**过程中发现并修正了计划本身的 bug**，见下） |
| 5 | `KimiWebSession` 参数化，去掉硬编码单例 | 2f18e31..167ae71 | ✅ complete, review clean after 1 fix round |

### 过程中发现的两处计划文档 bug（已修正，供了解背景）

1. **Task 4**：计划里 Step 3 的示例代码直接删除了 `codexEnabled` 等 5 个旧布尔字段，跟背景说明"只加不删"自相矛盾，也会立刻让 `SettingsView`/`ProviderFactory` 编译不过。子代理实现时准确抓出了这个矛盾并报告 BLOCKED（没有胡乱擅自处理）。已在提交 `25fe8b8`（docs 提交，纯文本修改计划文件）里修正：保留所有旧字段声明并正常解码，`migrateLegacyAccounts` 改成"不管 provider 是否启用都生成账号，只是 `enabled` 照抄旧值"（而不是被关掉的 provider 干脆不生成账号）。同步改了 Task 4 的测试预期。修完后重新 dispatch 实现，一次通过。
2. **Task 5**：`KimiWebSession.isLoggedIn` 从 `nonisolated static var` 改成普通 `@MainActor` 实例属性后，`ProviderFactory.make`（唯一调用方 `AppModel.refreshAll` 本来就是 `@MainActor`）需要整个 `enum ProviderFactory` 标 `@MainActor` 才能编译——这是计划里漏掉的一步。子代理自己发现并修好了（`@MainActor` 加在刚好需要的地方，没有滥用），标记 DONE_WITH_CONCERNS 如实汇报。已在提交 `1a70e39`（docs）里把这个要求写回计划文本，并同步调整了 Task 8 里对同一处 `@MainActor` 的说明（现在是冗余但无害）。

这两处都是**计划作者（我）的疏漏**，不是子代理的错——子代理的判断和处理方式都是对的（发现矛盾就停下汇报，而不是自己瞎猜着改）。

## 待完成任务（Task 6-13）

| Task | 内容 | 备注 |
|---|---|---|
| 6 | CLI 探针（Claude/Codex/Kimi）支持自定义登录目录（`homeDirectory` 参数 + `environmentOverrides` 纯函数） | **代码已经写出来了，但提交在错误的地方**（见上面"⚠️ 需要先处理的遗留问题"）。处理完位置问题后，这个任务的 review 步骤（task-reviewer 派发）还没做——需要先补上 review 这一步，再往下走。 |
| 7 | `TerminalLauncher`：拉起系统 Terminal 完成 CLI 账号登录 | 未开始 |
| 8 | `ProviderFactory` 新增按账号构造探针的重载 | 未开始，注意其中 `@MainActor` 标注现在是"重复但无害"（见上） |
| 9 | `AppModel` 核心重连线（最大最关键的一个任务） | 未开始 |
| 10 | 账号增删改方法 + Keychain 一次性迁移 | 未开始 |
| 11 | 设置页账号列表 UI（`AccountListSection` + 重写 `SettingsView`） | 未开始 |
| 12 | 清理 `AppPreferences` 遗留字段 | 未开始 |
| 13 | 最终集成验证 + README | 未开始 |

## 怎么接续执行

1. 确认并处理上面"⚠️ 需要先处理的遗留问题"（先跟用户确认要不要重置主仓库 `main` 分支）。
2. `cd` 进 worktree：`/Users/noah/Work/idea/quota-peek/.claude/worktrees/multi-account-support`（或用 `EnterWorktree` 工具 `path:` 参数进入；如果 worktree 已经不在 `git worktree list` 里了，说明上一个会话退出时可能被清理了，需要确认后重新从 `worktree-multi-account-support` 分支恢复，而不是从 `main` 重新建）。
3. 用 `superpowers:subagent-driven-development` 技能继续跑，plan 文件路径：`docs/superpowers/plans/2026-07-25-multi-account-support.md`。技能会自动识别 `.superpowers/sdd/2026-07-25-multi-account-support/progress.md` 里已经记录的完成任务，从 Task 6（处理完位置问题后）或视情况从 Task 7 开始继续，不用重新跑 Task 1-5。
4. **每次子代理汇报 DONE 后，先用 `git log`/`git status` 核实改动真的落在 worktree 分支上，再生成 review 包**——这是这次会话吃过的一次亏，值得作为固定检查步骤。

## 关键上下文（省得重新推导）

- `swift build`/`swift test` 目前在 worktree 分支（167ae71）上是全绿的：30 个测试，1 个跳过（`LiveProbeTests`，需要 `QUOTAPEEK_LIVE_TESTS=1` 才跑），0 失败。
- 用户已经明确选择"Subagent 驱动"执行方式，并同意先建隔离 worktree 再开始。
- 用户对本项目的一贯要求：改完之后要重装真机 App 验证（`./scripts/build-app.sh && open dist/QuotaPeek.app`），完成后 push 到 GitHub 前记得更新 README——这个模式在本次多账号功能里对应计划里的 Task 13。
