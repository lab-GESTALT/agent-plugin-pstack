---
name: build-control-for-your-app
description: 为任意目标应用生成 control-<app> 验证驱动技能(feature map 范式,结构参照 Cursor feature map 范式,不含其内部文本)。当用户要为自己的应用建立可被 agent 真实驱动的验证回路,或 create-verification-skill 需要控制适配层时使用。
---

# Build control-<app>

目标:让 agent 能真实驱动一个运行中的应用来证明改动有效,而不是自报完成。产物:项目级 skills/control-<app>/SKILL.md + 特性地图 features/。

## Steps

1. 盘点用户可见特性:每个特性一页,写明 what it is / how to get to it / how to use it;跨特性的用户旅程单独成节(格式见 references/feature-map-guide.md)。
2. 定基线前置条件(逐条可证伪):应用可运行、健康检查命令、登录态与权限、工作区状态;达不到就跳过并在证明里说明。
3. 选控制适配器:CLI / UI 自动化 / MCP / 应用内命令;每个动作必须产出可核验证据(截图、日志、输出),禁止自报。
4. 写 control-<app>/SKILL.md:drive 指令 + verify 流程 + 证明约定(真实驱动应用,逐条对照特性地图)。
5. 维护:特性地图与真实应用漂移时,按 maintain-verification-skill 的循环修正——一次一个 PR,只含已证实的修正。

## 来源说明

结构参照 Cursor 生态的 feature map 验证范式(与 create-verification-skill / maintain-verification-skill 同源);本技能不收录任何 Cursor 内部文本。
