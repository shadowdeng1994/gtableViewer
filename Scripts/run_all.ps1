<#
  run_all.ps1 — 一键把 rds/ 全部转成网站可展示数据，并重建 preview.html

  这条脚本存在的意义：机器上 Rscript 常常不在 PATH 里（本机就是），而且「导出 →
  校验路径 → 构建单文件」三步要按顺序跑，双击一个 .bat 比记三条命令现实得多。

  用法（在任意目录，或双击同目录的 run_all.bat）:
    powershell -NoProfile -ExecutionPolicy Bypass -File Scripts/run_all.ps1
    ... -Samples        强制重建 rds/*.rds（跑 make_samples.R）
    ... -Clean          删掉没有对应 rds 的 samples/*.json
    ... -SkipFresh      只重导「rds 比 json 新」的样例
    ... -SkipCheck      跳过 R 侧三项校验（check_loaders.R + check_math_label.R + check_rpath.R）
    ... -SkipPreview    跳过 build_preview.ps1
    ... -SkipSite       跳过 check_site.ps1（站点自检，Pages 上传前别跳）
    ... -Ref            重新生成 Scripts/.ref/*.grid.txt（R 渲染基准，改了导出器才需要）
    ... -Only scatter   只重导指定样例（逗号分隔多个 id）
    ... -MaxSampleMB 2  构建 preview.html 时跳过超过 2 MB 的样例（单文件版别膨胀到十几 MB）
    ... -Rscript <路径> 手动指定 Rscript.exe

  退出码：0 全部成功；2 某一步失败（输出里会写明是哪一步）。

  注意：本文件必须保存为 UTF-8 with BOM，否则 Windows PowerShell 5.1 会按 ANSI
  解析中文注释而报语法错误。
#>

[CmdletBinding()]
param(
  [switch]$Samples,
  [switch]$Clean,
  [switch]$SkipFresh,
  [switch]$SkipCheck,
  [switch]$SkipPreview,
  [switch]$SkipSite,
  [switch]$Ref,
  [double]$MaxSampleMB = 0,
  [string]$Only,
  [string]$Rscript
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot          # gtableViewer/
Set-Location $root

# R 输出的是 UTF-8 字节，PowerShell 默认按代码页解码会把中文打成乱码
try {
  [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
  $OutputEncoding = New-Object Text.UTF8Encoding $false
} catch { }

function Find-Rscript {
  $cands = @()
  # 1) PATH
  $cmd = Get-Command Rscript.exe -ErrorAction SilentlyContinue
  if ($cmd) { $cands += $cmd.Source }
  # 2) 注册表（R-core 官方安装器写的；64 位系统上 32 位视图也要看）
  foreach ($rk in 'HKLM:\SOFTWARE\R-core\R', 'HKCU:\SOFTWARE\R-core\R',
                  'HKLM:\SOFTWARE\WOW6432Node\R-core\R') {
    $ip = (Get-ItemProperty $rk -ErrorAction SilentlyContinue).InstallPath
    if ($ip) { $cands += (Join-Path $ip 'bin\Rscript.exe') }
  }
  # 3) 常见安装目录，按版本号从高到低
  foreach ($base in "$env:ProgramFiles\R", "${env:ProgramFiles(x86)}\R", "$env:LOCALAPPDATA\Programs\R") {
    if ($base -and (Test-Path $base)) {
      $cands += (Get-ChildItem $base -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName 'bin\Rscript.exe') } |
        Sort-Object { try { [version] ($_.Name -replace '^R-', '') } catch { [version]'0.0' } } -Descending |
        ForEach-Object { Join-Path $_.FullName 'bin\Rscript.exe' })
    }
  }
  $cands | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}

if (-not $Rscript) { $Rscript = Find-Rscript }
if (-not $Rscript) {
  Write-Host '  ✗ 找不到 Rscript.exe。装好 R 后重试，或用 -Rscript "C:\Program Files\R\R-4.6.0\bin\Rscript.exe" 指定。' -ForegroundColor Red
  exit 2
}

$rVersion = (& $Rscript --version 2>&1 | Select-Object -First 1)
"== gtableViewer 一键重跑 =="
"   根目录   : $root"
"   Rscript  : $Rscript"
"   R 版本   : $rVersion"
""

$swAll = [Diagnostics.Stopwatch]::StartNew()
function Invoke-Step($name, $block) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  Write-Host "--- $name ---" -ForegroundColor Cyan
  & $block
  $code = $LASTEXITCODE
  if ($code -ne 0) {
    Write-Host "  ✗ $name 失败（退出码 $code），后面的步骤不再执行。" -ForegroundColor Red
    exit 2
  }
  Write-Host ("  ✓ {0} 用时 {1:N1}s" -f $name, $sw.Elapsed.TotalSeconds) -ForegroundColor Green
  ""
}

# ── 1) 样例 rds（只在缺东西或被要求时才重建）───────────────────────────────
$rdsCount = @(Get-ChildItem 'rds' -Filter '*.rds' -ErrorAction SilentlyContinue).Count
if ($Samples -or $rdsCount -eq 0) {
  Invoke-Step 'make_samples.R（生成 rds/*.rds）' { & $Rscript 'Scripts/make_samples.R' }
} else {
  "--- make_samples.R（rds/ 已有 $rdsCount 个，跳过；要重建加 -Samples）---`n"
}

# ── 2) 导出：rds/*.rds → samples/*.json ────────────────────────────────────
$expArgs = @('Scripts/export_all.R')
if ($Clean)    { $expArgs += '--clean' }
if ($SkipFresh){ $expArgs += '--skip-fresh' }
if ($Only)     { $expArgs += "--only=$Only" }
Invoke-Step 'export_all.R（rds → samples/*.json）' { & $Rscript @expArgs }

# ── 3) R 侧回归：装载层 / 标签降级 / 定位路径 ──────────────────────────────
# 顺序按「跑得快 → 跑得慢」排：装载层两三秒，标签降级几秒，check_rpath 要重画所有图。
if ($Ref) { Invoke-Step 'ref_grid.R' { & $Rscript 'Scripts/ref_grid.R' } }
if ($SkipCheck) {
  "--- R 侧校验（check_loaders.R + check_math_label.R + check_rpath.R，已跳过）---`n"
} else {
  Invoke-Step 'check_loaders.R（.rds / .RData 装载回归）' { & $Rscript 'Scripts/check_loaders.R' }
  Invoke-Step 'check_math_label.R（plotmath 标签降级回归）' { & $Rscript 'Scripts/check_math_label.R' }
  Invoke-Step 'check_rpath.R（校验 gtable 定位路径）' { & $Rscript 'Scripts/check_rpath.R' }
}

# ── 4) 构建单文件 preview.html ─────────────────────────────────────────────
if ($SkipPreview) {
  "--- build_preview.ps1（已跳过）---`n"
} else {
  Invoke-Step 'build_preview.ps1（构建单文件预览）' {
    if ($MaxSampleMB -gt 0) { & (Join-Path $PSScriptRoot 'build_preview.ps1') -MaxSampleMB $MaxSampleMB }
    else { & (Join-Path $PSScriptRoot 'build_preview.ps1') }
  }
}

# ── 5) 站点自检：路径写法 / 清单一致性 / 脚本编码（不碰 R，几秒钟）──────
if ($SkipSite) {
  "--- check_site.ps1（已跳过）---`n"
} else {
  Invoke-Step 'check_site.ps1（站点自检）' { & (Join-Path $PSScriptRoot 'check_site.ps1') -Quiet }
}

$swAll.Stop()
"== 全部完成，总用时 {0:N1}s ==" -f $swAll.Elapsed.TotalSeconds
$json = @(Get-ChildItem 'samples' -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'index.json' })
"   samples/  : {0} 份可展示数据" -f $json.Count
if (Test-Path 'preview.html') {
  $p = Get-Item 'preview.html'
  "   双击可看  : {0}  ({1:N0} KB, {2:HH:mm:ss})" -f $p.FullName, ($p.Length / 1KB), $p.LastWriteTime
}
"   定量比对（要开浏览器）: Scripts/serve.ps1 后在页面里 eval Scripts/check_render.js"
