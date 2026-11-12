# AGENTS.md — agent-plugin-pstack(项目事实)

- 本仓库把上游 cursor/plugins 的 pstack 自动变换为通用版:Agent Plugins 1.0 结构(output/,随 tag 发布 zip)与 Claude Code 插件版(plugins/pstack/,本仓库即 CC 插件市场)。
- 管线:.github/workflows/sync.yml(每 3 日 cron + 手动触发);变换规则 transform/map.json(机器)与 transform/MAPPING.md(人读);验证门 transform/scripts/validate.ps1;上游跟踪状态 pin.json。
- 派生内容保留上游 MIT 声明:两种产物都必须带 LICENSE(plugins/pstack/LICENSE 入仓,output/LICENSE 随 zip),gate2 分别检查;详见 docs/upstream-attribution.md。产物不收录 Cursor 内部文本。
- 上游自身另有官方 Claude Code 构建(cursor/plugins 的 harness/pstack/claude-code,市场名 cursor-plugins),保留 Cursor 名称并用适配文档说明映射;本仓库是独立移植,差别是就地改写正文与 frontmatter。
- 变更约定:管线验证通过后直推 main 并打 tag pstack-{version}-r{N};人工变更提交前先跑 transform/scripts/validate.ps1。plugins/pstack 下的生成内容不手改,由 transform.ps1 重算。
