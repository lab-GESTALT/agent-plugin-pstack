$ErrorActionPreference = 'Stop'
$skillDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
$repo = (Resolve-Path (Join-Path $skillDir '..\..\..')).ProviderPath
$bad = @()

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
  $missing = @($idx.fixtures | Where-Object { -not (Test-Path (Join-Path $skillDir ("fixtures\" + $_.name + "\plugins"))) })
  Check 'every fixture has a plugins/ overlay' ($missing.Count -eq 0) (($missing | ForEach-Object { $_.name }) -join ', ')
}

$wf = Join-Path $repo '.github\workflows\sync.yml'
Check 'sync.yml present' (Test-Path $wf) ''
if (Test-Path $wf) {
  $names = @('Detect change','Record upstream','Commit','Tag and push','Publish release','Alert on failure')
  $text = Get-Content $wf -Raw
  $absent = @($names | Where-Object { $text -notmatch ('-\s*name:\s*' + [regex]::Escape($_)) })
  Check 'all harness-driven steps still exist in sync.yml' ($absent.Count -eq 0) ($absent -join ', ')
}

Write-Host ($(if ($bad.Count -eq 0) {'DOCTOR: healthy'} else {'DOCTOR: ' + $bad.Count + ' problem(s)'}))
if ($bad.Count -gt 0) { exit 1 }
exit 0