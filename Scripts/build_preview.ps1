<#
  build_preview.ps1 — 生成可直接双击打开的 preview.html（file:// 离线可用）

  为什么要构建：浏览器在 file:// 协议下禁止 <script type="module"> 与 fetch() 读取本地文件
  （CORS: "Cross origin requests are only supported on protocol http/https"）。
  本脚本把 three.js + OrbitControls + main.js + 三份样例 JSON 内联进单个 HTML，
  于是无需任何服务器即可在本地查看最终效果。

  用法： powershell -ExecutionPolicy Bypass -File Scripts/build_preview.ps1 [-MaxSampleMB 2]
  输出： gtableViewer/preview.html

  -MaxSampleMB：跳过超过该体积的样例（并从内嵌清单里一起去掉），默认 0 = 全部内联。
                大样例（RepresentativeTree 约 12MB）会让单文件版膨胀到十几 MB，
                调前端时用它出一个小的 preview.html 验证 file:// 路径即可，别拿它当交付物。

  做法（纯文本改写，不改动任何运行逻辑）：
    1. lib/three.module.js  删除末尾 `export { ... };`，并用该导出列表合成 `const THREE = { ... };`
    2. lib/OrbitControls.js 删除首尾的 import/export，整体包进 IIFE，
                            从 THREE 解构出它需要的符号（避免与 three 内部同名变量冲突，如 _ray）
    3. main.js              删除两行 `import ... from '...'`（它用 window 上的 THREE / OrbitControls）
    4. samples/*.json       注入 window.__EMBEDDED__（main.js 优先读它，否则 fetch samples/）
    5. style.css            内联成 <style>：preview.html 才是真正单文件，拷走一个文件也不散
    6. index.html           去掉 importmap，把 <script src="./main.js"> 换成内联脚本

  注意：本文件须保存为 UTF-8 with BOM，否则 Windows PowerShell 5.1 会按 ANSI 解析中文而报语法错误。
#>

param([double]$MaxSampleMB = 0)   # 0 = 全部内联；>0 时跳过超大样例（连清单一起裁）

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Read-Utf8($p) { [IO.File]::ReadAllText((Join-Path $root $p), (New-Object Text.UTF8Encoding $false)) }
$NL = [Environment]::NewLine

"== gtableViewer preview build =="
"   root: $root"

# ── 1) three.js：剥离 export，并合成 THREE 命名空间 ───────────────────────
$threeSrc = Read-Utf8 'lib/three.module.js'
$m = [regex]::Match($threeSrc, '(?ms)^export\s*\{(?<list>[^}]*)\};?[ \t]*\r?\n?\s*$')
if (-not $m.Success) { throw 'three.module.js: 未找到末尾的 export 块' }
$three = $threeSrc.Remove($m.Index, $m.Length)

$pairs = foreach ($item in ($m.Groups['list'].Value -split ',')) {
  $t = $item.Trim()
  if (-not $t) { continue }
  $as = [regex]::Match($t, '^([A-Za-z_$][\w$]*)\s+as\s+([A-Za-z_$][\w$]*)$')
  if ($as.Success) { "$($as.Groups[2].Value): $($as.Groups[1].Value)" }
  elseif ($t -match '^[A-Za-z_$][\w$]*$') { $t }
  else { throw "three.module.js: 无法解析导出项 '$t'" }
}
$three += $NL + "const THREE = {" + $NL + ($pairs -join ",") + $NL + "};" + $NL
"   three.module.js   {0:N0} KB  ({1} exports -> THREE)" -f ($three.Length / 1KB), $pairs.Count
if (-not ($pairs -contains 'Controls')) { throw 'three 导出中缺少 Controls（OrbitControls 基类）' }

# ── 2) OrbitControls：剥离 import/export，包进 IIFE ───────────────────────
$orbitSrc = Read-Utf8 'lib/OrbitControls.js'
$mi = [regex]::Match($orbitSrc, "(?s)\Aimport\s*\{(?<list>.*?)\}\s*from\s*'three';\s*")
if (-not $mi.Success) { throw 'OrbitControls.js: 未找到开头的 import ... from three' }
$orbit = $orbitSrc.Remove($mi.Index, $mi.Length)
$me = [regex]::Match($orbit, '(?ms)^export\s*\{[^}]*\};?[ \t]*\r?\n?\s*$')
if ($me.Success) { $orbit = $orbit.Remove($me.Index, $me.Length) }
if ($orbit -match '(?m)^(export|import) ') { throw 'OrbitControls.js: 仍有未剥离的 import/export' }

$need = ($mi.Groups['list'].Value -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
foreach ($sym in $need) {
  if ($pairs -notcontains $sym -and -not ($pairs | Where-Object { $_ -like "*$sym*" -or $_ -like "${sym}*" })) {
    throw "OrbitControls 需要 '$sym'，但 three 导出列表中没有"
  }
}
$orbit = 'const OrbitControls = (() => {' + $NL +
         'const { ' + ($need -join ', ') + ' } = THREE;' + $NL +
         $orbit + $NL + 'return OrbitControls;' + $NL + '})();' + $NL
"   OrbitControls.js  {0:N0} KB  (isolated, needs: {1})" -f ($orbit.Length / 1KB), ($need -join ' ')

# ── 3) main.js：剥离 import ──────────────────────────────────────────────
$main = Read-Utf8 'main.js'
$main = [regex]::Replace($main, "(?m)^import\s+.*?\s*from\s*'[^']*';\r?\n", '')
if ($main -match '(?m)^import ') { throw 'main.js: 仍有未剥离的 import' }
"   main.js           {0:N0} KB" -f ($main.Length / 1KB)

# ── 4) 样例数据 ──────────────────────────────────────────────────────────
# 枚举 samples/*.json：index.json（样例清单）会内嵌成 __EMBEDDED__.index，页面据此填下拉框
$files = @(Get-ChildItem 'samples' -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object Name)
if (-not $files) { throw 'samples/ 下没有 json —— 先跑 Scripts/export_all.R' }
if (-not ($files.Name -contains 'index.json')) {
  Write-Warning '缺 samples/index.json（样例清单），页面下拉框会退回内置三条；跑一次 Scripts/export_all.R 生成'
}
# 超大样例可以跳过，但清单必须跟着裁：下拉框读的是内嵌清单，留着条目却读不到数据就是死链
$skipped = @()
if ($MaxSampleMB -gt 0) {
  $cap = $MaxSampleMB * 1MB
  $skipped = @($files | Where-Object { $_.Name -ne 'index.json' -and $_.Length -gt $cap })
  if ($skipped) { $files = @($files | Where-Object { $skipped.Name -notcontains $_.Name }) }
}
$indexText = Read-Utf8 'samples/index.json'
if ($skipped) {
  $keep = @($files.Name | Where-Object { $_ -ne 'index.json' })
  # 注意：PS 5.1 的 ConvertFrom-Json 把顶层数组当「一个对象」丢进管道，
  # 直接 @(ConvertFrom-Json …) 会得到 1 个元素（整个数组），必须先接进变量再展开。
  $parsed = ConvertFrom-Json $indexText
  $list = @($parsed) | Where-Object { $keep -contains $_.file }
  $indexText = ConvertTo-Json @($list) -Compress
}
$parts = foreach ($f in $files) {
  $json = if ($f.Name -eq 'index.json') { $indexText } else { Read-Utf8 "samples/$($f.Name)" }
  "    `"$($f.BaseName)`": " + $json.Replace('</', '<\/')   # 防止 </script> 提前闭合
}
$embed = 'window.__EMBEDDED__ = {' + $NL + ($parts -join ",$NL") + '};' + $NL
"   samples           {0:N0} KB (embedded)" -f (($parts -join '').Length / 1KB)
if ($skipped) {
  Write-Warning ("已跳过超过 {0} MB 的样例：{1}（清单同步裁掉，这份 preview.html 不是完整交付物）" -f `
    $MaxSampleMB, (($skipped | ForEach-Object { $_.Name }) -join ', '))
}

# ── 5) 组装 ──────────────────────────────────────────────────────────────
$html = Read-Utf8 'index.html'
$html = [regex]::Replace($html, '(?s)<script type="importmap">.*?</script>\s*', '')

# 样式也内联：file:// 下 <link href="./style.css"> 虽然能读到同目录的文件，但 preview.html
# 号称单文件，拷走一个文件样式就散了，所以这里一并塞进 <style>。
$css = Read-Utf8 'style.css'
if ($css.Contains('</style')) { throw 'style.css: 含 </style，不能安全内联' }
$cssNeedle = '<link rel="stylesheet" href="./style.css" />'
if (-not $html.Contains($cssNeedle)) { throw 'index.html: 找不到 style.css 的 link 标签' }
$html = $html.Replace($cssNeedle, '<style>' + $NL + $css + $NL + '</style>')
"   style.css         {0:N0} KB (inlined)" -f ($css.Length / 1KB)

$inline = '<script type="module">' + $NL +
  '/* ===== three.js r170 (export stripped, THREE namespace synthesized) ===== */' + $NL + $three +
  '/* ===== OrbitControls r170 (isolated in IIFE) ===== */' + $NL + $orbit +
  '/* ===== embedded sample data ===== */' + $NL + $embed +
  '/* ===== main.js (imports stripped) ===== */' + $NL + $main +
  '</script>'

$needle = '<script type="module" src="./main.js"></script>'
if (-not $html.Contains($needle)) { throw 'index.html: 找不到 main.js 的 script 标签' }
$html = $html.Replace($needle, $inline)   # 字面替换：$ 等字符不会被当作正则反向引用

# Self-check first: a single-file build must not reference anything on disk any
# more. (<link href="./style.css"> used to slip through here - it still renders
# over file:// as long as style.css sits next to it, so local testing never caught it.)
# data: URIs are exempt - the inline SVG favicon carries its own bytes.
$ext = [regex]::Matches($html, '(?:src|href)="([^"]*)"') | ForEach-Object { $_.Groups[1].Value } |
  Where-Object { -not $_.StartsWith('data:') } | Sort-Object -Unique
if ($ext) { throw "preview.html still references external file(s): $($ext -join ', ')" }

$out = Join-Path $root 'preview.html'
[IO.File]::WriteAllText($out, $html, (New-Object Text.UTF8Encoding $false))
"   preview.html      {0:N0} KB" -f ((Get-Item $out).Length / 1KB)
"   -> $out"
"   Double-click it, or run Scripts/serve.ps1 and open http://localhost:8080/"
