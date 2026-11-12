# 上游声明与跟踪策略

## 上游

| | |
|---|---|
| 仓库 | <https://github.com/cursor/plugins>(main) |
| 跟踪路径 | [`pstack/`](https://github.com/cursor/plugins/tree/main/pstack) |
| 作者 | Lauren Tan([poteto](https://x.com/poteto)) |
| 许可 | MIT,`pstack/LICENSE`,Copyright (c) 2026 Lauren Tan |
| 起始跟踪版本 | v0.14.8 |
| 上游主页 | <https://github.com/cursor/plugins/tree/main/pstack> |

## 与上游官方 Claude Code 构建的关系

上游自身在 [`harness/pstack/claude-code`](https://github.com/cursor/plugins/tree/main/harness/pstack/claude-code) 提供官方 Claude Code 构建,由 `cursor/plugins` 根目录的 `.claude-plugin/marketplace.json` 以 `pstack@cursor-plugins` 发布,生成脚本是上游的 `scripts/generate-pstack-harness-trees.mjs`。

本仓库是独立移植,不是该构建的镜像,也不是 Cursor 或 poteto 的官方发布。两者的差别在于处理 Cursor 专属引用的方式:上游构建在技能正文中保留 Cursor 名称,另用 [`pstack/docs/harness/claude-code.md`](https://github.com/cursor/plugins/blob/main/pstack/docs/harness/claude-code.md) 说明映射;本仓库按 `transform/map.json` 就地改写正文与 frontmatter。逐项差异与测量基准见 README。

## 派生边界

| 处理 | 内容 |
|---|---|
| 原样复制 | 上游 `LICENSE`;清单中的 `author`、`homepage`、`repository`、`license`、`keywords` |
| 原样保留 | 上游 `.cursor-plugin/plugin.json` 全文,置于通用包的 `com.cursor/` 扩展目录 |
| 改写 | `skills/` 与 `agents/` 的 frontmatter 与正文,规则见 [`transform/map.json`](../transform/map.json) 与 [`transform/MAPPING.md`](../transform/MAPPING.md) |
| 新增 | `build-control-for-your-app` 技能,源在本仓库 `transform/assets/`,不含 Cursor 内部文本 |
| 不复制 | 上游 `docs/`、`assets/`、`automations/`、`README.md` |

## 许可义务

两种产物都是 pstack 的派生作品,必须随附上游 MIT 文本:

- Claude Code 形态:[`plugins/pstack/LICENSE`](../plugins/pstack/LICENSE),入仓分发。
- 通用形态:release zip 内的 `LICENSE`,由 CI 生成。

`transform.ps1` 在上游 `LICENSE` 缺失时直接失败,`validate.ps1` 的 gate2 对两种产物分别检查该文件存在。改名、打标、重写正文都不改变这一义务。

本仓库自身的许可是 MIT,Copyright (c) 2026 lab-GESTALT,见根目录 [`LICENSE`](../LICENSE);它覆盖本仓库的管线代码与文档,不替代上游对 pstack 内容的版权声明。

## 溯源链

- [`pin.json`](../pin.json) 的 `commit` 记录当前跟踪的上游提交,用于溯源与 release notes;`pstackTree` 记录 `pstack` 子树哈希,用于判断是否需要同步,上游其余目录的提交不触发重算;`version` 与 `date` 记录该次同步的上游版本与提交日期。
- 每个 release 的 tag 形如 `pstack-<version>-r<N>`,notes 写明 `Auto-synced from cursor/plugins@<commit>`,可直接定位上游快照。
- 通用包内 `com.cursor/plugin.json` 是上游原始清单,可与 `plugin.json` 对照,确认哪些字段被投影、哪些被归入扩展。

## 跟踪策略

同步节奏与发布方式见 [`.github/workflows/sync.yml`](../.github/workflows/sync.yml):每 3 日 cron 与手动触发,三层验证门全绿才提交、打 tag、推送并发布。失败时 `pin.json` 保持不变,下一次 cron 重试,并在单个 `sync failed:` issue 中附上门的实际输出。

移植缺陷在本仓库提 issue;pstack 自身的缺陷提到[上游](https://github.com/cursor/plugins/issues)。