param(
    [int]$Port = 8077,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11
}
catch { }

$Repo = 'dincer552/ebm_fan_scan'
$RepoApi = "https://api.github.com/repos/$Repo"
$ArchiveUrl = "https://github.com/$Repo/archive/refs/heads/main.zip"
$UpdaterUserAgent = 'EBM-Fan-Scan-Updater'

$root = Join-Path $PSScriptRoot 'app'
if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    Write-Host "app klasoru bulunamadi: $root" -ForegroundColor Red
    exit 1
}

$installFull = [IO.Path]::GetFullPath($PSScriptRoot)
$rootFull = [IO.Path]::GetFullPath($root)
$sep = [IO.Path]::DirectorySeparatorChar

function Send-Response {
    param(
        $Stream,
        [int]$Code,
        [string]$Text,
        [string]$ContentType,
        [byte[]]$Body
    )
    if ($null -eq $Body) { $Body = [byte[]]@() }
    $header = "HTTP/1.1 $Code $Text`r`nContent-Type: $ContentType`r`nContent-Length: $($Body.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
    $headerBytes = [Text.Encoding]::ASCII.GetBytes($header)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    if ($Body.Length -gt 0) { $Stream.Write($Body, 0, $Body.Length) }
    $Stream.Flush()
}

function Send-Json {
    param($Stream, [int]$Code, [string]$Text, $Object)
    $json = $Object | ConvertTo-Json -Depth 8 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    Send-Response -Stream $Stream -Code $Code -Text $Text -ContentType 'application/json; charset=utf-8' -Body $bytes
}

function Get-NormalizedHash {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    try {
        $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        $text = $text.TrimStart([char]0xFEFF)
        $text = $text -replace "`r`n", "`n"
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
            $hash = $sha.ComputeHash($bytes)
            return (([BitConverter]::ToString($hash)) -replace '-', '')
        }
        finally {
            $sha.Dispose()
        }
    }
    catch {
        return ''
    }
}

function Get-LocalBuildInfo {
    $file = Join-Path $installFull 'build_info.json'
    if (Test-Path -LiteralPath $file) {
        try {
            $j = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
            $sha = [string]$j.sha
            if ($sha) {
                return [pscustomobject]@{
                    sha     = $sha
                    short   = $sha.Substring(0, [Math]::Min(7, $sha.Length))
                    date    = [string]$j.date
                    version = [string]$j.version
                    source  = 'file'
                }
            }
        }
        catch { }
    }

    if (Test-Path -LiteralPath (Join-Path $installFull '.git')) {
        try {
            $sha = [string](& git -C $installFull rev-parse HEAD 2>$null)
            $sha = $sha.Trim()
            if ($sha) {
                $date = [string](& git -C $installFull show -s --format=%cI HEAD 2>$null)
                return [pscustomobject]@{
                    sha     = $sha
                    short   = $sha.Substring(0, [Math]::Min(7, $sha.Length))
                    date    = $date.Trim()
                    version = ''
                    source  = 'git'
                }
            }
        }
        catch { }
    }

    return [pscustomobject]@{ sha = ''; short = ''; date = ''; version = ''; source = 'none' }
}

function Get-RemoteCommit {
    $headers = @{
        'User-Agent'    = $UpdaterUserAgent
        'Accept'        = 'application/vnd.github+json'
        'Cache-Control' = 'no-cache'
    }
    $commit = Invoke-RestMethod -Uri "$RepoApi/commits/main" -Headers $headers -Method Get -TimeoutSec 25
    $sha = [string]$commit.sha
    if (-not $sha) { throw 'GitHub yanitinda commit SHA bulunamadi.' }
    $message = (([string]$commit.commit.message) -split "`n")[0].Trim()
    return [pscustomobject]@{
        sha     = $sha
        short   = $sha.Substring(0, [Math]::Min(7, $sha.Length))
        date    = [string]$commit.commit.author.date
        message = $message
        url     = [string]$commit.html_url
    }
}

function Test-IsNewer {
    param($Local, $Remote)
    if (-not $Remote.sha) { return $false }
    if (-not $Local.sha) { return $true }
    if ($Local.sha -eq $Remote.sha) { return $false }
    try {
        if ($Local.date) {
            $localDate = [datetimeoffset]::Parse($Local.date)
            $remoteDate = [datetimeoffset]::Parse($Remote.date)
            if ($localDate -ge $remoteDate) { return $false }
        }
    }
    catch { }
    return $true
}

$script:updateRunning = $false

