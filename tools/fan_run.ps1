param(
    [string]$Port = 'COM3',
    [int]$Baud = 19200,
    [string]$Parity = 'Even',
    [int]$Id = 1,
    [int]$Setpoint = 3200,
    [int]$Mode = -1,
    [int]$Seconds = 12,
    [int]$Timeout = 500,
    [switch]$Stop
)

$ErrorActionPreference = 'Stop'

function Get-Crc16 {
    param([byte[]]$Bytes)
    $crc = 0xFFFF
    foreach ($b in $Bytes) {
        $crc = $crc -bxor $b
        for ($i = 0; $i -lt 8; $i++) {
            if ($crc -band 1) { $crc = ($crc -shr 1) -bxor 0xA001 }
            else { $crc = $crc -shr 1 }
        }
    }
    return ($crc -band 0xFFFF)
}

function Build-Frame {
    param([byte[]]$Body)
    $crc = Get-Crc16 -Bytes $Body
    return [byte[]]($Body + [byte]($crc -band 0xFF) + [byte](($crc -shr 8) -band 0xFF))
}

function Receive-Frame {
    param($Sp, [int]$TimeoutMs)
    $buf = New-Object System.Collections.Generic.List[byte]
    $deadline = [DateTime]::Now.AddMilliseconds($TimeoutMs)
    while ([DateTime]::Now -lt $deadline) {
        if ($Sp.BytesToRead -gt 0) {
            $buf.Add([byte]$Sp.ReadByte())
            continue
        }
        if ($buf.Count -ge 3) {
            $expected = 5
            if (($buf[1] -band 0x80) -eq 0) {
                if ($buf[1] -eq 0x10 -or $buf[1] -eq 0x06) { $expected = 8 }
                else { $expected = 3 + $buf[2] + 2 }
            }
            if ($buf.Count -ge $expected) { break }
        }
        Start-Sleep -Milliseconds 3
    }
    return ,$buf.ToArray()
}

function Describe {
    param([byte[]]$Frame)
    if ($null -eq $Frame -or $Frame.Length -eq 0) { return 'yanit yok' }
    $hex = ($Frame | ForEach-Object { $_.ToString('X2') }) -join ' '
    if ($Frame.Length -ge 2 -and ($Frame[1] -band 0x80)) {
        return ('EXCEPTION {0} [{1}]' -f $Frame[2], $hex)
    }
    return ('OK [{0}]' -f $hex)
}

function Transact {
    param($Sp, [byte[]]$Body)
    $frame = Build-Frame -Body $Body
    $Sp.DiscardInBuffer()
    $Sp.Write($frame, 0, $frame.Length)
    return (Receive-Frame -Sp $Sp -TimeoutMs $Timeout)
}

function Read-Holding {
    param($Sp, [int]$Address)
    $resp = Transact -Sp $Sp -Body ([byte[]]($Id, 3, (($Address -shr 8) -band 0xFF), ($Address -band 0xFF), 0, 1))
    if ($resp.Length -lt 7 -or ($resp[1] -band 0x80)) { return $null }
    return ((([int]$resp[3]) -shl 8) -bor [int]$resp[4])
}

function Read-Input {
    param($Sp, [int]$Address)
    $resp = Transact -Sp $Sp -Body ([byte[]]($Id, 4, (($Address -shr 8) -band 0xFF), ($Address -band 0xFF), 0, 1))
    if ($resp.Length -lt 7 -or ($resp[1] -band 0x80)) { return $null }
    return ((([int]$resp[3]) -shl 8) -bor [int]$resp[4])
}

function Write-Holding {
    param($Sp, [int]$Address, [int]$Value)
    $resp = Transact -Sp $Sp -Body ([byte[]]($Id, 6, (($Address -shr 8) -band 0xFF), ($Address -band 0xFF), (($Value -shr 8) -band 0xFF), ($Value -band 0xFF)))
    return (Describe -Frame $resp)
}

$D001 = 0xD001
$D000 = 0xD000
$D010 = 0xD010
$D019 = 0xD019
$D106 = 0xD106
$D107 = 0xD107

$sp = New-Object System.IO.Ports.SerialPort($Port, $Baud, [System.IO.Ports.Parity]::$Parity, 8, [System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 50
$sp.WriteTimeout = 1000
$sp.Open()

try {
    $sp.DiscardInBuffer()

    if ($Stop) {
        Write-Output ("D001 <- 0 : {0}" -f (Write-Holding -Sp $sp -Address $D001 -Value 0))
        Start-Sleep -Seconds 2
        $actual = Read-Input -Sp $sp -Address $D010
        Write-Output ("D010 actual speed = {0} (0 = durdu)" -f $actual)
        return
    }

    $source = Read-Holding -Sp $sp -Address $D101
    $mode1 = Read-Holding -Sp $sp -Address $D106
    $mode2 = Read-Holding -Sp $sp -Address $D107
    $maxSpeed = Read-Holding -Sp $sp -Address $D119
    if (-not $maxSpeed) { $maxSpeed = 3000 }
    Write-Output ("Set value source D101={0}, mode D106={1}/D107={2}, max speed D119={3}" -f $source, $mode1, $mode2, $maxSpeed)

    if ($Mode -ge 0) {
        Write-Output ("D106 <- {0} : {1}" -f $Mode, (Write-Holding -Sp $sp -Address $D106 -Value $Mode))
        Write-Output ("D107 <- {0} : {1}" -f $Mode, (Write-Holding -Sp $sp -Address $D107 -Value $Mode))
        Write-Output ("D000 <- 1 (AS reset) : {0}" -f (Write-Holding -Sp $sp -Address $D000 -Value 1))
        Start-Sleep -Seconds 2
    }

    Write-Output ("D001 <- {0} : {1}" -f $Setpoint, (Write-Holding -Sp $sp -Address $D001 -Value $Setpoint))

    $deadline = [DateTime]::Now.AddSeconds($Seconds)
    while ([DateTime]::Now -lt $deadline) {
        $actual = Read-Input -Sp $sp -Address $D010
        $setpointRead = Read-Holding -Sp $sp -Address $D001
        $rpm = if ($null -ne $actual) { [math]::Round($actual * $maxSpeed / 64000) } else { '?' }
        $actualText = if ($null -ne $actual) { '0x{0:X4}' -f $actual } else { 'yok' }
        Write-Output ("t={0,3:N1}s  setpoint={1,5}  actual={2} ({3,5} rpm)" -f ($Seconds - ($deadline - [DateTime]::Now).TotalSeconds), $setpointRead, $actualText, $rpm)
        Start-Sleep -Milliseconds 700
    }
} finally {
    $sp.Close()
}
