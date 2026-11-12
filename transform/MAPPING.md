# MAPPING.md — 通用语义映射(人读)

机器规则:map.json;机制依据:Agent Plugins 1.0 规范与四端 harness 机制审计。

| # | Cursor 机制 | 通用映射 |
|---|---|---|
| 1 | mode / icon / color / reminder | mode → metadata.mode(session);reminder → metadata.reminder;icon/color 删除;文档标注「粘性会话语义不可移植,由 description 触发承接」 |
| 2 | subagent_type + agents/ | agent 类型注册表;frontmatter 的 name 归一为文件名,is_background 移入 metadata;引用改写「以类型名 X 委派子代理」,生成点与注册名对齐;AP 顶层携带 agents/,CC 适配器映射进原生 agents/ |
| 3 | AskQuestion | 「结构化提问(问题数组 + 选项 + 多选)」;等价表:CC=AskUserQuestion、Codex=request_user_input、Cursor=AskQuestion、其他 CLI harness=ask_user_question |
| 4 | /loop | 「循环执行直到谓词满足(间隔唤醒)」;等价:CC/Cursor=/loop、Codex=后台模式、其他 CLI harness=goal 机制或 ralph |
| 5 | ~/.cursor/rules + pstack-models.mdc | 通用 .md 规则(frontmatter: description/globs/alwaysApply);角色模型 = harness 无关 pstack-models.json,全路径与裸文件名两种写法都改写;端放置:CC=CLAUDE.md、Codex 与其他 CLI harness=AGENTS.md |
| 6 | cursor-team-kit 依赖 | 打标「可选组件」,不捆依赖;等价能力:去 AI 味写作类技能 ≈ deslop,浏览器/CLI 控制类技能 ≈ control-cli/ui |
| 7 | 产物 | map.json(机器)+ 本文件(人读),成对维护 |

变换范围:全量技能 + manifest 投影 + agents/ 变换;产出 output/(AP 通用版,由 CI 生成、打包后删除,从不入仓)与 plugins/pstack/(CC 市场形态,入仓)。生成内容不手改,一律由管线重算。

令牌顺序:bodyTokens 按「先特异后泛化」排列,全路径规则必须排在对应的裸文件名规则之前,生成点规则必须排在裸 subagent_type 之前(map.json 的数组顺序即执行顺序)。

补充规则(全量审计后新增):裸 subagent_type → 子代理类型;generalPurpose → 通用型子代理;~/.cursor/skills → ~/.agents/skills;.cursor/skills → .agents/skills;~/.cursor/projects → 会话转录目录;~/.cursor/plugins → 插件安装目录;.cursor/worktrees → worktree 目录;agent-transcripts → session-transcripts;api2.cursor.sh webhook → 打标(Cursor 专属端点,等价做法:改用目标应用的 webhook 接收端点)。agents/*.md 同样过令牌循环。

## 规则文件是被执行的,不是被描述的

transform.ps1 直接读取 map.json:manifest.keep 决定顶层保留字段,manifest.add 补齐 $schema,manifest.dropToExtension 与 keep 之外的上游字段全部进扩展目录,manifest.extension 决定扩展目录名与文件名;frontmatter.drop 删除字段,frontmatter.moveToMetadata 决定移入 metadata 的字段,frontmatter.keep 是必须存活的字段;agents.dir 是 agents 目录。

两处断言让规则与实现不可能悄悄分叉:上游 manifest 出现既不在 keep、也不在 dropToExtension 的字段时,变换直接失败;frontmatter.keep 里的字段在上游存在而产物丢失时,变换直接失败。

## 验证门(三层,唯一闸门)

gate1 残留扫描:扫描 plugins/pstack 与 output/ 两棵产物树的全部文本文件。待检项 = map.json 的 residualPatterns(作用于所有文件)加上 bodyTokens(只作用于散文)。文件算散文还是代码由 map.json 的 gate.proseExtensions 决定,变换与门读同一个字段:变换只改写散文,门对代码只查硬性残留标记。

匹配语义只有一个解释者:transform/scripts/rules.psm1。它把每条 bodyToken 归一为 token spec——没有 `pattern` 字段时按**字面串、区分大小写**(StringComparison.Ordinal)匹配与替换,有 `pattern` 字段时按该正则匹配与替换。transform.ps1 与 validate.ps1 调用同一组函数,所以「变换按字面、门按正则」这类两处漂移不可能再出现。正则替换走 MatchEvaluator:替换文本是给文档读的散文,不该被解释成 `$1` 之类的分组引用。

`/loop` 的 `pattern` 是 `(?<![\w./-])/loop(?![\w-])`,要求斜杠起始一个独立词元:命令用法改写,导入路径 `./passes/loop-check.ts` 原样保留。只收紧门、不收紧变换是不够的——那样散文里的路径会被改成 `./passes循环执行直到谓词满足(间隔唤醒)-check.ts`;共用解释者后两侧同时正确。

白名单与报错都按 `find`(令牌身份)匹配,不按正则串,所以调整 pattern 不需要改动已有的 codeResidualAllowlist 登记。登记按**类**而非按实例:`glob` 命中产物树内的相对路径(支持 `**`、`*`、`?`),`scope` 限定文件类别,`patterns` 限定令牌身份。`skills/**` + `scope: code` 的含义是「技能内的脚本按设计保留功能性字符串」,新增脚本自动继承,不必逐条登记;同一 glob 不豁免散文,所以 SKILL.md 里的 Cursor 路径仍然判失败。

gate2 frontmatter 与 Agent Plugins 契约:每个 SKILL.md 的 name 等于目录名,每个 agents/*.md 的 name 等于文件名,frontmatter 不得残留 Cursor 专属顶层字段(含引号写法)。待查字段集合由 map.json 的 frontmatter.drop ∪ frontmatter.moveToMetadata 推导,不另抄一份清单;匹配只作用于 frontmatter 区域,正文 fenced 代码块里的 `color:` / `mode:` / `reminder:` 是示例配置,不算违规。两种产物都必须随上游 MIT 许可文本分发:plugins/pstack/LICENSE 无条件检查,output/LICENSE 在 AP 部分检查。output/ 存在时另查 AP 清单:顶层字段必须落在 apContract.allowedKeys 内、必需字段齐、$schema 等于 canonical id、name 符合规范正则与长度上限、author 字段受限、keywords 为字符串数组、LICENSE 随产物存在、AP 与 CC 的技能数一致。

gate3 CC 市场 dry-run:marketplace.json 与各插件清单必须可解析,name/owner 齐备;每个 plugin.source 必须存在且其 .claude-plugin/plugin.json 可解析;清单声明的 skills/agents 路径必须存在且非空。

脚本类文件不做散文式令牌替换:替换文本是给文档读的措辞,写进 shell / TS / mjs 会破坏脚本行为。这类残留按类登记在 map.json 的 codeResidualAllowlist;门放行时打印 `gate1 allowed residual`,任何未登记的残留一律判失败,给出产物树、文件、行号,并指出修法:map.json 缺覆盖这种写法的改写规则、产物没重算、还是代码按设计不改写。

本地跑门时若 output/ 不存在,gate1 与 gate2 的 AP 部分都会打印跳过说明而不是静默通过——CI 里 output/ 总是刚由 transform 生成。
