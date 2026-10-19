#Requires -Version 5
<#
  gtableViewer 站点自检 —— 上传到 GitHub Pages 之前跑一遍。

  不碰 R、不联网、不构建，纯静态检查，几秒钟出结果。它只回答一个问题：
  「这个目录直接当仓库根推上去，Pages 上能不能正常打开？」

  查七件事：
    1) 站点必需文件在不在（含 LICENSE / .nojekyll）
    2) samples/index.json 与磁盘上的 json 是否一一对应、能否解析、节点数是否过期
    3) index.html 的 src/href 与 main.js 的 fetch 是否全是相对路径，
       且大小写与磁盘上的真实文件名完全一致（Pages 是 Linux，大小写敏感）
    4) import map 指向的 lib/ 文件是否存在且体积正常（防半份拷贝）
    5) 脚本编码约定：.ps1 带 BOM、.R 不带 BOM、.bat 纯 ASCII + CRLF
    6) 行尾约定跟 .gitattributes 对齐（.ps1/.bat 用 CRLF，站点文件与数据用 LF）
    7) 有没有把 Rplots.pdf 之类的垃圾文件、或 1.5 MB 的 preview.html 一起带上

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File Scripts/check_site.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File Scripts/check_site.ps1 -Quiet   # 只报问题

  退出码：0 = 可以上传；2 = 有 FAIL，先修。警告不影响退出码。
#>
param([switch]$Quiet)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$fails = New-Object System.Collections.Generic.List[string]
$warns = New-Object System.Collections.Generic.List[string]
$oks   = New-Object System.Collections.Generic.List[string]

function Ok($m)   { $oks.Add($m);   if (-not $Quiet) { Write-Host "   ok   $m" -ForegroundColor DarkGreen } }
function Warn($m) { $warns.Add($m); Write-Host "   WARN $m" -ForegroundColor Yellow }
function Fail($m) { $fails.Add($m); Write-Host "   FAIL $m" -ForegroundColor Red }
function Head($m) { Write-Host "-- $m --" -ForegroundColor Cyan }

Write-Host '== gtableViewer 站点自检（GitHub Pages 上传前）==' -ForegroundColor Cyan
Write-Host "   root: $root"
Write-Host ''

# ── 1) 站点必需文件 ──────────────────────────────────────────────────────
Head '1) 站点必需文件'
foreach ($f in @('index.html', 'style.css', 'main.js', 'samples/index.json',
                 'lib/three.module.js', 'lib/OrbitControls.js',
                 'README.md', 'LICENSE', '.nojekyll', '.gitignore')) {
  if (Test-Path -LiteralPath (Join-Path $root $f)) { Ok "存在 $f" } else { Fail "缺少 $f" }
}
foreach ($f in @('Scripts/run_all.bat', 'Scripts/run_all.ps1', 'Scripts/export_all.R', 'Scripts/export_gtable.R')) {
  if (-not (Test-Path -LiteralPath (Join-Path $root $f))) { Fail "缺少 $f（可复现链路断了）" }
}

# ── 2) 清单与数据 ────────────────────────────────────────────────────────
Head '2) 样例清单 samples/index.json'
$manPath = Join-Path $root 'samples/index.json'
$listed = @{}
if (Test-Path -LiteralPath $manPath) {
  $man = $null
  try { $man = Get-Content -LiteralPath $manPath -Raw -Encoding UTF8 | ConvertFrom-Json }
  catch { Fail "samples/index.json 不是合法 JSON：$_" }
  if ($man) {
    if (@($man).Count -eq 0) { Fail 'samples/index.json 是空清单，下拉框会是空的' }
    foreach ($e in @($man)) {
      if (-not $e.file) { Fail "清单里有一条缺 file 字段（id=$($e.id)）"; continue }
      $listed[$e.file] = $true
      $p = Join-Path $root ('samples/' + $e.file)
      if (-not (Test-Path -LiteralPath $p)) { Fail "清单收录了 $($e.file)，磁盘上却没有 —— 下拉框选中它就 404"; continue }
      try {
        $d = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($d.meta.id -ne $e.id) {
          Fail "samples/$($e.file) 里 meta.id='$($d.meta.id)' 与清单 id='$($e.id)' 不一致"
        } elseif (@($d.nodes).Count -ne [int]$e.nodes) {
          Warn "samples/$($e.file) 实际 $(@($d.nodes).Count) 个节点，清单写 $($e.nodes) —— 清单过期，重跑 export_all.R"
        } else {
          Ok ('{0}  {1} 节点 / {2} 叶子' -f $e.file, $e.nodes, $e.leaves)
        }
      } catch { Fail "samples/$($e.file) 不是合法 JSON：$_" }
    }
    foreach ($f in Get-ChildItem -LiteralPath (Join-Path $root 'samples') -Filter '*.json') {
      if ($f.Name -eq 'index.json') { continue }
      if (-not $listed.ContainsKey($f.Name)) { Warn "samples/$($f.Name) 没被清单收录 —— 重跑 export_all.R，或它已经是孤儿（export_all --clean 会删）" }
    }
  }
}

