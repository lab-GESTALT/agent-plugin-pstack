param([Parameter(Mandatory=$true)][string]$Root)
$ErrorActionPreference = 'Stop'
$errors = @()
$cc = Join-Path $Root 'plugins\pstack'

$tokens = @('AskQuestion','subagent_type','cursor-team-kit','/loop','generalPurpose','pstack-models\.mdc','\.cursor/(projects|plugins|worktrees|skills|rules)','agent-transcripts','api2\.cursor\.sh','mode: true','icon: crown','color: yellow')
foreach ($t in $tokens) {
  $hits = @(Get-ChildItem $cc -Recurse -File -Include *.md,*.json | Select-String -Pattern $t -ErrorAction SilentlyContinue)
  if ($hits.Count -gt 0) { $errors += ('gate1 residual: ' + $t + ' x' + $hits.Count) }
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
  if ($bad.Count -gt 0) { $errors += ('gate2 cursor fm field in ' + $d.Name) }
}

if (-not (Test-Path (Join-Path $cc 'agents'))) { $errors += 'gate3 missing agents dir' }
if (-not (Test-Path (Join-Path $cc 'skills'))) { $errors += 'gate3 missing skills dir' }

if ($errors.Count -gt 0) {
  Write-Output ('GATES FAILED: ' + $errors.Count)
  foreach ($e in $errors) { Write-Output ('  - ' + $e) }
  exit 1
}
Write-Output ('GATES GREEN: ' + $skillDirs.Count + ' skills, gates 1/2/3 passed')
