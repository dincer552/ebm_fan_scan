param(
    [string]$Port = 'COM3',
    [int]$Baud = 19200,
    [string]$Parity = 'Even',
    [int]$StartId = 1,
    [int]$EndId = 247,
    [int]$Timeout = 150,
    [int]$Func = 3
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

function Get-Crc16At {
    param([byte[]]$Bytes, [int]$Offset, [int]$Count)
    $slice = New-Object byte[] $Count
    [Array]::Copy($Bytes, $Offset, $slice, 0, $Count)
    return (Get-Crc16 -Bytes $slice)
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

$found = @()
$sw = [System.Diagnostics.Stopwatch]::StartNew()
for ($id = $StartId; $id -le $EndId; $id++) {
    $body = [byte[]]($id, $Func, 0x00, 0x00, 0x00, 0x04)
    $crc = Get-Crc16 -Bytes $body
    $frame = [byte[]]($body + [byte]($crc -band 0xFF) + [byte](($crc -shr 8) -band 0xFF))

    $sp.DiscardInBuffer()
    $sp.Write($frame, 0, $frame.Length)

    $resp = Receive-Frame -Sp $sp -TimeoutMs $Timeout
    if ($resp.Length -ge 5 -and $resp[0] -eq $id) {
        $rxCrc = [int]$resp[$resp.Length - 2] -bor ([int]$resp[$resp.Length - 1] -shl 8)
        $calcCrc = Get-Crc16At -Bytes $resp -Offset 0 -Count ($resp.Length - 2)
        if ($rxCrc -eq $calcCrc) {
            $hex = ($resp | ForEach-Object { $_.ToString('X2') }) -join ' '
            if (($resp[1] -band 0x80) -ne 0) {
                Write-Output ("FOUND id={0} EXCEPTION code={1} rx=[{2}]" -f $id, $resp[2], $hex)
                $found += $id
            }
            else {
                $regs = @()
                for ($i = 3; $i -lt (3 + $resp[2]); $i += 2) {
                    $regs += (($resp[$i] -shl 8) -bor $resp[$i + 1])
                }
                $regHex = ($regs | ForEach-Object { '0x{0:X4}' -f $_ }) -join ' '
                Write-Output ("FOUND id={0} regs=[{1}] rx=[{2}]" -f $id, $regHex, $hex)
                $found += $id
            }
        }
        else {
            Write-Output ("CRC-FAIL id={0} rx=[{1}]" -f $id, (($resp | ForEach-Object { $_.ToString('X2') }) -join ' '))
        }
    }
    if (($id % 25) -eq 0) { Write-Output ("... scanned {0}" -f $id) }
}
$sp.Close()
$sw.Stop()
Write-Output ("DONE found={0} elapsed={1:n1}s" -f $found.Count, $sw.Elapsed.TotalSeconds)
