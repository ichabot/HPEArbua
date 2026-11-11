<#
.SYNOPSIS
    Fragt Switche per SNMP (LLDP-MIB) ab und baut daraus einen Netzwerkplan.

.DESCRIPTION
    Keine Module, keine Installation noetig - SNMP v2c/v1 ist direkt im Skript umgesetzt.
    Laeuft unter Windows PowerShell 5.1 und PowerShell 7.

    Ablauf:
      1. Alle Zieladressen per SNMP anpingen (sysName/sysDescr)
      2. Bei jedem antwortenden Geraet die LLDP-Tabellen auslesen
      3. Per LLDP gemeldete Nachbar-Switche automatisch mit abfragen (abschaltbar)
      4. Links zusammenfuehren (beide Seiten eines Links = ein Eintrag)
      5. Je Link Geschwindigkeit und Medium bestimmen (z. B. "10G LWL", "10G DAC", "1G Kupfer")
      6. MAC-Tabellen der Switche auswerten: jede MAC-Adresse genau einem Switch-Port zuordnen,
         SNMP-Geraete ohne LLDP (Server, NAS, USV ...) an ihren Port haengen, Ports und
         Endgeraete je Switch zaehlen

    Ausgabe im Zielordner:
      <Name>.html          interaktiver Netzplan (im Browser oeffnen)
      <Name>.drawio        derselbe Plan zum Nachbearbeiten in draw.io / diagrams.net
      <Name>_links.csv     Switch A / Port A / Port B / Switch B
      <Name>_devices.csv   alle gefundenen Geraete
      <Name>_switches.csv  je Switch: Ports gesamt/aktiv, Endgeraete (MAC-Adressen)
      <Name>_endgeraete.csv  jede MAC-Adresse mit Switch, Port, IP und Name

.PARAMETER Target
    IP-Adressen, Hostnamen oder Netze in CIDR-Schreibweise. Mehrere mit Komma.

.PARAMETER Community
    SNMP-Community. Mehrere werden der Reihe nach probiert. Standard: public

.PARAMETER NoCrawl
    Nur die angegebenen Ziele abfragen, per LLDP gefundene Nachbar-Switche nicht nachziehen.

.PARAMETER IncludeEndpoints
    Access Points, Telefone und sonstige LLDP-Nachbarn auch in die draw.io-Datei aufnehmen.
    (Im HTML-Plan sind sie immer enthalten und dort ein-/ausblendbar.)

.PARAMETER NoMacTable
    MAC-Tabellen nicht auswerten (schneller, nur LLDP-Topologie).

.PARAMETER V1
    SNMP v1 statt v2c verwenden (fuer sehr alte Geraete).

.EXAMPLE
    .\Get-LldpTopology.ps1 192.168.10.0/24

.EXAMPLE
    .\Get-LldpTopology.ps1 10.0.0.1 -Community public,kunde123 -Name Kunde-XY -OutDir C:\Temp
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string[]]$Target,
    [string[]]$Community = @('public'),
    [string]$OutDir = (Get-Location).Path,
    [string]$Name = 'netzplan',
    [int]$TimeoutMs = 1500,
    [int]$Retries = 1,
    [int]$Port = 161,
    [switch]$V1,
    [switch]$NoCrawl,
    [switch]$IncludeEndpoints,
    [switch]$NoMacTable
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# BER / SNMP
# ---------------------------------------------------------------------------
$script:SnmpVersion = 1
if ($V1) { $script:SnmpVersion = 0 }
$script:ReqId = Get-Random -Minimum 1000 -Maximum 1000000
$script:NoBulk = @{}

function ConvertTo-BerLength([int]$Len) {
    if ($Len -lt 128) { return , ([byte[]]@($Len)) }
    $b = New-Object 'System.Collections.Generic.List[byte]'
    while ($Len -gt 0) { $b.Insert(0, [byte]($Len -band 0xFF)); $Len = $Len -shr 8 }
    $b.Insert(0, [byte](0x80 -bor $b.Count))
    return , $b.ToArray()
}

function New-Tlv([byte]$Tag, [byte[]]$Content) {
    if ($null -eq $Content) { $Content = [byte[]]@() }
    $l = New-Object 'System.Collections.Generic.List[byte]'
    $l.Add($Tag)
    $l.AddRange([byte[]](ConvertTo-BerLength $Content.Length))
    $l.AddRange($Content)
    return , $l.ToArray()
}

function ConvertTo-BerInt([long]$Value) {
    $b = New-Object 'System.Collections.Generic.List[byte]'
    $v = $Value
    do { $b.Insert(0, [byte]($v -band 0xFF)); $v = $v -shr 8 } while ($v -gt 0)
    if ($b[0] -band 0x80) { $b.Insert(0, [byte]0) }
    return , (New-Tlv 0x02 $b.ToArray())
}

function ConvertTo-BerOid([string]$Oid) {
    $p = @($Oid.Trim('.').Split('.') | ForEach-Object { [long]$_ })
    $l = New-Object 'System.Collections.Generic.List[byte]'
    $l.Add([byte](40 * $p[0] + $p[1]))
    for ($i = 2; $i -lt $p.Count; $i++) {
        $v = $p[$i]
        $t = New-Object 'System.Collections.Generic.List[byte]'
        $t.Add([byte]($v -band 0x7F)); $v = $v -shr 7
        while ($v -gt 0) { $t.Insert(0, [byte](($v -band 0x7F) -bor 0x80)); $v = $v -shr 7 }
        $l.AddRange($t)
    }
    return , (New-Tlv 0x06 $l.ToArray())
}

function New-SnmpRequest([byte]$PduType, [int]$ReqId, [string]$Comm, [string[]]$Oids, [int]$MaxRep) {
    $vbs = New-Object 'System.Collections.Generic.List[byte]'
    foreach ($o in $Oids) {
        $vb = New-Object 'System.Collections.Generic.List[byte]'
        $vb.AddRange([byte[]](ConvertTo-BerOid $o))
        $vb.Add([byte]0x05); $vb.Add([byte]0x00)
        $vbs.AddRange([byte[]](New-Tlv 0x30 $vb.ToArray()))
    }
    $pdu = New-Object 'System.Collections.Generic.List[byte]'
    $pdu.AddRange([byte[]](ConvertTo-BerInt $ReqId))
    $pdu.AddRange([byte[]](ConvertTo-BerInt 0))
    $pdu.AddRange([byte[]](ConvertTo-BerInt $MaxRep))
    $pdu.AddRange([byte[]](New-Tlv 0x30 $vbs.ToArray()))
    $msg = New-Object 'System.Collections.Generic.List[byte]'
    $msg.AddRange([byte[]](ConvertTo-BerInt $script:SnmpVersion))
    $msg.AddRange([byte[]](New-Tlv 0x04 ([System.Text.Encoding]::ASCII.GetBytes($Comm))))
    $msg.AddRange([byte[]](New-Tlv $PduType $pdu.ToArray()))
    return , (New-Tlv 0x30 $msg.ToArray())
}

function Read-BerTlv([byte[]]$Buf, [int]$Pos) {
    $tag = $Buf[$Pos]; $Pos++
    $len = [int]$Buf[$Pos]; $Pos++
    if ($len -band 0x80) {
        $n = $len -band 0x7F; $len = 0
        for ($i = 0; $i -lt $n; $i++) { $len = ($len -shl 8) -bor $Buf[$Pos]; $Pos++ }
    }
    if ($Pos + $len -gt $Buf.Length) { throw 'BER: Laenge ausserhalb des Pakets' }
    return @{ Tag = $tag; Start = $Pos; Len = $len; Next = $Pos + $len }
}

function ConvertTo-Int([byte[]]$B) {
    if ($null -eq $B -or $B.Length -eq 0) { return 0 }
    [long]$v = 0
    if ($B[0] -band 0x80) { $v = -1 }
    foreach ($x in $B) { $v = ($v -shl 8) -bor $x }
    return $v
}

function ConvertTo-UInt([byte[]]$B) {
    if ($null -eq $B -or $B.Length -eq 0) { return 0 }
    [long]$v = 0
    foreach ($x in $B) { $v = ($v -shl 8) -bor $x }
    return $v
}

function ConvertFrom-BerOid([byte[]]$Buf, [int]$Start, [int]$Len) {
    if ($Len -lt 1) { return '' }
    $sb = New-Object System.Text.StringBuilder
    $first = [int]$Buf[$Start]
    if ($first -lt 40) { [void]$sb.Append('0.').Append($first) }
    elseif ($first -lt 80) { [void]$sb.Append('1.').Append($first - 40) }
    else { [void]$sb.Append('2.').Append($first - 80) }
    [long]$v = 0
    for ($i = $Start + 1; $i -lt $Start + $Len; $i++) {
        $b = $Buf[$i]
        $v = ($v -shl 7) -bor ($b -band 0x7F)
        if (-not ($b -band 0x80)) { [void]$sb.Append('.').Append($v); $v = 0 }
    }
    return $sb.ToString()
}

function ConvertFrom-SnmpResponse([byte[]]$Buf) {
    $m = Read-BerTlv $Buf 0
    $v = Read-BerTlv $Buf $m.Start
    $c = Read-BerTlv $Buf $v.Next
    $p = Read-BerTlv $Buf $c.Next
    $r = Read-BerTlv $Buf $p.Start
    $e = Read-BerTlv $Buf $r.Next
    $x = Read-BerTlv $Buf $e.Next
    $l = Read-BerTlv $Buf $x.Next
    $rid = New-Object byte[] $r.Len; [Array]::Copy($Buf, $r.Start, $rid, 0, $r.Len)
    $err = New-Object byte[] $e.Len; [Array]::Copy($Buf, $e.Start, $err, 0, $e.Len)
    $vbs = New-Object System.Collections.ArrayList
    $pos = $l.Start
    while ($pos -lt $l.Next) {
        $vb = Read-BerTlv $Buf $pos
        $o = Read-BerTlv $Buf $vb.Start
        $val = Read-BerTlv $Buf $o.Next
        $bytes = New-Object byte[] $val.Len
        if ($val.Len -gt 0) { [Array]::Copy($Buf, $val.Start, $bytes, 0, $val.Len) }
        [void]$vbs.Add([pscustomobject]@{
                Oid   = (ConvertFrom-BerOid $Buf $o.Start $o.Len)
                Tag   = [int]$val.Tag
                Bytes = $bytes
            })
        $pos = $vb.Next
    }
    return @{ PduType = [int]$p.Tag; ReqId = (ConvertTo-Int $rid); Error = (ConvertTo-Int $err); VarBinds = $vbs }
}

$script:Udp = New-Object System.Net.Sockets.UdpClient (New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Any, 0))
$script:Udp.Client.ReceiveBufferSize = 1048576
# Windows: ICMP "Port unreachable" darf den Socket nicht mit ConnectionReset stoeren
try { [void]$script:Udp.Client.IOControl(-1744830452, [byte[]](0, 0, 0, 0), $null) } catch { }

function Invoke-Snmp([string]$Ip, [string]$Comm, [int]$PduType, [string[]]$Oids, [int]$MaxRep) {
    $script:ReqId = ($script:ReqId + 1) % 2000000000
    $id = $script:ReqId
    $req = New-SnmpRequest ([byte]$PduType) $id $Comm $Oids $MaxRep
    $ep = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse($Ip), $Port)
    for ($try = 0; $try -le $Retries; $try++) {
        [void]$script:Udp.Send($req, $req.Length, $ep)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
            $left = [int]($TimeoutMs - $sw.ElapsedMilliseconds)
            if ($left -lt 1) { break }
            $script:Udp.Client.ReceiveTimeout = $left
            $buf = $null
            try {
                $rep = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Any, 0)
                $buf = $script:Udp.Receive([ref]$rep)
            }
            catch { continue }
            $r = $null
            try { $r = ConvertFrom-SnmpResponse $buf } catch { continue }
            if ($r.ReqId -eq $id) { return $r }
        }
    }
    return $null
}

function Get-SnmpWalk([string]$Ip, [string]$Comm, [string]$Base) {
    $res = New-Object System.Collections.ArrayList
    $prefix = $Base + '.'
    $cur = $Base
    while ($res.Count -lt 50000) {
        $r = $null
        if (-not $V1 -and -not $script:NoBulk.ContainsKey($Ip)) {
            $r = Invoke-Snmp $Ip $Comm 0xA5 @($cur) 20
            if ($null -eq $r -or $r.Error -ne 0) { $script:NoBulk[$Ip] = $true; $r = $null }
        }
        if ($null -eq $r) { $r = Invoke-Snmp $Ip $Comm 0xA1 @($cur) 0 }
        if ($null -eq $r -or $r.Error -ne 0 -or $r.VarBinds.Count -eq 0) { break }
        $done = $false
        foreach ($vb in $r.VarBinds) {
            if ($vb.Tag -ge 0x80 -and $vb.Tag -le 0x82) { $done = $true; break }
            if (-not $vb.Oid.StartsWith($prefix)) { $done = $true; break }
            if ($vb.Oid -eq $cur) { $done = $true; break }
            [void]$res.Add($vb)
            $cur = $vb.Oid
        }
        if ($done) { break }
    }
    return , $res
}

# Walk als Tabelle: OID-Rest hinter der Basis -> VarBind
$script:WalkCache = @{}
function Get-WalkTable([string]$Ip, [string]$Comm, [string]$Base) {
    $ck = $Ip + '|' + $Base
    if ($script:WalkCache.ContainsKey($ck)) { return $script:WalkCache[$ck] }
    $t = @{}
    $len = $Base.Length + 1
    foreach ($vb in (Get-SnmpWalk $Ip $Comm $Base)) { $t[$vb.Oid.Substring($len)] = $vb }
    $script:WalkCache[$ck] = $t
    return $t
}

# Mehrere Einzelwerte per GET holen (in Bloecken), OID -> VarBind
function Get-SnmpValues([string]$Ip, [string]$Comm, [string[]]$Oids) {
    $out = @{}
    for ($i = 0; $i -lt $Oids.Count; $i += 8) {
        $chunk = @($Oids[$i..([math]::Min($i + 7, $Oids.Count - 1))])
        $r = Invoke-Snmp $Ip $Comm 0xA0 $chunk 0
        if ($null -eq $r) { continue }
        if ($r.Error -eq 0) {
            foreach ($vb in $r.VarBinds) { if ($vb.Tag -lt 0x80) { $out[$vb.Oid] = $vb } }
        }
        elseif ($chunk.Count -gt 1) {
            # SNMP v1 lehnt den ganzen Block ab, wenn ein Wert fehlt -> einzeln holen
            foreach ($o in $chunk) {
                $r1 = Invoke-Snmp $Ip $Comm 0xA0 @($o) 0
                if ($null -ne $r1 -and $r1.Error -eq 0) {
                    foreach ($vb in $r1.VarBinds) { if ($vb.Tag -lt 0x80) { $out[$vb.Oid] = $vb } }
                }
            }
        }
    }
    return $out
}

