param(
  [Parameter(Mandatory=$true)][ValidateSet('gates','corpus','rules','doctor','transform','detect','publish','alert')][string]$Feature,
  [string]$Fixture,
  [string]$Scenario = 'happy',
  [string]$RunId,
  [string]$WorkflowPath,
  [switch]$KeepRoot
)
$ErrorActionPreference = 'Stop'

$skillDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
$repo     = (Resolve-Path (Join-Path $skillDir '..\..\..')).ProviderPath
if (-not $RunId) { $RunId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + (-join ((48..57)+(97..102) | Get-Random -Count 4 | ForEach-Object {[char]$_})) }
$evidence = Join-Path $skillDir "artifacts\$RunId"
$scratch  = Join-Path ([System.IO.Path]::GetTempPath()) "pstack-verify-$RunId"
New-Item -ItemType Directory -Force -Path $evidence | Out-Null

$transcript = @()
function Log([string]$line) { $script:transcript += $line; Write-Host $line }

# 每个 drive 用独立 scratch;证据写在 skill 的 artifacts/ 下,cleanup 不碰它
# 局部变量名不得与调用方脚本块里的变量重名:& $body 在 Invoke-Logged 的作用域里执行,
# 重名会让脚本块读到本函数的局部值(GITHUB_OUTPUT 曾因此指向证据文件)。
function Invoke-Logged([string]$name, [scriptblock]$body) {
  $logFile = Join-Path $evidence "$name.txt"
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $captured = & $body 2>&1 | ForEach-Object { [string]$_ }
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prev
  $text = ($captured -join "`n")
  Set-Content -Path $logFile -Value $text -Encoding utf8
  Log ("[{0}] exit={1}" -f $name, $code)
  return [pscustomobject]@{ code = $code; text = $text; file = $logFile }
}

function Copy-Tree([string]$src, [string]$dst) {
  New-Item -ItemType Directory -Force -Path $dst | Out-Null
  Copy-Item (Join-Path $src '*') $dst -Recurse -Force
}

# bash 里反斜杠是转义符,插值前统一成正斜杠
function BashPath([string]$p) { return ($p -replace '\\','/') }

# 从 live sync.yml 抽取步骤的 run 块: harness 不复制 workflow 逻辑,避免第二份手工同步清单。
# 解析逻辑与 formal-verify-pstack-sync 共用 workflow.psm1,两个 harness 读到的必须是同一份文本。
Import-Module (Join-Path $PSScriptRoot 'workflow.psm1') -Force -DisableNameChecking

# 步骤文本只从这里取。-WorkflowPath 让判别性证明对一份改坏的副本跑同一条 drive,
# 不必改动真实 sync.yml,也不必手抄一遍执行逻辑。
function Get-Step([string]$name, [string]$From) { Get-WorkflowStep $name -Path $(if ($From) { $From } else { $WorkflowPath }) }

# Actions 的 Linux 默认 shell 是 bash -e -o pipefail。替身必须用同一套执行语义:
# 裸 bash 下,步骤里最后一条命令成功就会把前面的失败吞掉(release create 失败曾因此判绿)。
function Step-Command([string]$cwd, [string]$sh, [string]$prelude = '') {
  return "cd '$(BashPath $cwd)' && " + $prelude + "bash -e -o pipefail '$(BashPath $sh)'"
}

function Link-Upstream([string]$root) {
  $src = Join-Path $repo 'upstream'
  if (-not (Test-Path $src)) { throw 'upstream clone missing; run: git clone --depth 1 --filter=blob:none --sparse https://github.com/cursor/plugins.git upstream && git -C upstream sparse-checkout set pstack' }
  $dst = Join-Path $root 'upstream'
  if ($IsWindows) { New-Item -ItemType Junction -Path $dst -Target $src | Out-Null }
  else { New-Item -ItemType SymbolicLink -Path $dst -Target $src | Out-Null }
}

# GitHub 的替身:一份 stub,行为全部由环境变量决定。detect/publish/alert 共用,
# 不各抄一份,否则 stub 与真实 gh 的语义会分叉。
function New-GhStub([string]$binDir) {
  New-Item -ItemType Directory -Force -Path $binDir | Out-Null
  $stub = @'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "release view")
    if printf '%s\n' "$GH_RELEASES" | grep -qx "$3"; then exit 0; fi
    exit 1 ;;
  "release list")
    if [ "$GH_LIST_FAIL" = "1" ]; then echo "stub: release list refused" >&2; exit 1; fi
    printf '%s\n' "$GH_RELEASES"; exit 0 ;;
  "release create")
    if [ "$GH_RELEASE_FAIL" = "1" ]; then echo "stub: release create refused" >&2; exit 1; fi
    exit 0 ;;
  "issue list")
    printf '%s' "$GH_EXISTING_ISSUE"; exit 0 ;;
  "api --method")
    if [ "$GH_PIN_API_FAIL" = "1" ]; then echo "stub: contents api refused" >&2; exit 1; fi
    printf '%s\n' "$GH_RELEASE_PIN"; exit 0 ;;
  "api "*)
    if [ "$GH_API_FAIL" = "1" ]; then echo "stub: jobs api refused" >&2; exit 1; fi
    printf '%s\n' "$GH_FAILED_STEPS"; exit 0 ;;
  "run view"*)
    if [ "$GH_LOG_FAIL" = "1" ]; then echo "stub: run log not retrievable" >&2; exit 1; fi
    printf '%s\n' "$GH_FAILED_LOG"; exit 0 ;;
  "issue create"|"issue comment")
    printf '%s\n' "$*" >> "$GH_BODY_LOG"; exit 0 ;;
