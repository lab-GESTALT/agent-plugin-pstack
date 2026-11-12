param([Parameter(Mandatory=$true)][string]$Root)
$ErrorActionPreference = 'Stop'
$errors = @()
$details = @()
$notes = @()
$ccRel = Join-Path $Root 'plugins\pstack'
$apRel = Join-Path $Root 'output'
$map = Get-Content (Join-Path $PSScriptRoot '..\map.json') -Raw | ConvertFrom-Json

# 待检项 = map.residualPatterns + 变换表;单一事实源,避免门与变换表脱节
# id 用于白名单匹配与报错,regex 用于扫描:find 在 transform 里是字面串,在门里是正则,
# 语义不同,故允许 gatePattern 单独收紧门的匹配精度而不影响散文替换
$checks = @()
foreach ($p in $map.residualPatterns) { $checks += [pscustomobject]@{ id = $p; regex = $p } }
foreach ($t in $map.bodyTokens) {
  if (@($checks.id) -contains $t.find) { continue }
  $rx = $t.find
  if ($t.PSObject.Properties.Name -contains 'gatePattern') { $rx = $t.gatePattern }
  $checks += [pscustomobject]@{ id = $t.find; regex = $rx }
}
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
  Write-Output '  - gate1 missing plugins/pstack'
  exit 1
}
$cc = (Resolve-Path -Path $ccRel).ProviderPath

# ---- gate1: 残留扫描(全部文本文件,脚本类一并覆盖) ----
$files = @(Get-ChildItem $cc -Recurse -File | Where-Object { $_.Length -lt 5242880 } | Where-Object {
  $raw = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
  $null -ne $raw -and -not $raw.Contains([char]0)
})
foreach ($c in $checks) {
  $hits = @($files | Select-String -Pattern $c.regex -ErrorAction SilentlyContinue)
  $unexpected = @($hits | Where-Object {
    $rel = Get-RelPath $_.Path $cc
    $ok = $false
    foreach ($a in $allow) { if ($a.path -eq $rel -and $a.patterns -contains $c.id) { $ok = $true } }
    -not $ok
  })
  if ($unexpected.Count -gt 0) {
    $errors += ('gate1 residual: ' + $c.id + ' x' + $unexpected.Count)
    foreach ($h in ($unexpected | Select-Object -First 3)) {
      $details += [pscustomobject]@{ i = $errors.Count - 1; text = ('at ' + (Get-RelPath $h.Path $cc) + ':' + $h.LineNumber) }
    }
  } elseif ($hits.Count -gt 0) {
    $notes += ('gate1 allowed residual: ' + $c.id + ' x' + $hits.Count)
  }
}

# ---- gate2: frontmatter 契约(skills + agents) ----
$fmDrop = '(?m)^[''\"]?(mode|icon|color|reminder|is_background)[''\"]?\s*:'
$skillDirs = @(Get-ChildItem (Join-Path $cc 'skills') -Directory -ErrorAction SilentlyContinue)
if ($skillDirs.Count -eq 0) { $errors += 'gate2 no skill directories' }
foreach ($d in $skillDirs) {
  $smd = Join-Path $d.FullName 'SKILL.md'
  if (-not (Test-Path $smd)) { $errors += ('gate2 missing SKILL.md: ' + $d.Name); continue }
  $hit = Select-String -Path $smd -Pattern '^name:' | Select-Object -First 1
  if (-not $hit) { $errors += ('gate2 no name in ' + $d.Name); continue }
  $n = $hit.Line -replace '^name:\s*',''
  if ($n -ne $d.Name) { $errors += ('gate2 name mismatch: ' + $d.Name + ' => ' + $n) }
  $bad = @(Select-String -Path $smd -Pattern $fmDrop -ErrorAction SilentlyContinue)
  if ($bad.Count -gt 0) { $errors += ('gate2 cursor-only frontmatter field in ' + $d.Name) }
}
$agentFiles = @(Get-ChildItem (Join-Path $cc 'agents') -File -Filter *.md -ErrorAction SilentlyContinue)
if ($agentFiles.Count -eq 0) { $errors += 'gate2 no agent files' }
foreach ($a in $agentFiles) {
  $hit = Select-String -Path $a.FullName -Pattern '^name:' | Select-Object -First 1
  if (-not $hit) { $errors += ('gate2 no name in agents/' + $a.Name); continue }
  $n = $hit.Line -replace '^name:\s*',''
  if ($n -ne $a.BaseName) { $errors += ('gate2 agent name mismatch: ' + $a.Name + ' => ' + $n) }
  $bad = @(Select-String -Path $a.FullName -Pattern $fmDrop -ErrorAction SilentlyContinue)
  if ($bad.Count -gt 0) { $errors += ('gate2 cursor-only frontmatter field in agents/' + $a.Name) }
}

# ---- gate2(续): 许可文本随两种产物分发 ----
if (-not (Test-Path (Join-Path $cc 'LICENSE'))) { $errors += 'gate2 CC missing LICENSE' }

