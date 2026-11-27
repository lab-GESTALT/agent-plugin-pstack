param(
  [string]$RunId,
  [switch]$SkipVariants
)
$ErrorActionPreference = 'Stop'

$skillDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
$repo     = (Resolve-Path (Join-Path $skillDir '..\..\..')).ProviderPath
if (-not $RunId) { $RunId = (Get-Date -Format 'yyyyMMdd-HHmmss') }
$evidence = Join-Path $skillDir "artifacts\$RunId"
New-Item -ItemType Directory -Force -Path $evidence | Out-Null

Import-Module (Join-Path $repo '.agents\skills\verify-pstack-sync\helpers\workflow.psm1') -Force -DisableNameChecking

$verdict = [ordered]@{ skill = 'formal-verify-pstack-sync'; runId = $RunId; ok = $true; checks = @() }
function Assert([string]$label, [bool]$cond, [string]$detail) {
  Write-Host ("  {0} {1}{2}" -f $(if ($cond) {'PASS'} else {'FAIL'}), $label, $(if ($detail) {" -- $detail"} else {''}))
  $script:verdict.checks += [pscustomobject]@{ label = $label; ok = $cond; detail = $detail }
  if (-not $cond) { $script:verdict.ok = $false }
}

# ---- 工具:钉住版本与校验和,不入库,落在已被忽略的 artifacts/ 下 ----
$jarUrl  = 'https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar'
$jarHash = '936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88'
$toolDir = Join-Path $skillDir 'artifacts\tool'
$jar     = Join-Path $toolDir 'tla2tools.jar'
New-Item -ItemType Directory -Force -Path $toolDir | Out-Null
if (-not (Test-Path $jar)) {
  Write-Host "fetching TLC: $jarUrl"
  Invoke-WebRequest -Uri $jarUrl -OutFile $jar -UseBasicParsing
}
$actual = (Get-FileHash $jar -Algorithm SHA256).Hash.ToLowerInvariant()
Assert 'tla2tools.jar matches the pinned checksum' ($actual -eq $jarHash) $actual
if ($actual -ne $jarHash) { throw 'pinned TLC checksum mismatch; refusing to run an unverified tool' }
$java = Get-Command java -ErrorAction SilentlyContinue
Assert 'java on PATH' ($null -ne $java) $(if ($java) { $java.Source } else { 'install a JDK (>= 11)' })
if (-not $java) { throw 'java missing' }

# ---- 模型常量从 sync.yml 的实际写法推导,不手填 ----
# 锚点缺失即抛错:宁可拒绝出结论,也不要在读不懂 workflow 时默认「没问题」。
$detect  = Get-WorkflowStep 'Detect change'
$commit  = Get-WorkflowStep 'Commit'
$release = Get-WorkflowStep 'Publish release'
$record  = Get-WorkflowStep 'Record upstream'

if ($detect -notmatch 'gh release list') { throw 'Detect change no longer lists releases; the model premise is gone, re-derive it' }
if ($commit -notmatch 'git commit') { throw 'Commit step no longer runs git commit; re-derive the model' }
if ($release -notmatch 'gh release create') { throw 'Publish release no longer creates a release; re-derive the model' }
if ($record -notmatch 'VERSION=') { throw 'Record upstream no longer computes VERSION; re-derive the model' }

# 判据必须落在「决定」上,不能落在日志字符串上:CHANGED=yes 在步骤开头无条件出现,
# 只匹配 self-heal 字样会把「保留 echo、删掉判定」的死检查判为健康。
$selfHeal       = ($detect -match 'PIN_BLOB=\$\(git hash-object pin\.json\)') -and
                  ($detect -match 'RELEASE_PIN=\$\(gh api --method GET "[^\r\n]+/contents/pin\.json" -f ref="refs/tags/\$TAG" --jq \.sha\)') -and
                  ($detect -match '\[ "\$RELEASE_PIN" = "\$PIN_BLOB" \]; then\s*\r?\n\s*MATCH=1') -and
                  ($detect -match 'if \[ "\$MATCH" = 0 \]; then\s*\r?\n\s*CHANGED=yes')
$swallowCommit  = $commit -match 'git commit[^\r\n]*\|\|'
$swallowRelease = $release -match 'gh release create[^\r\n]*\|\|'
# 版本号必须取自刚变换出的清单;取自旧 pin 就会让 pinT 与 pinV 分家
$staleVersion   = $record -match 'VERSION=\$\(jq -r \.version pin\.json'
$verdict['derivedFrom'] = '.github/workflows/sync.yml'
$verdict['flags'] = [ordered]@{ SelfHeal = $selfHeal; SwallowCommit = $swallowCommit; SwallowRelease = $swallowRelease; StaleVersion = $staleVersion }
Write-Host ("derived: SelfHeal={0} SwallowCommit={1} SwallowRelease={2} StaleVersion={3}" -f $selfHeal, $swallowCommit, $swallowRelease, $staleVersion)

# ---- 有界 scope ----
$bounds = [ordered]@{ MaxV = 2; MaxFails = 2; MaxUp = 1 }
$verdict['bounds'] = $bounds

# 每个变体只改一个开关,其余沿用推导值:这样「会红」证明针对的是那一条规则本身
$variants = @(
  [pscustomobject]@{ Name = 'current';         Override = @{};                         Expect = 'pass' }
  [pscustomobject]@{ Name = 'no-self-heal';    Override = @{ SelfHeal = $false };      Expect = 'GreenConsistent' }
  [pscustomobject]@{ Name = 'swallow-release'; Override = @{ SwallowRelease = $true }; Expect = 'GreenConsistent' }
  [pscustomobject]@{ Name = 'swallow-commit';  Override = @{ SwallowCommit = $true };  Expect = 'GreenConsistent' }
  [pscustomobject]@{ Name = 'stale-version';   Override = @{ StaleVersion = $true };   Expect = 'EventuallyPublished' }
)
if ($SkipVariants) { $variants = @($variants[0]) }

