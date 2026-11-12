------------------------------ MODULE Sync ------------------------------
(***************************************************************************)
(* .github/workflows/sync.yml 的发布顺序模型。                               *)
(*                                                                         *)
(* 每个动作对应 workflow 里一个真实步骤,名字沿用仓库的名词:                 *)
(*   Detect    -> "Detect change"                                          *)
(*   Transform -> "Transform"                                              *)
(*   Record    -> "Record upstream"                                        *)
(*   Commit    -> "Commit"                                                 *)
(*   Push      -> "Tag and push" 的 push 部分                              *)
(*   Tag       -> "Tag and push" 的 tag 部分                               *)
(*   Release   -> "Publish release"                                        *)
(*                                                                         *)
(* 常量 SelfHeal / SwallowRelease / SwallowCommit 由 helpers/run.ps1 从      *)
(* sync.yml 的实际写法推导,不手填:改 workflow 就会改模型。                  *)
(*                                                                         *)
(* 抽象:一个版本号代表一棵 pstack 子树,也代表该版本的产物。                 *)
(* git 层面的 push 竞争、tag 树比对、zip 内容不在本模型内,                  *)
(* 它们由 verify-pstack-sync 的 -Feature publish 用真实 git 驱动。           *)
(***************************************************************************)
EXTENDS Integers, FiniteSets, TLC

CONSTANTS MaxV, MaxFails, MaxUp, SelfHeal, SwallowRelease, SwallowCommit,
          StaleVersion

V  == 1..MaxV
V0 == 0..MaxV

VARIABLES up, clonedV, pinV, pinT, mainV, tagV, released, phase, changed,
          localV, localCommitted, failBudget, upAdvances

vars == <<up, clonedV, pinV, pinT, mainV, tagV, released, phase, changed,
          localV, localCommitted, failBudget, upAdvances>>

TypeOK ==
  /\ up \in V
  /\ clonedV \in V0
  /\ pinV \in V0 /\ pinT \in V0 /\ mainV \in V0 /\ tagV \in V0
  /\ released \subseteq V
  /\ phase \in {"idle","detect","transform","record","commit","push","tag",
                "release","green","red"}
  /\ changed \in BOOLEAN
  /\ localV \in V0
  /\ localCommitted \in BOOLEAN
  /\ failBudget \in 0..MaxFails
  /\ upAdvances \in 0..MaxUp

Init ==
  /\ up = 1 /\ clonedV = 0
  /\ pinV = 0 /\ pinT = 0 /\ mainV = 0 /\ tagV = 0
  /\ released = {}
  /\ phase = "idle" /\ changed = FALSE
  /\ localV = 0 /\ localCommitted = FALSE
  /\ failBudget = MaxFails /\ upAdvances = 0

(***************************************************************************)
(* 失败预算:每次失败消耗一格,用尽后步骤必须成功。                          *)
(* 这让「故障终将停止」成为有界假设,而不是对公平性的空口承诺。               *)
(***************************************************************************)

(***************************************************************************)
(* Fetch upstream 在 Detect change 之前跑,一次运行只克隆一次。              *)
(* clonedV 就是那次克隆固定的上游版本:本运行里 Detect / Record / Push 读的   *)
(* 都是它,不是「此刻的上游」。上游中途前进不会改变本次运行看到的内容。       *)
(* 抓取本身也会失败(限流、网络):此时运行在 Detect 之前就红,pin不动。      *)
(***************************************************************************)
StartRun ==
  /\ phase = "idle"
  /\ \/ /\ clonedV' = up /\ phase' = "detect" /\ UNCHANGED failBudget
     \/ /\ failBudget > 0 /\ failBudget' = failBudget - 1 /\ phase' = "red"
        /\ UNCHANGED clonedV
  /\ UNCHANGED <<up, pinV, pinT, mainV, tagV, released, changed, localV,
                 localCommitted, upAdvances>>

(***************************************************************************)
(* Detect change:子树哈希不同 => 有变更。                                  *)
(* SelfHeal 为真时,pin 已有版本但没有对应 release 也判为有变更;             *)
(* 第二个析取项建模 gh release list 不可达时往「重跑」方向倒。               *)
(***************************************************************************)
Detect ==
  /\ phase = "detect"
  /\ \/ changed' = ((pinT # clonedV) \/
                    (SelfHeal /\ pinV \in V /\ pinV \notin released))
     \/ /\ SelfHeal /\ pinV \in V /\ changed' = TRUE
  /\ phase' = IF changed' THEN "transform" ELSE "green"
  /\ UNCHANGED <<up, clonedV, pinV, pinT, mainV, tagV, released, localV,
                 localCommitted, failBudget, upAdvances>>

Transform ==
  /\ phase = "transform"
  /\ \/ /\ phase' = "record" /\ UNCHANGED failBudget
     \/ /\ failBudget > 0 /\ failBudget' = failBudget - 1 /\ phase' = "red"
  /\ UNCHANGED <<up, clonedV, pinV, pinT, mainV, tagV, released, changed,
                 localV, localCommitted, upAdvances>>