# ── 3) 引用写法：必须相对路径 + 大小写精确 ───────────────────────────────
Head '3) 路径写法（子路径部署 / 不依赖 CDN / Linux 大小写）'
$html = Get-Content -LiteralPath (Join-Path $root 'index.html') -Raw -Encoding UTF8

function Resolve-OnDisk([string]$rel) {
  # Windows 的 Test-Path 不区分大小写，所以拿真实文件名回来自己比。
  $disk = Join-Path $root ($rel -replace '/', '\')
  if (-not (Test-Path -LiteralPath $disk)) { return $null }
  return (Get-Item -LiteralPath $disk).FullName.Substring($root.Length + 1).Replace('\', '/')
}

$refs = [regex]::Matches($html, '(?:src|href)="([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
foreach ($r in $refs) {
  if ($r.StartsWith('data:')) { Ok ('内联图标 data: URI（{0:N1} KB，不联网）' -f ($r.Length / 1KB)); continue }
  if ($r -match '^(https?:)?//')          { Fail "index.html 引用了外部地址 `"$r`" —— Pages 上等于吊着一条 CDN，请本地化" }
  elseif ($r.StartsWith('/'))             { Fail "index.html 用了根绝对路径 `"$r`" —— 部署到 /<仓库名>/ 子路径会 404" }
  elseif ($r -match 'localhost|127\.0\.0\.1') { Fail "index.html 里还写着本地地址 `"$r`"" }
  else {
    $rel = $r -replace '^\./', ''
    $real = Resolve-OnDisk $rel
    if ($null -eq $real) { Fail "index.html 引用的 `"$r`" 在磁盘上不存在" }
    elseif ($real -cne $rel) { Fail "大小写不一致：页面写 `"$rel`"，磁盘上是 `"$real`" —— Pages 是 Linux，会 404" }
    else { Ok "引用 $r（存在，大小写与磁盘一致）" }
  }
}

$js = Get-Content -LiteralPath (Join-Path $root 'main.js') -Raw -Encoding UTF8
foreach ($m in [regex]::Matches($js, "fetch\(\s*'([^']+)'([^\r\n]{0,60})")) {
  $u = $m.Groups[1].Value
  $tail = $m.Groups[2].Value.Trim() -replace '[),;]+$', ''
  if ($u -match '^(https?:)?//' -or $u.StartsWith('/')) { Fail "main.js 里 fetch('$u$tail') 不是相对路径" }
  elseif (($u + $tail) -match '\{\}|<|待填') { Fail "main.js 里 fetch('$u$tail') 像是没填完的占位符" }
  else { Ok "fetch('$u'$tail) 相对路径" }
}
if ($js -match '(?m)^\s*import\s') {
  Ok 'main.js 的 import 走 import map（Pages 上由 index.html 解析，正常）'
}

# import map：裸模块名 three / three/addons 必须映射到本地 lib/
foreach ($m in [regex]::Matches($html, '"(three[^"]*)"\s*:\s*"([^"]+)"')) {
  $name = $m.Groups[1].Value; $target = $m.Groups[2].Value
  $rel = $target -replace '^\./', ''
  $real = Resolve-OnDisk $rel
  if ($target -match '^(https?:)?//' -or $target.StartsWith('/')) { Fail "import map 里 `"$name`" 指向 $target —— 必须映射到本地相对路径" }
  elseif ($null -eq $real) { Fail "import map 里 `"$name`" 指向 $target，文件不存在" }
  elseif ($real -cne $rel) { Fail "import map 里 `"$name`" 指向 $target，磁盘上是 $real —— 大小写不一致会 404" }
  else { Ok "import map `"$name`" → $target" }
}

# 半份拷贝的兜底：three.module.js 少说也有 1 MB
foreach ($p in @('lib/three.module.js', 'lib/OrbitControls.js')) {
  $f = Get-Item -LiteralPath (Join-Path $root $p) -ErrorAction SilentlyContinue
  if ($f) {
    $min = if ($p -like '*three.module*') { 800KB } else { 15KB }
    if ($f.Length -lt $min) { Fail "$p 只有 $([Math]::Round($f.Length/1KB)) KB，像是被截断/占位了（正常 ≥ $([Math]::Round($min/1KB)) KB）" }
    else { Ok ('{0}  {1:N0} KB' -f $p, ($f.Length / 1KB)) }
  }
}

# ── 4) 页面基本元信息 ────────────────────────────────────────────────────
Head '4) 页面元信息'
if ($html -match '<title>[^<]{4,}</title>') { Ok '有 <title>' } else { Fail '<title> 缺失或太短（搜索结果与浏览器标签页都靠它）' }
if ($html -match 'name="description"')      { Ok '有 meta description' } else { Warn '缺 meta description（搜索引擎与分享卡片会用正文前几句顶上）' }
if ($html -match '<html[^>]+lang=')         { Ok '有 <html lang>（读屏与翻译都要）' } else { Warn '缺 <html lang> 属性' }
if ($html -match 'charset')                 { Ok '声明了字符集' } else { Fail '缺 <meta charset>，中文会按错误编码解析' }

# ── 5) 脚本编码约定 ──────────────────────────────────────────────────────
Head '5) 脚本编码约定（换台机器还能跑）'
$scriptDirs = @((Join-Path $root 'Scripts'), (Join-Path $root 'export')) | Where-Object { Test-Path -LiteralPath $_ }
foreach ($d in $scriptDirs) {
  foreach ($f in Get-ChildItem -Path $d -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.bat', '.R' }) {
    $b = [IO.File]::ReadAllBytes($f.FullName)
    $bom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
    $rel = $f.FullName.Substring($root.Length + 1).Replace('\', '/')
    $txt = [Text.Encoding]::UTF8.GetString($b)
    $bareLF = ([regex]::Matches($txt, '(?<!\r)\n')).Count
    if ($f.Extension -eq '.ps1') {
      if (-not $bom) { Fail "$rel 缺 UTF-8 BOM —— Windows PowerShell 5.1 会把中文读成乱码" }
      else { Ok "$rel BOM 正确（裸 LF $bareLF 处，PowerShell 不在乎）" }
    }
    if ($f.Extension -eq '.R') {
      if ($bom) { Fail "$rel 带 BOM —— Rscript 会把 BOM 当成语句，报意外符号" }
      else { Ok "$rel 无 BOM" }
    }
    if ($f.Extension -eq '.bat') {
      $bad = @()
      if ($bom) { $bad += '带 BOM（cmd 会把 BOM 当命令名）' }
      if ($txt -match '[^\x09\x0A\x0D\x20-\x7E]') { $bad += '含非 ASCII 字符（cmd 的代码页会读成乱码，改英文或先 chcp 65001）' }
      if ($bareLF -gt 0) { $bad += "$bareLF 处裸 LF（cmd 需要 CRLF）" }
      if ($bad.Count) { Fail ("$rel " + ($bad -join '；')) } else { Ok "$rel 纯 ASCII + CRLF 无 BOM" }
    }
  }
}

# 行尾约定：跟 .gitattributes 对齐 —— .ps1/.bat/.cmd 是 CRLF，站点文件与数据是 LF。
# 不一致的文件在 git 里会整篇显示成改动，跨平台重跑出来的字节也不同（校验哈希对不上）。
# 这里只看行尾；BOM 上面已经查过。lib/ 是原样分发的第三方拷贝，故意不查。
$eolTargets = @()
foreach ($p in @('index.html', 'style.css', 'main.js', 'README.md', '.gitignore', '.gitattributes', 'LICENSE')) {
  $fp = Join-Path $root $p
  if (Test-Path -LiteralPath $fp) { $eolTargets += Get-Item -LiteralPath $fp }
}
foreach ($p in @('Scripts', 'samples')) {
  $fp = Join-Path $root $p
  if (Test-Path -LiteralPath $fp -PathType Container) {
    $eolTargets += @(Get-ChildItem -LiteralPath $fp -Recurse -File |
      Where-Object { $_.Extension -in '.R', '.ps1', '.bat', '.cmd', '.js', '.json', '.txt', '.md' })
  }
}
$eolBad = @()
foreach ($f in $eolTargets) {
  $b = [IO.File]::ReadAllBytes($f.FullName)
  if ($b.Length -eq 0 -or ($b -contains 0)) { continue }
  $t = [Text.Encoding]::UTF8.GetString($b)
  $crlf = ([regex]::Matches($t, '\r\n')).Count
  $bare = ([regex]::Matches($t, '(?<!\r)\n')).Count
  $wantCrlf = $f.Extension -in '.ps1', '.bat', '.cmd'
  $rel = $f.FullName.Substring($root.Length + 1).Replace('\', '/')
  if ($wantCrlf -and $bare -gt 0) { $eolBad += "$rel 该用 CRLF，却有 $bare 处裸 LF" }
  if (-not $wantCrlf -and $crlf -gt 0) { $eolBad += "$rel 该用 LF，却有 $crlf 处 CRLF" }
}
if ($eolBad.Count) { foreach ($x in $eolBad) { Fail $x } }
else { Ok ('行尾统一（{0} 个文本文件按 .gitattributes 对齐）' -f $eolTargets.Count) }

# ── 6) 垃圾文件与构建产物 ────────────────────────────────────────────────
Head '6) 工作区干净度'
$junkPat = '^Rplots\.pdf$|\.Rhistory$|\.RData$|^\.DS_Store$|^Thumbs\.db$|^desktop\.ini$|\.tmp$|\.log$|\.bak$'
$junk = Get-ChildItem -LiteralPath $root -Recurse -File -Force | Where-Object {
  $_.Name -match $junkPat -and
  # rds/*.RData 是合法输入（一次存的整束图，导出器认它），不是 R 工作区残留。
  # 只有别处冒出来的 .RData（比如根目录 save.image() 的工作区）才算垃圾。
  -not ($_.Name -match '\.RData$' -and $_.Directory.Name -eq 'rds')
}
if ($junk) {
  foreach ($j in $junk) { Warn "$($j.FullName.Substring($root.Length + 1).Replace('\', '/')) 是临时产物（.gitignore 已忽略，但本地建议删掉）" }
} else { Ok '没有 Rplots.pdf / .Rhistory / .DS_Store 之类的残留' }

$pv = Join-Path $root 'preview.html'
if (Test-Path -LiteralPath $pv) {
  Ok ('preview.html 在（{0:N0} KB，已被 .gitignore 忽略，不会跟着上传；要带就 git add -f）' -f ((Get-Item -LiteralPath $pv).Length / 1KB))
} else {
  Warn '本地没有 preview.html —— 想双击直接看：powershell -File Scripts/build_preview.ps1'
}

# ── 7) 体积 ──────────────────────────────────────────────────────────────
Head '7) 体积'
$siteFiles = @()
foreach ($p in @('index.html', 'style.css', 'main.js', 'lib', 'samples')) {
  $full = Join-Path $root $p
  if (Test-Path -LiteralPath $full -PathType Container) { $siteFiles += @(Get-ChildItem -LiteralPath $full -Recurse -File) }
  elseif (Test-Path -LiteralPath $full) { $siteFiles += @(Get-Item -LiteralPath $full) }
}
$siteKB = ($siteFiles | Measure-Object Length -Sum).Sum / 1KB
Ok ('浏览器要下的文件：{0} 个 / {1:N0} KB（其中 lib/ 占 {2:N0} KB）' -f $siteFiles.Count, $siteKB, ((Get-ChildItem -LiteralPath (Join-Path $root 'lib') -File | Measure-Object Length -Sum).Sum / 1KB))
$allFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force | Where-Object { $_.Name -ne 'preview.html' -and $_.FullName -notmatch '\\\.git\\' })
Ok ('仓库里（不含 preview.html）：{0} 个 / {1:N1} MB' -f $allFiles.Count, (($allFiles | Measure-Object Length -Sum).Sum / 1MB))

# ── 结论 ─────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host ('== 自检结束：{0} 项通过 / {1} 警告 / {2} 失败 ==' -f $oks.Count, $warns.Count, $fails.Count) -ForegroundColor $(if ($fails.Count) { 'Red' } else { 'Green' })
foreach ($w in $warns) { Write-Host "   WARN $w" -ForegroundColor Yellow }
foreach ($f in $fails) { Write-Host "   FAIL $f" -ForegroundColor Red }
if ($fails.Count) {
  Write-Host '   先修完 FAIL 再 push。' -ForegroundColor Red
  exit 2
}
Write-Host '   可以上传：仓库根 = 站点根，Pages 选 Deploy from a branch → 分支 /(root) 即可。' -ForegroundColor Green
Write-Host '   若本目录只是大仓库里的一个子目录（如 AIBook/gtableViewer），用仓库根那份跳转 index.html + .nojekyll 落到这里。' -ForegroundColor Green
exit 0