# Schickt an alle Adressen gleichzeitig eine sysName/sysDescr-Abfrage und sammelt die Antworten
function Find-SnmpHosts([string[]]$Ips) {
    $found = @{}
    $pending = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($i in $Ips) { [void]$pending.Add($i) }
    foreach ($comm in $Community) {
        for ($try = 0; $try -le $Retries; $try++) {
            if ($pending.Count -eq 0) { break }
            $script:ReqId = ($script:ReqId + 1) % 2000000000
            $req = New-SnmpRequest ([byte]0xA0) $script:ReqId $comm @('1.3.6.1.2.1.1.5.0', '1.3.6.1.2.1.1.1.0') 0
            $n = 0
            foreach ($ip in @($pending)) {
                $ep = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse($ip), $Port)
                try { [void]$script:Udp.Send($req, $req.Length, $ep) } catch { }
                $n++
                if ($n % 64 -eq 0) { Start-Sleep -Milliseconds 15 }
            }
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            while ($sw.ElapsedMilliseconds -lt $TimeoutMs -and $pending.Count -gt 0) {
                $left = [int]($TimeoutMs - $sw.ElapsedMilliseconds)
                if ($left -lt 1) { break }
                $script:Udp.Client.ReceiveTimeout = $left
                $buf = $null
                $rep = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Any, 0)
                try { $buf = $script:Udp.Receive([ref]$rep) } catch { continue }
                $r = $null
                try { $r = ConvertFrom-SnmpResponse $buf } catch { continue }
                $src = $rep.Address.ToString()
                if ($r.Error -ne 0 -or -not $pending.Contains($src)) { continue }
                $sysName = ''; $sysDescr = ''
                foreach ($vb in $r.VarBinds) {
                    if ($vb.Tag -ne 0x04) { continue }
                    if ($vb.Oid -eq '1.3.6.1.2.1.1.5.0') { $sysName = ConvertTo-Text $vb.Bytes }
                    if ($vb.Oid -eq '1.3.6.1.2.1.1.1.0') { $sysDescr = ConvertTo-Text $vb.Bytes }
                }
                $found[$src] = @{ Community = $comm; SysName = $sysName; SysDescr = $sysDescr }
                [void]$pending.Remove($src)
            }
        }
    }
    return $found
}

# ---------------------------------------------------------------------------
# Hilfsfunktionen
# ---------------------------------------------------------------------------
function ConvertTo-Hex([byte[]]$B) {
    if ($null -eq $B -or $B.Length -eq 0) { return '' }
    return (($B | ForEach-Object { $_.ToString('x2') }) -join ':')
}

function Test-Printable([byte[]]$B) {
    if ($null -eq $B -or $B.Length -eq 0) { return $false }
    foreach ($x in $B) { if ($x -lt 0x20 -or $x -gt 0x7E) { return $false } }
    return $true
}

function ConvertTo-Text([byte[]]$B) {
    if ($null -eq $B -or $B.Length -eq 0) { return '' }
    $n = $B.Length
    while ($n -gt 0 -and $B[$n - 1] -eq 0) { $n-- }
    if ($n -eq 0) { return '' }
    $s = [System.Text.Encoding]::UTF8.GetString($B, 0, $n)
    if ($s -match '[\x00-\x08\x0B\x0C\x0E-\x1F]') { return (ConvertTo-Hex $B) }
    return ($s -replace '\s+', ' ').Trim()
}

# LLDP-ID (Chassis oder Port) je nach Subtype lesbar machen
function Format-LldpId([int]$Subtype, [byte[]]$B, [bool]$IsChassis) {
    if ($null -eq $B -or $B.Length -eq 0) { return '' }
    $macType = 3; $netType = 4
    if ($IsChassis) { $macType = 4; $netType = 5 }
    if ($Subtype -eq $macType -and $B.Length -eq 6) { return (ConvertTo-Hex $B) }
    if ($Subtype -eq $netType -and $B.Length -eq 5 -and $B[0] -eq 1) { return ('{0}.{1}.{2}.{3}' -f $B[1], $B[2], $B[3], $B[4]) }
    if ($B.Length -eq 6 -and -not (Test-Printable $B)) { return (ConvertTo-Hex $B) }
    $t = ConvertTo-Text $B
    $h = ($t -replace '[:\-\. ]', '')
    if ($Subtype -eq $macType -and $h -match '^[0-9a-fA-F]{12}$') {
        return ((($h.ToLower() -split '(..)') | Where-Object { $_ }) -join ':')
    }
    return $t
}

function Get-PortLabel([int]$Subtype, [byte[]]$IdBytes, [string]$Desc) {
    $id = Format-LldpId $Subtype $IdBytes $false
    $lbl = $id
    if ($Subtype -eq 3 -or $Subtype -eq 4 -or -not $id) {
        if ($Desc) { $lbl = $Desc }
    }
    elseif ($id -match '^\d+$' -and $Desc -and $Desc -ne $id -and $Desc.Length -le 28) {
        # "F2" bei ID 162 oder "Gi1/0/9" bei ID 9 ist der Portname; Freitext bekommt die ID dazu
        if ($Desc -match ('(^|\D)' + $id + '$') -or $Desc -notmatch '\s') { $lbl = $Desc } else { $lbl = "$Desc [$id]" }
    }
    return (Format-PortName $lbl)
}

function Format-PortName([string]$n) {
    $n = $n -replace '^(Ten-?GigabitEthernet|TenGigE)', 'Te' -replace '^GigabitEthernet', 'Gi' -replace '^FastEthernet', 'Fa'
    if ($n.Length -gt 40) { $n = $n.Substring(0, 39) + '~' }
    return $n
}

function Get-NodeType([byte[]]$Caps, [bool]$Scanned) {
    $c = 0
    if ($null -ne $Caps -and $Caps.Length -gt 0) { $c = [int]$Caps[0] }
    if ($c -band 0x04) { return 'phone' }
    if ($c -band 0x10) { return 'ap' }
    if ($c -band 0x20) { return 'switch' }
    if ($c -band 0x08) { return 'router' }
    if ($Scanned) { return '' }
    return 'other'
}

function Test-Big($n) { return ($n.Type -eq 'switch' -or $n.Type -eq 'router') }

function Get-SortKey([string]$s) {
    return [regex]::Replace($s, '\d+', { param($m) $m.Value.PadLeft(6, '0') })
}

# ---------------------------------------------------------------------------
# Geschwindigkeit und Medium eines Ports
# ---------------------------------------------------------------------------
# MAU-Typen nach IANA-MAU-MIB (dot3MauType, Stand 2017-04-10). Klassen:
# kupfer = Twisted Pair, lwl = Glasfaser, dac = Twinax/Direct Attach,
# sfp = steckbares Modul mit unbekanntem Medium, bp = Backplane
$script:MauTable = @{}
function Add-Mau([string]$MauName, [string]$Class, [int[]]$Nums) {
    foreach ($n in $Nums) { $script:MauTable[$n] = @($MauName, $Class) }
}
Add-Mau '10BASE-T' 'kupfer' 5, 10, 11
Add-Mau '10BASE-F' 'lwl' 6, 7, 8, 12, 13
Add-Mau '100BASE-T4' 'kupfer' 14
Add-Mau '100BASE-TX' 'kupfer' 15, 16
Add-Mau '100BASE-FX' 'lwl' 17, 18
Add-Mau '100BASE-T2' 'kupfer' 19, 20
Add-Mau '1000BASE-X' 'sfp' 21, 22
Add-Mau '1000BASE-LX' 'lwl' 23, 24
Add-Mau '1000BASE-SX' 'lwl' 25, 26
Add-Mau '1000BASE-CX' 'dac' 27, 28
Add-Mau '1000BASE-T' 'kupfer' 29, 30
Add-Mau '10GBASE-X' 'sfp' 31
Add-Mau '10GBASE-LX4' 'lwl' 32
Add-Mau '10GBASE-R' 'sfp' 33
Add-Mau '10GBASE-ER' 'lwl' 34
Add-Mau '10GBASE-LR' 'lwl' 35
Add-Mau '10GBASE-SR' 'lwl' 36
Add-Mau '10GBASE-W' 'sfp' 37
Add-Mau '10GBASE-EW' 'lwl' 38
Add-Mau '10GBASE-LW' 'lwl' 39
Add-Mau '10GBASE-SW' 'lwl' 40
Add-Mau '10GBASE-CX4' 'dac' 41
Add-Mau '100BASE-BX10' 'lwl' 44, 45
Add-Mau '100BASE-LX10' 'lwl' 46
Add-Mau '1000BASE-BX10' 'lwl' 47, 48
Add-Mau '1000BASE-LX10' 'lwl' 49
Add-Mau '1000BASE-PX' 'lwl' 50, 51, 52, 53, 80, 81, 82, 83
Add-Mau '10GBASE-T' 'kupfer' 54
Add-Mau '10GBASE-LRM' 'lwl' 55
Add-Mau '1000BASE-KX' 'bp' 56
Add-Mau '10GBASE-KX4' 'bp' 57
Add-Mau '10GBASE-KR' 'bp' 58
Add-Mau '10GBASE-PR' 'lwl' 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 84, 85, 86, 87
Add-Mau '40GBASE-KR4' 'bp' 70
Add-Mau '40GBASE-CR4' 'dac' 71
Add-Mau '40GBASE-SR4' 'lwl' 72
Add-Mau '40GBASE-FR' 'lwl' 73
Add-Mau '40GBASE-LR4' 'lwl' 74
Add-Mau '100GBASE-CR10' 'dac' 75
Add-Mau '100GBASE-SR10' 'lwl' 76
Add-Mau '100GBASE-LR4' 'lwl' 77
Add-Mau '100GBASE-ER4' 'lwl' 78
Add-Mau '1000BASE-T1' 'kupfer' 79
Add-Mau '25GBASE-CR' 'dac' 88, 89
Add-Mau '25GBASE-KR' 'bp' 90, 91
Add-Mau '25GBASE-R' 'sfp' 92
Add-Mau '25GBASE-SR' 'lwl' 93
Add-Mau '25GBASE-T' 'kupfer' 94
Add-Mau '40GBASE-ER4' 'lwl' 95
Add-Mau '40GBASE-R' 'sfp' 96
Add-Mau '40GBASE-T' 'kupfer' 97
Add-Mau '100GBASE-CR4' 'dac' 98
Add-Mau '100GBASE-KR4' 'bp' 99
Add-Mau '100GBASE-KP4' 'bp' 100
Add-Mau '100GBASE-R' 'sfp' 101
Add-Mau '100GBASE-SR4' 'lwl' 102

$script:MediaText = @{ lwl = 'LWL'; dac = 'DAC'; aoc = 'AOC'; kupfer = 'Kupfer'; sfp = 'SFP'; bp = 'Backplane' }

function Test-SpecificMedia([string]$Class) {
    return ($Class -eq 'lwl' -or $Class -eq 'dac' -or $Class -eq 'aoc' -or $Class -eq 'kupfer')
}

# Typbezeichnung eines Transceivers (z. B. "SFP+SR", "SFP+DAC3", "1000SX") einordnen
function Get-XcvrClass([string]$Text) {
    if (-not $Text) { return '' }
    $t = $Text.ToUpper()
    if ($t -match 'AOC|ACTIVE OPTICAL') { return 'aoc' }
    if ($t -match 'DAC|DIRECT|TWINAX|(?<![A-Z])DA\d|(?<![A-Z])CR\d*(?![A-Z])') { return 'dac' }
    if ($t -match '(?<![A-Z])(LRM|SR|LR|ER|ZR|SX|LX|LH|BX|ZX|EX|FX|PSM|CWDM|DWDM)\d*(?![A-Z])|FIBER|MMF|SMF|(?<![A-Z])LC(?![A-Z])') { return 'lwl' }
    if ($t -match 'RJ-?45|BASE-?T(?![A-Z])|(?<![A-Z])T(?![A-Z])') { return 'kupfer' }
    if ($t -match 'COPPER') { return 'dac' }
    return 'sfp'
}

# Medium eines Link-Endes. Rang: Transceiver-Typ 5, eigener MAU-Typ 4, vom Nachbarn
# gemeldeter MAU-Typ 3, unspezifisch (nur "SFP"/Backplane) 2 bzw. 1, unbekannt 0
function Get-EndMedia([string]$XcvrHint, [string]$XcvrShow, [int]$Mau, [bool]$Local) {
    $mName = ''; $mClass = ''; $mSpeed = 0
    if ($Mau -gt 0 -and $script:MauTable.ContainsKey($Mau)) {
        $mName = $script:MauTable[$Mau][0]; $mClass = $script:MauTable[$Mau][1]
        if ($mName -match '^(\d+)(G?)BASE') { $mSpeed = [long]$Matches[1]; if ($Matches[2]) { $mSpeed = $mSpeed * 1000 } }
    }
    $xClass = Get-XcvrClass $XcvrHint
    $spec = 3; $gen = 1
    if ($Local) { $spec = 4; $gen = 2 }
    if (Test-SpecificMedia $xClass) { return [pscustomobject]@{ Class = $xClass; Detail = $XcvrShow; Rank = 5; Speed = $mSpeed } }
    if (Test-SpecificMedia $mClass) { return [pscustomobject]@{ Class = $mClass; Detail = $mName; Rank = $spec; Speed = $mSpeed } }
    if ($xClass) { return [pscustomobject]@{ Class = 'sfp'; Detail = $XcvrShow; Rank = $gen; Speed = $mSpeed } }
    if ($mClass) { return [pscustomobject]@{ Class = $mClass; Detail = $mName; Rank = $gen; Speed = $mSpeed } }
    return [pscustomobject]@{ Class = ''; Detail = ''; Rank = 0; Speed = 0 }
}

function Format-Speed([long]$Mbps) {
    if ($Mbps -le 0) { return '' }
    if ($Mbps -lt 1000) { return "$($Mbps)M" }
    return "$([math]::Round($Mbps / 1000, 1))G"
}

