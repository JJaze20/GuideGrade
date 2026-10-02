$root = "C:\Users\jeroj\StudioProjects\GuideGrade\build\web"
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:8765/")
$listener.Start()
Write-Host "Serving $root on http://localhost:8765"

$mime = @{
  ".html"="text/html"; ".js"="application/javascript"; ".json"="application/json"
  ".css"="text/css"; ".png"="image/png"; ".jpg"="image/jpeg"; ".svg"="image/svg+xml"
  ".wasm"="application/wasm"; ".ico"="image/x-icon"
}

while ($listener.IsListening) {
  $context = $listener.GetContext()
  $path = $context.Request.Url.LocalPath
  if ($path -eq "/") { $path = "/index.html" }
  $filePath = Join-Path $root $path.TrimStart("/")
  if (-not (Test-Path $filePath -PathType Leaf)) {
    $filePath = Join-Path $root "index.html"
  }
  $ext = [System.IO.Path]::GetExtension($filePath)
  $contentType = $mime[$ext]
  if (-not $contentType) { $contentType = "application/octet-stream" }
  $bytes = [System.IO.File]::ReadAllBytes($filePath)
  $context.Response.ContentType = $contentType
  $context.Response.ContentLength64 = $bytes.Length
  $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $context.Response.OutputStream.Close()
}
