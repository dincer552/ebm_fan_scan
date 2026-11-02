param(
    [string]$Port = 'COM3',
    [int]$Baud = 19200,
    [string]$Parity = 'Even',
    [int]$Id = 1,
    [int]$Func = 3,
    [int]$Start = 0,
    [int]$End = 31,
    [int]$Count = 1,
    [int]$Timeout = 250
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
            if (($buf[1] -band 0x80) -eq 0) { $expected = 3 + $buf[2] + 2 }
            if ($buf.Count -ge $expected) { break }
        }
        Start-Sleep -Milliseconds 3
    }
    return ,$buf.ToArray()
}

$sp = New-Object System.IO.Ports.SerialPort($Port, $Baud, [System.IO.Ports.Parity]::$Parity, 8, [System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 50
$sp.WriteTimeout = 1000
$sp.Open()
Write-Output ("PORT {0} {1} {2}8{3} opened" -f $Port, $Baud, $Parity, 1)
Write-Output ("ID {0} FC{1} count={2} addresses 0x{3:X4}-0x{4:X4}" -f $Id, $Func, $Count, $Start, $End)

$valid = @()
for ($addr = $Start; $addr -le $End; $addr++) {
    $body = [byte[]]($Id, $Func, (($addr -shr 8) -band 0xFF), ($addr -band 0xFF), (($Count -shr 8) -band 0xFF), ($Count -band 0xFF))
    $crc = Get-Crc16 -Bytes $body
    $frame = [byte[]]($body + [byte]($crc -band 0xFF) + [byte](($crc -shr 8) -band 0xFF))

    $sp.DiscardInBuffer()
    $sp.Write($frame, 0, $frame.Length)
    $resp = Receive-Frame -Sp $sp -TimeoutMs $Timeout

    if ($resp.Length -lt 5 -or $resp[0] -ne $Id) {
        Write-Output ("---  0x{0:X4} : yanit yok" -f $addr)
        continue
    }

    $rxCrc = [int]$resp[$resp.Length - 2] -bor ([int]$resp[$resp.Length - 1] -shl 8)
    $calcCrc = Get-Crc16 -Bytes ([byte[]]$resp[0..($resp.Length - 3)])
    if ($rxCrc -ne $calcCrc) {
        Write-Output ("---  0x{0:X4} : CRC hatasi" -f $addr)
        continue
    }

    if ($resp[1] -band 0x80) {
        $code = $resp[2]
        if ($code -ne 2) {
            Write-Output ("EXC  0x{0:X4} : exception {1}" -f $addr, $code)
            $valid += [pscustomobject]@{ Address = $addr; Type = 'exception'; Code = $code }
        }
        continue
    }

    $regs = @()
    for ($i = 3; $i -lt (3 + $resp[2]); $i += 2) {
        $regs += (([int]$resp[$i] -shl 8) -bor [int]$resp[$i + 1])
    }
    $regHex = ($regs | ForEach-Object { '0x{0:X4}' -f $_ }) -join ' '
    Write-Output ("OK   0x{0:X4} : {1}" -f $addr, $regHex)
    $valid += [pscustomobject]@{ Address = $addr; Type = 'ok'; Values = $regs }
}

$sp.Close()
Write-Output ("DONE valid={0}" -f $valid.Count)
$valid | Format-Table -AutoSize
