# 规则的唯一解释者。变换与门都从这里取匹配语义:一个 token 只有一种匹配方式,
# 两边共用,杜绝"字面 vs 正则""大小写敏感 vs 不敏感"这类两处漂移。
$script:Map = $null

function Get-RuleMap {
  if (-not $script:Map) {
    $script:Map = Get-Content (Join-Path $PSScriptRoot '..\map.json') -Raw | ConvertFrom-Json
  }
  return $script:Map
}

function Get-TokenSpec($t) {
  $hasPattern = $t.PSObject.Properties.Name -contains 'pattern'
  return [pscustomobject]@{
    Id      = [string]$t.find
    Kind    = $(if ($hasPattern) { 'regex' } else { 'literal' })
    Pattern = $(if ($hasPattern) { [string]$t.pattern } else { $null })
    Find    = [string]$t.find
    Replace = [string]$t.replace
  }
}

function Get-TokenSpecs {
  $map = Get-RuleMap
  return @($map.bodyTokens | ForEach-Object { Get-TokenSpec $_ })
}

function Test-Token($spec, [string]$text) {
  if ($spec.Kind -eq 'regex') { return [regex]::IsMatch($text, $spec.Pattern) }
  return $text.Contains($spec.Find, [StringComparison]::Ordinal)
}

function Apply-Token($spec, [string]$text) {
  if ($spec.Kind -eq 'regex') {
    # 用 MatchEvaluator:替换串是散文,不该被解释成 $1 之类的分组引用
    return [regex]::Replace($text, $spec.Pattern, { param($m) $spec.Replace })
  }
  return $text.Replace($spec.Find, $spec.Replace, [StringComparison]::Ordinal)
}

function Apply-AllTokens([string]$text) {
  foreach ($spec in (Get-TokenSpecs)) { $text = Apply-Token $spec $text }
  return $text
}

# 门的待检项 = residualPatterns + 变换表;id 用于白名单匹配与报错
function Get-GateChecks {
  $map = Get-RuleMap
  $checks = @()
  foreach ($p in $map.residualPatterns) {
    $checks += [pscustomobject]@{ Id = $p; Kind = 'regex'; Pattern = $p; Find = $null; Source = 'residual' }
  }
  foreach ($spec in (Get-TokenSpecs)) {
    if (@($checks.Id) -contains $spec.Id) { continue }
    $checks += [pscustomobject]@{ Id = $spec.Id; Kind = $spec.Kind; Pattern = $spec.Pattern; Find = $spec.Find; Source = 'token' }
  }
  return $checks
}

function Test-Check($check, [string]$text) {
  if ($check.Kind -eq 'regex') { return [regex]::IsMatch($text, $check.Pattern) }
  return $text.Contains($check.Find, [StringComparison]::Ordinal)
}

Export-ModuleMember -Function Get-RuleMap, Get-TokenSpec, Get-TokenSpecs, Test-Token, Apply-Token, Apply-AllTokens, Get-GateChecks, Test-Check