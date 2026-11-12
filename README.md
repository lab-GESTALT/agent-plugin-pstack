# agent-plugin-pstack

[![sync-pstack](https://github.com/lab-GESTALT/agent-plugin-pstack/workflows/sync-pstack/badge.svg)](https://github.com/lab-GESTALT/agent-plugin-pstack/actions/workflows/sync.yml)

[English](#english) · [中文](#中文) · [Upstream pstack](https://github.com/cursor/plugins/tree/main/pstack) · [Releases](https://github.com/lab-GESTALT/agent-plugin-pstack/releases) · [MIT](LICENSE)

## English

### What is agent-plugin-pstack?

agent-plugin-pstack is an automated, harness-neutral port of [pstack](https://github.com/cursor/plugins/tree/main/pstack), the agent-workflow plugin by Lauren Tan ([poteto](https://x.com/poteto)) in [cursor/plugins](https://github.com/cursor/plugins). It rewrites Cursor-specific mechanisms into portable equivalents and republishes the result in two formats: an [Agent Plugins 1.0](https://agent-plugins.org) package and a Claude Code plugin. A GitHub Actions pipeline syncs every 3 days and publishes only after three validation gates pass.

pstack itself is a set of skills and subagents for rigorous engineering work: reproduce before fixing, verify against the running artifact, design before coding, and parallelize only once a single agent can be trusted. Its entry point is `poteto-mode`, which picks a playbook and drives the other skills.

### Install in Claude Code

```
/plugin marketplace add lab-GESTALT/agent-plugin-pstack
/plugin install pstack@agent-plugin-pstack
```

Claude Code namespaces plugin skills, so `/poteto-mode` becomes `/pstack:poteto-mode`. Two steps to start:

1. `/pstack:setup-pstack` — choose a reasoning budget and a model per role.
2. `/pstack:poteto-mode` — the main entry point for any task that needs rigor.

Auto-update is off for third-party marketplaces. Turn it on under `/plugin` → **marketplaces** → `agent-plugin-pstack`, or update once with `claude plugin update pstack@agent-plugin-pstack`.

This repository is the marketplace: [`.claude-plugin/marketplace.json`](.claude-plugin/marketplace.json) points at [`plugins/pstack/`](plugins/pstack), which is committed and installable directly from `main`.

### Install the generic Agent Plugins package

Every [release](https://github.com/lab-GESTALT/agent-plugin-pstack/releases) attaches `pstack-<version>-r<N>.zip`, an Agent Plugins 1.0 tree:

```
plugin.json      # $schema: https://agent-plugins.org/schemas/1.0.0/plugin.schema.json
skills/          # 59 skills, each a directory with SKILL.md
agents/          # 2 subagent definitions
LICENSE          # upstream MIT, Copyright (c) 2026 Lauren Tan
com.cursor/      # the original Cursor manifest, preserved verbatim
```

Extract it wherever your harness loads Agent Plugins packages. The zip is built by CI and is not committed to the repository.

### What is inside?

Counts below are for pstack 0.15.36.

| Component | Count | Detail |
|---|---|---|
| Skills | 59 | 58 from upstream, plus `build-control-for-your-app` |
| Engineering principles | 24 | the `principle-*` skills, e.g. `principle-prove-it-works`, `principle-fix-root-causes` |
| Playbooks | 23 | under `poteto-mode`, e.g. bug fix, perf, refactoring, runtime forensics |
| Subagents | 2 | `poteto-agent`, `comment-sicko` |

Frequently used skills: `poteto-mode` (orchestration), `setup-pstack` (model and budget configuration), `architect` (design before code), `swarm` (parallel workers), `blast-radius` (what a change could break), `tdd`, `unslop` (cut AI tells from prose), `technical-writing`.

The port ships skills and agents only. Upstream's guide and harness notes are not copied; read them at [`pstack/docs/guide`](https://github.com/cursor/plugins/tree/main/pstack/docs/guide).

### How is this different from upstream's Claude Code build?

Upstream ships an official Claude Code build at [`harness/pstack/claude-code`](https://github.com/cursor/plugins/tree/main/harness/pstack/claude-code), installable with `/plugin marketplace add cursor/plugins` then `/plugin install pstack@cursor-plugins`. That build keeps Cursor names in the skill text and explains the mapping in a separate adapter document.

This port instead rewrites those references in place, so the skills read as harness-neutral instructions. Matching lines in `skills/` plus `agents/`, measured against upstream `cursor/plugins@a5539b1` (pstack 0.15.36):

| Cursor-specific reference | Upstream Claude Code build | This port |
|---|---|---|
| `pstack-models.mdc` | 11 | 0 |
| `.cursor/skills` | 10 | 0 |
| `subagent_type` | 8 | 0 |
| `~/.cursor/rules` | 7 | 0 |
| `AskQuestion` | 6 | 0 |
| `api2.cursor.sh` | 1 | 0 |
| Files with `icon:` / `color:` frontmatter | 2 | 0 |

Two further differences: this port adds the `build-control-for-your-app` skill, and it publishes a standalone Agent Plugins 1.0 zip alongside the Claude Code marketplace.

One caveat: the replacement wording is Chinese, so a rewritten passage appears in Chinese inside otherwise English skills. The mapping is documented in [`transform/MAPPING.md`](transform/MAPPING.md).

### Upstream, attribution, and license

| | |
|---|---|
| Upstream repository | [cursor/plugins](https://github.com/cursor/plugins) |
| Tracked path | [`pstack/`](https://github.com/cursor/plugins/tree/main/pstack) |
| Upstream author | Lauren Tan ([poteto](https://x.com/poteto)) |
| Upstream license | MIT, Copyright (c) 2026 Lauren Tan |
| This repository's license | MIT, Copyright (c) 2026 lab-GESTALT |
| Tracked commit and version | [`pin.json`](pin.json) |
| Attribution details | [`docs/upstream-attribution.md`](docs/upstream-attribution.md) |

Both output formats are derivative works of pstack and carry the upstream MIT text: [`plugins/pstack/LICENSE`](plugins/pstack/LICENSE) for the Claude Code build, `LICENSE` inside the release zip for the generic package. The `author`, `homepage`, `repository`, and `license` fields in the generated manifest are preserved from upstream unchanged.

This is an independent port, not an official Cursor or poteto release. Report porting defects here; report pstack defects [upstream](https://github.com/cursor/plugins/issues).

### How does the sync pipeline work?

[`.github/workflows/sync.yml`](.github/workflows/sync.yml) runs on a 3-day cron and on manual dispatch:

1. Sparse-clone `cursor/plugins` and compare the `pstack` subtree hash against `pin.json`. Commits elsewhere in the upstream repository do not trigger a rebuild.
2. Run [`transform/scripts/transform.ps1`](transform/scripts/transform.ps1), driven entirely by [`transform/map.json`](transform/map.json).
3. Run three validation gates ([`transform/scripts/validate.ps1`](transform/scripts/validate.ps1)): residual Cursor-reference scan, frontmatter and Agent Plugins 1.0 contract checks, and a Claude Code marketplace dry-run.
4. Only on green: commit, tag `pstack-<version>-r<N>`, push, and publish the release zip.

A failed run opens or comments on a single `sync failed:` issue and includes the gate output, so the report is diagnosable without opening the log. `pin.json` is left unchanged and the next cron retries.

To reproduce a build locally:

```bash
git clone --depth 1 --filter=blob:none --sparse https://github.com/cursor/plugins.git upstream
git -C upstream sparse-checkout set pstack
pwsh ./transform/scripts/transform.ps1 -Upstream upstream/pstack -Out output -OutCc .
pwsh ./transform/scripts/validate.ps1 -Root .
```

Generated content under `plugins/pstack/` is never hand-edited; change `transform/map.json` and let the pipeline recompute.

## 中文

### agent-plugin-pstack 是什么?

agent-plugin-pstack 是 [pstack](https://github.com/cursor/plugins/tree/main/pstack) 的自动化通用移植版。pstack 是 Lauren Tan([poteto](https://x.com/poteto))在 [cursor/plugins](https://github.com/cursor/plugins) 中维护的 agent 工作流插件。本仓库把其中绑定 Cursor 的机制改写为可移植的等价语义,并以两种格式重新发布:[Agent Plugins 1.0](https://agent-plugins.org) 通用包与 Claude Code 插件。GitHub Actions 管线每 3 日同步一次,三层验证门全绿才发布。

pstack 本身是一套面向严格工程作业的技能与子代理:先复现再修、对运行中的产物做验证、先设计再写码、单个 agent 可信之后再并行。入口是 `poteto-mode`,它选择 playbook 并调度其余技能。

### 在 Claude Code 中安装

```
/plugin marketplace add lab-GESTALT/agent-plugin-pstack
/plugin install pstack@agent-plugin-pstack
```

Claude Code 会给插件技能加命名空间,`/poteto-mode` 对应 `/pstack:poteto-mode`。起步两步:

1. `/pstack:setup-pstack`:选择推理预算与各角色使用的模型。
2. `/pstack:poteto-mode`:需要严格作业时的主入口。

第三方市场默认关闭自动更新。可在 `/plugin` → **marketplaces** → `agent-plugin-pstack` 中开启,或用 `claude plugin update pstack@agent-plugin-pstack` 手动更新一次。

本仓库自身即插件市场:[`.claude-plugin/marketplace.json`](.claude-plugin/marketplace.json) 指向 [`plugins/pstack/`](plugins/pstack),该目录入仓,可直接从 `main` 安装。

### 安装通用 Agent Plugins 包

每个 [release](https://github.com/lab-GESTALT/agent-plugin-pstack/releases) 附带 `pstack-<version>-r<N>.zip`,是 Agent Plugins 1.0 结构的目录树:

```
plugin.json      # $schema: https://agent-plugins.org/schemas/1.0.0/plugin.schema.json
skills/          # 59 个技能,每个是一个含 SKILL.md 的目录
agents/          # 2 个子代理定义
LICENSE          # 上游 MIT,Copyright (c) 2026 Lauren Tan
com.cursor/      # 原样保留的 Cursor 清单
```

解压到所用 harness 加载 Agent Plugins 包的位置即可。zip 由 CI 生成,不入仓。

### 包含哪些内容?

下列数量对应 pstack 0.15.36。

| 组成 | 数量 | 说明 |
|---|---|---|
| 技能 | 59 | 上游 58 个,另加 `build-control-for-your-app` |
| 工程原则 | 24 | `principle-*` 技能,如 `principle-prove-it-works`、`principle-fix-root-causes` |
| Playbook | 23 | 位于 `poteto-mode` 下,如 bug 修复、性能、重构、运行时取证 |
| 子代理 | 2 | `poteto-agent`、`comment-sicko` |

常用技能:`poteto-mode`(编排)、`setup-pstack`(模型与预算配置)、`architect`(先设计再写码)、`swarm`(并行 worker)、`blast-radius`(改动可能波及什么)、`tdd`、`unslop`(去除 AI 味行文)、`technical-writing`。

移植版只包含技能与 agents。上游的指南与 harness 说明不复制,请读 [`pstack/docs/guide`](https://github.com/cursor/plugins/tree/main/pstack/docs/guide)。

### 与上游官方 Claude Code 版有什么区别?

上游在 [`harness/pstack/claude-code`](https://github.com/cursor/plugins/tree/main/harness/pstack/claude-code) 提供官方 Claude Code 构建,安装方式是 `/plugin marketplace add cursor/plugins` 后 `/plugin install pstack@cursor-plugins`。该构建在技能正文中保留 Cursor 名称,另用一份适配文档说明映射关系。

本移植版改为就地改写这些引用,使技能正文读起来是 harness 无关的指令。下表为 `skills/` 与 `agents/` 中的匹配行数,测量基准是上游 `cursor/plugins@a5539b1`(pstack 0.15.36):

| Cursor 专属引用 | 上游 Claude Code 构建 | 本移植版 |
|---|---|---|
| `pstack-models.mdc` | 11 | 0 |
| `.cursor/skills` | 10 | 0 |
| `subagent_type` | 8 | 0 |
| `~/.cursor/rules` | 7 | 0 |
| `AskQuestion` | 6 | 0 |
| `api2.cursor.sh` | 1 | 0 |
| 含 `icon:` / `color:` frontmatter 的文件 | 2 | 0 |

另有两处不同:本移植版增加 `build-control-for-your-app` 技能;在 Claude Code 市场之外还发布独立的 Agent Plugins 1.0 zip。

一处需要注意:替换措辞是中文,因此被改写的段落会以中文出现在整体为英文的技能中。映射规则见 [`transform/MAPPING.md`](transform/MAPPING.md)。

### 上游、署名与许可

| | |
|---|---|
| 上游仓库 | [cursor/plugins](https://github.com/cursor/plugins) |
| 跟踪路径 | [`pstack/`](https://github.com/cursor/plugins/tree/main/pstack) |
| 上游作者 | Lauren Tan([poteto](https://x.com/poteto)) |
| 上游许可 | MIT,Copyright (c) 2026 Lauren Tan |
| 本仓库许可 | MIT,Copyright (c) 2026 lab-GESTALT |
| 跟踪的提交与版本 | [`pin.json`](pin.json) |
| 署名细节 | [`docs/upstream-attribution.md`](docs/upstream-attribution.md) |

两种产物都是 pstack 的派生作品,均随附上游 MIT 文本:Claude Code 构建见 [`plugins/pstack/LICENSE`](plugins/pstack/LICENSE),通用包见 release zip 内的 `LICENSE`。生成清单中的 `author`、`homepage`、`repository`、`license` 字段原样保留上游取值。

这是独立移植版,不是 Cursor 或 poteto 的官方发布。移植缺陷请在本仓库提 issue;pstack 自身的缺陷请提到[上游](https://github.com/cursor/plugins/issues)。

### 同步管线如何工作?

[`.github/workflows/sync.yml`](.github/workflows/sync.yml) 按 3 日 cron 与手动触发运行:

1. 稀疏克隆 `cursor/plugins`,用 `pstack` 子树哈希与 `pin.json` 比对。上游其余目录的提交不触发重算。
2. 运行 [`transform/scripts/transform.ps1`](transform/scripts/transform.ps1),规则全部来自 [`transform/map.json`](transform/map.json)。
3. 运行三层验证门([`transform/scripts/validate.ps1`](transform/scripts/validate.ps1)):Cursor 残留扫描、frontmatter 与 Agent Plugins 1.0 契约检查、Claude Code 市场 dry-run。
4. 全绿才提交、打 tag `pstack-<version>-r<N>`、推送并发布 release zip。

失败时只开一个 `sync failed:` issue 或在其下追加评论,并附上门的实际输出,不翻日志即可定位。`pin.json` 保持不变,下一次 cron 重试。

本地复现一次构建:

```bash
git clone --depth 1 --filter=blob:none --sparse https://github.com/cursor/plugins.git upstream
git -C upstream sparse-checkout set pstack
pwsh ./transform/scripts/transform.ps1 -Upstream upstream/pstack -Out output -OutCc .
pwsh ./transform/scripts/validate.ps1 -Root .
```

`plugins/pstack/` 下的生成内容不手改;要改行为就改 `transform/map.json`,由管线重算。

---

Last updated / 文档更新:2026-11-12