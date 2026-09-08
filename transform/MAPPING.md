# MAPPING.md — 通用语义映射(人读)

机器规则:map.json;机制依据:Agent Plugins 1.0 规范与四端 harness 机制审计。

| # | Cursor 机制 | 通用映射 |
|---|---|---|
| 1 | mode / icon / color / reminder | mode → metadata.mode(session);reminder → metadata.reminder;icon/color 删除;文档标注「粘性会话语义不可移植,由 description 触发承接」 |
| 2 | subagent_type + agents/ | agent 类型注册表;引用改写「以类型名 X 委派子代理」;AP 顶层携带 agents/,CC 适配器映射进原生 agents/ |
| 3 | AskQuestion | 「结构化提问(问题数组 + 选项 + 多选)」;等价表:DSH=ask_user_question、CC=AskUserQuestion、Codex=request_user_input、Cursor=AskQuestion |
| 4 | /loop | 「循环执行直到谓词满足(间隔唤醒)」;等价:CC/Cursor=/loop、DSH=goal 机制或 ralph、Codex=后台模式 |
| 5 | ~/.cursor/rules + pstack-models.mdc | 通用 .md 规则(frontmatter: description/globs/alwaysApply);角色模型 = harness 无关 pstack-models.json;端放置:CC=CLAUDE.md、DSH=AGENTS.md、Codex=AGENTS.md |
| 6 | cursor-team-kit 依赖 | 打标「可选组件」;本端等价:deslop ≈ 去 AI 味写作类技能;control-cli/ui ≈ 浏览器/CLI 控制类技能;不捆依赖 |
| 7 | 产物 | map.json(机器)+ 本文件(人读),成对维护 |

变换范围:全量技能 + manifest 投影 + agents/ 变换;产出 output/(AP 通用版,gitignore)与 plugins/pstack/(CC 市场形态,入仓)。

补充规则(全量审计后新增,按先特异后泛化顺序):裸 subagent_type → 子代理类型;generalPurpose → 通用型子代理;~/.cursor/skills → ~/.agents/skills;.cursor/skills → .agents/skills;~/.cursor/projects → 本端会话转录目录;~/.cursor/plugins → 本端插件安装目录;.cursor/worktrees → 本端 worktree 目录;agent-transcripts → session-transcripts;api2.cursor.sh webhook → 打标(Cursor 专属端点,本端等价:目标应用 webhook)。agents/*.md 同样过令牌循环。
