param([string]$WorkflowPath)
$ErrorActionPreference = 'Stop'
$skillDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
$repo = (Resolve-Path (Join-Path $skillDir '..\..\..')).ProviderPath
$bad = @()
Import-Module (Join-Path $PSScriptRoot 'workflow.psm1') -Force -DisableNameChecking

function Check([string]$label, [bool]$ok, [string]$detail) {
  Write-Host ("{0} {1}{2}" -f $(if ($ok) {'ok  '} else {'BAD '}), $label, $(if ($detail) {" -- $detail"} else {''}))
  if (-not $ok) { $script:bad += $label }
}

$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
Check 'pwsh on PATH' ($null -ne $pwshCmd) $(if ($pwshCmd) { $pwshCmd.Source } else { 'install PowerShell 7' })
foreach ($t in @('git','jq','zip','bash')) {
  $c = Get-Command $t -ErrorAction SilentlyContinue
  Check "$t on PATH" ($null -ne $c) ''
}

$up = Join-Path $repo 'upstream\pstack'
Check 'upstream sparse clone present' (Test-Path $up) 'git clone --depth 1 --filter=blob:none --sparse https://github.com/cursor/plugins.git upstream; git -C upstream sparse-checkout set pstack'
if (Test-Path $up) {
  $head = (& git -C (Join-Path $repo 'upstream') rev-parse HEAD).Trim()
  $pin = Get-Content (Join-Path $repo 'pin.json') -Raw | ConvertFrom-Json
  Check 'upstream clone matches pin.commit' ($head -eq [string]$pin.commit) "clone=$head pin=$($pin.commit)"
}

$map = $null
try { $map = Get-Content (Join-Path $repo 'transform\map.json') -Raw | ConvertFrom-Json } catch {}
Check 'map.json parses' ($null -ne $map) ''
$idx = $null
try { $idx = Get-Content (Join-Path $skillDir 'fixtures\index.json') -Raw | ConvertFrom-Json } catch {}
Check 'fixture index parses' ($null -ne $idx) ''
if ($idx) {
  $missing = @($idx.fixtures | Where-Object {
    $fx = Join-Path $skillDir ("fixtures\" + $_.name)
    -not ((Test-Path (Join-Path $fx 'plugins')) -or (Test-Path (Join-Path $fx 'output')))
  })
  Check 'every fixture overlays an artifact tree (plugins/ or output/)' ($missing.Count -eq 0) (($missing | ForEach-Object { $_.name }) -join ', ')
  # 夹具是交付物:被忽略规则吞掉的夹具在本机看着正常,新克隆里根本不存在。
  # 必须用 --no-index:已入仓的文件不再受忽略规则影响,查索引会让这条检查在提交后永远为真,
  # 之后新增的夹具被吞掉就抓不到了。这里查的是规则本身会不会吞掉这些路径。
  # 路径走 argv 不走 stdin:PowerShell 管道给原生进程的是 CRLF,git 会把 \r 当成路径的一部分。
  $unshippable = @($idx.fixtures | Where-Object {
    $fx = Join-Path $skillDir ("fixtures\" + $_.name)
    $rels = @(Get-ChildItem $fx -Recurse -File | ForEach-Object { $_.FullName.Substring($repo.Length + 1).Replace('\', '/') })
    if ($rels.Count -eq 0) { return $false }
    # --quiet 只接受单个路径;多路径时 git 打印命中的那些,无命中则退出 1 且不输出
    $hit = @(& git -C $repo check-ignore --no-index -- @rels)
    $hit.Count -gt 0
  })
  Check 'every fixture would ship (not swallowed by an ignore rule)' ($unshippable.Count -eq 0) (($unshippable | ForEach-Object { $_.name }) -join ', ')
}

$wf = if ($WorkflowPath) { $WorkflowPath } else { Join-Path $repo '.github\workflows\sync.yml' }
Check 'sync.yml present' (Test-Path $wf) ''
if (Test-Path $wf) {
  $names = @('Detect change','Record upstream','Commit','Tag and push','Publish release','Alert on failure')
  $text = Get-Content $wf -Raw
  $absent = @($names | Where-Object { $text -notmatch ('-\s*name:\s*' + [regex]::Escape($_)) })
  Check 'all harness-driven steps still exist in sync.yml' ($absent.Count -eq 0) ($absent -join ', ')
  # 匿名 clone 走 GitHub 对数据中心 IP 的反爬配额,会被 429 拒掉,整条管线在第一步就红。
  # 判据落在「URL 带凭据」上,不是落在步骤名或注释上;步骤读不出来同样判坏,不默认健康。
  $fetchAuth = $false
  try {
    $fetch = Get-WorkflowStep 'Fetch upstream' -Path $wf
    $fetchAuth = ($fetch -match 'x-access-token:\$\{GH_TOKEN\}@') -or ($fetch -match 'http\.extraheader')
  } catch {}
  Check 'upstream fetch is authenticated (anonymous clone gets rate-limited)' $fetchAuth ''
  # 告警读 jobs API 取失败步骤名。存在 permissions 块时未列出的作用域为 none,
  # 缺 actions: read 会让步骤名静默消失,而告警本身仍然 exit 0。判据落在「步骤用了 API 且授权到位」。
  $jobsApi = $false
  try { $jobsApi = (Get-WorkflowStep 'Alert on failure' -Path $wf) -match 'gh api .*actions/runs/' } catch {}
  if ($jobsApi) {
    Check 'alert can read the jobs API (actions permission granted)' ($text -match '(?m)^\s*actions:\s*(read|write)\s*$') 'add actions: read to the permissions block'
  }
}

Write-Host ($(if ($bad.Count -eq 0) {'DOCTOR: healthy'} else {'DOCTOR: ' + $bad.Count + ' problem(s)'}))
if ($bad.Count -gt 0) { exit 1 }
exit 0