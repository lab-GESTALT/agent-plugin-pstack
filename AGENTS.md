# AGENTS.md — agent-plugin-pstack(项目事实)

- 本仓库把上游 cursor/plugins 的 pstack 自动变换为通用版:Agent Plugins 1.0 结构(output/,随 tag 发布 zip)与 Claude Code 插件版(plugins/pstack/,本仓库即 CC 插件市场)。
- 管线:.github/workflows/sync.yml(每 3 日 cron + 手动触发);变换规则 transform/map.json(机器)与 transform/MAPPING.md(人读);验证门 transform/scripts/validate.ps1;上游跟踪状态 pin.json。
- 派生内容保留上游 MIT 声明:两种产物都必须带 LICENSE(plugins/pstack/LICENSE 入仓,output/LICENSE 随 zip),gate2 分别检查;详见 docs/upstream-attribution.md。产物不收录 Cursor 内部文本。
- 上游自身另有官方 Claude Code 构建(cursor/plugins 的 harness/pstack/claude-code,市场名 cursor-plugins),保留 Cursor 名称并用适配文档说明映射;本仓库是独立移植,差别是就地改写正文与 frontmatter。
- 变更约定:管线验证通过后直推 main 并打 tag pstack-{version}-r{N};人工变更提交前先跑 transform/scripts/validate.ps1。plugins/pstack 下的生成内容不手改,由 transform.ps1 重算。

## 规则 ↔ 强制器

一条规则如果没有强制器,它就是下一次重复事故的入口。改规则时同时改这一行;新增规则必须同时指出强制器与「会红的证明」。
验证入口统一是 `.agents/skills/verify-pstack-sync/helpers/drive.ps1`(先跑 `doctor.ps1`),特征图在 `features/README.md`。
跨运行的发布次序由 `.agents/skills/formal-verify-pstack-sync/helpers/run.ps1` 模型检查(TLA+/TLC),两个 harness 共用 `helpers/workflow.psm1` 读取步骤正文。

| 规则 | 强制器 | 会红的证明 |
| --- | --- | --- |
| 一个令牌只有一种匹配语义,变换与门共用 | `transform/scripts/rules.psm1` | `-Feature corpus`(fp-loop-import / fp-loop-test-other-path) |
| 散文/代码分界只有一个来源 | `map.json` 的 `gate.proseExtensions` → `Get-FileScope` | `-Feature corpus`(fp-ts-* 必绿、tp-prose-cursor-path 必红) |
| 产物不得残留 Cursor 内部标记 | `map.json` 的 `residualPatterns` → gate1 | `-Feature corpus`(tp-models-bare / tp-api2) |
| 代码里的功能性字符串按类豁免,不逐条登记 | `map.json` 的 `codeResidualAllowlist`(glob+scope+patterns) | `-Feature corpus`(fp-new-sh-transcripts) |
| frontmatter 不得含 Cursor-only 字段,字段集合由 map 派生 | `Get-FrontmatterDropPattern` → gate2 | `-Feature rules`(注入合成键必须立刻被判违规) |
| frontmatter 检查只在 frontmatter 区域内匹配 | `Get-Frontmatter` → gate2 | `-Feature corpus`(fp-body-css-color / fp-body-yaml-mode 必绿) |
| skill 的 `name` 必须等于目录名 | gate2 | `-Feature corpus`(tp-name-mismatch) |
| 两种产物都必须带上游 MIT 原文,复制而非改写 | `transform.ps1` 缺失即抛错 + gate2 | `-Feature transform`(LICENSE 字节比较) |
| AP 清单只含契约允许的键,未分类字段拒绝猜测 | `transform.ps1` 抛错 + gate2 AP 契约 | `-Feature transform` |
| 两种产物 skill 数一致 | gate2 parity | `-Feature transform` |
| 入仓生成内容必须等于当前规则重算的结果 | harness drift 断言 | `-Feature transform`(committed CC artifact equals recomputed output) |
| 验证夹具必须能入仓,不被忽略规则吞掉 | `doctor.ps1` 的 `check-ignore --no-index` | `-Feature doctor`(临时 excludesFile 注入未锚定 `output/`) |
| 绿运行必须意味着已发布且远端自洽 | `sync.yml` 不再吞失败 + publish 性质断言 + 模型 `GreenConsistent` | `-Feature publish -Scenario release-fails / commit-fails`;`swallow-release` / `swallow-commit` 变体 |
| 发布缺失必须自愈,不能永久短路 | `Detect change` 的 release 检查 + 模型 `SelfHeal` 开关 | `-Feature detect -Scenario release-missing / gh-fails`;`no-self-heal` 变体 |
| 上游停下后,当前版本终须发布(跨运行活性) | 模型 `EventuallyPublished` | `stale-version` 变体(版本号取自旧 pin 时必红) |
| 模型开关必须从 workflow 正文派生,锚点缺失即拒绝出结论 | `formal-verify-pstack-sync/helpers/run.ps1` 的派生与 throw | 对真实 `sync.yml` 做两次 scratch 改动:删掉自愈判定、只留 echo 删掉赋值,均被判红后还原 |
| push 被拒必须 rebase 重试,冲突必须红 | `Tag and push` 的 `rebase_onto_remote` | `-Feature publish -Scenario push-rejected`(断言重试分支真的跑了) |
| 同版本同树重跑复用已有 tag,不造空标签 | `Tag and push` 的 HEAD_SHA 比对 | `-Feature publish -Scenario self-heal` |
| 同版本不同树必须递增序号,不覆盖已发布的 tag | `Tag and push` 的远端序号查询 | `-Feature publish -Scenario tag-serial`(把 sha 比对换成非空判断即红) |
| 告警必须自带定位信息,不能只有 run 链接 | `Alert on failure` 引用 gate-report.txt | `-Feature alert`(body 含失败 pattern) |
| 替身执行语义必须与 Actions 一致 | harness `bash -e -o pipefail` + 失败中止后续 | `-Feature publish -Scenario release-fails`(裸 bash 下会误绿) |
| 公开面不得含内部内容 | public-face-gate(仓库外),push 前 `range origin/main..HEAD` | 该工具自带的 red/green 语料 |

### 尚无强制器的规则(已知缺口,不要当成已验证)

- **代码文件里新增的 Cursor 内部文本**:gate1 对代码只查 `residualPatterns`,散文式替换按设计不作用于代码。新出现的内部字符串若不在该清单里,不会被任何门抓到。
- **cron 真的按时跑了**:GitHub 可延迟或停用 schedule,仓库内没有哨兵。一次绿色的短路运行不构成管线可用的证据。