function Invoke-UpdateApply {
    if ($script:updateRunning) { throw 'Guncelleme zaten suruyor.' }
    $script:updateRunning = $true

    $zip = $null
    $extract = $null
    try {
        $remote = Get-RemoteCommit
        $stamp = [guid]::NewGuid().ToString('N')
        $zip = Join-Path $env:TEMP "ebm_fan_scan_$stamp.zip"
        $extract = Join-Path $env:TEMP "ebm_fan_scan_$stamp"

        $headers = @{
            'User-Agent'    = $UpdaterUserAgent
            'Accept'        = 'application/zip'
            'Cache-Control' = 'no-cache'
        }
        Invoke-WebRequest -Uri $ArchiveUrl -Headers $headers -OutFile $zip -UseBasicParsing -TimeoutSec 120

        New-Item -ItemType Directory -Path $extract -Force | Out-Null
        Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force

        $srcRoot = $null
        foreach ($dir in Get-ChildItem -LiteralPath $extract -Directory) {
            if (Test-Path -LiteralPath (Join-Path $dir.FullName 'app\index.html')) {
                $srcRoot = $dir.FullName
                break
            }
        }
        if (-not $srcRoot) { throw 'Indirilen arsivde app/index.html bulunamadi.' }

        foreach ($rel in @('app\app.js', 'app\style.css', 'start.ps1', 'start.bat')) {
            if (-not (Test-Path -LiteralPath (Join-Path $srcRoot $rel))) {
                throw "Arsivde eksik dosya: $rel"
            }
        }

        $backupRoot = Join-Path $installFull 'backup'
        New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
        $backupDir = Join-Path $backupRoot (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

        foreach ($rel in @('app', 'tools', 'start.ps1', 'start.bat')) {
            $sourcePath = Join-Path $installFull $rel
            if (Test-Path -LiteralPath $sourcePath) {
                Copy-Item -LiteralPath $sourcePath -Destination $backupDir -Recurse -Force
            }
        }
        Get-ChildItem -LiteralPath $backupRoot -Directory |
            Sort-Object Name -Descending |
            Select-Object -Skip 3 |
            ForEach-Object {
                try { Remove-Item -LiteralPath $_.FullName -Recurse -Force } catch { }
            }

        $startPath = Join-Path $installFull 'start.ps1'
        $beforeHash = Get-NormalizedHash -Path $startPath

        $appDest = Join-Path $installFull 'app'
        New-Item -ItemType Directory -Path $appDest -Force | Out-Null
        Copy-Item -Path (Join-Path $srcRoot 'app\*') -Destination $appDest -Recurse -Force

        $toolsSource = Join-Path $srcRoot 'tools'
        if (Test-Path -LiteralPath $toolsSource) {
            $toolsDest = Join-Path $installFull 'tools'
            New-Item -ItemType Directory -Path $toolsDest -Force | Out-Null
            Copy-Item -Path (Join-Path $toolsSource '*') -Destination $toolsDest -Recurse -Force
        }

        Copy-Item -LiteralPath (Join-Path $srcRoot 'start.ps1') -Destination $installFull -Force
        Copy-Item -LiteralPath (Join-Path $srcRoot 'start.bat') -Destination $installFull -Force

        $afterHash = Get-NormalizedHash -Path $startPath
        $restartRequired = [bool]($beforeHash -and $beforeHash -ne $afterHash)

        $buildInfo = [ordered]@{
            version   = 'commit-' + $remote.short
            sha       = $remote.sha
            date      = $remote.date
            message   = $remote.message
            appliedAt = (Get-Date).ToUniversalTime().ToString('o')
        }
        $buildInfo | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $installFull 'build_info.json') -Encoding UTF8

        return [pscustomobject]@{
            sha             = $remote.sha
            short           = $remote.short
            date            = $remote.date
            message         = $remote.message
            restartRequired = $restartRequired
            backup          = $backupDir
        }
    }
    finally {
        foreach ($path in @($zip, $extract)) {
            if (-not $path) { continue }
            try {
                if (Test-Path -LiteralPath $path) {
                    if ((Get-Item -LiteralPath $path).PSIsContainer) {
                        Remove-Item -LiteralPath $path -Recurse -Force
                    }
                    else {
                        Remove-Item -LiteralPath $path -Force
                    }
                }
            }
            catch { }
        }
        $script:updateRunning = $false
    }
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
$runtimeFile = Join-Path $installFull 'runtime_url.txt'
try { Set-Content -LiteralPath $runtimeFile -Value $url -Encoding ASCII -Force } catch { }

Write-Host ''
Write-Host '  Fan Modbus - yerel arayuz' -ForegroundColor Cyan
Write-Host "  $url" -ForegroundColor Green
Write-Host '  Kapatmak icin bu pencereyi kapatin.' -ForegroundColor DarkGray
Write-Host ''

if (-not $NoBrowser) {
    Start-Process $url | Out-Null
}

while ($true) {
    $client = $null
    $responded = $false
    try {
        $client = $listener.AcceptTcpClient()
        $client.ReceiveTimeout = 10000
        $client.SendTimeout = 120000
        $stream = $client.GetStream()

        $buffer = New-Object byte[] 16384
        $read = 0
        try { $read = $stream.Read($buffer, 0, $buffer.Length) } catch { $read = 0 }
        if ($read -le 0) { continue }

        $request = [Text.Encoding]::ASCII.GetString($buffer, 0, $read)
        $firstLine = ($request -split "`r`n")[0]
        $parts = $firstLine -split ' '

        $method = 'GET'
        $rawPath = '/'
        if ($parts.Length -ge 1) { $method = $parts[0] }
        if ($parts.Length -ge 2) { $rawPath = $parts[1] }

        $path = $rawPath.Split('?')[0]
        if ([string]::IsNullOrWhiteSpace($path) -or $path -eq '/') { $path = '/index.html' }

        if ($path -like '/api/*') {
            if ($path -eq '/api/version') {
                $local = Get-LocalBuildInfo
                Send-Json -Stream $stream -Code 200 -Text 'OK' -Object ([ordered]@{
                        ok      = $true
                        repo    = $Repo
                        sha     = $local.sha
                        short   = $local.short
                        date    = $local.date
                        version = $local.version
                        source  = $local.source
                    })
                $responded = $true
            }
            elseif ($path -eq '/api/update/check') {
                try {
                    $local = Get-LocalBuildInfo
                    $remote = Get-RemoteCommit
                    $available = Test-IsNewer -Local $local -Remote $remote
                    Send-Json -Stream $stream -Code 200 -Text 'OK' -Object ([ordered]@{
                            ok        = $true
                            available = $available
                            repo      = $Repo
                            local     = $local
                            remote    = $remote
                        })
                    $responded = $true
                }
                catch {
                    Send-Json -Stream $stream -Code 502 -Text 'Bad Gateway' -Object ([ordered]@{
                            ok    = $false
                            error = 'GitHub kontrolu basarisiz: ' + $_.Exception.Message
                        })
                    $responded = $true
                }
            }
            elseif ($path -eq '/api/update/apply') {
                $csrfOk = $request -match '(?im)^X-FanModbus-Update:\s*apply\s*$'
                if ($method -ne 'POST' -or -not $csrfOk) {
                    Send-Json -Stream $stream -Code 403 -Text 'Forbidden' -Object ([ordered]@{
                            ok    = $false
                            error = 'Yetkisiz istek.'
                        })
                    $responded = $true
                }
                else {
                    try {
                        $result = Invoke-UpdateApply
                        Send-Json -Stream $stream -Code 200 -Text 'OK' -Object ([ordered]@{
                                ok              = $true
                                sha             = $result.sha
                                short           = $result.short
                                date            = $result.date
                                message         = $result.message
                                restartRequired = $result.restartRequired
                            })
                        $responded = $true
                    }
                    catch {
                        Send-Json -Stream $stream -Code 500 -Text 'Internal Server Error' -Object ([ordered]@{
                                ok    = $false
                                error = 'Guncelleme uygulanamadi: ' + $_.Exception.Message
                            })
                        $responded = $true
                    }
                }
            }
            else {
                Send-Json -Stream $stream -Code 404 -Text 'Not Found' -Object ([ordered]@{
                        ok    = $false
                        error = 'Bilinmeyen API.'
                    })
                $responded = $true
            }
        }
        else {
            $rel = [Uri]::UnescapeDataString($path).TrimStart('/')
            $rel = $rel.Replace('/', $sep)
            $full = [IO.Path]::GetFullPath((Join-Path $rootFull $rel))

            $statusCode = 200
            $statusText = 'OK'
            $contentType = 'application/octet-stream'
            $body = $null

            if (-not $full.StartsWith($rootFull + $sep, [StringComparison]::OrdinalIgnoreCase)) {
                $statusCode = 403
                $statusText = 'Forbidden'
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
                $statusCode = 404
                $statusText = 'Not Found'
                $contentType = 'text/plain; charset=utf-8'
                $body = [Text.Encoding]::UTF8.GetBytes('Not found')
            }

            Send-Response -Stream $stream -Code $statusCode -Text $statusText -ContentType $contentType -Body $body
            $responded = $true
        }
    }
    catch {
        if (-not $responded) {
            try {
                Send-Response -Stream $stream -Code 500 -Text 'Internal Server Error' -ContentType 'text/plain; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes('Internal server error'))
            }
            catch { }
        }
    }
    finally {
        if ($client) { try { $client.Close() } catch { } }
    }
}
