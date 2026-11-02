param(
    [string]$Output = 'FanModbus.exe'
)

$ErrorActionPreference = 'Stop'

$root = [IO.Path]::GetFullPath($PSScriptRoot)
$framework = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$csc = Join-Path $framework 'csc.exe'
if (-not (Test-Path -LiteralPath $csc)) {
    throw "C# derleyici bulunamadi: $csc"
}

$payload = Join-Path $root 'payload.zip'
if (Test-Path -LiteralPath $payload) {
    Remove-Item -LiteralPath $payload -Force
}

$staging = Join-Path $env:TEMP ('fanmodbus_payload_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $staging -Force | Out-Null

try {
    Copy-Item -LiteralPath (Join-Path $root 'app') -Destination $staging -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $root 'tools') -Destination $staging -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $root 'start.ps1') -Destination $staging -Force
    Copy-Item -LiteralPath (Join-Path $root 'start.bat') -Destination $staging -Force

    $sha = [string]$env:GITHUB_SHA
    if (-not $sha) {
        try { $sha = [string](& git -C $root rev-parse HEAD 2>$null).Trim() } catch { $sha = '' }
    }
    $date = [string]$env:BUILD_DATE
    if (-not $date) {
        try { $date = [string](& git -C $root show -s --format=%cI HEAD 2>$null).Trim() } catch { $date = '' }
    }
    if (-not $date) { $date = (Get-Date).ToUniversalTime().ToString('o') }

    $message = [string]$env:FANMODBUS_MESSAGE
    if ($message) { $message = (($message -split "`n")[0]).Trim() }
    if (-not $message) {
        try { $message = [string](& git -C $root log -1 --pretty=%s 2>$null).Trim() } catch { $message = '' }
    }

    $short = if ($sha) { $sha.Substring(0, [Math]::Min(7, $sha.Length)) } else { 'dev' }
    $version = [string]$env:FANMODBUS_VERSION
    if (-not $version) { $version = "commit-$short" }

    $buildInfo = [ordered]@{
        version = $version
        sha     = $sha
        date    = $date
        message = $message
        builtAt = (Get-Date).ToUniversalTime().ToString('o')
        source  = 'build'
    }
    $buildInfo | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $staging 'build_info.json') -Encoding UTF8

    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $payload -CompressionLevel Optimal -Force
}
finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}

$exe = Join-Path $root $Output
if (Test-Path -LiteralPath $exe) {
    Remove-Item -LiteralPath $exe -Force
}

& $csc /nologo /target:winexe /platform:anycpu "/out:$exe" `
    "/resource:$payload,payload.zip" `
    "/reference:$framework\System.dll" `
    "/reference:$framework\System.Core.dll" `
    "/reference:$framework\System.Drawing.dll" `
    "/reference:$framework\System.Windows.Forms.dll" `
    "/reference:$framework\System.IO.Compression.dll" `
    "/reference:$framework\System.IO.Compression.FileSystem.dll" `
    (Join-Path $root 'launcher.cs')

if ($LASTEXITCODE -ne 0) {
    throw "C# derleme basarisiz (csc exit $LASTEXITCODE)."
}

Remove-Item -LiteralPath $payload -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host "EXE hazir: $exe" -ForegroundColor Green
Write-Host ("Boyut: {0:N0} byte" -f (Get-Item -LiteralPath $exe).Length)