esac
exit 0
'@
  $path = Join-Path $binDir 'gh'
  Set-Content -Path $path -Value $stub -Encoding utf8 -NoNewline
  & bash -c "chmod +x '$(BashPath $path)'" | Out-Null
  $env:PATH = $binDir + [System.IO.Path]::PathSeparator + $env:PATH
  $env:GH_LOG = Join-Path $evidence 'gh-calls.log'
  $env:GH_BODY_LOG = Join-Path $evidence 'gh-body.log'
  return $path
}

$fixtureIndex = Get-Content (Join-Path $skillDir 'fixtures\index.json') -Raw | ConvertFrom-Json

# 「上次同步态」的 pin 由生产步骤自己算,不由 harness 手推,也不读仓库里的 pin.json:
# Record upstream 是这个状态的唯一所有者。仓库的 pin 可能正处在刻意的中间态,
# 把它当前提会让 unchanged / self-heal 以看不懂的理由红,而代码其实是对的。
function Invoke-RecordUpstream([string]$root, [string]$From) {
  $step = Join-Path $root 'record-baseline.sh'
  Set-Content -Path $step -Value (Get-Step 'Record upstream' -From $From) -Encoding utf8
  $envOut = Join-Path $root 'record-baseline-env'
  New-Item -ItemType File -Force -Path $envOut | Out-Null
  $r = Invoke-Logged 'baseline-record' { $env:GITHUB_ENV = $envOut; & bash -c (Step-Command $root $step) }
  if ($r.code -ne 0) { throw 'Record upstream failed; cannot derive a synced pin' }
  return (Get-Content (Join-Path $root 'pin.json') -Raw | ConvertFrom-Json)
}

function Invoke-Fixture([string]$name, [string]$root) {
  $spec = @($fixtureIndex.fixtures | Where-Object { $_.name -eq $name }) | Select-Object -First 1
  if (-not $spec) { throw "unknown fixture: $name" }
  Copy-Tree (Join-Path $skillDir 'fixtures\base') $root
  $fx = Join-Path $skillDir "fixtures\$name"
  if (Test-Path $fx) { Copy-Tree $fx $root }
  $r = Invoke-Logged "validate-$name" { & pwsh -NoProfile -File (Join-Path $repo 'transform\scripts\validate.ps1') -Root $root }
  $want = if ($spec.kind -eq 'must-block') { 1 } else { 0 }
  Assert ("{0} ({1}) exit={2} want={3}" -f $name, $spec.kind, $r.code, $want) ($r.code -eq $want) $spec.class
  if ($spec.PSObject.Properties.Name -contains 'expectMessage') {
    Assert ("{0} error names the fix" -f $name) ($r.text -match [regex]::Escape($spec.expectMessage)) $spec.expectMessage
  }
  return [ordered]@{ name = $name; kind = $spec.kind; class = $spec.class; expectedExit = $want; actualExit = $r.code; pass = ($r.code -eq $want) }
}

$verdict = [ordered]@{ runId = $RunId; feature = $Feature; fixture = $Fixture; scenario = $Scenario; assertions = @(); ok = $true }
function Assert([string]$label, [bool]$cond, [string]$detail) {
  $script:verdict.assertions += [ordered]@{ label = $label; pass = $cond; detail = $detail }
  if (-not $cond) { $script:verdict.ok = $false }
  Log ("  {0} {1}{2}" -f $(if ($cond) {'PASS'} else {'FAIL'}), $label, $(if ($detail) {" -- $detail"} else {''}))
}

