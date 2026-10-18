<#
  serve.ps1 — 极简静态文件服务器（仅用于本地开发/验证，网站本身不需要服务器）

  用法： powershell -ExecutionPolicy Bypass -File Scripts/serve.ps1 [-Port 8080]
  然后浏览器打开 http://localhost:8080/          （index.html，走 fetch + importmap）
       浏览器打开 http://localhost:8080/preview.html  （内联版，也可离线双击打开）

  仅监听 127.0.0.1，只读，Ctrl+C 停止。
#>
param([int]$Port = 8080)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$mime = @{
  '.html' = 'text/html; charset=utf-8';   '.css'  = 'text/css; charset=utf-8'
  '.js'   = 'text/javascript; charset=utf-8'; '.json' = 'application/json; charset=utf-8'
  '.png'  = 'image/png'; '.jpg' = 'image/jpeg'; '.svg' = 'image/svg+xml'; '.ico' = 'image/x-icon'
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
"Serving $root at http://localhost:$Port/  (Ctrl+C to stop)"

try {
  while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    $rel = [Uri]::UnescapeDataString($ctx.Request.Url.AbsolutePath).TrimStart('/')
    if ([string]::IsNullOrWhiteSpace($rel)) { $rel = 'index.html' }
    $path = [IO.Path]::GetFullPath((Join-Path $root $rel))
    if (-not $path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path $path -PathType Leaf)) {
      $ctx.Response.StatusCode = 404
      $buf = [Text.Encoding]::UTF8.GetBytes('404 Not Found: ' + $rel)
      $ctx.Response.OutputStream.Write($buf, 0, $buf.Length)
    } else {
      $ext = [IO.Path]::GetExtension($path).ToLowerInvariant()
      $ctx.Response.ContentType = if ($mime.ContainsKey($ext)) { $mime[$ext] } else { 'application/octet-stream' }
      $ctx.Response.Headers.Add('Cache-Control', 'no-cache')
      $bytes = [IO.File]::ReadAllBytes($path)
      $ctx.Response.ContentLength64 = $bytes.Length
      $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
      "  200  /$rel  ($([Math]::Round($bytes.Length/1KB)) KB)"
    }
    $ctx.Response.Close()
  }
} finally { $listener.Stop() }