# Fuer die LLDP-Ports eines Geraets: Geschwindigkeit (IF-MIB), MAU-Typ (LLDP-dot3 / MAU-MIB)
# und Transceiver-Typ (HPE ArubaOS-Switch und AOS-CX) holen
function Get-PortDetails([string]$Ip, [string]$Comm, $Ports, [string[]]$Nums) {
    $res = @{}
    foreach ($n in $Nums) { $res[$n] = @{ Speed = [long]0; Mau = 0; Xcvr = ''; XcvrHint = ''; IfIndex = '' } }
    if ($Nums.Count -eq 0) { return $res }

    # LLDP-Portnummer -> ifIndex: ueber Portnamen, sonst gilt Portnummer = ifIndex
    $ifIdx = @{}
    $tables = New-Object System.Collections.ArrayList
    foreach ($base in @('1.3.6.1.2.1.31.1.1.1.1', '1.3.6.1.2.1.2.2.1.2')) {
        if ($ifIdx.Count -eq $Nums.Count) { break }
        $tbl = Get-WalkTable $Ip $Comm $base
        [void]$tables.Add($tbl)
        $byName = @{}
        foreach ($k in $tbl.Keys) { $byName[(ConvertTo-Text $tbl[$k].Bytes).ToLower()] = $k }
        foreach ($n in $Nums) {
            if ($ifIdx.ContainsKey($n)) { continue }
            $p = $Ports[$n]
            if (-not $p) { continue }
            foreach ($cand in @((Format-LldpId $p.Sub $p.Id $false), $p.Desc)) {
                if ($cand -and $byName.ContainsKey($cand.ToLower())) { $ifIdx[$n] = $byName[$cand.ToLower()]; break }
            }
        }
    }
    foreach ($n in $Nums) {
        if ($ifIdx.ContainsKey($n)) { continue }
        foreach ($tbl in $tables) { if ($tbl.ContainsKey($n)) { $ifIdx[$n] = $n; break } }
    }
    $numByIf = @{}
    foreach ($n in $ifIdx.Keys) { $numByIf[$ifIdx[$n]] = $n; $res[$n].IfIndex = [string]$ifIdx[$n] }

    # Geschwindigkeit: ifHighSpeed (Mbit/s), ersatzweise ifSpeed (bit/s)
    if ($numByIf.Count -gt 0) {
        $hs = '1.3.6.1.2.1.31.1.1.1.15.'
        $vals = Get-SnmpValues $Ip $Comm @($numByIf.Keys | ForEach-Object { $hs + $_ })
        foreach ($o in $vals.Keys) { $i = $o.Substring($hs.Length); if ($numByIf.ContainsKey($i)) { $res[$numByIf[$i]].Speed = [long](ConvertTo-UInt $vals[$o].Bytes) } }
        $rest = @($numByIf.Keys | Where-Object { $res[$numByIf[$_]].Speed -le 0 })
        if ($rest.Count -gt 0) {
            $sp = '1.3.6.1.2.1.2.2.1.5.'
            $vals = Get-SnmpValues $Ip $Comm @($rest | ForEach-Object { $sp + $_ })
            foreach ($o in $vals.Keys) { $i = $o.Substring($sp.Length); if ($numByIf.ContainsKey($i)) { $res[$numByIf[$i]].Speed = [long][math]::Round((ConvertTo-UInt $vals[$o].Bytes) / 1000000) } }
        }
    }

    # MAU-Typ: LLDP-802.3-Erweiterung (nach LLDP-Portnummer), sonst MAU-MIB (nach ifIndex)
    $mau = Get-WalkTable $Ip $Comm '1.0.8802.1.1.2.1.5.4623.1.2.1.1.4'
    foreach ($n in $Nums) { if ($mau.ContainsKey($n)) { $res[$n].Mau = [int](ConvertTo-UInt $mau[$n].Bytes) } }
    if (@($numByIf.Values | Where-Object { $res[$_].Mau -le 0 }).Count -gt 0) {
        $mm = Get-WalkTable $Ip $Comm '1.3.6.1.2.1.26.2.1.1.3'
        foreach ($k in $mm.Keys) {
            $vb = $mm[$k]
            $if = $k.Split('.')[0]
            if ($vb.Tag -ne 0x06 -or -not $numByIf.ContainsKey($if)) { continue }
            $n = $numByIf[$if]
            if ($res[$n].Mau -gt 0) { continue }
            $oid = ConvertFrom-BerOid $vb.Bytes 0 $vb.Bytes.Length
            if ($oid.StartsWith('1.3.6.1.2.1.26.4.')) { $res[$n].Mau = [int]($oid.Split('.')[-1]) }
        }
    }

    # Transceiver-Typ, indiziert nach ifIndex
    if ($numByIf.Count -gt 0) {
        # ArubaOS-Switch / ProCurve: HP-ICF-TRANSCEIVER-MIB hpicfXcvrType
        $x = Get-WalkTable $Ip $Comm '1.3.6.1.4.1.11.2.14.11.5.1.82.1.1.1.1.5'
        foreach ($k in $x.Keys) {
            if (-not $numByIf.ContainsKey($k)) { continue }
            $t = ConvertTo-Text $x[$k].Bytes
            $res[$numByIf[$k]].Xcvr = $t; $res[$numByIf[$k]].XcvrHint = $t
        }
        if ($x.Count -eq 0) {
            # AOS-CX: ARUBAWIRED-PM-MIB arubaWiredPmXcvrType, -Description, -CableType
            $cx = '1.3.6.1.4.1.47196.4.1.1.3.27.1.1.1.1.'
            $xt = Get-WalkTable $Ip $Comm ($cx + '7')
            if ($xt.Count -gt 0) {
                $xd = Get-WalkTable $Ip $Comm ($cx + '3')
                $xc = Get-WalkTable $Ip $Comm ($cx + '11')
                foreach ($k in $xt.Keys) {
                    if (-not $numByIf.ContainsKey($k)) { continue }
                    $t = ConvertTo-Text $xt[$k].Bytes
                    $d = ''; $c = ''
                    if ($xd.ContainsKey($k)) { $d = ConvertTo-Text $xd[$k].Bytes }
                    if ($xc.ContainsKey($k)) { $c = ConvertTo-Text $xc[$k].Bytes }
                    $show = $t
                    if (-not $show) { $show = $d }
                    $res[$numByIf[$k]].Xcvr = $show
                    $res[$numByIf[$k]].XcvrHint = ("$t $d $c").Trim()
                }
            }
        }
    }
    return $res
}

# ---------------------------------------------------------------------------
# MAC-Tabelle, Portstatus, eigene MACs und ARP eines Geraets
# ---------------------------------------------------------------------------
function Test-UnicastMac([string]$Mac) {
    if ($Mac -eq '00:00:00:00:00:00') { return $false }
    return (([Convert]::ToInt32($Mac.Substring(0, 2), 16) -band 1) -eq 0)
}

function Get-BridgeData([string]$Ip, [string]$Comm) {
    $b = @{ OwnMacs = @{}; Arp = @{}; Fdb = @{}; AllMacs = @{}; Names = @{}; Lag = @{}; PhysTotal = 0; PhysUp = 0 }

    # eigene MAC-Adressen (ifPhysAddress)
    $pa = Get-WalkTable $Ip $Comm '1.3.6.1.2.1.2.2.1.6'
    foreach ($k in $pa.Keys) {
        $x = $pa[$k].Bytes
        if ($null -eq $x -or $x.Length -ne 6) { continue }
        $m = ConvertTo-Hex $x
        if (Test-UnicastMac $m) { $b.OwnMacs[$m] = $true }
    }

    # ARP-Tabelle (ipNetToMediaPhysAddress), Index: ifIndex.a.b.c.d
    $arp = Get-WalkTable $Ip $Comm '1.3.6.1.2.1.4.22.1.2'
    foreach ($k in $arp.Keys) {
        $x = $arp[$k].Bytes
        $p = $k.Split('.')
        if ($null -eq $x -or $x.Length -ne 6 -or $p.Count -lt 5) { continue }
        $m = ConvertTo-Hex $x
        if (Test-UnicastMac $m) { $b.Arp[$m] = ($p[($p.Count - 4)..($p.Count - 1)] -join '.') }
    }

    # MAC-Tabelle: Q-BRIDGE-MIB (alle VLANs), sonst BRIDGE-MIB
    $fdb = Get-WalkTable $Ip $Comm '1.3.6.1.2.1.17.7.1.2.2.1.2'
    if ($fdb.Count -eq 0) { $fdb = Get-WalkTable $Ip $Comm '1.3.6.1.2.1.17.4.3.1.2' }
    if ($fdb.Count -eq 0) { return $b }

    $bp = Get-WalkTable $Ip $Comm '1.3.6.1.2.1.17.1.4.1.2'      # Bridge-Port -> ifIndex
    foreach ($k in $fdb.Keys) {
        $p = $k.Split('.')
        if ($p.Count -lt 6) { continue }
        $bport = [string](ConvertTo-UInt $fdb[$k].Bytes)
        if ($bport -eq '0') { continue }
        $mac = (($p[($p.Count - 6)..($p.Count - 1)] | ForEach-Object { ([int]$_).ToString('x2') }) -join ':')
        if (-not (Test-UnicastMac $mac)) { continue }
        $if = $bport
        if ($bp.ContainsKey($bport)) { $if = [string](ConvertTo-UInt $bp[$bport].Bytes) }
        if (-not $b.Fdb.ContainsKey($if)) { $b.Fdb[$if] = @{} }
        $b.Fdb[$if][$mac] = $true
        $b.AllMacs[$mac] = $true
    }

    # Portnamen und Portstatus
    $names = Get-WalkTable $Ip $Comm '1.3.6.1.2.1.31.1.1.1.1'
    if ($names.Count -eq 0) { $names = Get-WalkTable $Ip $Comm '1.3.6.1.2.1.2.2.1.2' }
    foreach ($k in $names.Keys) { $b.Names[$k] = Format-PortName (ConvertTo-Text $names[$k].Bytes) }
    $types = Get-WalkTable $Ip $Comm '1.3.6.1.2.1.2.2.1.3'
    $oper = Get-WalkTable $Ip $Comm '1.3.6.1.2.1.2.2.1.8'
    foreach ($k in $types.Keys) {
        $t = [int](ConvertTo-UInt $types[$k].Bytes)
        if ($t -ne 6 -and $t -ne 62 -and $t -ne 117) { continue }      # nur Ethernet-Ports
        $b.PhysTotal++
        if ($oper.ContainsKey($k) -and (ConvertTo-UInt $oper[$k].Bytes) -eq 1) { $b.PhysUp++ }
    }

    # LAG-Mitglied -> LAG-Interface: IEEE8023-LAG-MIB, zusaetzlich ifStackTable
    $lag = Get-WalkTable $Ip $Comm '1.2.840.10006.300.43.1.2.1.1.13'
    foreach ($k in $lag.Keys) {
        $agg = [string](ConvertTo-UInt $lag[$k].Bytes)
        if ($agg -ne '0' -and $agg -ne $k) { $b.Lag[$k] = $agg }
    }
    $stack = Get-WalkTable $Ip $Comm '1.3.6.1.2.1.31.1.2.1.3'
    foreach ($k in $stack.Keys) {
        $p = $k.Split('.')
        if ($p.Count -ne 2 -or $p[0] -eq '0' -or $p[1] -eq '0') { continue }
        if ($b.Fdb.ContainsKey($p[0]) -and -not $b.Lag.ContainsKey($p[1])) { $b.Lag[$p[1]] = $p[0] }
    }
    return $b
}

function Get-LocalArp {
    $out = @{}
    $lines = @()
    try { $lines = @(& arp -a 2>$null) } catch { }
    foreach ($ln in $lines) {
        if ([string]$ln -match '(\d{1,3}(?:\.\d{1,3}){3})\s+([0-9a-fA-F]{2}(?:[-:][0-9a-fA-F]{2}){5})') {
            $m = ($Matches[2] -replace '-', ':').ToLower()
            if (Test-UnicastMac $m) { $out[$m] = $Matches[1] }
        }
    }
    return $out
}

function Expand-Target([string[]]$Items) {
    $out = New-Object System.Collections.ArrayList
    foreach ($raw in $Items) {
        foreach ($item in ($raw -split '[,;\s]+' | Where-Object { $_ })) {
            if ($item -match '^(\d{1,3}(\.\d{1,3}){3})/(\d{1,2})$') {
                $prefix = [int]$Matches[3]
                if ($prefix -lt 16 -or $prefix -gt 32) { throw "Netz $item : nur /16 bis /32 erlaubt" }
                $o = $Matches[1].Split('.') | ForEach-Object { [long]$_ }
                [long]$ip = ($o[0] -shl 24) + ($o[1] -shl 16) + ($o[2] -shl 8) + $o[3]
                [long]$size = [long]1 -shl (32 - $prefix)
                [long]$net = $ip - ($ip % $size)
                $first = $net; $last = $net + $size - 1
                if ($prefix -le 30) { $first++; $last-- }
                for ($a = $first; $a -le $last; $a++) {
                    [void]$out.Add(('{0}.{1}.{2}.{3}' -f (($a -shr 24) -band 255), (($a -shr 16) -band 255), (($a -shr 8) -band 255), ($a -band 255)))
                }
            }
            elseif ($item -match '^\d{1,3}(\.\d{1,3}){3}$') { [void]$out.Add($item) }
            else {
                try {
                    $addr = [System.Net.Dns]::GetHostAddresses($item) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
                    if ($addr) { [void]$out.Add($addr.ToString()) } else { Write-Warning "$item : keine IPv4-Adresse gefunden" }
                }
                catch { Write-Warning "$item : Name nicht aufloesbar" }
            }
        }
    }
    return , @($out | Select-Object -Unique)
}

