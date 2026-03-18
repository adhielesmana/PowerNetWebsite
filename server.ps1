param(
  [int]$Port = 8080
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
$mimeTypes = @{
  ".html" = "text/html; charset=utf-8"
  ".css"  = "text/css; charset=utf-8"
  ".js"   = "application/javascript; charset=utf-8"
  ".png"  = "image/png"
  ".jpg"  = "image/jpeg"
  ".jpeg" = "image/jpeg"
  ".webp" = "image/webp"
  ".svg"  = "image/svg+xml"
  ".ico"  = "image/x-icon"
  ".woff" = "font/woff"
  ".woff2" = "font/woff2"
}

function Send-Response {
  param(
    [System.Net.Sockets.NetworkStream]$Stream,
    [int]$StatusCode,
    [string]$StatusText,
    [byte[]]$Body,
    [string]$ContentType,
    [bool]$HeadOnly = $false
  )

  $writer = New-Object System.IO.StreamWriter($Stream, [System.Text.UTF8Encoding]::new($false), 1024, $true)
  $writer.NewLine = "`r`n"
  $writer.WriteLine("HTTP/1.1 $StatusCode $StatusText")
  $writer.WriteLine("Content-Type: $ContentType")
  $writer.WriteLine("Content-Length: $($Body.Length)")
  $writer.WriteLine("Connection: close")
  $writer.WriteLine()
  $writer.Flush()

  if (-not $HeadOnly -and $Body.Length -gt 0) {
    $Stream.Write($Body, 0, $Body.Length)
  }
}

$listener.Start()
Write-Output "PowerNet local server running at http://localhost:$Port"

try {
  while ($true) {
    $client = $listener.AcceptTcpClient()

    try {
      $stream = $client.GetStream()
      $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::ASCII, $false, 8192, $true)
      $requestLine = $reader.ReadLine()

      if ([string]::IsNullOrWhiteSpace($requestLine)) {
        continue
      }

      do {
        $line = $reader.ReadLine()
      } while ($line -ne "")

      $parts = $requestLine.Split(" ")
      $method = $parts[0]
      $rawPath = $parts[1]

      if ($method -notin @("GET", "HEAD")) {
        $body = [System.Text.Encoding]::UTF8.GetBytes("Method Not Allowed")
        Send-Response -Stream $stream -StatusCode 405 -StatusText "Method Not Allowed" -Body $body -ContentType "text/plain; charset=utf-8"
        continue
      }

      $relativePath = [System.Uri]::UnescapeDataString(($rawPath.Split("?")[0]).TrimStart("/"))
      if ([string]::IsNullOrWhiteSpace($relativePath)) {
        $relativePath = "index.html"
      }

      $candidatePath = Join-Path $root $relativePath
      $fullPath = [System.IO.Path]::GetFullPath($candidatePath)
      $looksLikeAssetRequest = -not [string]::IsNullOrWhiteSpace([System.IO.Path]::GetExtension($relativePath))
      $isSafePath = $fullPath.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)
      $fileExists = $isSafePath -and (Test-Path $fullPath -PathType Leaf)

      if (-not $fileExists) {
        if ($looksLikeAssetRequest) {
          $body = [System.Text.Encoding]::UTF8.GetBytes("Not Found")
          Send-Response -Stream $stream -StatusCode 404 -StatusText "Not Found" -Body $body -ContentType "text/plain; charset=utf-8" -HeadOnly:($method -eq "HEAD")
          continue
        }

        $fullPath = Join-Path $root "index.html"
      }

      $extension = [System.IO.Path]::GetExtension($fullPath).ToLowerInvariant()
      $contentType = if ($mimeTypes.ContainsKey($extension)) { $mimeTypes[$extension] } else { "application/octet-stream" }
      $body = [System.IO.File]::ReadAllBytes($fullPath)

      Send-Response -Stream $stream -StatusCode 200 -StatusText "OK" -Body $body -ContentType $contentType -HeadOnly:($method -eq "HEAD")
    }
    catch {
      try {
        $errorBody = [System.Text.Encoding]::UTF8.GetBytes("Internal Server Error")
        Send-Response -Stream $stream -StatusCode 500 -StatusText "Internal Server Error" -Body $errorBody -ContentType "text/plain; charset=utf-8"
      }
      catch {
      }
    }
    finally {
      $client.Close()
    }
  }
}
finally {
  $listener.Stop()
}
