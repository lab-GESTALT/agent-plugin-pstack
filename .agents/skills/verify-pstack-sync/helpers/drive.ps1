param(
  [Parameter(Mandatory=$true)][ValidateSet('gates','corpus','rules','doctor','transform','detect','publish','alert')][string]$Feature,
  [string]$Fixture,
  [string]$Scenario = 'happy',
  [string]$RunId,
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
function Invoke-Logged([string]$name, [scriptblock]$body) {
  $outFile = Join-Path $evidence "$name.txt"
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $out = & $body 2>&1 | ForEach-Object { [string]$_ }
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prev
  $text = ($out -join "`n")
  Set-Content -Path $outFile -Value $text -Encoding utf8
  Log ("[{0}] exit={1}" -f $name, $code)
  return [pscustomobject]@{ code = $code; text = $text; file = $outFile }
}

function Copy-Tree([string]$src, [string]$dst) {
  New-Item -ItemType Directory -Force -Path $dst | Out-Null
  Copy-Item (Join-Path $src '*') $dst -Recurse -Force
}

# bash 里反斜杠是转义符,插值前统一成正斜杠
function BashPath([string]$p) { return ($p -replace '\\','/') }

# 从 live sync.yml 抽取步骤的 run 块: harness 不复制 workflow 逻辑,避免第二份手工同步清单
function Get-WorkflowStep([string]$stepName) {
  $lines = Get-Content (Join-Path $repo '.github\workflows\sync.yml')
  $start = -1
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match ('^\s*-\s*name:\s*' + [regex]::Escape($stepName) + '\s*$')) { $start = $i; break }
  }
  if ($start -lt 0) { throw "step not found in sync.yml: $stepName" }
  $runAt = -1
  for ($i = $start + 1; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*-\s*name:') { break }
    if ($lines[$i] -match '^(\s*)run:\s*\|\s*$') { $runAt = $i; $indent = $Matches[1].Length; break }
  }
  if ($runAt -lt 0) { throw "step has no literal run block: $stepName" }
  $body = @()
  for ($i = $runAt + 1; $i -lt $lines.Count; $i++) {
    $ln = $lines[$i]
    if ($ln.Trim() -ne '' ) {
      $lead = ($ln -replace '^( *).*$','$1').Length
      if ($lead -le $indent) { break }
    }
    $body += $ln.Substring([Math]::Min($indent + 2, $ln.Length))
  }
  $text = ($body -join "`n")
  if ($text.Trim() -eq '') { throw "empty run block: $stepName" }
  return $text
}

function Link-Upstream([string]$root) {
  $src = Join-Path $repo 'upstream'
  if (-not (Test-Path $src)) { throw 'upstream clone missing; run: git clone --depth 1 --filter=blob:none --sparse https://github.com/cursor/plugins.git upstream && git -C upstream sparse-checkout set pstack' }
  $dst = Join-Path $root 'upstream'
  if ($IsWindows) { New-Item -ItemType Junction -Path $dst -Target $src | Out-Null }
  else { New-Item -ItemType SymbolicLink -Path $dst -Target $src | Out-Null }
}

$fixtureIndex = Get-Content (Join-Path $skillDir 'fixtures\index.json') -Raw | ConvertFrom-Json
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
    $pin = Get-Content $pinPath -Raw | ConvertFrom-Json
    if ($Scenario -eq 'changed') { $pin.pstackTree = '' }
    elseif ($Scenario -eq 'missing-field') { $pin.PSObject.Properties.Remove('pstackTree') }
    elseif ($Scenario -ne 'unchanged') { throw "unknown detect scenario: $Scenario" }
    $pin | ConvertTo-Json -Depth 6 | Set-Content $pinPath -Encoding utf8
    $step = Join-Path $scratch 'detect.sh'
    Set-Content -Path $step -Value (Get-WorkflowStep 'Detect change') -Encoding utf8
    $outFile = Join-Path $scratch 'gh-output'
    New-Item -ItemType File -Force -Path $outFile | Out-Null
    $r = Invoke-Logged 'detect' { $env:GITHUB_OUTPUT = $outFile; & bash $step }
    $changed = (Get-Content $outFile | Where-Object { $_ -match '^changed=' }) -replace '^changed=',''
    $want = if ($Scenario -eq 'unchanged') { 'no' } else { 'yes' }
    Assert ("detect scenario={0} changed={1} want={2}" -f $Scenario, $changed, $want) ($changed -eq $want) ''
    $verdict['changed'] = $changed
    Assert 'detect exit=0' ($r.code -eq 0) ''
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
    # 替身 setup:scratch 从真实历史同步态(221395a 的 pin)起步。目标环境里"上游真的前进了"
    # 提供这个前提;本地必须显式构造,否则无变更可提交,走不到 commit/tag/release 的真实路径。
    $oldPin = ((& git -C $repo show '221395a:pin.json') -join "`n") | ConvertFrom-Json
    $oldPin | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $work 'pin.json') -Encoding utf8
    $tf = { & pwsh -NoProfile -File (Join-Path $work 'transform\scripts\transform.ps1') -Upstream (Join-Path $work 'upstream\pstack') -Out (Join-Path $work 'output') -OutCc $work }
    $t = Invoke-Logged 'transform' $tf
    Assert 'transform exit=0' ($t.code -eq 0) ''
    $ccManPath = Join-Path $work 'plugins\pstack\.claude-plugin\plugin.json'
    $ccMan = Get-Content $ccManPath -Raw | ConvertFrom-Json
    $ccMan.version = [string]$oldPin.version
    $ccMan | ConvertTo-Json -Depth 6 | Set-Content $ccManPath -Encoding utf8
    & git -C $work add -A 2>&1 | Out-Null
    & git -C $work -c user.name=verify -c user.email=verify@local commit -q -m baseline 2>&1 | Out-Null
    & git -C $work push -q origin main 2>&1 | Out-Null
    $baseHead = (& git -C $work rev-parse HEAD).Trim()
    $t2 = Invoke-Logged 'transform-rerun' $tf
    Assert 'transform rerun exit=0' ($t2.code -eq 0) ''
    $verdict['standInSetup'] = @(
      'local bare remote replaces GitHub',
      'gh replaced by a stub that logs calls and can refuse release create',
      "pin.json and plugin version rewound to 221395a (version $($oldPin.version)) to create a real previous-sync state",
      'transform run twice: once for the baseline commit, once to simulate upstream advancing'
    )

    $bin = Join-Path $scratch 'bin'
    New-Item -ItemType Directory -Force -Path $bin | Out-Null
    $ghLog = Join-Path $evidence 'gh-calls.log'
    $ghStub = @'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