# ---------------------------------------------------------------------------
# LLDP eines Geraets auslesen
# ---------------------------------------------------------------------------
function Get-DeviceLldp([string]$Ip, $Sys) {
    $comm = $Sys.Community

    # lldpLocalSystemData
    $locBase = '1.0.8802.1.1.2.1.3.'
    $chSub = 0; $chId = $null; $caps = $null; $lName = ''; $lDesc = ''
    $ports = @{}
    foreach ($vb in (Get-SnmpWalk $Ip $comm '1.0.8802.1.1.2.1.3')) {
        $s = $vb.Oid.Substring($locBase.Length)
        if ($s -eq '1.0') { $chSub = [int](ConvertTo-Int $vb.Bytes) }
        elseif ($s -eq '2.0') { $chId = $vb.Bytes }
        elseif ($s -eq '3.0') { $lName = ConvertTo-Text $vb.Bytes }
        elseif ($s -eq '4.0') { $lDesc = ConvertTo-Text $vb.Bytes }
        elseif ($s -eq '6.0') { $caps = $vb.Bytes }
        elseif ($s.StartsWith('7.1.')) {
            $p = $s.Split('.')
            if ($p.Count -lt 4) { continue }
            $num = $p[3]
            if (-not $ports.ContainsKey($num)) { $ports[$num] = @{ Sub = 0; Id = $null; Desc = '' } }
            if ($p[2] -eq '2') { $ports[$num].Sub = [int](ConvertTo-Int $vb.Bytes) }
            elseif ($p[2] -eq '3') { $ports[$num].Id = $vb.Bytes }
            elseif ($p[2] -eq '4') { $ports[$num].Desc = ConvertTo-Text $vb.Bytes }
        }
    }

    # lldpRemTable
    $remBase = '1.0.8802.1.1.2.1.4.1.1.'
    $nb = @{}
    $order = New-Object System.Collections.ArrayList
    foreach ($vb in (Get-SnmpWalk $Ip $comm '1.0.8802.1.1.2.1.4.1.1')) {
        $p = $vb.Oid.Substring($remBase.Length).Split('.')
        if ($p.Count -lt 4) { continue }
        $k = $p[1] + '.' + $p[2] + '.' + $p[3]
        if (-not $nb.ContainsKey($k)) {
            $nb[$k] = @{ PortNum = $p[2]; ChSub = 0; ChId = $null; PSub = 0; PId = $null; PDesc = ''; Name = ''; Desc = ''; CapS = $null; CapE = $null; Mgmt = '' }
            [void]$order.Add($k)
        }
        $e = $nb[$k]
        $col = $p[0]
        if ($col -eq '4') { $e.ChSub = [int](ConvertTo-Int $vb.Bytes) }
        elseif ($col -eq '5') { $e.ChId = $vb.Bytes }
        elseif ($col -eq '6') { $e.PSub = [int](ConvertTo-Int $vb.Bytes) }
        elseif ($col -eq '7') { $e.PId = $vb.Bytes }
        elseif ($col -eq '8') { $e.PDesc = ConvertTo-Text $vb.Bytes }
        elseif ($col -eq '9') { $e.Name = ConvertTo-Text $vb.Bytes }
        elseif ($col -eq '10') { $e.Desc = ConvertTo-Text $vb.Bytes }
        elseif ($col -eq '11') { $e.CapS = $vb.Bytes }
        elseif ($col -eq '12') { $e.CapE = $vb.Bytes }
    }

    # lldpRemManAddrTable - die Adresse steckt im Index
    $manBase = '1.0.8802.1.1.2.1.4.2.1.'
    if ($order.Count -gt 0) {
        foreach ($vb in (Get-SnmpWalk $Ip $comm '1.0.8802.1.1.2.1.4.2.1')) {
            $p = $vb.Oid.Substring($manBase.Length).Split('.')
            if ($p.Count -lt 9) { continue }
            $k = $p[1] + '.' + $p[2] + '.' + $p[3]
            if (-not $nb.ContainsKey($k) -or $nb[$k].Mgmt -or $p[4] -ne '1') { continue }
            $a = @($p[5..($p.Count - 1)])
            $m = ''
            if ($a.Count -eq 5 -and $a[0] -eq '4') { $m = ($a[1..4] -join '.') }
            elseif ($a.Count -eq 4) { $m = ($a -join '.') }
            if ($m -and $m -ne '0.0.0.0') { $nb[$k].Mgmt = $m }
        }
    }

    # Geschwindigkeit / Medium der Ports mit Nachbarn
    $det = @{}; $advMau = @{}
    if ($order.Count -gt 0) {
        $nums = @($order | ForEach-Object { $nb[$_].PortNum } | Select-Object -Unique)
        $det = Get-PortDetails $Ip $comm $ports $nums
        # MAU-Typ, den der Nachbar fuer sein Ende meldet
        $adv = Get-WalkTable $Ip $comm '1.0.8802.1.1.2.1.5.4623.1.3.1.1.4'
        foreach ($k in $adv.Keys) { $advMau[$k] = [int](ConvertTo-UInt $adv[$k].Bytes) }
    }

    $key = Format-LldpId $chSub $chId $true
    if (-not $key) { $key = 'ip:' + $Ip }
    $devName = $Sys.SysName
    if (-not $devName) { $devName = $lName }
    if (-not $devName) { $devName = $Ip }
    $devDesc = $Sys.SysDescr
    if (-not $devDesc) { $devDesc = $lDesc }

    $neighbors = New-Object System.Collections.ArrayList
    foreach ($k in $order) {
        $e = $nb[$k]
        $lp = $ports[$e.PortNum]
        if ($lp) {
            $localLabel = Get-PortLabel $lp.Sub $lp.Id $lp.Desc
            $localKey = Format-LldpId $lp.Sub $lp.Id $false
        }
        else { $localLabel = ''; $localKey = '' }
        if (-not $localLabel) { $localLabel = 'Port ' + $e.PortNum }
        if (-not $localKey) { $localKey = 'num' + $e.PortNum }

        $rKey = Format-LldpId $e.ChSub $e.ChId $true
        if (-not $rKey -and $e.Name) { $rKey = 'name:' + $e.Name }
        if (-not $rKey) { continue }
        $rPortKey = Format-LldpId $e.PSub $e.PId $false
        if (-not $rPortKey) { $rPortKey = 'idx' + $k }
        $rCaps = $e.CapE
        if ($null -eq $rCaps -or $rCaps.Length -eq 0 -or $rCaps[0] -eq 0) { $rCaps = $e.CapS }
        $rName = $e.Name
        if (-not $rName) { $rName = $rKey }
        $speed = [long]0
        $locMedia = Get-EndMedia '' '' 0 $true
        $pd = $det[$e.PortNum]
        $localIf = ''
        if ($pd) { $speed = $pd.Speed; $localIf = $pd.IfIndex; $locMedia = Get-EndMedia $pd.XcvrHint $pd.Xcvr $pd.Mau $true }
        $remMau = 0
        if ($advMau.ContainsKey($k)) { $remMau = $advMau[$k] }
        $remMedia = Get-EndMedia '' '' $remMau $false

        [void]$neighbors.Add([pscustomobject]@{
                LocalPort    = $localLabel
                LocalPortKey = $localKey
                Key          = $rKey
                Name         = $rName
                Port         = (Get-PortLabel $e.PSub $e.PId $e.PDesc)
                PortKey      = $rPortKey
                Descr        = $e.Desc
                Type         = (Get-NodeType $rCaps $false)
                LocalIfIndex = $localIf
                Mgmt         = $e.Mgmt
                Speed        = $speed
                LocMedia     = $locMedia
                RemMedia     = $remMedia
            })
    }

    $bridge = $null
    if (-not $NoMacTable) { $bridge = Get-BridgeData $Ip $comm }
    # Typ: LLDP-Capabilities; ohne Angabe ist ein Geraet mit MAC-Tabelle ein Switch, sonst ein Host
    $type = Get-NodeType $caps $true
    if (-not $type) {
        if (($bridge -and $bridge.Fdb.Count -gt 0) -or $neighbors.Count -gt 1) { $type = 'switch' } else { $type = 'host' }
    }

    return [pscustomobject]@{
        Ip        = $Ip
        Key       = $key
        Name      = $devName
        Descr     = $devDesc
        Type      = $type
        Neighbors = $neighbors
        Bridge    = $bridge
    }
}

# ---------------------------------------------------------------------------
# Scan
# ---------------------------------------------------------------------------
$ips = Expand-Target $Target
if ($ips.Count -eq 0) { throw 'Keine gueltigen Ziele angegeben.' }
Write-Host ("Suche SNMP-Geraete unter {0} Adresse(n), Community: {1} ..." -f $ips.Count, ($Community -join ', '))

$known = Find-SnmpHosts $ips
$tried = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($i in $ips) { [void]$tried.Add($i) }
$queue = New-Object System.Collections.Queue
foreach ($i in ($known.Keys | Sort-Object { Get-SortKey $_ })) { $queue.Enqueue($i) }
Write-Host ("{0} Geraet(e) antworten per SNMP." -f $known.Count)

$devices = New-Object System.Collections.ArrayList
$seenKeys = @{}
while ($queue.Count -gt 0) {
    $ip = $queue.Dequeue()
    $dev = Get-DeviceLldp $ip $known[$ip]
    if ($seenKeys.ContainsKey($dev.Key)) {
        Write-Host ("  {0,-15} {1} - gleiches Geraet wie {2}, uebersprungen" -f $ip, $dev.Name, $seenKeys[$dev.Key])
        continue
    }
    $seenKeys[$dev.Key] = $ip
    [void]$devices.Add($dev)
    $hint = ''
    if ($dev.Bridge -and $dev.Bridge.Fdb.Count -gt 0) { $hint = ', {0,4} MACs' -f $dev.Bridge.AllMacs.Count }
    elseif ($dev.Type -eq 'host') { $hint = '  (kein Switch)' }
    elseif ($dev.Neighbors.Count -eq 0) { $hint = '  (LLDP aus oder keine LLDP-MIB?)' }
    Write-Host ("  {0,-15} {1,-28} {2,3} LLDP-Nachbarn{3}" -f $ip, $dev.Name, $dev.Neighbors.Count, $hint)

    if (-not $NoCrawl) {
        foreach ($n in $dev.Neighbors) {
            if (-not $n.Mgmt -or $tried.Contains($n.Mgmt)) { continue }
            if ($n.Type -ne 'switch' -and $n.Type -ne 'router') { continue }
            [void]$tried.Add($n.Mgmt)
            $hit = Find-SnmpHosts @($n.Mgmt)
            if ($hit.ContainsKey($n.Mgmt)) {
                $known[$n.Mgmt] = $hit[$n.Mgmt]
                $queue.Enqueue($n.Mgmt)
            }
            else {
                Write-Host ("  {0,-15} {1,-28} per LLDP gesehen, antwortet nicht auf SNMP" -f $n.Mgmt, $n.Name)
            }
        }
    }
}

if ($devices.Count -eq 0) {
    $script:Udp.Close()
    Write-Warning 'Kein Geraet hat geantwortet. Community, SNMP-Freigabe (ACL/Management-VLAN) und Firewall pruefen, ggf. -V1 testen.'
    return
}

# ---------------------------------------------------------------------------
# Knoten und Links zusammenfuehren
# ---------------------------------------------------------------------------
# Meldet ein Nachbar eine andere Chassis-ID als das Geraet selbst, ueber die Management-IP zuordnen
$alias = @{}
$ipToKey = @{}
foreach ($d in $devices) { $ipToKey[$d.Ip] = $d.Key }
foreach ($d in $devices) {
    foreach ($n in $d.Neighbors) {
        if ($n.Mgmt -and $ipToKey.ContainsKey($n.Mgmt) -and $ipToKey[$n.Mgmt] -ne $n.Key -and -not $seenKeys.ContainsKey($n.Key)) {
            $alias[$n.Key] = $ipToKey[$n.Mgmt]
        }
    }
}

