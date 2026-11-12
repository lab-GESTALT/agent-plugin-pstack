# 上游声明与跟踪策略

- 上游:<https://github.com/cursor/plugins>(main)
- 目标:pstack(插件目录),v0.14.8 起跟踪,作者 Lauren Tan,许可 MIT(pstack/LICENSE,Copyright (c) 2026 Lauren Tan)
- 本仓库变换产物是 pstack 的派生作品:输出中保留上游 MIT 声明;改名 / 打标不改变这一义务。
- 跟踪策略:pin.json 的 commit 记录当前跟踪的上游提交(用于溯源与 release notes),pstackTree 记录 pstack 子树哈希(用于判断是否需要同步,上游其余目录的提交不触发重算);同步节奏与发布方式见 .github/workflows/sync.yml。
