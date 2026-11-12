param(
  [Parameter(Mandatory=$true)][string]$Upstream,
  [Parameter(Mandatory=$true)][string]$Out,
  [Parameter(Mandatory=$true)][string]$OutCc
)
$ErrorActionPreference = 'Stop'
$nl = [char]10
Import-Module (Join-Path $PSScriptRoot 'rules.psm1') -Force -DisableNameChecking
$map = Get-RuleMap

if (Test-Path $Out) { Remove-Item $Out -Recurse -Force }

# 引号形式的键名同样识别,避免带引号的 frontmatter 字段躲过规则
function Get-FrontmatterKey([string]$line) {
  if ($line -match '^[''\"]?([A-Za-z_][A-Za-z0-9_-]*)[''\"]?\s*:') { return $Matches[1] }
  return ''
}

function Set-Frontmatter([string]$path, [string]$nameValue) {
  $raw = Get-Content $path -Raw
  if ($raw -notmatch '(?s)^---\r?\n(.*?)\r?\n---') { return }
  $fm = $Matches[1]
  $kept = @()
  $metaLines = @()
  foreach ($ln in ($fm -split '\r?\n')) {
    $key = Get-FrontmatterKey $ln
    if (-not $key) { $kept += $ln; continue }
    if (@($map.frontmatter.drop) -contains $key) { continue }
    if ($key -eq 'name') { $kept += ('name: ' + $nameValue); continue }
    $move = @($map.frontmatter.moveToMetadata.PSObject.Properties | Where-Object { $_.Name -eq $key }) | Select-Object -First 1
    if ($move) {
      $spec = [string]$move.Value
      if ($spec -match '^[A-Za-z_][A-Za-z0-9_-]*$') {
        $val = ([regex]::Match($fm, ('(?m)^' + [regex]::Escape($key) + '\s*:\s*(.+)$'))).Groups[1].Value.Trim()
        if ($val) { $metaLines += ('  ' + $key + ': ' + $val) }
      } else {
        $metaLines += ('  ' + $spec)
      }
      continue
    }
    $kept += $ln
  }
  $fm2 = $kept -join $nl
  if ($metaLines.Count -gt 0) { $fm2 = $fm2.TrimEnd() + $nl + 'metadata:' + $nl + ($metaLines -join $nl) }
  $out = [regex]::Replace($raw, '(?s)^---\r?\n.*?\r?\n---', ('---' + $nl + $fm2 + $nl + '---'))
  Set-Content -Path $path -Value $out -Encoding utf8
}

function Apply-BodyTokens([string]$file) {
  Set-Content -Path $file -Value (Apply-AllTokens (Get-Content $file -Raw)) -Encoding utf8
}

function Convert-SkillTree([string]$srcDir, [string]$dstDir, [string]$skillName) {
  New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
  Copy-Item (Join-Path $srcDir '*') $dstDir -Recurse -Force
  Set-Frontmatter (Join-Path $dstDir 'SKILL.md') $skillName
  foreach ($f in (Get-ChildItem $dstDir -Recurse -File | Where-Object { (Get-FileScope $_.Name) -eq 'prose' })) { Apply-BodyTokens $f.FullName }
}

