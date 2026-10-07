param([Parameter(Mandatory=$true)][string]$Root)
$ErrorActionPreference = 'Stop'
$errors = @()
$notes = @()
$ccRel = Join-Path $Root 'plugins\pstack'
$map = Get-Content (Join-Path $PSScriptRoot '..\map.json') -Raw | ConvertFrom-Json

# 待检模式 = map.residualPatterns + 变换表的 find 字面串;单一事实源,避免门与变换表脱节
$patterns = @($map.residualPatterns)
foreach ($t in $map.bodyTokens) { if ($patterns -notcontains $t.find) { $patterns += $t.find } }
$allow = @($map.codeResidualAllowlist)

# Root 可能是相对路径(CI 传 -Root .),统一解析成绝对路径后再与文件路径比对
function Get-RelPath([string]$full, [string]$base) {
  $f = $full.Replace('\','/')
  $b = $base.Replace('\','/')
  if ($f.ToLowerInvariant().StartsWith($b.ToLowerInvariant())) { return $f.Substring($b.Length).TrimStart('/') }
  return $f
}

if (-not (Test-Path $ccRel)) {
  Write-Output 'GATES FAILED: 1'
  Write-Output '  - gate3 missing plugins/pstack'
  exit 1
}
$cc = (Resolve-Path -Path $ccRel).ProviderPath

# 扫描全部文本文件(含脚本类):此前只扫 *.md/*.json,脚本里的 Cursor 残留长期不可见
$files = @(Get-ChildItem $cc -Recurse -File | Where-Object { $_.Length -lt 5242880 } | Where-Object {
  $raw = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
  $null -ne $raw -and -not $raw.Contains([char]0)
})

foreach ($t in $patterns) {
  $hits = @($files | Select-String -Pattern $t -ErrorAction SilentlyContinue)
  $unexpected = @($hits | Where-Object {
    $rel = Get-RelPath $_.Path $cc
    $ok = $false
    foreach ($a in $allow) { if ($a.path -eq $rel -and $a.patterns -contains $t) { $ok = $true } }
    -not $ok
  })
  if ($unexpected.Count -gt 0) {
    $errors += ('gate1 residual: ' + $t + ' x' + $unexpected.Count)
    foreach ($h in ($unexpected | Select-Object -First 3)) {
      $errors += ('  at ' + (Get-RelPath $h.Path $cc) + ':' + $h.LineNumber)
    }
  } elseif ($hits.Count -gt 0) {
    $notes += ('gate1 allowed residual: ' + $t + ' x' + $hits.Count)
  }
}

$mp = Join-Path $Root '.claude-plugin\marketplace.json'
if (-not (Test-Path $mp)) { $errors += 'gate2 missing marketplace.json' }
else {
  try { $m = Get-Content $mp -Raw | ConvertFrom-Json } catch { $errors += 'gate2 marketplace.json unparsable' }
  if ($m.plugins.Count -lt 1) { $errors += 'gate2 marketplace has no plugins' }
}
$pj = Join-Path $cc '.claude-plugin\plugin.json'
if (-not (Test-Path $pj)) { $errors += 'gate2 missing plugin.json' }
else {
  try { $p = Get-Content $pj -Raw | ConvertFrom-Json } catch { $errors += 'gate2 plugin.json unparsable' }
  if (-not $p.name) { $errors += 'gate2 plugin.json missing name' }
}
$skillDirs = @(Get-ChildItem (Join-Path $cc 'skills') -Directory -ErrorAction SilentlyContinue)
if ($skillDirs.Count -lt 40) { $errors += ('gate2 skill count low: ' + $skillDirs.Count) }
foreach ($d in $skillDirs) {
  $smd = Join-Path $d.FullName 'SKILL.md'
  if (-not (Test-Path $smd)) { $errors += ('gate2 missing SKILL.md: ' + $d.Name); continue }
  $hit = Select-String -Path $smd -Pattern '^name:' | Select-Object -First 1
  if (-not $hit) { $errors += ('gate2 no name: ' + $d.Name); continue }
  $n = $hit.Line -replace '^name:\s*',''
  if ($n -ne $d.Name) { $errors += ('gate2 name mismatch: ' + $d.Name + ' => ' + $n) }
  $bad = @(Select-String -Path $smd -Pattern '^(mode|icon|color|reminder):' -ErrorAction SilentlyContinue)
  if ($bad.Count -gt 0) { $errors += ('gate2 leftover frontmatter field in ' + $d.Name) }
}

if (-not (Test-Path (Join-Path $cc 'agents'))) { $errors += 'gate3 missing agents dir' }
if (-not (Test-Path (Join-Path $cc 'skills'))) { $errors += 'gate3 missing skills dir' }

foreach ($n in $notes) { Write-Output $n }
if ($errors.Count -gt 0) {
  Write-Output ('GATES FAILED: ' + $errors.Count)
  foreach ($e in $errors) { Write-Output ('  - ' + $e) }
  exit 1
}
Write-Output ('GATES GREEN: ' + $skillDirs.Count + ' skills, ' + $patterns.Count + ' patterns, gates 1/2/3 passed')