Copy-Item (Join-Path $skillDir 'model\Sync.tla') (Join-Path $evidence 'Sync.tla') -Force
$results = @{}
foreach ($v in $variants) {
  $flags = @{ SelfHeal = $selfHeal; SwallowCommit = $swallowCommit; SwallowRelease = $swallowRelease; StaleVersion = $staleVersion }
  foreach ($k in $v.Override.Keys) { $flags[$k] = $v.Override[$k] }
  $cfg = @(
    'SPECIFICATION Spec'
    'CONSTANTS'
    ("  MaxV = {0}" -f $bounds.MaxV)
    ("  MaxFails = {0}" -f $bounds.MaxFails)
    ("  MaxUp = {0}" -f $bounds.MaxUp)
    ("  SelfHeal = {0}" -f $(if ($flags.SelfHeal) {'TRUE'} else {'FALSE'}))
    ("  SwallowRelease = {0}" -f $(if ($flags.SwallowRelease) {'TRUE'} else {'FALSE'}))
    ("  SwallowCommit = {0}" -f $(if ($flags.SwallowCommit) {'TRUE'} else {'FALSE'}))
    ("  StaleVersion = {0}" -f $(if ($flags.StaleVersion) {'TRUE'} else {'FALSE'}))
    'INVARIANT TypeOK'
    'INVARIANT GreenConsistent'
    'PROPERTY EventuallyPublished'
  ) -join "`n"
  $cfgPath = Join-Path $evidence ("{0}.cfg" -f $v.Name)
  Set-Content -Path $cfgPath -Value $cfg -Encoding utf8
  $logPath = Join-Path $evidence ("{0}.txt" -f $v.Name)
  Write-Host ("[TLC {0}]" -f $v.Name)
  $out = & java -cp $jar tlc2.TLC -config $cfgPath -workers auto -metadir (Join-Path $evidence ("meta-" + $v.Name)) (Join-Path $evidence 'Sync.tla') 2>&1
  $code = $LASTEXITCODE
  $text = ($out | ForEach-Object { [string]$_ }) -join "`n"
  Set-Content -Path $logPath -Value $text -Encoding utf8
  # 区分「性质被违反」与「模型/工具出错」:后者是建模问题,不能当成被验证代码的 finding
  $violated = @()
  if ($text -match 'Invariant\s+(\w+)\s+is violated') { $violated += $Matches[1] }
  if ($text -match 'Temporal properties were violated') { $violated += 'EventuallyPublished' }
  $clean = $text -match 'No error has been found'
  $toolError = (-not $clean) -and ($violated.Count -eq 0)
  $states = if ($text -match '(\d+) distinct states found') { [int]$Matches[1] } else { 0 }
  $results[$v.Name] = [pscustomobject]@{ expect = $v.Expect; clean = $clean; violated = $violated; toolError = $toolError; exit = $code; states = $states; flags = $flags }
  Write-Host ("  exit={0} clean={1} violated={2} states={3}" -f $code, $clean, ($violated -join ','), $states)
  if ($toolError) {
    Assert ("TLC ran cleanly for {0}" -f $v.Name) $false ('model or tool error; see ' + $logPath)
    continue
  }
  if ($v.Expect -eq 'pass') {
    Assert ("current sync.yml satisfies both properties" -f $v.Name) $clean ($violated -join ', ')
  } else {
    # 判别性证明:去掉那一条规则,性质必须真的红。从未红过的检查什么也没证明。
    Assert ("broken variant {0} violates {1}" -f $v.Name, $v.Expect) ($violated -contains $v.Expect) ($violated -join ', ')
  }
}
$verdict['variants'] = $results
$verdict['coverage'] = [ordered]@{
  model      = 'model/Sync.tla'
  covers     = @('.github/workflows/sync.yml: Detect change, Transform, Record upstream, Commit, Tag and push, Publish release')
  notCovered = @(
    'git 层面的 push 竞争与 rebase 重试(由 verify-pstack-sync -Feature publish -Scenario push-rejected 用真实 git 驱动)',
    'tag 树与远端树的逐字节比对、zip 内容(同上,-Feature publish / -Feature transform)',
    '变换规则与三个门(由 verify-pstack-sync -Feature corpus / rules / transform 覆盖)',
    '告警 issue 的正文能否定位故障(由 verify-pstack-sync -Feature alert 覆盖,含门之前就失败的两条)',
    'GitHub cron 是否真的触发(仓库内无强制器,见 AGENTS.md 的已知缺口)'
  )
  bounds     = 'MaxV=2 个上游版本, MaxFails=2 次失败, MaxUp=1 次上游前进; 失败预算用尽后步骤必须成功'
  syncCommit = (& git -C $repo rev-parse HEAD).Trim()
  # HEAD 不足以标识被判定的文本:工作区脏时,提交号指向的是另一份 sync.yml。
  # 逐字节哈希把证据绑到真正读过的那份内容上。
  syncSha256 = (Get-FileHash (Join-Path $repo '.github\workflows\sync.yml') -Algorithm SHA256).Hash.ToLower()
  syncDirty  = [bool](& git -C $repo status --porcelain -- '.github/workflows/sync.yml')
}
$verdict | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $evidence 'verdict.json') -Encoding utf8
Write-Output ("EVIDENCE: " + $evidence)
Write-Output ("FORMAL: " + $(if ($verdict.ok) {'PASS'} else {'FAIL'}))
if (-not $verdict.ok) { exit 1 }
exit 0