$skillDirs = @(Get-ChildItem (Join-Path $Upstream 'skills') -Directory)
if ($map.sampleSkills.Count -gt 0) { $skillDirs = @($skillDirs | Where-Object { $map.sampleSkills -contains $_.Name }) }
foreach ($d in $skillDirs) { Convert-SkillTree $d.FullName (Join-Path $Out ('skills\' + $d.Name)) $d.Name }

# agents: 同一套 frontmatter 规则,name 归一为文件名
$agentsOut = Join-Path $Out 'agents'
Copy-Item (Join-Path $Upstream 'agents') $agentsOut -Recurse -Force
foreach ($f in (Get-ChildItem $agentsOut -File | Where-Object { (Get-FileScope $_.Name) -eq 'prose' })) {
  Set-Frontmatter $f.FullName $f.BaseName
  Apply-BodyTokens $f.FullName
}

$injected = 0
$asset = Join-Path $PSScriptRoot '..\assets\build-control-for-your-app'
if (Test-Path $asset) { Copy-Item $asset (Join-Path $Out 'skills\build-control-for-your-app') -Recurse -Force; $injected = 1 }
$expected = $skillDirs.Count + $injected
$actual = @(Get-ChildItem (Join-Path $Out 'skills') -Directory).Count
if ($actual -ne $expected) { throw ('skill count mismatch: expected ' + $expected + ', produced ' + $actual) }

# 派生产物必须随上游许可文本一同分发
$lic = Join-Path $Upstream 'LICENSE'
if (-not (Test-Path $lic)) { throw 'upstream LICENSE missing; the derived artifact must carry it' }
Copy-Item $lic (Join-Path $Out 'LICENSE') -Force

# manifest 投影由 map.json 驱动:keep 保留,add 补齐,其余归入客户端扩展目录
$srcMan = Get-Content (Join-Path $Upstream $map.manifest.from) -Raw | ConvertFrom-Json
$unclassified = @($srcMan.PSObject.Properties.Name | Where-Object { (@($map.manifest.keep) -notcontains $_) -and (@($map.manifest.dropToExtension) -notcontains $_) })
if ($unclassified.Count -gt 0) { throw ('manifest fields not classified in map.json: ' + ($unclassified -join ', ')) }
$new = [ordered]@{}
foreach ($k in $map.manifest.keep) { $new[$k] = $srcMan.$k }
foreach ($k in $map.manifest.add.PSObject.Properties) { $new[$k.Name] = [string]$k.Value }
$new | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $Out 'plugin.json') -Encoding utf8
$extDir = Join-Path $Out $map.manifest.extension.namespace
New-Item -ItemType Directory -Force -Path $extDir | Out-Null
Copy-Item (Join-Path $Upstream $map.manifest.from) (Join-Path $extDir $map.manifest.extension.file) -Force

# frontmatter.keep 是契约:上游有,产物就必须还在
foreach ($pair in @(@('skills','skills'), @('agents','agents'))) {
  $srcRoot = Join-Path $Upstream $pair[0]
  $dstRoot = Join-Path $Out $pair[1]
  foreach ($k in $map.frontmatter.keep) {
    $pat = ('(?m)^\s*' + [regex]::Escape($k) + '\s*:')
    foreach ($h in @(Get-ChildItem $srcRoot -Recurse -File -Filter *.md | Select-String -Pattern $pat -List)) {
      $base = (Resolve-Path $srcRoot).ProviderPath
      $rel = $h.Path.Substring($base.Length).TrimStart('\','/')
      $dst = Join-Path $dstRoot $rel
      if (@(Select-String -Path $dst -Pattern $pat -List -ErrorAction SilentlyContinue).Count -eq 0) {
        throw ('frontmatter.keep violated: ' + $k + ' missing in ' + $rel)
      }
    }
  }
}

# CC 市场清单是仓库产物,只在缺失时补齐,不覆盖人工修订
New-Item -ItemType Directory -Force -Path (Join-Path $OutCc '.claude-plugin') | Out-Null
$marketPath = Join-Path $OutCc '.claude-plugin\marketplace.json'
if (-not (Test-Path $marketPath)) {
  $market = [ordered]@{ name='agent-plugin-pstack'; owner=[ordered]@{name='lab-GESTALT'}; plugins=@([ordered]@{name='pstack'; source='./plugins/pstack'}) }
  $market | ConvertTo-Json -Depth 6 | Set-Content $marketPath -Encoding utf8
}
if (Test-Path (Join-Path $OutCc 'plugins\pstack')) { Remove-Item (Join-Path $OutCc 'plugins\pstack') -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $OutCc 'plugins\pstack\.claude-plugin') | Out-Null
$ccMan = [ordered]@{ name='pstack'; displayName='pstack (generic)'; version=[string]$srcMan.version; skills='./skills/'; agents='./agents/' }
$ccMan | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $OutCc 'plugins\pstack\.claude-plugin\plugin.json') -Encoding utf8
Copy-Item (Join-Path $Out 'skills') (Join-Path $OutCc 'plugins\pstack\skills') -Recurse -Force
Copy-Item (Join-Path $Out 'agents') (Join-Path $OutCc 'plugins\pstack\agents') -Recurse -Force
# CC 形态是入仓分发的派生产物,同样必须随上游许可文本分发
Copy-Item $lic (Join-Path $OutCc 'plugins\pstack\LICENSE') -Force

Write-Output ('OK: ' + $Out + ' / ' + $OutCc + ' (' + $actual + ' skills)')
