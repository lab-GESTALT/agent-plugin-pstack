param(
  [Parameter(Mandatory=$true)][string]$Upstream,
  [Parameter(Mandatory=$true)][string]$Out,
  [Parameter(Mandatory=$true)][string]$OutCc
)
$ErrorActionPreference = 'Stop'
$nl = [char]10
$map = Get-Content (Join-Path $PSScriptRoot '..\map.json') -Raw | ConvertFrom-Json

if (Test-Path $Out) { Remove-Item $Out -Recurse -Force }

function Transform-Skill([string]$srcDir, [string]$dstDir, [string]$dirName) {
  New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
  Copy-Item (Join-Path $srcDir '*') $dstDir -Recurse -Force
  $p = Join-Path $dstDir 'SKILL.md'
  $raw = Get-Content $p -Raw

  if ($raw -match '(?s)^---\r?\n(.*?)\r?\n---') {
    $fm = $Matches[1]
    $modeVal = [regex]::Match($fm, '(?m)^mode:\s*(.+)$').Groups[1].Value.Trim()
    $remVal  = [regex]::Match($fm, '(?m)^reminder:\s*(.+)$').Groups[1].Value.Trim()
    $kept = @()
    foreach ($ln in ($fm -split '\r?\n')) {
      if ($ln -match '^(icon|color|mode|reminder):') { continue }
      if ($ln -match '^name:') { $kept += ('name: ' + $dirName); continue }
      $kept += $ln
    }
    $fm2 = $kept -join $nl
    $metaLines = @()
    if ($modeVal) { $metaLines += '  mode: session' }
    if ($remVal)  { $metaLines += ('  reminder: ' + $remVal) }
    if ($metaLines.Count -gt 0) {
      $fm2 = $fm2.TrimEnd() + $nl + 'metadata:' + $nl + ($metaLines -join $nl)
    }
    $raw = [regex]::Replace($raw, '(?s)^---\r?\n.*?\r?\n---', { param($m) '---' + $nl + $fm2 + $nl + '---' })
  }

  Set-Content -Path $p -Value $raw -Encoding utf8

  foreach ($f in (Get-ChildItem $dstDir -Recurse -File -Include *.md)) {
    $c = Get-Content $f.FullName -Raw
    foreach ($t in $map.bodyTokens) { $c = $c.Replace([string]$t.find, [string]$t.replace) }
    Set-Content -Path $f.FullName -Value $c -Encoding utf8
  }
}

$skillDirs = @(Get-ChildItem (Join-Path $Upstream 'skills') -Directory)
if ($map.sampleSkills.Count -gt 0) { $skillDirs = @($skillDirs | Where-Object { $map.sampleSkills -contains $_.Name }) }
foreach ($d in $skillDirs) {
  Transform-Skill $d.FullName (Join-Path $Out ("skills\" + $d.Name)) $d.Name
}

Copy-Item (Join-Path $Upstream 'agents') (Join-Path $Out 'agents') -Recurse -Force
$asset = Join-Path $PSScriptRoot '..\assets\build-control-for-your-app'
if (Test-Path $asset) { Copy-Item $asset (Join-Path $Out 'skills\build-control-for-your-app') -Recurse -Force }
foreach ($f in (Get-ChildItem (Join-Path $Out 'agents') -File -Filter *.md)) {
  $c = Get-Content $f.FullName -Raw
  foreach ($t in $map.bodyTokens) { $c = $c.Replace([string]$t.find, [string]$t.replace) }
  Set-Content -Path $f.FullName -Value $c -Encoding utf8
}

$srcMan = Get-Content (Join-Path $Upstream '.cursor-plugin\plugin.json') -Raw | ConvertFrom-Json
$new = [ordered]@{}
foreach ($k in $map.manifest.keep) { $new[$k] = $srcMan.$k }
$new['$schema'] = $map.manifest.add.'$schema'
$new | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $Out 'plugin.json') -Encoding utf8
New-Item -ItemType Directory -Force -Path (Join-Path $Out 'com.cursor') | Out-Null
Copy-Item (Join-Path $Upstream '.cursor-plugin\plugin.json') (Join-Path $Out 'com.cursor\plugin.json') -Force

if (Test-Path (Join-Path $OutCc 'plugins\pstack')) { Remove-Item (Join-Path $OutCc 'plugins\pstack') -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $OutCc '.claude-plugin') | Out-Null
$market = [ordered]@{ name='agent-plugin-pstack'; owner=[ordered]@{name='TurnX-alt'}; plugins=@([ordered]@{name='pstack'; source='./plugins/pstack'}) }
$market | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $OutCc '.claude-plugin\marketplace.json') -Encoding utf8
New-Item -ItemType Directory -Force -Path (Join-Path $OutCc 'plugins\pstack\.claude-plugin') | Out-Null
$ccMan = [ordered]@{ name='pstack'; displayName='pstack (generic)'; version=[string]$srcMan.version; skills='./skills/'; agents='./agents/' }
$ccMan | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $OutCc 'plugins\pstack\.claude-plugin\plugin.json') -Encoding utf8
Copy-Item (Join-Path $Out 'skills') (Join-Path $OutCc 'plugins\pstack\skills') -Recurse -Force
Copy-Item (Join-Path $Out 'agents') (Join-Path $OutCc 'plugins\pstack\agents') -Recurse -Force

Write-Output ("OK: " + $Out + " / " + $OutCc)
