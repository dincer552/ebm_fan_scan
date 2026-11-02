param(
    [string]$Port = 'COM3',
    [int]$Baud = 19200,
    [string]$Parity = 'Even',
    [int]$Id = 1,
    [int[]]$Words = @(25968, 19744, 17731),
    [int]$TestAddress = 53509,
    [int]$Timeout = 500
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

$sp = New-Object System.IO.Ports.SerialPort($Port, $Baud, [System.IO.Ports.Parity]::$Parity, 8, [System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 50
$sp.WriteTimeout = 1000
$sp.Open()
Write-Output ("PORT {0} {1} {2}8{3}" -f $Port, $Baud, $Parity, 1)
Write-Output ("Test register 0x{0:X4}, password words: {1}" -f $TestAddress, (($Words | ForEach-Object { '0x{0:X4}' -f $_ }) -join ' '))

# Read current test register value
$read = Transact -Sp $sp -Body ([byte[]]($Id, 3, (($TestAddress -shr 8) -band 0xFF), ($TestAddress -band 0xFF), 0, 1))
Write-Output ("READ  -> {0}" -f (Describe -Frame $read))
if ($read.Length -lt 5 -or ($read[1] -band 0x80)) { $sp.Close(); exit 1 }
$current = ([int]$read[3] -shl 8) -bor [int]$read[4]
Write-Output ("Current value = 0x{0:X4} ({1})" -f $current, $current)

# Write without password
$noPass = Transact -Sp $sp -Body ([byte[]]($Id, 6, (($TestAddress -shr 8) -band 0xFF), ($TestAddress -band 0xFF), (($current -shr 8) -band 0xFF), ($current -band 0xFF)))
Write-Output ("WRITE WITHOUT PASSWORD -> {0}" -f (Describe -Frame $noPass))

# Send password candidate
$data = @()
foreach ($w in $Words) { $data += [byte](($w -shr 8) -band 0xFF); $data += [byte]($w -band 0xFF) }
$passwordBody = [byte[]]($Id, 0x10, 0xD0, 0x02, 0x00, 0x03, 0x06) + [byte[]]$data
$passwordResp = Transact -Sp $sp -Body $passwordBody
Write-Output ("PASSWORD WRITE -> {0}" -f (Describe -Frame $passwordResp))

# Write same value again
$afterPass = Transact -Sp $sp -Body ([byte[]]($Id, 6, (($TestAddress -shr 8) -band 0xFF), ($TestAddress -band 0xFF), (($current -shr 8) -band 0xFF), ($current -band 0xFF)))
Write-Output ("WRITE AFTER PASSWORD -> {0}" -f (Describe -Frame $afterPass))

if ($afterPass.Length -ge 2 -and -not ($afterPass[1] -band 0x80)) {
    Write-Output 'PASSWORD ACCEPTED'
} else {
    Write-Output 'PASSWORD REJECTED'
}

$sp.Close()