# ---- gate2(续): AP 1.0 清单契约 ----
if (-not (Test-Path $apRel)) {
  $notes += 'gate2 AP checks skipped: output/ not generated (run transform.ps1 first)'
} else {
  $ap = (Resolve-Path -Path $apRel).ProviderPath
  $apManifest = Join-Path $ap 'plugin.json'
  if (-not (Test-Path $apManifest)) { $errors += 'gate2 AP missing plugin.json' }
  else {
    $p = $null
    try { $p = Get-Content $apManifest -Raw | ConvertFrom-Json } catch { $errors += 'gate2 AP plugin.json unparsable' }
    if ($p) {
      $keys = @($p.PSObject.Properties.Name)
      $unknown = @($keys | Where-Object { @($map.apContract.allowedKeys) -notcontains $_ })
      if ($unknown.Count -gt 0) { $errors += ('gate2 AP unknown top-level field: ' + ($unknown -join ', ')) }
      foreach ($k in $map.apContract.requiredKeys) { if ($keys -notcontains $k) { $errors += ('gate2 AP missing required field: ' + $k) } }
      if ($p.'$schema' -ne $map.apContract.schemaId) { $errors += ('gate2 AP schema id mismatch: ' + $p.'$schema') }
      if ($p.name -notmatch $map.apContract.namePattern) { $errors += ('gate2 AP name pattern violation: ' + $p.name) }
      elseif ($p.name.Length -gt [int]$map.apContract.maxNameLength) { $errors += ('gate2 AP name too long: ' + $p.name.Length) }
      if ($p.author) {
        $badAuthor = @($p.author.PSObject.Properties.Name | Where-Object { @($map.apContract.authorKeys) -notcontains $_ })
        if ($badAuthor.Count -gt 0) { $errors += ('gate2 AP author field not allowed: ' + ($badAuthor -join ', ')) }
      }
      if ($p.keywords -and @($p.keywords | Where-Object { $_ -isnot [string] }).Count -gt 0) { $errors += 'gate2 AP keywords must be strings' }
    }
  }
  if (-not (Test-Path (Join-Path $ap 'LICENSE'))) { $errors += 'gate2 AP missing LICENSE' }
  $apSkills = @(Get-ChildItem (Join-Path $ap 'skills') -Directory -ErrorAction SilentlyContinue).Count
  if ($apSkills -ne $skillDirs.Count) { $errors += ('gate2 skill parity: AP ' + $apSkills + ' vs CC ' + $skillDirs.Count) }
}

# ---- gate3: CC 市场清单 dry-run(解析声明路径,确认可被加载) ----
$mp = Join-Path $Root '.claude-plugin\marketplace.json'
if (-not (Test-Path $mp)) { $errors += 'gate3 missing marketplace.json' }
else {
  $m = $null
  try { $m = Get-Content $mp -Raw | ConvertFrom-Json } catch { $errors += 'gate3 marketplace.json unparsable' }
  if ($m) {
    if (-not $m.name) { $errors += 'gate3 marketplace name missing' }
    if (-not $m.owner.name) { $errors += 'gate3 marketplace owner.name missing' }
    if ($m.plugins.Count -lt 1) { $errors += 'gate3 marketplace has no plugin entries' }
    foreach ($pl in $m.plugins) {
      if (-not $pl.name) { $errors += 'gate3 plugin entry without name'; continue }
      $src = [string]$pl.source
      if (-not $src) { $errors += ('gate3 plugin ' + $pl.name + ' without source'); continue }
      $srcPath = Join-Path $Root $src.TrimStart('.','/','\')
      if (-not (Test-Path $srcPath)) { $errors += ('gate3 plugin source not found: ' + $src); continue }
      $spec = Join-Path $srcPath '.claude-plugin\plugin.json'
      if (-not (Test-Path $spec)) { $errors += ('gate3 plugin manifest missing under ' + $src); continue }
      $pm = $null
      try { $pm = Get-Content $spec -Raw | ConvertFrom-Json } catch { $errors += ('gate3 plugin manifest unparsable under ' + $src) }
      if ($pm) {
        if (-not $pm.name) { $errors += ('gate3 plugin manifest without name under ' + $src) }
        foreach ($field in @('skills','agents')) {
          $rel = [string]$pm.$field
          if (-not $rel) { continue }
          $target = Join-Path $srcPath $rel.TrimStart('.','/','\')
          if (-not (Test-Path $target)) { $errors += ('gate3 declared ' + $field + ' path missing: ' + $rel) }
          elseif (@(Get-ChildItem $target).Count -eq 0) { $errors += ('gate3 declared ' + $field + ' path empty: ' + $rel) }
        }
      }
    }
  }
}

foreach ($n in $notes) { Write-Output $n }
if ($errors.Count -gt 0) {
  Write-Output ('GATES FAILED: ' + $errors.Count)
  for ($i = 0; $i -lt $errors.Count; $i++) {
    Write-Output ('  - ' + $errors[$i])
    foreach ($d in ($details | Where-Object { $_.i -eq $i })) { Write-Output ('      ' + $d.text) }
  }
  exit 1
}
Write-Output ('GATES GREEN: ' + $skillDirs.Count + ' skills, ' + $checks.Count + ' patterns, gates 1/2/3 passed')
exit 0
