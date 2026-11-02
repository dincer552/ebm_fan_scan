param(
    [int]$Port = 8077,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'

$root = Join-Path $PSScriptRoot 'app'
if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    Write-Host "app klasoru bulunamadi: $root" -ForegroundColor Red
    exit 1
}

$listener = $null
for ($p = $Port; $p -lt ($Port + 20); $p++) {
    try {
        $candidate = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $p)
        $candidate.Start()
        $listener = $candidate
        $Port = $p
        break
    }
    catch { }
}

if (-not $listener) {
    Write-Host 'Bos bir yerel port bulunamadi.' -ForegroundColor Red
    exit 1
}

$url = 'http://localhost:{0}/' -f $Port
Write-Host ''
Write-Host '  Fan Modbus - yerel arayuz' -ForegroundColor Cyan
Write-Host "  $url" -ForegroundColor Green
Write-Host '  Kapatmak icin bu pencereyi kapatin.' -ForegroundColor DarkGray
Write-Host ''

if (-not $NoBrowser) {
    Start-Process $url | Out-Null
}

$rootFull = [IO.Path]::GetFullPath($root)
$sep = [IO.Path]::DirectorySeparatorChar

while ($true) {
    $client = $null
    try {
        $client = $listener.AcceptTcpClient()
        $client.ReceiveTimeout = 3000
        $client.SendTimeout = 5000
        $stream = $client.GetStream()

        $buffer = New-Object byte[] 16384
        $read = 0
        try { $read = $stream.Read($buffer, 0, $buffer.Length) } catch { $read = 0 }
        if ($read -le 0) { continue }

        $request = [Text.Encoding]::ASCII.GetString($buffer, 0, $read)
        $firstLine = ($request -split "`r`n")[0]
        $parts = $firstLine -split ' '
        $rawPath = '/'
        if ($parts.Length -ge 2) { $rawPath = $parts[1] }

        $path = $rawPath.Split('?')[0]
        if ([string]::IsNullOrWhiteSpace($path) -or $path -eq '/') { $path = '/index.html' }

        $rel = [Uri]::UnescapeDataString($path).TrimStart('/')
        $rel = $rel.Replace('/', $sep)
        $full = [IO.Path]::GetFullPath((Join-Path $rootFull $rel))

        $status = '200 OK'
        $contentType = 'application/octet-stream'
        $body = $null

        if (-not $full.StartsWith($rootFull + $sep, [StringComparison]::OrdinalIgnoreCase)) {
            $status = '403 Forbidden'
            $contentType = 'text/plain; charset=utf-8'
            $body = [Text.Encoding]::UTF8.GetBytes('Forbidden')
        }
        elseif (Test-Path -LiteralPath $full -PathType Leaf) {
            switch ([IO.Path]::GetExtension($full).ToLowerInvariant()) {
                '.html' { $contentType = 'text/html; charset=utf-8' }
                '.js'   { $contentType = 'application/javascript; charset=utf-8' }
                '.css'  { $contentType = 'text/css; charset=utf-8' }
                '.json' { $contentType = 'application/json; charset=utf-8' }
                '.svg'  { $contentType = 'image/svg+xml' }
                '.png'  { $contentType = 'image/png' }
                '.ico'  { $contentType = 'image/x-icon' }
                default { $contentType = 'application/octet-stream' }
            }
            $body = [IO.File]::ReadAllBytes($full)
        }
        else {
            $status = '404 Not Found'
            $contentType = 'text/plain; charset=utf-8'
            $body = [Text.Encoding]::UTF8.GetBytes('Not found')
        }

        $header = "HTTP/1.1 $status`r`nContent-Type: $contentType`r`nContent-Length: $($body.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
        $headerBytes = [Text.Encoding]::ASCII.GetBytes($header)
        $stream.Write($headerBytes, 0, $headerBytes.Length)
        $stream.Write($body, 0, $body.Length)
        $stream.Flush()
    }
    catch {
        # istemci hatalarini yoksay
    }
    finally {
        if ($client) { try { $client.Close() } catch { } }
    }
}