(***************************************************************************)
(* Record upstream:把本次克隆到的上游版本写进本地 pin。                     *)
(* 注意它发生在 Commit / Push / Release 之前:pin 会先于发布前进。           *)
(* StaleVersion 建模一类 jq 写法错误:子树哈希取自新克隆,版本号却取自旧 pin, *)
(* 于是 pinT 与 pinV 分家,Detect 永远判「无变更」。                         *)
(***************************************************************************)
Record ==
  /\ phase = "record"
  /\ localV' = IF StaleVersion /\ pinV \in V THEN pinV ELSE clonedV
  /\ \/ /\ phase' = "commit" /\ UNCHANGED failBudget
     \/ /\ failBudget > 0 /\ failBudget' = failBudget - 1 /\ phase' = "red"
  /\ UNCHANGED <<up, clonedV, pinV, pinT, mainV, tagV, released, changed,
                 localCommitted, upAdvances>>

(***************************************************************************)
(* Commit:SwallowCommit 为真时,提交失败被 || echo 吞掉,流程继续,           *)
(* 但本地并没有新提交(localCommitted = FALSE)。                            *)
(***************************************************************************)
Commit ==
  /\ phase = "commit"
  /\ \/ /\ localCommitted' = TRUE /\ phase' = "push" /\ UNCHANGED failBudget
     \/ /\ failBudget > 0 /\ failBudget' = failBudget - 1
        /\ localCommitted' = FALSE
        /\ phase' = IF SwallowCommit THEN "push" ELSE "red"
  /\ UNCHANGED <<up, clonedV, pinV, pinT, mainV, tagV, released, changed,
                 localV, upAdvances>>

(***************************************************************************)
(* Push:推的是本次变换出的产物(localV),pinT 记的是本次克隆的子树(clonedV)。*)
(* 正常时两者相等,StaleVersion 下分家。                                    *)
(* 没有新提交时 push 是 up-to-date,远端不动。                              *)
(***************************************************************************)
Push ==
  /\ phase = "push"
  /\ \/ /\ localCommitted = TRUE
        /\ mainV' = localV /\ pinV' = localV /\ pinT' = clonedV
        /\ phase' = "tag" /\ UNCHANGED failBudget
     \/ /\ localCommitted = FALSE
        /\ phase' = "tag"
        /\ UNCHANGED <<mainV, pinV, pinT, failBudget>>
     \/ /\ failBudget > 0 /\ failBudget' = failBudget - 1 /\ phase' = "red"
        /\ UNCHANGED <<mainV, pinV, pinT>>
  /\ UNCHANGED <<up, clonedV, tagV, released, changed, localV,
                 localCommitted, upAdvances>>

(***************************************************************************)
(* Tag:标签名里的版本来自 Record 算出的 localV。                            *)
(* 提交被吞掉时,这个名字会与远端实际的树不一致。                          *)
(***************************************************************************)
Tag ==
  /\ phase = "tag"
  /\ tagV' = localV
  /\ \/ /\ phase' = "release" /\ UNCHANGED failBudget
     \/ /\ failBudget > 0 /\ failBudget' = failBudget - 1 /\ phase' = "red"
  /\ UNCHANGED <<up, clonedV, pinV, pinT, mainV, released, changed, localV,
                 localCommitted, upAdvances>>

(***************************************************************************)
(* Publish release:SwallowRelease 为真时,create 失败被吞成绿。             *)
(***************************************************************************)
Release ==
  /\ phase = "release"
  /\ \/ /\ released' = released \cup {tagV} /\ phase' = "green"
        /\ UNCHANGED failBudget
     \/ /\ failBudget > 0 /\ failBudget' = failBudget - 1
        /\ phase' = IF SwallowRelease THEN "green" ELSE "red"
        /\ UNCHANGED released
  /\ UNCHANGED <<up, clonedV, pinV, pinT, mainV, tagV, changed, localV,
                 localCommitted, upAdvances>>

Finish ==
  /\ phase \in {"green","red"}
  /\ phase' = "idle"
  /\ UNCHANGED <<up, clonedV, pinV, pinT, mainV, tagV, released, changed,
                 localV, localCommitted, failBudget, upAdvances>>

(***************************************************************************)
(* 环境:上游可以在任意时刻前进,包括一次运行的中途。                       *)
(* 次数有界(MaxUp),因此 up 最终稳定,活性性质才有意义。                    *)
(***************************************************************************)
UpstreamAdvances ==
  /\ upAdvances < MaxUp
  /\ up < MaxV
  /\ up' = up + 1
  /\ upAdvances' = upAdvances + 1
  /\ UNCHANGED <<clonedV, pinV, pinT, mainV, tagV, released, phase, changed,
                 localV, localCommitted, failBudget>>

Next == StartRun \/ Detect \/ Transform \/ Record \/ Commit \/ Push \/ Tag \/
        Release \/ Finish \/ UpstreamAdvances

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

(***************************************************************************)
(* 性质一(安全):任何一次绿色运行结束时,远端都必须已经存在与 pin 同版本    *)
(* 的 release,且 tag 名里的版本、pin 版本、远端产物版本三者一致。           *)
(* 破坏它的后果:下游按 tag 下载,拿到的却不是 tag 声称的那个版本。          *)
(***************************************************************************)
GreenConsistent ==
  phase = "green" => (pinV = mainV /\ tagV = mainV /\ pinV \in released)

(***************************************************************************)
(* 性质二(活性):上游稳定、故障停止后,当前上游版本终将有 release。          *)
(* 破坏它的后果:pin 声称已同步,通用版产物却永远发不出去,cron 失去意义。    *)
(***************************************************************************)
EventuallyPublished == <>(up \in released)

=============================================================================