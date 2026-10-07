# MAPPING.md — 通用语义映射(人读)

机器规则:map.json;机制依据:Agent Plugins 1.0 规范与四端 harness 机制审计。

| # | Cursor 机制 | 通用映射 |
|---|---|---|
| 1 | mode / icon / color / reminder | mode → metadata.mode(session);reminder → metadata.reminder;icon/color 删除;文档标注「粘性会话语义不可移植,由 description 触发承接」 |
| 2 | subagent_type + agents/ | agent 类型注册表;引用改写「以类型名 X 委派子代理」;AP 顶层携带 agents/,CC 适配器映射进原生 agents/ |
| 3 | AskQuestion | 「结构化提问(问题数组 + 选项 + 多选)」;等价表:DSH=ask_user_question、CC=AskUserQuestion、Codex=request_user_input、Cursor=AskQuestion |
| 4 | /loop | 「循环执行直到谓词满足(间隔唤醒)」;等价:CC/Cursor=/loop、DSH=goal 机制或 ralph、Codex=后台模式 |
| 5 | ~/.cursor/rules + pstack-models.mdc | 通用 .md 规则(frontmatter: description/globs/alwaysApply);角色模型 = harness 无关 pstack-models.json,全路径与裸文件名两种写法都改写;端放置:CC=CLAUDE.md、DSH=AGENTS.md、Codex=AGENTS.md |
| 6 | cursor-team-kit 依赖 | 打标「可选组件」,不捆依赖;等价能力:去 AI 味写作类技能 ≈ deslop,浏览器/CLI 控制类技能 ≈ control-cli/ui |
| 7 | 产物 | map.json(机器)+ 本文件(人读),成对维护 |

变换范围:全量技能 + manifest 投影 + agents/ 变换;产出 output/(AP 通用版,由 CI 生成、打包后删除,从不入仓)与 plugins/pstack/(CC 市场形态,入仓)。

令牌顺序:bodyTokens 按「先特异后泛化」排列,全路径规则必须排在对应的裸文件名规则之前(map.json 的数组顺序即执行顺序)。

补充规则(全量审计后新增):裸 subagent_type → 子代理类型;generalPurpose → 通用型子代理;~/.cursor/skills → ~/.agents/skills;.cursor/skills → .agents/skills;~/.cursor/projects → 会话转录目录;~/.cursor/plugins → 插件安装目录;.cursor/worktrees → worktree 目录;agent-transcripts → session-transcripts;api2.cursor.sh webhook → 打标(Cursor 专属端点,等价做法:改用目标应用的 webhook 接收端点)。agents/*.md 同样过令牌循环。

## 验证门的扫描范围

gate1 扫描 plugins/pstack 下全部文本文件,模式集 = map.json 的 residualPatterns 加上 bodyTokens 的 find 串,门与变换表同源,不再各存一份清单。

脚本类文件不做散文式令牌替换:替换文本是给文档读的措辞,写进 shell / TS / mjs 会破坏脚本行为。这类已知残留逐条登记在 map.json 的 codeResidualAllowlist(路径 + 模式 + 原因);门放行时打印 `gate1 allowed residual`,任何未登记的新残留一律判失败并给出文件与行号。
