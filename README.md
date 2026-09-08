# agent-plugin-pstack

自动跟踪上游 [cursor/plugins](https://github.com/cursor/plugins) 的 pstack,产出去 Cursor 化通用版的管线仓库。

- 双格式产物:
  - 通用版 pstack(Agent Plugins 1.0 结构),随 tag 以 zip 发布;
  - Claude Code 插件版(plugins/pstack/,本仓库即 CC 插件市场)。
- Claude Code 安装:打开 Claude Code 后执行 /plugin marketplace add TurnX-alt/agent-plugin-pstack,再 /plugin install pstack@agent-plugin-pstack。
- 上游与许可:docs/upstream-attribution.md(本仓库 MIT;上游 pstack MIT)。
- 管线:自动(每 3 日)或手动触发;三层验证门通过后直推并打 tag;详见 .github/workflows/sync.yml。
