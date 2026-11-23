# Собирает однофайловую версию монитора: v4/monitor.lua + v4/lib/*.lua -> install/monitor.lua
# Запуск:  pwsh -File tools\build-bundle.ps1
param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$src  = Join-Path $Root 'v4'
$out  = Join-Path $Root 'install\monitor.lua'
$mods = @('lscm_core','lscm_stats','lscm_gfx','lscm_fx','lscm_pages','lscm_settings')

$texts = [ordered]@{}
foreach ($m in $mods) {
    $t = [IO.File]::ReadAllText((Join-Path $src "lib\$m.lua"))
    $texts[$m] = ($t -replace "`r`n", "`n").TrimEnd("`n")
}
$main = ([IO.File]::ReadAllText((Join-Path $src 'monitor.lua')) -replace "`r`n", "`n").TrimEnd("`n")

$all = (($texts.Values) -join "`n") + $main
$lvl = 3
while ($all.Contains(']' + ('=' * $lvl) + ']')) { $lvl++ }
$open  = '[' + ('=' * $lvl) + '['
$close = ']' + ('=' * $lvl) + ']'

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('-- monitor.lua v4 — монитор лапотронного суперконденсатора (GTNH, OpenComputers)')
[void]$sb.AppendLine('-- ОДНОФАЙЛОВАЯ СБОРКА: модули lscm_* встроены через package.preload.')
[void]$sb.AppendLine('-- Установка: положить как /home/monitor.lua и запустить: monitor')
[void]$sb.AppendLine('--   monitor <адрес>   — конкретный gt_machine')
[void]$sb.AppendLine('--   monitor --dump    — сырые данные машины в /home/lsc_dump.txt')
[void]$sb.AppendLine('-- Клавиши: Q выход, Tab страница, M график, 1-4 период, T сирена')
[void]$sb.AppendLine('-- Собрано из v4: monitor.lua + lib/lscm_{core,stats,gfx,fx,pages,settings}.lua')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('local __BUNDLE = {')
foreach ($m in $mods) {
    [void]$sb.AppendLine('  ["' + $m + '"] = ' + $open)
    [void]$sb.AppendLine($texts[$m])
    [void]$sb.AppendLine($close + ',')
}
[void]$sb.AppendLine('}')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('for __name, __src in pairs(__BUNDLE) do')
[void]$sb.AppendLine('  package.preload[__name] = assert(load(__src), __name)')
[void]$sb.AppendLine('end')
[void]$sb.AppendLine('__BUNDLE = nil')
[void]$sb.AppendLine('')
[void]$sb.AppendLine($main)
[void]$sb.AppendLine('')

$content = $sb.ToString() -replace "`r`n", "`n" # AppendLine uses CRLF, приводим всё к LF
[IO.File]::WriteAllText($out, $content, (New-Object System.Text.UTF8Encoding($false)))
Write-Output ("written: {0}  bytes={1}  delimiter level={2}" -f $out, (Get-Item $out).Length, $lvl)
