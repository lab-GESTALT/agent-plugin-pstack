# sync.yml 步骤文本的唯一读取者。verify-pstack-sync 与 formal-verify-pstack-sync
# 都从这里取 run: 块,不各抄一份解析逻辑,否则两个 harness 会对同一步骤读出不同文本。
$script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).ProviderPath

function Get-WorkflowStep([string]$stepName) {
  $lines = Get-Content (Join-Path $script:Repo '.github\workflows\sync.yml')
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

Export-ModuleMember -Function Get-WorkflowStep