try {
  New-Item -ItemType Directory -Force -Path $scratch | Out-Null

  if ($Feature -eq 'gates') {
    if (-not $Fixture) { throw 'gates feature needs -Fixture' }
    $one = Invoke-Fixture $Fixture $scratch
    $verdict['expectedExit'] = $one.expectedExit
    $verdict['actualExit'] = $one.actualExit
    $verdict['class'] = $one.class
  }

  elseif ($Feature -eq 'corpus') {
    $rows = @()
    foreach ($f in $fixtureIndex.fixtures) { $rows += Invoke-Fixture $f.name (Join-Path $scratch $f.name) }
    $verdict['corpus'] = $rows
    $bad = @($rows | Where-Object { -not $_.pass })
    Log ("  corpus: {0}/{1} as expected" -f ($rows.Count - $bad.Count), $rows.Count)
    foreach ($b in $bad) { Log ("    MISS {0} ({1}, class {2}) exit={3} want={4}" -f $b.name, $b.kind, $b.class, $b.actualExit, $b.expectedExit) }
  }

  elseif ($Feature -eq 'doctor') {
    $healthy = Invoke-Logged 'doctor' { & pwsh -NoProfile -File (Join-Path $skillDir 'helpers\doctor.ps1') }
    Assert 'doctor healthy on the real repo' ($healthy.code -eq 0) ''
    # 判别性证明:未锚定的 output/ 忽略规则会吞掉 AP 夹具。本机看着正常,新克隆里夹具根本不存在,
    # 语料会少两条却仍然报 PASS。这里用一份临时 excludesFile 复现那个规则,doctor 必须抓到。
    $probe = Join-Path $scratch 'excludes-probe'
    Set-Content -Path $probe -Value "output/`n" -Encoding utf8 -NoNewline
    $env:GIT_CONFIG_COUNT = '1'
    $env:GIT_CONFIG_KEY_0 = 'core.excludesFile'
    $env:GIT_CONFIG_VALUE_0 = (BashPath $probe)
    $mutated = Invoke-Logged 'doctor-mutation' { & pwsh -NoProfile -File (Join-Path $skillDir 'helpers\doctor.ps1') }
    Remove-Item Env:GIT_CONFIG_COUNT, Env:GIT_CONFIG_KEY_0, Env:GIT_CONFIG_VALUE_0
    Assert 'ignore-swallowed fixtures are caught' ($mutated.code -eq 1 -and $mutated.text -match 'would ship') ("exit=" + $mutated.code)
    # 判别性证明:去掉 clone URL 的凭据,doctor 必须抓到。匿名 clone 会被反爬配额 429 拒掉,
    # 而这条故障发生在 harness 从不驱动的第一步,只有静态判据能守。
    $wfCopy = Join-Path $scratch 'sync-anonymous.yml'
    $wfText = Get-Content (Join-Path $repo '.github\workflows\sync.yml') -Raw
    $anon = $wfText -replace 'https://x-access-token:\$\{GH_TOKEN\}@github\.com/', 'https://github.com/'
    Assert 'mutation actually removed the credential' ($anon -ne $wfText) ''
    Set-Content -Path $wfCopy -Value $anon -Encoding utf8 -NoNewline
    $anonRun = Invoke-Logged 'doctor-anonymous' { & pwsh -NoProfile -File (Join-Path $skillDir 'helpers\doctor.ps1') -WorkflowPath $wfCopy }
    Assert 'anonymous upstream fetch is caught' ($anonRun.code -eq 1 -and $anonRun.text -match 'authenticated') ("exit=" + $anonRun.code)
    # 判别性证明:撤掉 actions 授权。告警步骤照样 exit 0,只是步骤名静默消失,
    # 所以这条只能靠静态判据守。
    $noPerm = $wfText -replace '(?m)^\s*actions:\s*read\s*\r?\n', ''
    Assert 'mutation actually removed the actions grant' ($noPerm -ne $wfText) ''
    $permCopy = Join-Path $scratch 'sync-no-actions-perm.yml'
    Set-Content -Path $permCopy -Value $noPerm -Encoding utf8 -NoNewline
    $permRun = Invoke-Logged 'doctor-no-actions-perm' { & pwsh -NoProfile -File (Join-Path $skillDir 'helpers\doctor.ps1') -WorkflowPath $permCopy }
    Assert 'a missing actions permission is caught' ($permRun.code -eq 1 -and $permRun.text -match 'jobs API') ("exit=" + $permRun.code)
  }

  elseif ($Feature -eq 'rules') {
    # 判别性证明:待查 frontmatter 字段是推导的还是另抄了一份硬编码清单。
    # 往 map 的 frontmatter.drop 注入一个合成键,门必须立刻认识它;硬编码清单会在这里放行。
    $synthetic = 'synthetic_cursor_field'
    $root = Join-Path $scratch 'repo'
    Copy-Tree (Join-Path $skillDir 'fixtures\base') $root
    Set-Content -Path (Join-Path $root 'plugins\pstack\skills\demo\SKILL.md') -Encoding utf8 -Value ("---`nname: demo`n" + $synthetic + ": leaked`n---`n`nplain body`n")
    $before = Invoke-Logged 'rules-undeclared' { & pwsh -NoProfile -File (Join-Path $repo 'transform\scripts\validate.ps1') -Root $root }
    Assert 'undeclared key is not a violation' ($before.code -eq 0) ("exit=" + $before.code)
    $tfDir = Join-Path $scratch 'transform'
    Copy-Tree (Join-Path $repo 'transform') $tfDir
    $mapPath = Join-Path $tfDir 'map.json'
    $m = Get-Content $mapPath -Raw | ConvertFrom-Json
    $m.frontmatter.drop = @($m.frontmatter.drop) + $synthetic
    $m | ConvertTo-Json -Depth 12 | Set-Content $mapPath -Encoding utf8
    $after = Invoke-Logged 'rules-declared' { & pwsh -NoProfile -File (Join-Path $tfDir 'scripts\validate.ps1') -Root $root }
    Assert 'declaring a key in map.json immediately enforces it' ($after.code -eq 1 -and $after.text -match $synthetic) ("exit=" + $after.code)
    $verdict['syntheticKey'] = $synthetic
  }

  elseif ($Feature -eq 'transform') {
    Copy-Tree (Join-Path $repo '.claude-plugin') (Join-Path $scratch '.claude-plugin')
    $t = Invoke-Logged 'transform' { & pwsh -NoProfile -File (Join-Path $repo 'transform\scripts\transform.ps1') -Upstream (Join-Path $repo 'upstream\pstack') -Out (Join-Path $scratch 'output') -OutCc $scratch }
    Assert 'transform exit=0' ($t.code -eq 0) $t.text.Split("`n")[-1]
    $v = Invoke-Logged 'validate' { & pwsh -NoProfile -File (Join-Path $repo 'transform\scripts\validate.ps1') -Root $scratch }
    Assert 'gates exit=0 on real upstream' ($v.code -eq 0) ($v.text -join ' ')
    Assert 'CC LICENSE present' (Test-Path (Join-Path $scratch 'plugins\pstack\LICENSE')) ''
    Assert 'AP LICENSE present' (Test-Path (Join-Path $scratch 'output\LICENSE')) ''
    $ccSkills = @(Get-ChildItem (Join-Path $scratch 'plugins\pstack\skills') -Directory).Count
    $apSkills = @(Get-ChildItem (Join-Path $scratch 'output\skills') -Directory).Count
    Assert 'skill parity' ($ccSkills -eq $apSkills) "CC=$ccSkills AP=$apSkills"
    # 入仓产物必须等于当前规则重算的结果:AGENTS.md 说生成内容不手改,这条断言是那个约定的强制器
    $norm = {
      param($base)
      $h = @{}
      foreach ($f in (Get-ChildItem $base -Recurse -File)) {
        $rel = $f.FullName.Substring($base.Length).TrimStart('\','/').Replace('\','/')
        $h[$rel] = ((Get-Content $f.FullName -Raw) -replace "`r`n", "`n")
      }
      return $h
    }
    $committed = & $norm (Join-Path $repo 'plugins\pstack')
    $produced  = & $norm (Join-Path $scratch 'plugins\pstack')
    $drift = @($committed.Keys | Where-Object { -not $produced.ContainsKey($_) -or $produced[$_] -ne $committed[$_] }) + @($produced.Keys | Where-Object { -not $committed.ContainsKey($_) })
    Assert 'committed CC artifact equals recomputed output' ($drift.Count -eq 0) (($drift | Select-Object -First 5) -join ', ')
    $verdict['skills'] = $ccSkills
  }

  elseif ($Feature -eq 'detect') {
    Copy-Item (Join-Path $repo 'pin.json') (Join-Path $scratch 'pin.json')
    Link-Upstream $scratch
    $pinPath = Join-Path $scratch 'pin.json'
    if ($Scenario -in @('unchanged','release-missing','same-version-old-release','pin-api-fails','gh-fails')) {
      # 这些场景的前提是「pin 已同步」。现算,不继承仓库当时的状态。
      $tf = { & pwsh -NoProfile -File (Join-Path $repo 'transform\scripts\transform.ps1') -Upstream (Join-Path $scratch 'upstream\pstack') -Out (Join-Path $scratch 'output') -OutCc $scratch }
      $bt = Invoke-Logged 'baseline-transform' $tf
      Assert 'baseline transform exit=0' ($bt.code -eq 0) ''
      Invoke-RecordUpstream $scratch | Out-Null
    }
    $pin = Get-Content $pinPath -Raw | ConvertFrom-Json
    $releases = "pstack-$($pin.version)-r1"
    if ($Scenario -eq 'changed') { $pin.pstackTree = '' }
    elseif ($Scenario -eq 'missing-field') { $pin.PSObject.Properties.Remove('pstackTree') }
    elseif ($Scenario -eq 'release-missing') { $releases = '' }
    elseif ($Scenario -notin @('unchanged','same-version-old-release','pin-api-fails','gh-fails')) { throw "unknown detect scenario: $Scenario" }
    $pin | ConvertTo-Json -Depth 6 | Set-Content $pinPath -Encoding utf8
    New-GhStub (Join-Path $scratch 'bin') | Out-Null
    $env:GH_RELEASES = $releases
    $env:GITHUB_REPOSITORY = 'local/pstack-fixture'
    $env:GH_RELEASE_PIN = if ($Scenario -eq 'same-version-old-release') { 'older-pin-blob' } else { & git hash-object -- $pinPath }
    $env:GH_PIN_API_FAIL = if ($Scenario -eq 'pin-api-fails') { '1' } else { '0' }
    $env:GH_LIST_FAIL = if ($Scenario -eq 'gh-fails') { '1' } else { '0' }
    $step = Join-Path $scratch 'detect.sh'
    Set-Content -Path $step -Value (Get-Step 'Detect change') -Encoding utf8
    $ghOut = Join-Path $scratch 'gh-output'
    New-Item -ItemType File -Force -Path $ghOut | Out-Null
    # 步骤按相对路径读 pin.json 与 upstream/,必须在 scratch 里跑,否则读到的是真仓库
    $r = Invoke-Logged 'detect' { $env:GITHUB_OUTPUT = $ghOut; & bash -c (Step-Command $scratch $step) }
    $lines = @(Get-Content $ghOut)
    Assert 'detect wrote changed= to GITHUB_OUTPUT' (@($lines | Where-Object { $_ -match '^changed=' }).Count -eq 1) ($lines -join ' | ')
    $changed = [string](($lines | Where-Object { $_ -match '^changed=' }) -replace '^changed=','')
    $want = if ($Scenario -eq 'unchanged') { 'no' } else { 'yes' }
    Assert ("detect scenario={0} changed={1} want={2}" -f $Scenario, $changed, $want) ($changed -eq $want) ''
    $verdict['changed'] = $changed
    Assert 'detect exit=0' ($r.code -eq 0) ''
    if ($Scenario -in @('unchanged','release-missing','same-version-old-release','pin-api-fails','gh-fails')) {
      $verdict['standInSetup'] = @('synced pin derived by running the real Record upstream step against the local clone, not read from the repo')
    }

    if ($Scenario -eq 'unchanged') {
      # 判别性证明:「已同步」这个前提必须真由 Record upstream 算出。让该步骤写出空树
      # (历史上真实出现过的退化态),同一条 drive 必须立刻判有变更。
      # 若 harness 自己编造基线,这个改动就不会有任何影响,证明也就无从成立。
      $wfText = Get-Content (Join-Path $repo '.github\workflows\sync.yml') -Raw
      $needle = '.pstackTree=$t'
      Assert 'mutation target exists in Record upstream' ($wfText.Contains($needle)) ''
      $mutWf = Join-Path $scratch 'sync-blank-tree.yml'
      Set-Content -Path $mutWf -Value $wfText.Replace($needle, '.pstackTree=""') -Encoding utf8 -NoNewline
      $mutRoot = Join-Path $scratch 'mut'
      New-Item -ItemType Directory -Force -Path $mutRoot | Out-Null
      Copy-Item $pinPath (Join-Path $mutRoot 'pin.json') -Force
      Copy-Tree (Join-Path $scratch 'plugins') (Join-Path $mutRoot 'plugins')
      Link-Upstream $mutRoot
      Invoke-RecordUpstream $mutRoot -From $mutWf | Out-Null
      $mutStep = Join-Path $mutRoot 'detect.sh'
      Set-Content -Path $mutStep -Value (Get-Step 'Detect change' -From $mutWf) -Encoding utf8
      $mutOut = Join-Path $mutRoot 'gh-output'
      New-Item -ItemType File -Force -Path $mutOut | Out-Null
      $mutRun = Invoke-Logged 'detect-blank-tree' { $env:GITHUB_OUTPUT = $mutOut; & bash -c (Step-Command $mutRoot $mutStep) }
      $mutChanged = [string](@(Get-Content $mutOut) | Where-Object { $_ -match '^changed=' }) -replace '^changed=',''
      Assert 'a Record step that drops the tree is caught' ($mutRun.code -eq 0 -and $mutChanged -eq 'yes') ("changed=" + $mutChanged)
    }
  }

  elseif ($Feature -eq 'publish') {
    # 本地 bare remote 是 GitHub 的替身: 真 git 提交/标签/推送,gh 用受控 stub
    $remote = Join-Path $scratch 'remote.git'
    & git init -q --bare -b main $remote | Out-Null
    $work = Join-Path $scratch 'work'
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    & git -C $work init -q -b main | Out-Null
    & git -C $work remote add origin $remote | Out-Null
    Copy-Tree (Join-Path $repo 'transform') (Join-Path $work 'transform')
    Copy-Tree (Join-Path $repo '.claude-plugin') (Join-Path $work '.claude-plugin')
    Copy-Item (Join-Path $repo '.gitignore') (Join-Path $work '.gitignore')
    Link-Upstream $work
    # 替身 setup:scratch 从一个真实的"上次同步态"起步。目标环境里"上游真的前进了"
    # 提供这个前提;本地必须显式构造,否则无变更可提交,走不到 commit/tag/release 的真实路径。
    # self-heal / tag-serial 反过来:pin 已是当前态,要构造的是"产物相同但 release 缺失"。
    $synced = $Scenario -in @('self-heal','tag-serial')
    $oldPin = ((& git -C $repo show '221395a:pin.json') -join "`n") | ConvertFrom-Json
    if ($synced) {
      Copy-Item (Join-Path $repo 'pin.json') (Join-Path $work 'pin.json') -Force
    } else {
      $oldPin | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $work 'pin.json') -Encoding utf8
    }
    $tf = { & pwsh -NoProfile -File (Join-Path $work 'transform\scripts\transform.ps1') -Upstream (Join-Path $work 'upstream\pstack') -Out (Join-Path $work 'output') -OutCc $work }
    $t = Invoke-Logged 'transform' $tf
    Assert 'transform exit=0' ($t.code -eq 0) ''
    if ($synced) {
      $pinBaseline = Invoke-RecordUpstream $work
      if ($Scenario -eq 'tag-serial') {
        # 同版本、不同树:只把 pstackTree 退回上一次同步的树。重跑只改 pin.json,
        # 版本不变而树变了,正是生产里 r1 落后于 main 的状态。
        $pinBaseline.pstackTree = [string]$oldPin.pstackTree
      }
      $pinBaseline | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $work 'pin.json') -Encoding utf8
    } else {
      $pinBaseline = $oldPin
    }
    $ccManPath = Join-Path $work 'plugins\pstack\.claude-plugin\plugin.json'
    $ccMan = Get-Content $ccManPath -Raw | ConvertFrom-Json
    # 本次运行会发布的版本,取自刚变换出的清单,不是旧 pin
    $publishedVersion = [string]$ccMan.version
    # tag-serial 要构造「同版本、不同树」:基线清单已是当前版本,只有 pin 仍是旧态,
    # 重跑只改 pin.json —— 版本不变而树变了,正是生产里 r1 落后于 main 的状态。
    $ccMan.version = if ($Scenario -eq 'tag-serial') { $publishedVersion } else { [string]$pinBaseline.version }
    $ccMan | ConvertTo-Json -Depth 6 | Set-Content $ccManPath -Encoding utf8
    & git -C $work add -A 2>&1 | Out-Null
    & git -C $work -c user.name=verify -c user.email=verify@local commit -q -m baseline 2>&1 | Out-Null
    & git -C $work push -q origin main 2>&1 | Out-Null
    $baseHead = (& git -C $work rev-parse HEAD).Trim()
    if ($Scenario -in @('self-heal','tag-serial')) {
      # 远端已有 r1 指向 baseline 树。self-heal 不产生新提交,必须复用它;
      # tag-serial 产生新提交,HEAD 与 r1 不同,必须递增到 r2 而不是覆盖 r1。
      & git -C $work tag "pstack-$publishedVersion-r1" $baseHead 2>&1 | Out-Null
      & git -C $work push -q origin "refs/tags/pstack-$publishedVersion-r1" 2>&1 | Out-Null
    }
    $t2 = Invoke-Logged 'transform-rerun' $tf
    Assert 'transform rerun exit=0' ($t2.code -eq 0) ''
    $verdict['standInSetup'] = @(
      'local bare remote replaces GitHub',
      'gh replaced by the shared env-driven stub (release view/list/create, issue list/create/comment, api, run view)',
      $(if ($synced) { "synced pin derived by the real Record upstream step (version $($pinBaseline.version))" } else { "pin.json rewound to the previous-sync state (version $($pinBaseline.version))" }),
      "baseline manifest version $publishedVersion",
      'transform run twice: once for the baseline commit, once to simulate upstream advancing',
      'a failed step aborts the remaining steps, as GitHub does without continue-on-error'
    )
    if ($Scenario -eq 'tag-serial') {
      $verdict['standInSetup'] += 'pin.pstackTree rewound to the previous-sync tree while the version stays current'
    }
    if ($synced) {
      $verdict['standInSetup'] += "remote already carries pstack-$publishedVersion-r1 at the baseline commit"
    }

    New-GhStub (Join-Path $scratch 'bin') | Out-Null
    $ghLog = $env:GH_LOG
    # tag-serial 下 r1 已发布:release view r2 必须落空,才会走到 create
    $env:GH_RELEASES = if ($Scenario -eq 'tag-serial') { "pstack-$publishedVersion-r1" } else { '' }
    $env:GH_LIST_FAIL = '0'
    $env:GH_RELEASE_FAIL = if ($Scenario -eq 'release-fails') { '1' } else { '0' }
    if ($Scenario -eq 'commit-fails') {
      $hook = Join-Path $work '.git\hooks\pre-commit'
      Set-Content -Path $hook -Value "#!/usr/bin/env bash`nexit 1`n" -Encoding utf8 -NoNewline
      & bash -c "chmod +x '$(BashPath $hook)'" | Out-Null
    }
    elseif ($Scenario -eq 'push-rejected') {
      # 竞争窗口在 rebase 之后、push 之前:setup 里先推进远端会被开场的 rebase 吸收,
      # 根本走不到重试分支。用 pre-push 钩子在第一次 push 的瞬间推进远端并拒绝该次推送。
      $other = Join-Path $scratch 'other'
      & git clone -q $remote $other 2>&1 | Out-Null
      Set-Content -Path (Join-Path $other 'REMOTE-ADVANCE.md') -Value "advanced by another writer`n" -Encoding utf8
      & git -C $other add REMOTE-ADVANCE.md 2>&1 | Out-Null
      & git -C $other -c user.name=other -c user.email=other@local commit -q -m 'remote advances' 2>&1 | Out-Null
      $advancer = (& git -C $other rev-parse HEAD).Trim()
      # 先把对象送进远端(侧 ref),钩子只需移动 main,不必在钩子里嵌套 push
      & git -C $other push -q origin main:refs/heads/advancer 2>&1 | Out-Null
      $hookBody = @'
#!/usr/bin/env bash
marker="$(git rev-parse --git-dir)/push-race-fired"
if [ -e "$marker" ]; then exit 0; fi
touch "$marker"
git --git-dir='__REMOTE__' update-ref refs/heads/main __ADVANCER__
echo "stub: remote advanced during push; rejecting" >&2
exit 1
'@
      $hookBody = $hookBody.Replace('__REMOTE__', (BashPath $remote)).Replace('__ADVANCER__', $advancer)
      $hook = Join-Path $work '.git\hooks\pre-push'
      Set-Content -Path $hook -Value $hookBody -Encoding utf8 -NoNewline
      & bash -c "chmod +x '$(BashPath $hook)'" | Out-Null
      $verdict['remoteAdvancer'] = $advancer
    }
    elseif ($Scenario -notin @('happy','release-fails','self-heal','tag-serial')) { throw "unknown publish scenario: $Scenario" }

    $envFile = Join-Path $scratch 'gh-env'
    New-Item -ItemType File -Force -Path $envFile | Out-Null
    $stepResults = [ordered]@{}
    $aborted = $false
    foreach ($name in @('Record upstream','Commit','Tag and push','Publish release')) {
      if ($aborted) { $stepResults[$name] = 'skipped'; continue }
      $slug = ($name -replace ' ','-').ToLowerInvariant()
      $sh = Join-Path $scratch "$slug.sh"
      Set-Content -Path $sh -Value (Get-Step $name) -Encoding utf8
      # Actions 把上一步的 GITHUB_ENV 注入后续步骤;这里照做,否则 VERSION/TAG 传不下去
      $r = Invoke-Logged $slug { $env:GITHUB_ENV = $envFile; & bash -c (Step-Command $work $sh "set -a && . '$(BashPath $envFile)' 2>/dev/null; set +a; ") }
      $stepResults[$name] = $r.code
      if ($r.code -ne 0) { $aborted = $true }
      if (Test-Path $envFile) { foreach ($ln in (Get-Content $envFile)) { if ($ln -match '^([^=]+)=(.*)$') { Set-Item -Path ("Env:" + $Matches[1]) -Value $Matches[2] } } }
    }
    $allZero = -not $aborted
    # 下游消费者看的是远端,不是工作树:性质必须断言远端状态
    $remoteHead = (& git -C $remote rev-parse main).Trim()
    $remoteTree = (& git -C $remote rev-parse 'main^{tree}').Trim()
    $remotePin = ((& git -C $remote show 'main:pin.json') -join "`n") | ConvertFrom-Json
    $remoteMan = ((& git -C $remote show 'main:plugins/pstack/.claude-plugin/plugin.json') -join "`n") | ConvertFrom-Json
    $tags = @(& git -C $remote tag -l 'pstack-*')
    $tagName = if ($env:TAG) { [string]$env:TAG } elseif ($tags.Count -gt 0) { $tags[-1] } else { $null }
    $tagOnRemote = ($null -ne $tagName) -and ($tags -contains $tagName)
    $tagTree = if ($tagOnRemote) { (& git -C $remote rev-parse ($tagName + '^{tree}')).Trim() } else { '' }
    $tagVersion = if ($tagName -match '^pstack-(.+)-r\d+$') { $Matches[1] } else { '' }
    $ghCalls = if (Test-Path $ghLog) { @(Get-Content $ghLog) } else { @() }
    # 发布成功由观察判定,不由 scenario 名字判定:名字是输入,不是证据
    $releaseCreated = @($ghCalls | Where-Object { $_ -match '^release create' }).Count -gt 0
    $releaseSucceeded = $releaseCreated -and ($stepResults['Publish release'] -eq 0)
    $remoteAdvanced = ($remoteHead -ne $baseHead)
    $versionAgree = ($tagVersion -eq [string]$remotePin.version) -and ([string]$remoteMan.version -eq [string]$remotePin.version)
    $consistent = $releaseSucceeded -and $tagOnRemote -and ($tagTree -eq $remoteTree) -and $versionAgree
    $verdict['steps'] = $stepResults
    $verdict['remoteAdvanced'] = $remoteAdvanced
    $verdict['tag'] = $tagName
    $verdict['tagOnRemote'] = $tagOnRemote
    $verdict['remoteTagCount'] = $tags.Count
    $verdict['tagTreeEqualsRemoteTree'] = ($tagTree -eq $remoteTree)
    $verdict['remotePinVersion'] = [string]$remotePin.version
    $verdict['remoteManifestVersion'] = [string]$remoteMan.version
    $verdict['tagVersion'] = $tagVersion
    $verdict['releaseSucceeded'] = $releaseSucceeded
    Log ("  steps: " + (($stepResults.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '))
    Log ("  remoteAdvanced=$remoteAdvanced tag=$tagName tagTree==remoteTree=$($tagTree -eq $remoteTree) versions(tag/pin/manifest)=$tagVersion/$($remotePin.version)/$($remoteMan.version) release=$releaseSucceeded")
    # 性质: 全绿 => release 存在 且 tag 在远端 且 tag 树==远端树 且 tag/pin/清单版本三者一致
    $property = (-not $allZero) -or $consistent
    Assert 'green-run implies published artifact matches pinned tree' $property ("allStepsZero=$allZero scenario=$Scenario")
    if ($Scenario -in @('release-fails','commit-fails')) {
      # 判别性证明:这两条路径此前全绿却什么都没发布出去,现在必须红
      Assert 'a failed publish step turns the run red' (-not $allZero) ''
    } else {
      Assert 'happy path stays green' $allZero ''
      Assert 'release exists for the pushed tag' $releaseSucceeded ''
      if ($Scenario -eq 'self-heal') {
        Assert 'self-heal reuses the existing tag' ($tags.Count -eq 1) ($tags -join ', ')
        Assert 'self-heal makes no empty commit' (-not $remoteAdvanced) ''
      } else {
        Assert 'remote main advanced' $remoteAdvanced ''
      }
      if ($Scenario -eq 'push-rejected') {
        # 场景名不是证据:必须看到重试分支真的跑了,否则这条路径只是名义上被覆盖
        $pushLog = Get-Content (Join-Path $evidence 'tag-and-push.txt') -Raw
        Assert 'push rejection exercised the rebase-and-retry path' ($pushLog -match 'push rejected') ''
      }
      if ($Scenario -eq 'tag-serial') {
        # 序号递增分支此前从未被驱动:每个 drive 都新建远端,只看得到 r1。
        # 这里预置一个指向旧树的 r1,新提交必须落到 r2,且 r1 原地不动。
        $r1 = "pstack-$publishedVersion-r1"
        Assert 'tag serial incremented to r2' ($tagName -eq "pstack-$publishedVersion-r2") ($tags -join ', ')
        Assert 'both tags are on the remote' ($tags.Count -eq 2) ($tags -join ', ')
        Assert 'existing r1 still points at the baseline commit' ((& git -C $remote rev-parse ($r1 + '^{commit}')).Trim() -eq $baseHead) $baseHead
      }
    }
  }

  elseif ($Feature -eq 'alert') {
    # 用真实失败的门输出驱动告警步骤:告警必须自带定位信息,不能只有 run 链接
    # no-gate-report / no-log-available 覆盖门之前就失败的那一类:抓取、变换阶段红,没有 gate-report
    $early = $Scenario -in @('no-gate-report','no-log-available')
    $fx = if ($Fixture) { $Fixture } else { 'tp-models-bare' }
    if ($Scenario -in @('open-issue','no-open-issue')) {
      $root = Join-Path $scratch 'repo'
      Invoke-Fixture $fx $root | Out-Null
      Copy-Item (Join-Path $evidence "validate-$fx.txt") (Join-Path $scratch 'gate-report.txt') -Force
      Link-Upstream $scratch
    } elseif (-not $early) { throw "unknown alert scenario: $Scenario" }
    # 抓取失败时克隆根本不存在,upstream 标题只能是 unknown。链上真实克隆会把这条前提抹掉。
    New-GhStub (Join-Path $scratch 'bin') | Out-Null
    $ghLog = $env:GH_LOG
    if ($Scenario -eq 'open-issue') { $env:GH_EXISTING_ISSUE = '6' } else { $env:GH_EXISTING_ISSUE = '' }
    if ($early) {
      $env:GH_FAILED_STEPS = 'Fetch upstream'
      $env:GH_API_FAIL = ''
      # 生产里这一步的真实输出:匿名 clone 撞上反爬配额
      $env:GH_FAILED_LOG = "Fetch upstream`tfatal: unable to access 'https://github.com/cursor/plugins.git/': The requested URL returned error: 429"
      $env:GH_LOG_FAIL = if ($Scenario -eq 'no-log-available') { '1' } else { '' }
    } else {
      $env:GH_FAILED_STEPS = 'Validate gates'
      $env:GH_LOG_FAIL = ''
    }
    $env:GITHUB_SERVER_URL = 'https://github.com'
    $env:GITHUB_REPOSITORY = 'lab-GESTALT/agent-plugin-pstack'
    $env:GITHUB_RUN_ID = '0'
    $sh = Join-Path $scratch 'alert.sh'
    Set-Content -Path $sh -Value (Get-Step 'Alert on failure') -Encoding utf8
    $r = Invoke-Logged 'alert' { & bash -c (Step-Command $scratch $sh) }
    Assert 'alert step exit=0' ($r.code -eq 0) ''
    $calls = if (Test-Path $ghLog) { @(Get-Content $ghLog) } else { @() }
    $body = if (Test-Path $env:GH_BODY_LOG) { (Get-Content $env:GH_BODY_LOG -Raw) } else { '' }
    $wantCmd = if ($Scenario -eq 'open-issue') { 'issue comment 6' } else { 'issue create' }
    Assert ("alert uses {0}" -f $wantCmd) (@($calls | Where-Object { $_ -like "$wantCmd*" }).Count -gt 0) ($calls -join ' | ')
    if ($early) {
      Assert 'alert body names the failed step' ($body -match 'Failed step: Fetch upstream') ''
      if ($Scenario -eq 'no-log-available') {
        # 日志尚未归档时也必须明说,不能静默退回裸链接
        Assert 'alert says the log is unavailable instead of going bare' ($body -match 'not retrievable') ''
      } else {
        Assert 'alert body carries the failed-step log' ($body -match 'Failed step output:' -and $body -match '429') ''
      }
      Assert 'alert issue title falls back to unknown upstream' (@($calls | Where-Object { $_ -like '*upstream unknown*' }).Count -gt 0) ($calls -join ' | ')
    } else {
      Assert 'alert body carries gate output' ($body -match 'Gate output:' -and $body -match 'gate1 residual') ''
      $spec = @($fixtureIndex.fixtures | Where-Object { $_.name -eq $fx }) | Select-Object -First 1
      $wantPattern = [string]$spec.expectMessage
      Assert ("alert body names the failing pattern ({0})" -f $wantPattern) ($body -match [regex]::Escape($wantPattern)) ''
    }
    $verdict['ghCalls'] = $calls
    if ($early) { $verdict['standInSetup'] = @('no gate-report.txt and no upstream clone (failure preceded the gates)') }

    if ($Scenario -eq 'no-gate-report') {
      # 判别性证明:这是历史上真实存在过的告警步骤(只给 run 链接)。冻结成红夹具,
      # 不是随手改坏当前步骤 —— 上面的断言必须能把这个真实旧版本判红,否则它只是装饰。
      $bareStep = @'
NEW=$(git -C upstream rev-parse HEAD 2>/dev/null || echo unknown)
BODY="pstack sync pipeline failed. See run: ${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}. pin.json unchanged; next cron will retry."
EXISTING=$(gh issue list --state open --limit 100 --json number,title --jq '[.[] | select(.title | startswith("sync failed:"))][0].number' || true)
if [ -n "$EXISTING" ] && [ "$EXISTING" != "null" ]; then
  gh issue comment "$EXISTING" --body "upstream ${NEW}: ${BODY}" || echo "::warning::alert comment failed"
else
  gh issue create --title "sync failed: upstream ${NEW}" --body "$BODY" || echo "::warning::alert create failed"
fi
'@
      $bareSh = Join-Path $scratch 'alert-bare.sh'
      Set-Content -Path $bareSh -Value $bareStep -Encoding utf8
      $env:GH_BODY_LOG = Join-Path $evidence 'gh-body-bare.log'
      $bareRun = Invoke-Logged 'alert-bare' { & bash -c (Step-Command $scratch $bareSh) }
      $bareBody = if (Test-Path $env:GH_BODY_LOG) { (Get-Content $env:GH_BODY_LOG -Raw) } else { '' }
      Assert 'historical bare-link alert still runs' ($bareRun.code -eq 0) ("exit=" + $bareRun.code)
      Assert 'bare-link alert is caught by the locatability assertion' (($bareBody -notmatch 'Failed step:') -and ($bareBody -notmatch 'Failed step output:') -and ($bareBody -notmatch 'Gate output:')) ''
    }
  }

  $verdict['scratch'] = $scratch
}
finally {
  if (-not $KeepRoot -and (Test-Path $scratch)) {
    # 先摘掉 junction/symlink:递归删除不得跟进真实的 upstream 克隆
    if ($IsWindows) {
      Get-ChildItem $scratch -Recurse -Force -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint } |
        ForEach-Object { & cmd /c "rmdir `"$($_.FullName)`"" 2>&1 | Out-Null }
      & cmd /c "rmdir /s /q `"$scratch`"" 2>&1 | Out-Null
    } else {
      & find $scratch -type l -delete 2>&1 | Out-Null
      Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
  Assert 'cleanup removed scratch' ((-not $KeepRoot) -and (-not (Test-Path $scratch))) ''
  Assert 'upstream clone survived cleanup' (Test-Path (Join-Path $repo 'upstream\pstack')) ''
  $verdict['scratchRemoved'] = (-not $KeepRoot) -and (-not (Test-Path $scratch))
  $verdict | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $evidence 'verdict.json') -Encoding utf8
  Set-Content -Path (Join-Path $evidence 'commands.txt') -Value ($transcript -join "`n") -Encoding utf8
  Assert 'cleanup kept evidence' ((Test-Path (Join-Path $evidence 'verdict.json')) -and (Test-Path (Join-Path $evidence 'commands.txt'))) $evidence
  $verdict | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $evidence 'verdict.json') -Encoding utf8
  Write-Output ("EVIDENCE: " + $evidence)
  Write-Output ("VERIFY: " + $(if ($verdict.ok) {'PASS'} else {'FAIL'}))
}
if (-not $verdict.ok) { exit 1 }
exit 0