if [ "$1" = "release" ] && [ "$2" = "create" ] && [ "$GH_RELEASE_FAIL" = "1" ]; then
  echo "stub: release create refused" >&2; exit 1
fi
exit 0
'@
    Set-Content -Path (Join-Path $bin 'gh') -Value $ghStub -Encoding utf8 -NoNewline
    & bash -c "chmod +x '$(BashPath (Join-Path $bin 'gh'))'" | Out-Null
    if ($Scenario -eq 'commit-fails') {
      $hook = Join-Path $work '.git\hooks\pre-commit'
      Set-Content -Path $hook -Value "#!/usr/bin/env bash`nexit 1`n" -Encoding utf8 -NoNewline
      & bash -c "chmod +x '$(BashPath $hook)'" | Out-Null
    }
    elseif ($Scenario -notin @('happy','release-fails')) { throw "unknown publish scenario: $Scenario" }

    $env:PATH = $bin + [System.IO.Path]::PathSeparator + $env:PATH
    $env:GH_LOG = $ghLog
    $env:GH_RELEASE_FAIL = if ($Scenario -eq 'release-fails') { '1' } else { '0' }
    $envFile = Join-Path $scratch 'gh-env'
    New-Item -ItemType File -Force -Path $envFile | Out-Null
    $stepResults = @{}
    foreach ($name in @('Record upstream','Commit','Tag and push','Publish release')) {
      $slug = ($name -replace ' ','-').ToLowerInvariant()
      $sh = Join-Path $scratch "$slug.sh"
      Set-Content -Path $sh -Value (Get-WorkflowStep $name) -Encoding utf8
      # Actions 把上一步的 GITHUB_ENV 注入后续步骤;这里照做,否则 VERSION/TAG 传不下去
      $r = Invoke-Logged $slug { $env:GITHUB_ENV = $envFile; & bash -c "cd '$(BashPath $work)' && set -a && . '$(BashPath $envFile)' 2>/dev/null; set +a; bash '$(BashPath $sh)'"; }
      $stepResults[$name] = $r.code
      if (Test-Path $envFile) { foreach ($ln in (Get-Content $envFile)) { if ($ln -match '^([^=]+)=(.*)$') { Set-Item -Path ("Env:" + $Matches[1]) -Value $Matches[2] } } }
    }
    $allZero = @($stepResults.Values | Where-Object { $_ -ne 0 }).Count -eq 0
    # 下游消费者看的是远端,不是工作树:性质必须断言远端状态
    $remoteHead = (& git -C $remote rev-parse main).Trim()
    $remoteTree = (& git -C $remote rev-parse 'main^{tree}').Trim()
    $remotePin = ((& git -C $remote show 'main:pin.json') -join "`n") | ConvertFrom-Json
    $remoteMan = ((& git -C $remote show 'main:plugins/pstack/.claude-plugin/plugin.json') -join "`n") | ConvertFrom-Json
    $tags = @(& git -C $remote tag -l 'pstack-*')
    $tagName = if ($tags.Count -gt 0) { $tags[-1] } else { $null }
    $tagTree = if ($tagName) { (& git -C $remote rev-parse ($tagName + '^{tree}')).Trim() } else { '' }
    $tagVersion = if ($tagName -match '^pstack-(.+)-r\d+$') { $Matches[1] } else { '' }
    $ghCalls = if (Test-Path $ghLog) { @(Get-Content $ghLog) } else { @() }
    $releaseAttempted = @($ghCalls | Where-Object { $_ -match '^release create' }).Count -gt 0
    $releaseSucceeded = $releaseAttempted -and $Scenario -ne 'release-fails'
    $remoteAdvanced = ($remoteHead -ne $baseHead)
    $versionAgree = ($tagVersion -eq [string]$remotePin.version) -and ([string]$remoteMan.version -eq [string]$remotePin.version)
    $consistent = $releaseSucceeded -and $remoteAdvanced -and ($tagTree -eq $remoteTree) -and $versionAgree
    $verdict['steps'] = $stepResults
    $verdict['remoteAdvanced'] = $remoteAdvanced
    $verdict['tag'] = $tagName
    $verdict['tagTreeEqualsRemoteTree'] = ($tagTree -eq $remoteTree)
    $verdict['remotePinVersion'] = [string]$remotePin.version
    $verdict['remoteManifestVersion'] = [string]$remoteMan.version
    $verdict['tagVersion'] = $tagVersion
    $verdict['releaseSucceeded'] = $releaseSucceeded
    Log ("  steps: " + (($stepResults.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '))
    Log ("  remoteAdvanced=$remoteAdvanced tag=$tagName tagTree==remoteTree=$($tagTree -eq $remoteTree) versions(tag/pin/manifest)=$tagVersion/$($remotePin.version)/$($remoteMan.version) release=$releaseSucceeded")
    # 性质: 全绿 => release 存在 且 远端 main 前进 且 tag 树==远端树 且 tag/pin/清单版本三者一致
    $property = (-not $allZero) -or $consistent
    Assert 'green-run implies published artifact matches pinned tree' $property ("allStepsZero=$allZero scenario=$Scenario")
  }

  elseif ($Feature -eq 'alert') {
    # 用真实失败的门输出驱动告警步骤:告警必须自带定位信息,不能只有 run 链接
    $fx = if ($Fixture) { $Fixture } else { 'tp-models-bare' }
    $root = Join-Path $scratch 'repo'
    Invoke-Fixture $fx $root | Out-Null
    Copy-Item (Join-Path $evidence "validate-$fx.txt") (Join-Path $scratch 'gate-report.txt') -Force
    Link-Upstream $scratch
    $bin = Join-Path $scratch 'bin'
    New-Item -ItemType Directory -Force -Path $bin | Out-Null
    $ghLog = Join-Path $evidence 'gh-calls.log'
    $ghStub = @'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
if [ "$1" = "issue" ] && [ "$2" = "list" ]; then printf '%s' "$GH_EXISTING_ISSUE"; exit 0; fi
if [ "$1" = "issue" ] && { [ "$2" = "create" ] || [ "$2" = "comment" ]; }; then
  printf '%s\n' "$*" >> "$GH_BODY_LOG"; exit 0
fi
exit 0
'@
    Set-Content -Path (Join-Path $bin 'gh') -Value $ghStub -Encoding utf8 -NoNewline
    & bash -c "chmod +x '$(BashPath (Join-Path $bin 'gh'))'" | Out-Null
    if ($Scenario -eq 'open-issue') { $env:GH_EXISTING_ISSUE = '6' }
    elseif ($Scenario -eq 'no-open-issue') { $env:GH_EXISTING_ISSUE = '' }
    else { throw "unknown alert scenario: $Scenario" }
    $env:PATH = $bin + [System.IO.Path]::PathSeparator + $env:PATH
    $env:GH_LOG = $ghLog
    $env:GH_BODY_LOG = (Join-Path $evidence 'gh-body.log')
    $env:GITHUB_SERVER_URL = 'https://github.com'
    $env:GITHUB_REPOSITORY = 'lab-GESTALT/agent-plugin-pstack'
    $env:GITHUB_RUN_ID = '0'
    $sh = Join-Path $scratch 'alert.sh'
    Set-Content -Path $sh -Value (Get-WorkflowStep 'Alert on failure') -Encoding utf8
    $r = Invoke-Logged 'alert' { & bash -c "cd '$(BashPath $scratch)' && bash '$(BashPath $sh)'" }
    Assert 'alert step exit=0' ($r.code -eq 0) ''
    $calls = if (Test-Path $ghLog) { @(Get-Content $ghLog) } else { @() }
    $body = if (Test-Path $env:GH_BODY_LOG) { (Get-Content $env:GH_BODY_LOG -Raw) } else { '' }
    $wantCmd = if ($Scenario -eq 'open-issue') { 'issue comment 6' } else { 'issue create' }
    Assert ("alert uses {0}" -f $wantCmd) (@($calls | Where-Object { $_ -like "$wantCmd*" }).Count -gt 0) ($calls -join ' | ')
    Assert 'alert body carries gate output' ($body -match 'Gate output:' -and $body -match 'gate1 residual') ''
    $spec = @($fixtureIndex.fixtures | Where-Object { $_.name -eq $fx }) | Select-Object -First 1
    $wantPattern = [string]$spec.expectMessage
    Assert ("alert body names the failing pattern ({0})" -f $wantPattern) ($body -match [regex]::Escape($wantPattern)) ''
    $verdict['ghCalls'] = $calls
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