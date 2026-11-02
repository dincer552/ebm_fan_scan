param(
    [string]$Port = 'COM3',
    [int]$Timeout = 300
)

$ErrorActionPreference = 'Continue'

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

function Probe {
    param($Sp, [int]$Id, [int]$Func, [int]$TimeoutMs)
    $body = [byte[]]($Id, $Func, 0x00, 0x00, 0x00, 0x02)
    $crc = Get-Crc16 -Bytes $body
    $frame = [byte[]]($body + [byte]($crc -band 0xFF) + [byte](($crc -shr 8) -band 0xFF))
    $sp.DiscardInBuffer()
    $sp.Write($frame, 0, $frame.Length)
    $buf = New-Object System.Collections.Generic.List[byte]
    $deadline = [DateTime]::Now.AddMilliseconds($TimeoutMs)
    while ([DateTime]::Now -lt $deadline) {
        try {
            if ($sp.BytesToRead -gt 0) { $buf.Add([byte]$sp.ReadByte()); continue }
        } catch { break }
        if ($buf.Count -ge 3) {
            $expected = 5
            if (($buf[1] -band 0x80) -eq 0) { $expected = 3 + $buf[2] + 2 }
            if ($buf.Count -ge $expected) { break }
        }
        Start-Sleep -Milliseconds 3
    }
    if ($buf.Count -lt 5) { return $null }
    $resp = $buf.ToArray()
    $rxCrc = $resp[$resp.Length - 2] -bor ($resp[$resp.Length - 1] -shl 8)
    $calcCrc = Get-Crc16 -Bytes ([byte[]]$resp[0..($resp.Length - 3)])
    if ($rxCrc -ne $calcCrc) { return $null }
    return $resp
}

$bauds = @(9600, 19200, 38400, 57600, 115200)
$parities = @('Even', 'None', 'Odd')
$ids = @(1, 2, 3, 4, 5)
$funcs = @(3, 4)
$found = @()

foreach ($b in $bauds) {
    foreach ($p in $parities) {
        $sp = New-Object System.IO.Ports.SerialPort($Port, $b, [System.IO.Ports.Parity]::$p, 8, [System.IO.Ports.StopBits]::One)
        $sp.ReadTimeout = 50
        $sp.WriteTimeout = 1000
        try { $sp.Open() } catch {
            Write-Output ("OPEN-FAIL {0} {1}: {2}" -f $b, $p, $_.Exception.Message)
            continue
        }
        foreach ($id in $ids) {
            foreach ($f in $funcs) {
                $resp = Probe -Sp $sp -Id $id -Func $f -TimeoutMs $Timeout
                if ($resp) {
                    $hex = ($resp | ForEach-Object { $_.ToString('X2') }) -join ' '
                    Write-Output ("FOUND {0} {1}8{2} id={3} func={4} rx=[{5}]" -f $b, $p, 1, $id, $f, $hex)
                    $found += "$b/$p/id$id/f$f"
                }
            }
        }
        $sp.Close()
        $sp.Dispose()
        Write-Output ("tried {0} {1}" -f $b, $p)
    }
}

if ($found.Count -eq 0) { Write-Output 'NO-DEVICE' } else { Write-Output ("FOUND-COUNT {0}" -f $found.Count) }
