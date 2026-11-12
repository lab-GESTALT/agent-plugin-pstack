param([Parameter(Mandatory=$true)][string]$Root)
$ErrorActionPreference = 'Stop'
$errors = @()
$details = @()
$notes = @()
$ccRel = Join-Path $Root 'plugins\pstack'
$apRel = Join-Path $Root 'output'
Import-Module (Join-Path $PSScriptRoot 'rules.psm1') -Force -DisableNameChecking
$map = Get-RuleMap
$checks = @(Get-GateChecks)
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

# ---- gate1: 残留扫描(两种产物都扫;散文查全部规则,代码只查硬性标记) ----
function Read-Tree([string]$base, [string]$label) {
  return @(Get-ChildItem $base -Recurse -File | Where-Object { $_.Length -lt 5242880 } | ForEach-Object {
    $raw = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
    if ($null -ne $raw -and -not $raw.Contains([char]0)) {
      $rel = (Get-RelPath $_.FullName $base)
      [pscustomobject]@{ Tree = $label; Rel = $rel; Scope = (Get-FileScope $rel); Text = $raw; Lines = ($raw -split "\r?\n") }
    }
  })
}

# 报错要指到修法:规则没覆盖这种写法,还是产物没重算,还是代码按设计不改写
function Get-ResidualFix($check, $hit) {
  if ($hit.Scope -ne 'prose') {
    return 'fix: 代码文件按设计不做散文式替换。确认是功能性字符串后,在 map.json 的 codeResidualAllowlist 按类登记(glob + scope + patterns);若是真泄露,改上游脚本'
  }
  if (Test-Check $check (Apply-AllTokens $hit.Line)) {
    return 'fix: map.json 缺少覆盖这种写法的改写规则。在 bodyTokens 增加条目或收紧已有条目的 pattern,变换与门共用同一解释者'
  }
  return 'fix: 规则已覆盖这一行,产物却是旧的。重跑 transform.ps1,不要手改生成内容'
}

$files = @(Read-Tree $cc 'plugins/pstack')
if (Test-Path $apRel) { $files += @(Read-Tree (Resolve-Path $apRel).ProviderPath 'output') }
else { $notes += 'gate1 output/ not generated: AP artifact unscanned (run transform.ps1 first)' }
foreach ($c in $checks) {
  $hits = @()
  foreach ($f in $files) {
    if ($c.Scope -eq 'prose' -and $f.Scope -ne 'prose') { continue }
    if (-not (Test-Check $c $f.Text)) { continue }
    for ($i = 0; $i -lt $f.Lines.Count; $i++) {
      if (Test-Check $c $f.Lines[$i]) {
        $hits += [pscustomobject]@{ Tree = $f.Tree; Rel = $f.Rel; Scope = $f.Scope; LineNumber = $i + 1; Line = $f.Lines[$i] }
      }
    }
  }
  $unexpected = @($hits | Where-Object { -not (Test-Allowlisted $allow $_.Rel $_.Scope $c.Id) })
  if ($unexpected.Count -gt 0) {
    $errors += ('gate1 residual: ' + $c.Id + ' x' + $unexpected.Count)
    foreach ($h in ($unexpected | Select-Object -First 3)) {
      $details += [pscustomobject]@{ i = $errors.Count - 1; text = ('at ' + $h.Tree + '/' + $h.Rel + ':' + $h.LineNumber) }
      $details += [pscustomobject]@{ i = $errors.Count - 1; text = (Get-ResidualFix $c $h) }
    }
  } elseif ($hits.Count -gt 0) {
    $notes += ('gate1 allowed residual: ' + $c.Id + ' x' + $hits.Count)
  }
}

# ---- gate2: frontmatter 契约(skills + agents) ----
# 待查字段由 map.json 推导,且只在 frontmatter 区域内匹配:正文里的 css/yaml 代码块不算违规
$fmDrop = Get-FrontmatterDropPattern
function Get-CursorFrontmatterField([string]$path) {
  $fm = Get-Frontmatter (Get-Content $path -Raw)
  if ($null -eq $fm) { return '' }
  $m = [regex]::Match($fm, $fmDrop)
  if (-not $m.Success) { return '' }
  return $m.Groups[1].Value
}
$skillDirs = @(Get-ChildItem (Join-Path $cc 'skills') -Directory -ErrorAction SilentlyContinue)
if ($skillDirs.Count -eq 0) { $errors += 'gate2 no skill directories' }
foreach ($d in $skillDirs) {
  $smd = Join-Path $d.FullName 'SKILL.md'
  if (-not (Test-Path $smd)) { $errors += ('gate2 missing SKILL.md: ' + $d.Name); continue }
  $hit = Select-String -Path $smd -Pattern '^name:' | Select-Object -First 1
  if (-not $hit) { $errors += ('gate2 no name in ' + $d.Name); continue }
  $n = $hit.Line -replace '^name:\s*',''
  if ($n -ne $d.Name) { $errors += ('gate2 name mismatch: ' + $d.Name + ' => ' + $n) }
  $bad = Get-CursorFrontmatterField $smd
  if ($bad) { $errors += ('gate2 cursor-only frontmatter field in ' + $d.Name + ': ' + $bad + '; fix: 重跑 transform.ps1,该字段已由 map.json 的 frontmatter.drop/moveToMetadata 声明') }
}
$agentFiles = @(Get-ChildItem (Join-Path $cc 'agents') -File -Filter *.md -ErrorAction SilentlyContinue)
if ($agentFiles.Count -eq 0) { $errors += 'gate2 no agent files' }
foreach ($a in $agentFiles) {
  $hit = Select-String -Path $a.FullName -Pattern '^name:' | Select-Object -First 1
  if (-not $hit) { $errors += ('gate2 no name in agents/' + $a.Name); continue }
  $n = $hit.Line -replace '^name:\s*',''
  if ($n -ne $a.BaseName) { $errors += ('gate2 agent name mismatch: ' + $a.Name + ' => ' + $n) }
  $bad = Get-CursorFrontmatterField $a.FullName
  if ($bad) { $errors += ('gate2 cursor-only frontmatter field in agents/' + $a.Name + ': ' + $bad + '; fix: 重跑 transform.ps1,该字段已由 map.json 的 frontmatter.drop/moveToMetadata 声明') }
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
