# 规则的唯一解释者。变换与门都从这里取匹配语义与文件作用域:一个 token 只有一种
# 匹配方式、一个适用范围,两边共用,杜绝"字面 vs 正则""散文 vs 脚本"这类两处漂移。
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

# 散文/代码的分界由 map.json 拥有:变换只改写散文,门对代码只查硬性残留标记
function Get-FileScope([string]$rel) {
  $ext = [System.IO.Path]::GetExtension($rel).ToLowerInvariant()
  if (@((Get-RuleMap).gate.proseExtensions) -contains $ext) { return 'prose' }
  return 'code'
}

function Convert-GlobToRegex([string]$glob) {
  $sb = [System.Text.StringBuilder]::new()
  [void]$sb.Append('^')
  $i = 0
  while ($i -lt $glob.Length) {
    $c = $glob[$i]
    if ($c -eq '*') {
      if ($i + 1 -lt $glob.Length -and $glob[$i + 1] -eq '*') {
        if ($i + 2 -lt $glob.Length -and $glob[$i + 2] -eq '/') { [void]$sb.Append('(?:.*/)?'); $i += 3; continue }
        [void]$sb.Append('.*'); $i += 2; continue
      }
      [void]$sb.Append('[^/]*'); $i++; continue
    }
    if ($c -eq '?') { [void]$sb.Append('[^/]'); $i++; continue }
    [void]$sb.Append([regex]::Escape([string]$c)); $i++
  }
  [void]$sb.Append('$')
  return $sb.ToString()
}

function Test-Glob([string]$glob, [string]$rel) {
  return [regex]::IsMatch($rel.Replace('\', '/'), (Convert-GlobToRegex $glob))
}

# 白名单按类登记:glob 命中路径,scope 限定文件类别,patterns 限定令牌身份
function Test-Allowlisted($allow, [string]$rel, [string]$scope, [string]$id) {
  foreach ($a in $allow) {
    if (@($a.patterns) -notcontains $id) { continue }
    if ($a.PSObject.Properties.Name -contains 'scope' -and [string]$a.scope -ne $scope) { continue }
    if (Test-Glob ([string]$a.glob) $rel) { return $true }
  }
  return $false
}

function Get-Frontmatter([string]$text) {
  $m = [regex]::Match($text, '(?s)^---\r?\n(.*?)\r?\n---')
  if (-not $m.Success) { return $null }
  return $m.Groups[1].Value
}

# 不得残留的 frontmatter 字段 = 变换会删除的 + 会移入 metadata 的,不另抄一份清单
function Get-FrontmatterDropPattern {
  $fm = (Get-RuleMap).frontmatter
  $keys = @($fm.drop) + @($fm.moveToMetadata.PSObject.Properties.Name) | Select-Object -Unique
  return '(?m)^[''\"]?(' + (($keys | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')[''\"]?\s*:'
}

# 门的待检项 = residualPatterns(全文件)+ 变换表(仅散文);id 用于白名单匹配与报错
function Get-GateChecks {
  $map = Get-RuleMap
  $checks = @()
  foreach ($p in $map.residualPatterns) {
    $checks += [pscustomobject]@{ Id = $p; Kind = 'regex'; Pattern = $p; Find = $null; Source = 'residual'; Scope = 'all' }
  }
  foreach ($spec in (Get-TokenSpecs)) {
    if (@($checks.Id) -contains $spec.Id) { continue }
    $checks += [pscustomobject]@{ Id = $spec.Id; Kind = $spec.Kind; Pattern = $spec.Pattern; Find = $spec.Find; Source = 'token'; Scope = 'prose' }
  }
  return $checks
}

function Test-Check($check, [string]$text) {
  if ($check.Kind -eq 'regex') { return [regex]::IsMatch($text, $check.Pattern) }
  return $text.Contains($check.Find, [StringComparison]::Ordinal)
}

Export-ModuleMember -Function Get-RuleMap, Get-TokenSpec, Get-TokenSpecs, Test-Token, Apply-Token, Apply-AllTokens, Get-FileScope, Convert-GlobToRegex, Test-Glob, Test-Allowlisted, Get-Frontmatter, Get-FrontmatterDropPattern, Get-GateChecks, Test-Check