$nodes = [ordered]@{}
foreach ($d in $devices) {
    $nodes[$d.Key] = [pscustomobject]@{ Id = ''; Key = $d.Key; Name = $d.Name; Ip = $d.Ip; Descr = $d.Descr; Type = $d.Type; Scanned = $true }
}
$links = [ordered]@{}
foreach ($d in $devices) {
    foreach ($n in $d.Neighbors) {
        $rk = $n.Key
        if ($alias.ContainsKey($rk)) { $rk = $alias[$rk] }
        if ($rk -eq $d.Key) { continue }
        if (-not $nodes.Contains($rk)) {
            $nodes[$rk] = [pscustomobject]@{ Id = ''; Key = $rk; Name = $n.Name; Ip = $n.Mgmt; Descr = $n.Descr; Type = $n.Type; Scanned = $false }
        }
        else {
            $x = $nodes[$rk]
            if (-not $x.Scanned) {
                if (-not $x.Ip -and $n.Mgmt) { $x.Ip = $n.Mgmt }
                if (-not $x.Descr -and $n.Descr) { $x.Descr = $n.Descr }
                if ($x.Type -eq 'other' -and $n.Type -ne 'other') { $x.Type = $n.Type }
            }
        }
        $ea = $d.Key + '|' + $n.LocalPortKey
        $eb = $rk + '|' + $n.PortKey
        if ([string]::CompareOrdinal($ea, $eb) -le 0) { $lk = $ea + '||' + $eb } else { $lk = $eb + '||' + $ea }
        if ($links.Contains($lk)) {
            # Link wurde schon von der Gegenseite gemeldet: eigene Portbezeichnung hat Vorrang
            $l = $links[$lk]
            if ($l.AEnd -eq $ea) {
                $l.APort = $n.LocalPort
                if ($n.LocMedia.Rank -gt $l.AMedia.Rank) { $l.AMedia = $n.LocMedia }
                if ($n.RemMedia.Rank -gt $l.BMedia.Rank) { $l.BMedia = $n.RemMedia }
            }
            else {
                $l.BPort = $n.LocalPort
                if ($n.LocMedia.Rank -gt $l.BMedia.Rank) { $l.BMedia = $n.LocMedia }
                if ($n.RemMedia.Rank -gt $l.AMedia.Rank) { $l.AMedia = $n.RemMedia }
            }
            if ($l.Speed -le 0) { $l.Speed = $n.Speed }
            $l.Both = $true
        }
        else {
            $links[$lk] = [pscustomobject]@{
                AKey = $d.Key; AEnd = $ea; APort = $n.LocalPort; BKey = $rk; BEnd = $eb; BPort = $n.Port; Both = $false
                Speed = $n.Speed; AMedia = $n.LocMedia; BMedia = $n.RemMedia
                SpeedText = ''; Media = ''; MediaText = ''; Detail = ''; Label = ''; Via = 'lldp'
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Endgeraete ueber die MAC-Tabellen verorten
# ---------------------------------------------------------------------------
# Prinzip: Jede MAC-Adresse wird netzweit genau einem Switch-Port zugeordnet.
#  - Ports, hinter denen laut LLDP ein abgefragter Switch haengt, sind Uplinks und scheiden aus.
#  - Unter den uebrigen Sichtungen gewinnt der Port mit den wenigsten MAC-Adressen
#    (am Anschlussport steht ein Geraet allein, auf Durchgangsports stehen viele).
#  - Ist eine MAC nur auf Uplinks zu sehen, haengt sie hinter dem Switch am Ende der Kette.
$endpoints = New-Object System.Collections.ArrayList
$swStats = [ordered]@{}
if (-not $NoMacTable) {
    $bridges = @($devices | Where-Object { $_.Bridge -and $_.Bridge.Fdb.Count -gt 0 })
    $bridgeByKey = @{}
    foreach ($d in $bridges) { $bridgeByKey[$d.Key] = $d }
    $macRx = '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'

    # MAC -> Switch (eigene Adressen), MAC -> bekannter Knoten, MAC -> IP
    $switchMac = @{}; $macNode = @{}; $macIp = @{}
    foreach ($d in $devices) {
        if (-not $d.Bridge) { continue }
        foreach ($m in $d.Bridge.OwnMacs.Keys) {
            if ($bridgeByKey.ContainsKey($d.Key)) { $switchMac[$m] = $d.Key } else { $macNode[$m] = $d.Key }
        }
        foreach ($m in $d.Bridge.Arp.Keys) { $macIp[$m] = $d.Bridge.Arp[$m] }
    }
    $localArp = Get-LocalArp
    foreach ($m in $localArp.Keys) { if (-not $macIp.ContainsKey($m)) { $macIp[$m] = $localArp[$m] } }
    foreach ($k in $bridgeByKey.Keys) { if ($k -match $macRx) { $switchMac[$k] = $k } }

    # Uplinks (Nachbar ist abgefragter Switch) und sonstige LLDP-Nachbarn je Port
    $hard = @{}; $nbrAt = @{}
    foreach ($d in $devices) {
        foreach ($n in $d.Neighbors) {
            $rk = $n.Key
            if ($alias.ContainsKey($rk)) { $rk = $alias[$rk] }
            foreach ($m in @($n.Key, $n.PortKey)) {
                if ($m -notmatch $macRx) { continue }
                if ($bridgeByKey.ContainsKey($rk)) { $switchMac[$m] = $rk } elseif (-not $macNode.ContainsKey($m)) { $macNode[$m] = $rk }
            }
            if (-not $bridgeByKey.ContainsKey($d.Key) -or -not $n.LocalIfIndex) { continue }
            $ifs = @($n.LocalIfIndex)
            if ($d.Bridge.Lag.ContainsKey($n.LocalIfIndex)) { $ifs += $d.Bridge.Lag[$n.LocalIfIndex] }
            foreach ($i in $ifs) {
                $pk = $d.Key + '|' + $i
                if ($bridgeByKey.ContainsKey($rk)) { $hard[$pk] = $rk } elseif (-not $nbrAt.ContainsKey($pk)) { $nbrAt[$pk] = $rk }
            }
        }
    }

    # Sichtungen je MAC und Anzahl MACs je Port (ohne die Adressen der Switche selbst)
    $seen = @{}; $size = @{}
    foreach ($d in $bridges) {
        foreach ($i in $d.Bridge.Fdb.Keys) {
            $pk = $d.Key + '|' + $i
            $c = 0
            foreach ($m in $d.Bridge.Fdb[$i].Keys) {
                if ($switchMac.ContainsKey($m)) { continue }
                $c++
                if (-not $seen.ContainsKey($m)) { $seen[$m] = New-Object System.Collections.ArrayList }
                [void]$seen[$m].Add($pk)
            }
            $size[$pk] = $c
        }
    }

    # Zuordnung
    $assign = @{}
    foreach ($m in $seen.Keys) {
        $best = $null; $bestUp = $null
        foreach ($pk in $seen[$m]) {
            if ($hard.ContainsKey($pk)) {
                if (-not $bridgeByKey[$hard[$pk]].Bridge.AllMacs.ContainsKey($m)) {
                    if ($null -eq $bestUp -or $size[$pk] -lt $size[$bestUp]) { $bestUp = $pk }
                }
            }
            elseif ($null -eq $best -or $size[$pk] -lt $size[$best]) { $best = $pk }
        }
        if ($best) {
            $cut = $best.LastIndexOf('|')
            $assign[$m] = @{ Dev = $best.Substring(0, $cut); If = $best.Substring($cut + 1) }
        }
        elseif ($bestUp) { $assign[$m] = @{ Dev = $hard[$bestUp]; If = '' } }
    }

    # Liste der Endgeraete und Zaehler je Switch
    foreach ($d in $bridges) {
        $swStats[$d.Key] = [pscustomobject]@{ Key = $d.Key; Name = $d.Name; Ip = $d.Ip; PortsTotal = $d.Bridge.PhysTotal; PortsUp = $d.Bridge.PhysUp; Macs = 0; EdgePorts = 0; BehindAp = 0; Ports = @{} }
    }
    foreach ($m in $assign.Keys) {
        $a = $assign[$m]
        $d = $bridgeByKey[$a.Dev]
        $st = $swStats[$a.Dev]
        $st.Macs++
        $portName = '?'; $note = 'Port unbekannt, MAC nur am Uplink zu diesem Switch gesehen'
        if ($a.If) {
            $pk = $a.Dev + '|' + $a.If
            $st.Ports[$a.If] = $true
            $portName = $d.Bridge.Names[$a.If]
            if (-not $portName) { $portName = 'ifIndex ' + $a.If }
            $note = ''
            if ($nbrAt.ContainsKey($pk) -and $nodes.Contains($nbrAt[$pk])) {
                $nbNode = $nodes[$nbrAt[$pk]]
                if ($macNode[$m] -eq $nbNode.Key) { $note = 'LLDP-Nachbar' }
                else {
                    $note = 'hinter ' + $nbNode.Name
                    if ($nbNode.Type -eq 'ap') { $st.BehindAp++; $note = 'WLAN, hinter ' + $nbNode.Name }
                }
            }
            elseif ($size[$pk] -gt 2) { $note = '{0} MACs an diesem Port (unmanaged Switch, VM-Host, LAG?)' -f $size[$pk] }
        }
        $epName = ''; $epIp = ''
        if ($macNode.ContainsKey($m) -and $nodes.Contains($macNode[$m])) { $epName = $nodes[$macNode[$m]].Name; $epIp = $nodes[$macNode[$m]].Ip }
        if ($macIp.ContainsKey($m)) { $epIp = $macIp[$m] }
        [void]$endpoints.Add([pscustomobject]@{ SwitchKey = $a.Dev; Switch = $d.Name; Port = $portName; Mac = $m; Ip = $epIp; Name = $epName; Hinweis = $note })
    }
    foreach ($st in $swStats.Values) { $st.EdgePorts = $st.Ports.Count }

    # Abgefragte Geraete ohne LLDP-Verbindung an ihren Port haengen
    $linked = @{}
    foreach ($l in $links.Values) { $linked[$l.AKey] = $true; $linked[$l.BKey] = $true }
    $none = Get-EndMedia '' '' 0 $true
    foreach ($d in $devices) {
        if (-not $d.Bridge -or $bridgeByKey.ContainsKey($d.Key) -or $linked.ContainsKey($d.Key)) { continue }
        $cands = @($d.Bridge.OwnMacs.Keys)
        foreach ($m in $macIp.Keys) { if ($macIp[$m] -eq $d.Ip) { $cands += $m } }
        $hit = $null
        foreach ($m in $cands) { if ($assign.ContainsKey($m)) { $hit = $m; break } }
        if (-not $hit) { continue }
        $a = $assign[$hit]
        $from = $a.Dev; $fromPort = '?'; $speed = [long]0
        if ($a.If) {
            $pk = $a.Dev + '|' + $a.If
            $sw = $bridgeByKey[$a.Dev]
            $fromPort = $sw.Bridge.Names[$a.If]
            if (-not $fromPort) { $fromPort = 'ifIndex ' + $a.If }
            if ($nbrAt.ContainsKey($pk) -and $nodes.Contains($nbrAt[$pk]) -and $nbrAt[$pk] -ne $d.Key) {
                # MAC liegt hinter einem LLDP-Nachbarn (AP, nicht abgefragter Switch, Router)
                $from = $nbrAt[$pk]; $fromPort = ''
                if ($nodes[$from].Type -eq 'ap') { $fromPort = 'WLAN' }
            }
            else {
                $oid = '1.3.6.1.2.1.31.1.1.1.15.' + $a.If
                $v = Get-SnmpValues $sw.Ip $known[$sw.Ip].Community @($oid)
                if ($v.ContainsKey($oid)) { $speed = [long](ConvertTo-UInt $v[$oid].Bytes) }
                if ($speed -le 0) {
                    $oid = '1.3.6.1.2.1.2.2.1.5.' + $a.If
                    $v = Get-SnmpValues $sw.Ip $known[$sw.Ip].Community @($oid)
                    if ($v.ContainsKey($oid)) { $speed = [long][math]::Round((ConvertTo-UInt $v[$oid].Bytes) / 1000000) }
                }
            }
        }
        $links['mac|' + $d.Key] = [pscustomobject]@{
            AKey = $from; AEnd = ''; APort = $fromPort; BKey = $d.Key; BEnd = ''; BPort = ''; Both = $false
            Speed = $speed; AMedia = $none; BMedia = $none
            SpeedText = ''; Media = ''; MediaText = ''; Detail = ''; Label = ''; Via = 'mac'
        }
    }
}
$script:Udp.Close()

# Je Link: Geschwindigkeit und Medium aus beiden Enden zusammenfuehren
foreach ($l in $links.Values) {
    # Switch nach links: (AP, Switch) -> (Switch, AP)
    if (-not (Test-Big $nodes[$l.AKey]) -and (Test-Big $nodes[$l.BKey])) {
        $t = $l.AKey; $l.AKey = $l.BKey; $l.BKey = $t
        $t = $l.APort; $l.APort = $l.BPort; $l.BPort = $t
        $t = $l.AEnd; $l.AEnd = $l.BEnd; $l.BEnd = $t
        $t = $l.AMedia; $l.AMedia = $l.BMedia; $l.BMedia = $t
    }
    $m = $l.AMedia; $o = $l.BMedia
    if ($o.Rank -gt $m.Rank) { $m = $l.BMedia; $o = $l.AMedia }
    if ($l.Speed -le 0) { $l.Speed = $m.Speed }
    if ($l.Speed -le 0) { $l.Speed = $o.Speed }
    $l.SpeedText = Format-Speed $l.Speed
    $l.Media = $m.Class
    $l.Detail = $m.Detail
    if ($m.Class) { $l.MediaText = $script:MediaText[$m.Class] }
    # beide Enden gleich sicher, aber unterschiedlich (z. B. Medienkonverter): beides nennen
    if ($o.Rank -eq $m.Rank -and $m.Rank -ge 3 -and $o.Class -ne $m.Class) {
        $l.MediaText = $script:MediaText[$l.AMedia.Class] + '/' + $script:MediaText[$l.BMedia.Class]
        $l.Detail = $l.AMedia.Detail + ' / ' + $l.BMedia.Detail
    }
    $l.Label = ("$($l.SpeedText) $($l.MediaText)").Trim()
}

$i = 0
foreach ($n in $nodes.Values) { $i++; $n.Id = 'n' + $i }
$nodeList = @($nodes.Values)
$linkList = @($links.Values | Sort-Object { Get-SortKey $nodes[$_.AKey].Name }, { Get-SortKey $_.APort })

# ---------------------------------------------------------------------------
# Ausgabe: CSV
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $OutDir)) { [void](New-Item -ItemType Directory -Path $OutDir) }
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path
$typeText = @{ switch = 'Switch'; router = 'Router/Firewall'; ap = 'Access Point'; phone = 'Telefon'; host = 'Server/Geraet (SNMP)'; other = 'Sonstiges' }

$linkRows = foreach ($l in $linkList) {
    $a = $nodes[$l.AKey]; $b = $nodes[$l.BKey]
    $src = 'eine Seite'
    if ($l.Both) { $src = 'beide Seiten' }
    if ($l.Via -eq 'mac') { $src = 'MAC-Tabelle' }
    [pscustomobject]@{
        GeraetA   = $a.Name; IpA = $a.Ip; TypA = $typeText[$a.Type]; PortA = $l.APort
        PortB     = $l.BPort; GeraetB = $b.Name; IpB = $b.Ip
        TypB      = $typeText[$b.Type]
        Link      = $l.Label; Geschwindigkeit = $l.SpeedText; Medium = $l.MediaText; Detail = $l.Detail
        GemeldetVon = $src
    }
}
$devRows = foreach ($n in ($nodeList | Sort-Object { Get-SortKey $_.Name })) {
    $q = 'nein (nur per LLDP gesehen)'
    if ($n.Scanned) { $q = 'ja' }
    [pscustomobject]@{ Name = $n.Name; Ip = $n.Ip; Typ = $typeText[$n.Type]; Abgefragt = $q; ChassisId = $n.Key; Beschreibung = $n.Descr }
}
$csvLinks = Join-Path $OutDir ($Name + '_links.csv')
$csvDevs = Join-Path $OutDir ($Name + '_devices.csv')
$csvEnc = 'UTF8'
if ($PSVersionTable.PSVersion.Major -ge 6) { $csvEnc = 'utf8BOM' }
@($linkRows) | Export-Csv -LiteralPath $csvLinks -Delimiter ';' -NoTypeInformation -Encoding $csvEnc
@($devRows) | Export-Csv -LiteralPath $csvDevs -Delimiter ';' -NoTypeInformation -Encoding $csvEnc

$csvSw = Join-Path $OutDir ($Name + '_switches.csv')
$csvEp = Join-Path $OutDir ($Name + '_endgeraete.csv')
$swRows = @(foreach ($st in ($swStats.Values | Sort-Object { Get-SortKey $_.Name })) {
        [pscustomobject]@{ Switch = $st.Name; Ip = $st.Ip; PortsGesamt = $st.PortsTotal; PortsAktiv = $st.PortsUp; PortsMitEndgeraet = $st.EdgePorts; Endgeraete = $st.Macs; DavonWLAN = $st.BehindAp }
    })
$epRows = @($endpoints | Sort-Object { Get-SortKey $_.Switch }, { Get-SortKey $_.Port }, Mac | Select-Object Switch, Port, Mac, Ip, Name, Hinweis)
if (-not $NoMacTable) {
    $swRows | Export-Csv -LiteralPath $csvSw -Delimiter ';' -NoTypeInformation -Encoding $csvEnc
    $epRows | Export-Csv -LiteralPath $csvEp -Delimiter ';' -NoTypeInformation -Encoding $csvEnc
}

# ---------------------------------------------------------------------------
# Ausgabe: draw.io
# ---------------------------------------------------------------------------
function Get-NodeSize($n) { if (Test-Big $n) { return @(200, 64) } else { return @(150, 40) } }

function Get-TreeWidth([string]$Id, $Kids, $ById, $Width) {
    $own = (Get-NodeSize $ById[$Id])[0] + 40
    $sum = 0
    foreach ($k in $Kids[$Id]) { $sum += (Get-TreeWidth $k $Kids $ById $Width) }
    if ($sum -gt $own) { $Width[$Id] = $sum } else { $Width[$Id] = $own }
    return $Width[$Id]
}
function Set-TreePos([string]$Id, [double]$X0, $Kids, $Depth, $Width, $Pos) {
    $Pos[$Id] = @(($X0 + $Width[$Id] / 2), ($Depth[$Id] * 170))
    $sum = 0
    foreach ($k in $Kids[$Id]) { $sum += $Width[$k] }
    $cx = $X0 + ($Width[$Id] - $sum) / 2
    foreach ($k in $Kids[$Id]) { Set-TreePos $k $cx $Kids $Depth $Width $Pos; $cx += $Width[$k] }
}
function Get-Layout($NodeSet, $LinkSet) {
    $byId = @{}; $adj = @{}
    foreach ($n in $NodeSet) { $byId[$n.Id] = $n; $adj[$n.Id] = New-Object System.Collections.ArrayList }
    foreach ($l in $LinkSet) {
        if (-not $adj[$l.A].Contains($l.B)) { [void]$adj[$l.A].Add($l.B) }
        if (-not $adj[$l.B].Contains($l.A)) { [void]$adj[$l.B].Add($l.A) }
    }
    $rank = { param($id) $n = $byId[$id]; $g = 1; if (Test-Big $n) { $g = 0 }; '{0}{1:d5}{2}' -f $g, (99999 - $adj[$id].Count), (Get-SortKey $n.Name) }
    $pos = @{}; $seen = @{}; $offX = 0.0
    foreach ($rootId in @($NodeSet | ForEach-Object { $_.Id } | Sort-Object { & $rank $_ })) {
        if ($seen.ContainsKey($rootId)) { continue }
        $kids = @{}; $depth = @{}; $width = @{}
        $q = New-Object System.Collections.Queue
        $q.Enqueue($rootId); $seen[$rootId] = $true; $depth[$rootId] = 0
        while ($q.Count -gt 0) {
            $u = $q.Dequeue()
            $kids[$u] = New-Object System.Collections.ArrayList
            foreach ($v in @($adj[$u] | Sort-Object { & $rank $_ })) {
                if ($seen.ContainsKey($v)) { continue }
                $seen[$v] = $true; $depth[$v] = $depth[$u] + 1
                [void]$kids[$u].Add($v); $q.Enqueue($v)
            }
        }
        [void](Get-TreeWidth $rootId $kids $byId $width)
        Set-TreePos $rootId $offX $kids $depth $width $pos
        $offX += $width[$rootId] + 80
    }
    return $pos
}

function ConvertTo-XmlText([string]$s) { return [System.Security.SecurityElement]::Escape($s) }

$dNodes = @($nodeList | Where-Object { $IncludeEndpoints -or (Test-Big $_) -or $_.Type -eq 'host' })
$dIds = @{}
foreach ($n in $dNodes) { $dIds[$n.Id] = $true }
$dLinks = @(foreach ($l in $linkList) {
        $a = $nodes[$l.AKey].Id; $b = $nodes[$l.BKey].Id
        if ($dIds.ContainsKey($a) -and $dIds.ContainsKey($b)) { [pscustomobject]@{ A = $a; B = $b; APort = $l.APort; BPort = $l.BPort; Label = $l.Label; Media = $l.Media; Speed = $l.Speed; Via = $l.Via } }
    })
$pos = Get-Layout $dNodes $dLinks
$styleByType = @{
    switch = 'fillColor=#dae8fc;strokeColor=#6c8ebf;'
    router = 'fillColor=#e1d5e7;strokeColor=#9673a6;'
    ap     = 'fillColor=#d5e8d4;strokeColor=#82b366;'
    phone  = 'fillColor=#ffe6cc;strokeColor=#d79b00;'
    host   = 'fillColor=#d0ece7;strokeColor=#0e8074;'
    other  = 'fillColor=#f5f5f5;strokeColor=#666666;'
}
$mediaColor = @{ lwl = '#e07c0c'; aoc = '#e07c0c'; dac = '#111827'; kupfer = '#4f7396'; sfp = '#8b5cf6'; bp = '#0f766e'; '' = '#9aa5b1' }
$x = New-Object System.Text.StringBuilder
[void]$x.Append('<mxfile host="app.diagrams.net"><diagram name="' + (ConvertTo-XmlText $Name) + '" id="netzplan">')
[void]$x.Append('<mxGraphModel dx="1400" dy="900" grid="1" gridSize="10" guides="1" tooltips="1" connect="1" arrows="1" fold="1" page="0" pageScale="1" pageWidth="1169" pageHeight="827" math="0" shadow="0"><root><mxCell id="0"/><mxCell id="1" parent="0"/>')
foreach ($n in $dNodes) {
    $sz = Get-NodeSize $n
    $label = '<b>' + (ConvertTo-XmlText $n.Name) + '</b>'
    if ($n.Ip) { $label += '<br>' + (ConvertTo-XmlText $n.Ip) }
    $style = 'rounded=1;whiteSpace=wrap;html=1;fontSize=11;' + $styleByType[$n.Type]
    if (-not $n.Scanned) { $style += 'dashed=1;' }
    $px = [math]::Round($pos[$n.Id][0] - $sz[0] / 2); $py = [math]::Round($pos[$n.Id][1] - $sz[1] / 2)
    [void]$x.Append(('<mxCell id="{0}" value="{1}" style="{2}" vertex="1" parent="1"><mxGeometry x="{3}" y="{4}" width="{5}" height="{6}" as="geometry"/></mxCell>' -f $n.Id, (ConvertTo-XmlText $label), $style, $px, $py, $sz[0], $sz[1]))
}
$pairCount = @{}; $pairIdx = @{}
foreach ($l in $dLinks) {
    if ([string]::CompareOrdinal($l.A, $l.B) -le 0) { $pk = $l.A + '|' + $l.B } else { $pk = $l.B + '|' + $l.A }
    if ($pairCount.ContainsKey($pk)) { $pairCount[$pk]++ } else { $pairCount[$pk] = 1 }
}
$e = 0
foreach ($l in $dLinks) {
    $e++
    if ([string]::CompareOrdinal($l.A, $l.B) -le 0) { $pk = $l.A + '|' + $l.B; $p1 = $pos[$l.A]; $p2 = $pos[$l.B] } else { $pk = $l.B + '|' + $l.A; $p1 = $pos[$l.B]; $p2 = $pos[$l.A] }
    if ($pairIdx.ContainsKey($pk)) { $pairIdx[$pk]++ } else { $pairIdx[$pk] = 0 }
    $geo = '<mxGeometry relative="1" as="geometry"/>'
    if ($l.Via -eq 'mac') { $style += 'dashed=1;' }
    $sw = 2
    if ($l.Speed -ge 25000) { $sw = 5 } elseif ($l.Speed -ge 10000) { $sw = 4 } elseif ($l.Speed -ge 2500) { $sw = 3 } elseif ($l.Speed -gt 0 -and $l.Speed -lt 1000) { $sw = 1 }
    $style = 'endArrow=none;html=1;rounded=0;fontSize=10;fontStyle=1;labelBackgroundColor=#ffffff;strokeWidth=' + $sw + ';strokeColor=' + $mediaColor[$l.Media] + ';fontColor=' + $mediaColor[$l.Media] + ';'
    if ($pairCount[$pk] -gt 1) {
        # parallele Links (LAG) leicht auseinanderziehen
        $off = ($pairIdx[$pk] - ($pairCount[$pk] - 1) / 2) * 40
        $dx = $p2[0] - $p1[0]; $dy = $p2[1] - $p1[1]
        $len = [math]::Sqrt($dx * $dx + $dy * $dy); if ($len -lt 1) { $len = 1 }
        $mx = [math]::Round(($p1[0] + $p2[0]) / 2 - $dy / $len * $off); $my = [math]::Round(($p1[1] + $p2[1]) / 2 + $dx / $len * $off)
        $geo = '<mxGeometry relative="1" as="geometry"><Array as="points"><mxPoint x="' + $mx + '" y="' + $my + '"/></Array></mxGeometry>'
        $style += 'curved=1;'
    }
    [void]$x.Append(('<mxCell id="e{0}" value="{5}" style="{1}" edge="1" parent="1" source="{2}" target="{3}">{4}</mxCell>' -f $e, $style, $l.A, $l.B, $geo, (ConvertTo-XmlText (ConvertTo-XmlText $l.Label))))
    $ls = 'edgeLabel;html=1;align=center;verticalAlign=middle;resizable=0;points=[];fontSize=10;fontStyle=0;fontColor=#27323e;fontFamily=Courier New;'
    [void]$x.Append(('<mxCell id="e{0}a" value="{1}" style="{2}" vertex="1" connectable="0" parent="e{0}"><mxGeometry x="-0.7" relative="1" as="geometry"><mxPoint as="offset"/></mxGeometry></mxCell>' -f $e, (ConvertTo-XmlText (ConvertTo-XmlText $l.APort)), $ls))
    [void]$x.Append(('<mxCell id="e{0}b" value="{1}" style="{2}" vertex="1" connectable="0" parent="e{0}"><mxGeometry x="0.7" relative="1" as="geometry"><mxPoint as="offset"/></mxGeometry></mxCell>' -f $e, (ConvertTo-XmlText (ConvertTo-XmlText $l.BPort)), $ls))
}
[void]$x.Append('</root></mxGraphModel></diagram></mxfile>')
$drawio = Join-Path $OutDir ($Name + '.drawio')
[System.IO.File]::WriteAllText($drawio, $x.ToString(), (New-Object System.Text.UTF8Encoding $false))

# ---------------------------------------------------------------------------
# Ausgabe: HTML
# ---------------------------------------------------------------------------
function ConvertTo-JsString([string]$s) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $s.ToCharArray()) {
        $c = [int]$ch
        if ($c -eq 34 -or $c -eq 92) { [void]$sb.Append('\').Append($ch) }
        elseif ($c -lt 0x20 -or $c -gt 0x7E -or $c -eq 60 -or $c -eq 62 -or $c -eq 38) { [void]$sb.Append('\u').Append($c.ToString('x4')) }
        else { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}
$jNodes = foreach ($n in $nodeList) {
    $sc = 'false'; if ($n.Scanned) { $sc = 'true' }
    $pt = ''; $mc = -1
    if ($swStats.Contains($n.Key)) { $pt = '{0}/{1}' -f $swStats[$n.Key].PortsUp, $swStats[$n.Key].PortsTotal; $mc = $swStats[$n.Key].Macs }
    '{"id":' + (ConvertTo-JsString $n.Id) + ',"name":' + (ConvertTo-JsString $n.Name) + ',"ip":' + (ConvertTo-JsString $n.Ip) + ',"descr":' + (ConvertTo-JsString $n.Descr) + ',"type":' + (ConvertTo-JsString $n.Type) + ',"scanned":' + $sc + ',"ports":' + (ConvertTo-JsString $pt) + ',"macs":' + $mc + '}'
}
$jLinks = foreach ($l in $linkList) {
    '{"a":' + (ConvertTo-JsString $nodes[$l.AKey].Id) + ',"aPort":' + (ConvertTo-JsString $l.APort) + ',"b":' + (ConvertTo-JsString $nodes[$l.BKey].Id) + ',"bPort":' + (ConvertTo-JsString $l.BPort) + ',"speed":' + [long]$l.Speed + ',"media":' + (ConvertTo-JsString $l.Media) + ',"label":' + (ConvertTo-JsString $l.Label) + ',"detail":' + (ConvertTo-JsString $l.Detail) + ',"via":' + (ConvertTo-JsString $l.Via) + '}'
}
$jEps = foreach ($e in $endpoints) {
    '{"sw":' + (ConvertTo-JsString $nodes[$e.SwitchKey].Id) + ',"port":' + (ConvertTo-JsString $e.Port) + ',"mac":' + (ConvertTo-JsString $e.Mac) + ',"ip":' + (ConvertTo-JsString $e.Ip) + ',"name":' + (ConvertTo-JsString $e.Name) + ',"note":' + (ConvertTo-JsString $e.Hinweis) + '}'
}
$json = '{"name":' + (ConvertTo-JsString $Name) + ',"generated":' + (ConvertTo-JsString (Get-Date -Format 'dd.MM.yyyy HH:mm')) + ',"nodes":[' + (@($jNodes) -join ',') + '],"links":[' + (@($jLinks) -join ',') + '],"endpoints":[' + (@($jEps) -join ',') + ']}'

$template = @'
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Netzplan</title>
<style>
*{box-sizing:border-box}
html,body{height:100%;margin:0}
body{font:14px/1.4 "Segoe UI",system-ui,-apple-system,Roboto,sans-serif;color:#17212b;background:#eef1f5;display:flex;flex-direction:column}
header{display:flex;align-items:center;gap:18px;flex-wrap:wrap;padding:10px 18px;background:#101b2b;color:#fff}
header h1{font-size:17px;margin:0;font-weight:650;letter-spacing:.2px}
header .sub{font-size:12px;color:#9fb0c5;margin-top:1px}
.chips{display:flex;gap:6px;flex-wrap:wrap;margin-left:auto}
.chip{display:inline-flex;align-items:center;gap:6px;padding:4px 10px;border-radius:999px;border:1px solid #33455c;background:transparent;color:#9fb0c5;font:inherit;font-size:12px;cursor:pointer;user-select:none}
.chip i{width:9px;height:9px;border-radius:50%;display:inline-block;opacity:.35}
.chip.on{background:#1d2c42;color:#fff;border-color:#4a6283}
.chip.on i{opacity:1}
.chip b{font-weight:600;color:inherit;opacity:.7}
.btns{display:flex;gap:6px}
.btn{padding:5px 11px;border-radius:6px;border:1px solid #33455c;background:#1d2c42;color:#fff;font:inherit;font-size:12px;cursor:pointer}
.btn:hover,.chip:hover{border-color:#7f9cc4}
main{flex:1;display:flex;min-height:0}
#cvwrap{flex:1;min-width:0;display:flex;flex-direction:column}
#cv{flex:1;min-height:0;width:100%;display:block;cursor:grab;touch-action:none;background:#eef1f5}
#cv.grabbing{cursor:grabbing}
#legend{display:flex;flex-wrap:wrap;align-items:center;gap:5px 18px;padding:7px 16px;background:#fff;border-top:1px solid #d5dbe3;font-size:12px;color:#27323e}
#legend span{display:inline-flex;align-items:center;gap:7px;white-space:nowrap}
#legend i{display:inline-block;width:26px;border-radius:2px}
#legend .sep{width:1px;height:16px;background:#d5dbe3}
aside{width:500px;max-width:45vw;background:#fff;border-left:1px solid #d5dbe3;display:flex;flex-direction:column;min-height:0}
#side{overflow-y:auto;overflow-x:hidden;padding:16px 16px 24px}
#side h2{font-size:15px;margin:0 0 2px}
#side .hint{color:#687888;font-size:12px;margin:0 0 12px}
#side .hd{display:flex;align-items:center;gap:8px;margin-bottom:8px}
#side .hd h2{margin:0}
#side .dot{width:11px;height:11px;border-radius:50%;flex:none}
#side dl{display:grid;grid-template-columns:82px 1fr;gap:3px 10px;margin:0 0 14px;font-size:12.5px}
#side dt{color:#687888}
#side dd{margin:0;word-break:break-word}
#side input{width:100%;padding:7px 10px;border:1px solid #c9d1db;border-radius:6px;font:inherit;margin-bottom:10px}
#side input:focus{outline:2px solid #1668c7;outline-offset:-1px}
table{border-collapse:collapse;width:100%;font-size:12.5px;table-layout:fixed}
th{text-align:left;color:#687888;font-weight:600;font-size:11px;text-transform:uppercase;letter-spacing:.4px;padding:4px 6px;border-bottom:1px solid #d5dbe3;position:sticky;top:-16px;background:#fff}
td{padding:6px 6px;border-bottom:1px solid #edf0f4;vertical-align:top;overflow-wrap:anywhere}
td.p,.dp{font-family:ui-monospace,Consolas,Menlo,monospace;font-size:12px}
td.lc{white-space:nowrap}
.dn{display:flex;align-items:baseline;gap:6px}
.dn .t{flex:none;margin-right:0}
.dp{color:#4d5c6b;font-size:11.5px;padding-left:13px;margin-top:1px}
.dp.sub{font-family:inherit;padding-left:0}
table.lt th:nth-child(2),table.nb th:nth-child(2){width:98px}
table.nb th:first-child{width:27%}
table.ep th:first-child{width:22%}
table.ep th:nth-child(2){width:44%}
td.nt{color:#687888;font-size:11.5px}
#side h3{font-size:13px;margin:20px 0 6px}
table.ep tbody tr{cursor:default}
tbody tr{cursor:pointer}
tbody tr:hover{background:#f2f6fb}
td .t{display:inline-block;width:7px;height:7px;border-radius:50%;margin-right:6px;vertical-align:1px}
.back{background:none;border:0;color:#1668c7;font:inherit;font-size:12.5px;padding:0;margin-bottom:10px;cursor:pointer}
@media print{header .chips,header .btns,aside,#legend{display:none}header{background:#fff;color:#000}header .sub{color:#444}}
</style>
</head>
<body>
<header>
  <div><h1 id="ttl"></h1><div class="sub" id="sub"></div></div>
  <div class="chips" id="chips"></div>
  <div class="btns">
    <button class="btn" id="bFit">Einpassen</button>
    <button class="btn" id="bReset">Layout zur&uuml;cksetzen</button>
    <button class="btn" id="bSvg">Als SVG speichern</button>
  </div>
</header>
<main>
<div id="cvwrap">
<svg id="cv" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <style>
      .lk{fill:none}
      .lk.dim{opacity:.18}
      .pl rect{fill:#fff;stroke:#b9c3cf;stroke-width:1}
      .pl text{font:11px ui-monospace,Consolas,Menlo,monospace;fill:#27323e}
      .pl.hot rect{stroke:#1668c7;fill:#eaf2fc}
      .pl.dim{opacity:.15}
      .ml rect{fill:#fff;stroke-width:1.4}
      .ml text{font:600 10.5px "Segoe UI",system-ui,sans-serif;fill:#27323e}
      .ml.dim{opacity:.15}
      .nd{cursor:pointer}
      .nd .card{fill:#fff;stroke:#c3ccd7;stroke-width:1.2}
      .nd.ghost .card{stroke-dasharray:5 4;fill:#f8f9fb}
      .nd.sel .card{stroke:#1668c7;stroke-width:2.5}
      .nd.dim{opacity:.3}
      .nd .nm{font:600 13px "Segoe UI",system-ui,sans-serif;fill:#17212b}
      .nd .nm.sm{font-size:12px}
      .nd .ip{font:11px ui-monospace,Consolas,Menlo,monospace;fill:#4d5c6b}
      .nd .ds{font:10px "Segoe UI",system-ui,sans-serif;fill:#8491a0}
    </style>
    <pattern id="dots" width="24" height="24" patternUnits="userSpaceOnUse"><circle cx="1.2" cy="1.2" r="1.2" fill="#d3dae3"/></pattern>
    <filter id="sh" x="-10%" y="-20%" width="120%" height="150%"><feDropShadow dx="0" dy="2" stdDeviation="3" flood-color="#1b2a3d" flood-opacity=".13"/></filter>
  </defs>
  <rect id="bg" x="0" y="0" width="100%" height="100%" fill="url(#dots)"/>
  <g id="root"><g id="gL"></g><g id="gP"></g><g id="gN"></g></g>
</svg>
<div id="legend"></div>
</div>
<aside><div id="side"></div></aside>
</main>
<script>const DATA = __DATA__;</script>
<script>
(function(){
'use strict';
const NS='http://www.w3.org/2000/svg';
const TYPES={switch:['Switches','Switch','#1668c7'],router:['Router','Router/Firewall','#7b46d6'],ap:['APs','Access Point','#0c8a5f'],phone:['Telefone','Telefon','#c56a00'],host:['Server/Ger\u00e4te','Server/Ger\u00e4t (SNMP)','#0e8074'],other:['Sonstige','Sonstiges','#66727f']};
const MEDIA={lwl:['LWL (Glasfaser)','#e07c0c'],aoc:['AOC (aktives optisches Kabel)','#e07c0c'],dac:['DAC (Twinax)','#111827'],kupfer:['Kupfer (Twisted Pair)','#4f7396'],sfp:['SFP, Medium unbekannt','#8b5cf6'],bp:['Backplane','#0f766e'],'':['unbekannt','#9aa5b1']};
const lw=function(s){return s>=25000?5:s>=10000?3.8:s>=2500?2.9:s>=1000?2.2:s>0?1.4:2;};
const show={switch:true,router:true,ap:false,phone:false,host:true,other:false};
const nodes=DATA.nodes,links=DATA.links,byId={};
nodes.forEach(function(n){byId[n.id]=n;n.x=0;n.y=0;});
const GAPX=44,GAPY=170,LSKEY='netzplan:'+DATA.name+':'+nodes.length+':'+links.length;
const svg=document.getElementById('cv'),root=document.getElementById('root'),gL=document.getElementById('gL'),gP=document.getElementById('gP'),gN=document.getElementById('gN');
let view={x:0,y:0,k:1},selected=null,filter='',raf=0;

const isBig=function(n){return n.type==='switch'||n.type==='router';};
const sz=function(n){return {w:n.w||204,h:n.h||66};};
function measure(){
  const deg={};visLinks().forEach(function(l){deg[l.a]=(deg[l.a]||0)+1;deg[l.b]=(deg[l.b]||0)+1;});
  nodes.forEach(function(n){if(isBig(n)){n.w=Math.max(204,Math.min(460,24+44*(deg[n.id]||0)));n.h=66;}else{n.w=158;n.h=42;}});
}
const cut=function(s,n){s=s||'';return s.length>n?s.slice(0,n-1)+'\u2026':s;};
const nat=function(a,b){return String(a).localeCompare(String(b),undefined,{numeric:true,sensitivity:'base'});};
function S(tag,attrs,parent,text){const e=document.createElementNS(NS,tag);for(const k in attrs)e.setAttribute(k,attrs[k]);if(text!=null)e.textContent=text;if(parent)parent.appendChild(e);return e;}
function H(tag,attrs,parent,text){const e=document.createElement(tag);for(const k in (attrs||{}))e.setAttribute(k,attrs[k]);if(text!=null)e.textContent=text;if(parent)parent.appendChild(e);return e;}
let forced={};
const vis=function(n){return show[n.type]||!!forced[n.id];};
// Haengt ein sichtbares Geraet laut MAC-Tabelle an einem ausgeblendeten Knoten (z. B. WLAN-Drucker am AP), wird der mit angezeigt
function recalcForced(){forced={};links.forEach(function(l){if(l.via==='mac'&&show[byId[l.b].type]&&!show[byId[l.a].type])forced[l.a]=true;});}
const visLinks=function(){return links.filter(function(l){return vis(byId[l.a])&&vis(byId[l.b]);});};
function neighbors(id){const s=new Set();links.forEach(function(l){if(l.a===id)s.add(l.b);if(l.b===id)s.add(l.a);});return s;}

function layout(){
  measure();
  const v=nodes.filter(vis),adj={};
  v.forEach(function(n){adj[n.id]=new Set();});
  visLinks().forEach(function(l){if(l.a!==l.b){adj[l.a].add(l.b);adj[l.b].add(l.a);}});
  const rank=function(a,b){const A=byId[a],B=byId[b];return (isBig(B)-isBig(A))||(adj[b].size-adj[a].size)||nat(A.name,B.name);};
  const seen=new Set();let offX=0;
  v.map(function(n){return n.id;}).sort(rank).forEach(function(r){
    if(seen.has(r))return;
    const kids={},depth={},width={},q=[r];seen.add(r);depth[r]=0;
    while(q.length){const u=q.shift();kids[u]=[];Array.from(adj[u]).sort(rank).forEach(function(w){if(!seen.has(w)){seen.add(w);depth[w]=depth[u]+1;kids[u].push(w);q.push(w);}});}
    const calc=function(u){let s=0;kids[u].forEach(function(k){s+=calc(k);});return width[u]=Math.max(sz(byId[u]).w+GAPX,s);};
    const place=function(u,x0){let s=0;kids[u].forEach(function(k){s+=width[k];});byId[u].x=x0+width[u]/2;byId[u].y=depth[u]*GAPY;let cx=x0+(width[u]-s)/2;kids[u].forEach(function(k){place(k,cx);cx+=width[k];});};
    calc(r);place(r,offX);offX+=width[r]+90;
  });
}
function loadPos(){try{const p=JSON.parse(localStorage.getItem(LSKEY)||'{}');nodes.forEach(function(n){if(p[n.id]){n.x=p[n.id][0];n.y=p[n.id][1];}});}catch(e){}}
function savePos(){try{const p=JSON.parse(localStorage.getItem(LSKEY)||'{}');nodes.filter(vis).forEach(function(n){p[n.id]=[Math.round(n.x),Math.round(n.y)];});localStorage.setItem(LSKEY,JSON.stringify(p));}catch(e){}}
function clearPos(){try{localStorage.removeItem(LSKEY);}catch(e){}}

const lblW=function(t){return cut(t,24).length*6.7+14;};
function anchors(vl){
  const ends={},out=[];
  const push=function(id,side,e){const n=ends[id]=ends[id]||{};(n[side]=n[side]||[]).push(e);};
  vl.forEach(function(l,i){
    const A=byId[l.a],B=byId[l.b],dx=B.x-A.x,dy=B.y-A.y;out.push({});
    let sa,sb;
    if(Math.abs(dy)>Math.abs(dx)*0.3){sa=dy>0?'bottom':'top';sb=dy>0?'top':'bottom';}
    else{sa=dx>0?'right':'left';sb=dx>0?'left':'right';}
    push(l.a,sa,{i:i,o:B,end:'a',text:l.aPort});push(l.b,sb,{i:i,o:A,end:'b',text:l.bPort});
  });
  Object.keys(ends).forEach(function(id){
    const N=byId[id],s=sz(N);
    Object.keys(ends[id]).forEach(function(side){
      const vert=side==='top'||side==='bottom',list=ends[id][side];
      list.sort(function(p,q){return vert?(p.o.x-q.o.x)||(p.i-q.i):(p.o.y-q.o.y)||(p.i-q.i);});
      const n=list.length,step=(vert?s.w:s.h)/(n+1);
      let maxW=0;list.forEach(function(e){maxW=Math.max(maxW,lblW(e.text));});
      const rows=Math.max(1,Math.min(3,Math.ceil((vert?maxW+6:21)/step)));
      list.forEach(function(e,k){
        const pt=vert?{x:N.x-s.w/2+step*(k+1),y:N.y+(side==='bottom'?s.h/2:-s.h/2)}:{x:N.x+(side==='right'?s.w/2:-s.w/2),y:N.y-s.h/2+step*(k+1)};
        pt.vert=vert;pt.row=k%rows;pt.maxW=maxW;out[e.i][e.end]=pt;
      });
    });
  });
  return out;
}
function portLabel(p,q,text,cls){
  if(!text)return;
  const dx=q.x-p.x,dy=q.y-p.y,len=Math.hypot(dx,dy)||1,ux=dx/len,uy=dy/len,txt=cut(text,24),w=lblW(text);
  let t=p.vert?(14+p.row*22)/Math.max(Math.abs(uy),0.2):(w/2+8+p.row*(p.maxW+6))/Math.max(Math.abs(ux),0.2);
  t=Math.min(t,len*0.45);
  const cx=p.x+ux*t,cy=p.y+uy*t,g=S('g',{'class':'pl'+cls},gP);
  S('title',{},g,text);
  S('rect',{x:cx-w/2,y:cy-9.5,width:w,height:19,rx:9.5},g);
  S('text',{x:cx,y:cy+4,'text-anchor':'middle'},g,txt);
}
function drawLink(l,an,mid){
  const hot=selected&&(l.a===selected||l.b===selected),cls=hot?' hot':(selected?' dim':''),m=MEDIA[l.media]||MEDIA[''];
  const la={x1:an.a.x,y1:an.a.y,x2:an.b.x,y2:an.b.y,'class':'lk'+cls,stroke:m[1],'stroke-width':lw(l.speed)+(hot?1.2:0)};
  if(l.via==='mac')la['stroke-dasharray']='6 5';
  S('line',la,gL);
  portLabel(an.a,an.b,l.aPort,cls);
  portLabel(an.b,an.a,l.bPort,cls);
  if(mid){
    const w=mid.text.length*6.2+14,g=S('g',{'class':'ml'+cls},gP);
    S('title',{},g,l.detail?mid.text+' ('+l.detail+')':mid.text);
    S('rect',{x:mid.x-w/2,y:mid.y-8.5,width:w,height:17,rx:4,stroke:m[1]},g);
    S('text',{x:mid.x,y:mid.y+3.8,'text-anchor':'middle'},g,mid.text);
  }
}
function drawNode(n,nb){
  const s=sz(n),c=TYPES[n.type][2];
  let cls='nd'+(n.scanned?'':' ghost');
  if(selected===n.id)cls+=' sel';else if(selected&&!nb.has(n.id))cls+=' dim';
  const g=S('g',{'class':cls,'data-id':n.id,transform:'translate('+(n.x-s.w/2)+','+(n.y-s.h/2)+')'},gN);
  S('title',{},g,[n.name,n.ip,n.descr,n.scanned?'':'nicht per SNMP abgefragt'].filter(Boolean).join('\n'));
  S('rect',{'class':'card',width:s.w,height:s.h,rx:10,filter:'url(#sh)'},g);
  S('rect',{x:8,y:9,width:5,height:s.h-18,rx:2.5,fill:c},g);
  if(isBig(n)){
    S('text',{'class':'nm',x:24,y:25},g,cut(n.name,Math.floor((s.w-36)/7.4)));
    S('text',{'class':'ip',x:24,y:41},g,n.ip||'keine IP gemeldet');
    S('text',{'class':'ds',x:24,y:55},g,cut(n.ports?n.ports+' Ports aktiv \u00b7 '+n.macs+' Endger\u00e4te':n.descr,Math.floor((s.w-36)/5.3)));
  }else{
    S('text',{'class':'nm sm',x:22,y:18},g,cut(n.name,19));
    S('text',{'class':'ip',x:22,y:32},g,n.ip||cut(n.descr,20));
  }
}
function render(){
  gL.textContent='';gP.textContent='';gN.textContent='';
  const vl=visLinks(),an=anchors(vl),pairs={},mids=[];
  vl.forEach(function(l,i){const k=l.a<l.b?l.a+'|'+l.b:l.b+'|'+l.a;(pairs[k]=pairs[k]||[]).push(i);});
  const at=function(i,t){return {x:an[i].a.x+(an[i].b.x-an[i].a.x)*t,y:an[i].a.y+(an[i].b.y-an[i].a.y)*t};};
  Object.keys(pairs).forEach(function(k){
    const g=pairs[k],f=vl[g[0]];
    if(g.every(function(i){return vl[i].label===f.label&&vl[i].media===f.media;})){
      // gleiche parallele Links (LAG): eine gemeinsame Beschriftung
      if(!f.label)return;
      let x=0,y=0;g.forEach(function(i){const p=at(i,0.5);x+=p.x;y+=p.y;});
      mids[g[0]]={x:x/g.length,y:y/g.length,text:(g.length>1?g.length+'\u00d7 ':'')+f.label};
    }else g.forEach(function(i,j){if(vl[i].label){const p=at(i,0.5+(j-(g.length-1)/2)*0.2);mids[i]={x:p.x,y:p.y,text:vl[i].label};}});
  });
  vl.forEach(function(l,i){drawLink(l,an[i],mids[i]);});
  const nb=selected?neighbors(selected):new Set();
  nodes.filter(vis).forEach(function(n){drawNode(n,nb);});
}
function schedule(){if(!raf)raf=requestAnimationFrame(function(){raf=0;render();});}
function applyView(){root.setAttribute('transform','translate('+view.x+','+view.y+') scale('+view.k+')');}
function bbox(){
  const v=nodes.filter(vis);if(!v.length)return null;
  let x1=1e9,y1=1e9,x2=-1e9,y2=-1e9;
  v.forEach(function(n){const s=sz(n);x1=Math.min(x1,n.x-s.w/2);y1=Math.min(y1,n.y-s.h/2);x2=Math.max(x2,n.x+s.w/2);y2=Math.max(y2,n.y+s.h/2);});
  return {x:x1,y:y1,w:x2-x1,h:y2-y1};
}
function fit(){
  const b=bbox();if(!b)return;
  const r=svg.getBoundingClientRect(),W=r.width||1200,Hh=r.height||700;
  view.k=Math.max(0.12,Math.min(1.2,(W-90)/b.w,(Hh-90)/b.h));
  view.x=(W-b.w*view.k)/2-b.x*view.k;view.y=(Hh-b.h*view.k)/2-b.y*view.k;applyView();
}

// --- Seitenleiste ---------------------------------------------------------
function typeDot(parent,n){const i=H('span',{'class':'t'},parent);i.style.background=TYPES[n.type][2];return i;}
function devCell(tr,n,port){const c=H('td',{},tr),a=H('div',{'class':'dn'},c);typeDot(a,n);H('span',{},a,n.name);if(port)H('div',{'class':'dp'},c,port);return c;}
function linkCell(tr,l){const c=H('td',{'class':'lc'},tr);if(l.label){const i=H('span',{'class':'t'},c);i.style.background=(MEDIA[l.media]||MEDIA[''])[1];i.style.borderRadius='2px';c.appendChild(document.createTextNode(l.label));if(l.detail)c.title=l.detail;}return c;}
function legend(){
  const box=document.getElementById('legend'),vl=visLinks();box.textContent='';
  const used={};vl.forEach(function(l){used[l.media||'']=true;});
  ['lwl','aoc','dac','kupfer','sfp','bp',''].forEach(function(k){if(!used[k])return;const d=H('span',{},box),i=H('i',{},d);i.style.height='3px';i.style.background=MEDIA[k][1];d.appendChild(document.createTextNode(MEDIA[k][0]));});
  const steps=[[100,'bis 100M',0,1000],[1000,'1G',1000,2500],[2500,'2.5G / 5G',2500,10000],[10000,'10G',10000,25000],[25000,'ab 25G',25000,1e12]].filter(function(s){return vl.some(function(l){return l.speed>0&&l.speed>=s[2]&&l.speed<s[3];});});
  if(vl.some(function(l){return l.via==='mac';})){const d=H('span',{},box),i=H('i',{},d);i.style.height='0';i.style.borderTop='2px dashed #5d6b78';i.style.borderRadius='0';d.appendChild(document.createTextNode('per MAC-Tabelle zugeordnet'));}
  if(steps.length&&box.childNodes.length)H('span',{'class':'sep'},box);
  steps.forEach(function(s){const d=H('span',{},box),e=H('i',{},d);e.style.height=lw(s[0])+'px';e.style.background='#5d6b78';d.appendChild(document.createTextNode(s[1]));});
  box.style.display=box.childNodes.length?'':'none';
}
function select(id){selected=id;render();side();}
function side(){
  const box=document.getElementById('side');box.textContent='';
  if(selected){
    const n=byId[selected];
    H('button',{'class':'back'},box,'\u2190 alle Verbindungen').onclick=function(){select(null);};
    const hd=H('div',{'class':'hd'},box);const d=H('span',{'class':'dot'},hd);d.style.background=TYPES[n.type][2];H('h2',{},hd,n.name);
    const dl=H('dl',{},box);
    [['IP',n.ip||'\u2013'],['Typ',TYPES[n.type][1]],['System',n.descr||'\u2013']].concat(n.ports?[['Ports',n.ports+' aktiv'],['Endger\u00e4te',n.macs+' MAC-Adressen an diesem Switch']]:[]).concat([['Abfrage',n.scanned?'per SNMP ausgelesen':'nur per LLDP vom Nachbarn gemeldet']]).forEach(function(r){H('dt',{},dl,r[0]);H('dd',{},dl,r[1]);});
    const rows=links.filter(function(l){return l.a===n.id||l.b===n.id;}).map(function(l){return l.a===n.id?{p:l.aPort,o:byId[l.b],op:l.bPort,l:l}:{p:l.bPort,o:byId[l.a],op:l.aPort,l:l};}).sort(function(a,b){return nat(a.p,b.p);});
    const t=H('table',{'class':'nb'},box),th=H('tr',{},H('thead',{},t));['Port','Link','Nachbar / Port'].forEach(function(x){H('th',{},th,x);});
    const tb=H('tbody',{},t);
    rows.forEach(function(r){const tr=H('tr',{},tb);H('td',{'class':'p'},tr,r.p);linkCell(tr,r.l);devCell(tr,r.o,r.op);
      tr.onclick=function(){if(!show[r.o.type]){show[r.o.type]=true;chips();relayout();}select(r.o.id);};});
    if(!rows.length)H('p',{'class':'hint'},box,'Keine LLDP-Nachbarn.');
    const eps=(DATA.endpoints||[]).filter(function(e){return e.sw===n.id;}).sort(function(a,b){return nat(a.port,b.port)||nat(a.mac,b.mac);});
    if(eps.length){
      H('h3',{},box,'Endger\u00e4te laut MAC-Tabelle ('+eps.length+')');
      const t2=H('table',{'class':'ep'},box),h2=H('tr',{},H('thead',{},t2));['Port','Ger\u00e4t','Hinweis'].forEach(function(x){H('th',{},h2,x);});
      const b2=H('tbody',{},t2);
      eps.forEach(function(e){const tr=H('tr',{},b2);H('td',{'class':'p'},tr,e.port);const c=H('td',{},tr);H('div',{'class':'dp sub',style:'font-family:ui-monospace,Consolas,Menlo,monospace;color:#17212b'},c,e.mac);const w=[e.name,e.ip].filter(Boolean).join(' \u00b7 ');if(w)H('div',{'class':'dp sub'},c,w);H('td',{'class':'nt'},tr,e.note);});
    }
  }else{
    H('h2',{},box,'Verbindungen');
    H('p',{'class':'hint'},box,'Ger\u00e4t im Plan anklicken zeigt dessen Portbelegung. Knoten lassen sich verschieben.');
    const inp=H('input',{type:'search',placeholder:'Filtern nach Ger\u00e4t, IP oder Port \u2026'},box);inp.value=filter;
    const t=H('table',{'class':'lt'},box),th=H('tr',{},H('thead',{},t));['Von','Link','Nach'].forEach(function(x){H('th',{},th,x);});
    const tb=H('tbody',{},t);
    const fill=function(){
      tb.textContent='';const f=filter.toLowerCase();
      visLinks().forEach(function(l){const A=byId[l.a],B=byId[l.b];
        if(f&&[A.name,A.ip,l.aPort,l.label,l.detail,l.bPort,B.name,B.ip].join(' ').toLowerCase().indexOf(f)<0)return;
        const tr=H('tr',{},tb);devCell(tr,A,l.aPort);linkCell(tr,l);devCell(tr,B,l.bPort);
        tr.onclick=function(){select(l.a);};});
    };
    inp.oninput=function(){filter=inp.value;fill();};fill();
  }
}

// --- Kopfzeile ------------------------------------------------------------
function chips(){
  const box=document.getElementById('chips');box.textContent='';
  Object.keys(TYPES).forEach(function(t){
    const cnt=nodes.filter(function(n){return n.type===t;}).length;if(!cnt)return;
    const b=H('button',{'class':'chip'+(show[t]?' on':'')},box);const i=H('i',{},b);i.style.background=TYPES[t][2];
    b.appendChild(document.createTextNode(TYPES[t][0]+' '));H('b',{},b,String(cnt));
    b.onclick=function(){show[t]=!show[t];if(selected&&!vis(byId[selected]))selected=null;chips();relayout();side();};
  });
}
function relayout(){recalcForced();legend();layout();loadPos();render();fit();}

// --- Maus -----------------------------------------------------------------
let drag=null;
svg.addEventListener('pointerdown',function(e){
  if(e.button!==0)return;
  const g=e.target.closest?e.target.closest('.nd'):null;
  try{svg.setPointerCapture(e.pointerId);}catch(x){}
  if(g){const n=byId[g.getAttribute('data-id')];drag={n:n,sx:e.clientX,sy:e.clientY,ox:n.x,oy:n.y,moved:false};}
  else{drag={pan:true,sx:e.clientX,sy:e.clientY,ox:view.x,oy:view.y,moved:false};svg.classList.add('grabbing');}
});
svg.addEventListener('pointermove',function(e){
  if(!drag)return;
  const dx=e.clientX-drag.sx,dy=e.clientY-drag.sy;
  if(Math.abs(dx)+Math.abs(dy)>3)drag.moved=true;
  if(!drag.moved)return;
  if(drag.pan){view.x=drag.ox+dx;view.y=drag.oy+dy;applyView();}
  else{drag.n.x=drag.ox+dx/view.k;drag.n.y=drag.oy+dy/view.k;schedule();}
});
function endDrag(){
  if(!drag)return;const d=drag;drag=null;svg.classList.remove('grabbing');
  if(d.pan){if(!d.moved&&selected)select(null);}
  else if(d.moved)savePos();
  else select(selected===d.n.id?null:d.n.id);
}
svg.addEventListener('pointerup',endDrag);
svg.addEventListener('pointercancel',function(){drag=null;svg.classList.remove('grabbing');});
svg.addEventListener('wheel',function(e){
  e.preventDefault();
  const r=svg.getBoundingClientRect(),mx=e.clientX-r.left,my=e.clientY-r.top;
  const k=Math.min(3,Math.max(0.12,view.k*Math.exp(-e.deltaY*0.0015)));
  view.x=mx-(mx-view.x)*(k/view.k);view.y=my-(my-view.y)*(k/view.k);view.k=k;applyView();
},{passive:false});

document.getElementById('bFit').onclick=fit;
document.getElementById('bReset').onclick=function(){clearPos();layout();render();fit();};
document.getElementById('bSvg').onclick=function(){
  const b=bbox();if(!b)return;
  const pad=40,c=svg.cloneNode(true),vb=[b.x-pad,b.y-pad,b.w+2*pad,b.h+2*pad];
  c.querySelector('#root').removeAttribute('transform');
  c.setAttribute('viewBox',vb.join(' '));c.setAttribute('width',vb[2]);c.setAttribute('height',vb[3]);c.removeAttribute('class');
  const bg=c.querySelector('#bg');bg.setAttribute('x',vb[0]);bg.setAttribute('y',vb[1]);bg.setAttribute('width',vb[2]);bg.setAttribute('height',vb[3]);bg.setAttribute('fill','#ffffff');
  c.querySelectorAll('.dim').forEach(function(x){x.classList.remove('dim');});
  const blob=new Blob(['<?xml version="1.0" encoding="UTF-8"?>\n'+new XMLSerializer().serializeToString(c)],{type:'image/svg+xml'});
  const a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download=DATA.name+'.svg';document.body.appendChild(a);a.click();a.remove();
};
window.addEventListener('resize',function(){if(!drag)fit();});

document.title='Netzplan '+DATA.name;
document.getElementById('ttl').textContent='Netzplan '+DATA.name;
const cnt=function(t){return nodes.filter(function(n){return n.type===t;}).length;};
document.getElementById('sub').textContent=cnt('switch')+' Switches \u00b7 '+nodes.length+' Ger\u00e4te \u00b7 '+links.length+' Verbindungen \u00b7 Stand '+DATA.generated;
chips();relayout();side();
})();
</script>
</body>
</html>
'@
$html = Join-Path $OutDir ($Name + '.html')
[System.IO.File]::WriteAllText($html, $template.Replace('__DATA__', $json), (New-Object System.Text.UTF8Encoding $false))

# ---------------------------------------------------------------------------
# Zusammenfassung
# ---------------------------------------------------------------------------
$bigText = @('Switch', 'Router/Firewall')
$swLinks = @($linkRows | Where-Object { $bigText -contains $_.TypA -and $bigText -contains $_.TypB })
Write-Host ''
Write-Host ("{0} Geraete, {1} Verbindungen ({2} zwischen Switchen/Routern):" -f $nodeList.Count, $linkList.Count, $swLinks.Count)
$swLinks | Format-Table GeraetA, PortA, Link, PortB, GeraetB, GemeldetVon -AutoSize | Out-String -Width 200 | Write-Host
if ($swRows.Count -gt 0) {
    Write-Host 'Ports und Endgeraete je Switch (jede MAC-Adresse zaehlt nur an ihrem Anschlussport):'
    $swRows | Format-Table Switch, PortsAktiv, PortsGesamt, PortsMitEndgeraet, Endgeraete, DavonWLAN -AutoSize | Out-String -Width 200 | Write-Host
    Write-Host ("Summe: {0} MAC-Adressen, davon {1} hinter Access Points." -f ($swRows | Measure-Object Endgeraete -Sum).Sum, ($swRows | Measure-Object DavonWLAN -Sum).Sum)
    Write-Host ''
}
Write-Host "Netzplan:  $html"
Write-Host "draw.io:   $drawio"
Write-Host "CSV:       $csvLinks"
Write-Host "           $csvDevs"
if (-not $NoMacTable) {
    Write-Host "           $csvSw"
    Write-Host "           $csvEp"
}
