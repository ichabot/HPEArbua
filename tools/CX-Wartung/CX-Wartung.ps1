<#
.SYNOPSIS
  CX-Wartung.ps1 - Wartungsfenster-Automation fuer HPE Aruba Networking CX Switches
  (Firmware-Updates in Wellen, Backup, Basis-Konfiguration, STP, VLANs, Inventar).

.DESCRIPTION
  Jede Phase einzeln starten und danach selbst pruefen (Go/No-Go).
  Alle Kundendaten (CSV-Dateien, Backups, Logs) liegen im AKTUELLEN Ordner, nicht beim Skript.

    Backup   - running-config, LLDP, Version, Images, Transceiver, Interfaces, show system je Switch sichern (nur lesend)
    Stage1   - Access: Image Welle 1 -> secondary | Core: Core-Image -> secondary   (kein Neustart)
    Stage2   - Access: erst "boot set-default secondary", dann Image Welle 2 -> primary (kein Neustart)
    Welle1   - Access: boot system secondary   (NEUSTART) + Versionspruefung
    Welle2   - Access: boot system primary     (NEUSTART) + Versionspruefung
    Cores    - Cores EINZELN nacheinander: boot system secondary (NEUSTART) + Versionspruefung
    Hostname - setzt den Hostnamen jedes Switches auf die Spalte Name aus switches.csv, write memory
    Basis    - Default-Gateway, DNS, NTP, Zeitzone, Pruefung per show ip route, write memory
    Passwort - neues Passwort fuer den angemeldeten User (zweimal abgefragt, nie im Log), danach Login-Test, Abbruch beim ersten Fehler
    Banner   - setzt leeren motd (ersetzt Default "Please register..."), entfernt exec-Banner, write memory
    Inventar - Rack -> snmp-server system-location, Inventar-Nr. -> snmp-server system-contact, write memory
    STP      - Priorities aus switches.csv, Pruefung Bridge-/Root-Priority nach jedem Geraet, write memory
    VLAN     - VLANs aus vlans.csv, Trunks aus trunks.csv, Pruefung, write memory

  -DryRun  zeigt nur an, was passieren wuerde (keine Verbindung, keine Aenderung).
  -Only    nur eine IP bearbeiten (Einzeltest).
  -Gruppe  nur Switches dieser Gruppe aus switches.csv (Gruppen frei waehlbar, z. B. 0 = Cores, 1..n = Ketten/Gebaeude).
  Typ in switches.csv: Core oder Access (6100/6000/6200 ... gelten als Access).
  Neustart-Phasen ueberspringen Switches, die schon mit der Zielversion laufen.
  Reihenfolge innerhalb einer Gruppe = Zeilenreihenfolge in switches.csv.

  Sicherheitsnetz:
  - Neustart-Phasen pruefen VORHER auf allen Zielen die Ziel-Partition. Passt eine nicht -> Abbruch, nichts startet neu.
  - Vor jedem Neustart und zwischen Gruppen: Bestaetigung mit "JA".
  - Jeder Fehler stoppt das Skript. Log unter .\logs\

.EXAMPLE
  .\CX-Wartung.ps1 -Phase Backup
  .\CX-Wartung.ps1 -Phase Stage1 -Tftp 10.0.0.5 -ImageAccessWelle1 PL_10_13_1190.swi -ImageCore FL_10_16_1060.swi -DryRun
  .\CX-Wartung.ps1 -Phase Welle1 -VersionAccessWelle1 10.13 -VersionAccessWelle2 10.16 -Gruppe 1
  .\CX-Wartung.ps1 -Phase Basis -Gateway 10.0.0.1 -Dns 10.0.0.1 -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Backup', 'Stage1', 'Stage2', 'Welle1', 'Welle2', 'Cores', 'STP', 'VLAN', 'Basis', 'Hostname', 'Banner', 'Inventar', 'Passwort')]
    [string]$Phase,

    [string]$SwitchCsv = '.\switches.csv',
    [string]$VlanCsv   = '.\vlans.csv',
    [string]$TrunkCsv  = '.\trunks.csv',
    [string]$Tftp      = '',
    [string]$Gateway   = '',
    [string]$Dns       = '',
    [string]$Ntp       = 'pool.ntp.org',
    [string]$Timezone  = 'europe/berlin',

    [Alias('Image6100Welle1')][string]$ImageAccessWelle1 = '',
    [Alias('Image6100Welle2')][string]$ImageAccessWelle2 = '',
    [string]$ImageCore = '',

    # Leer = wird aus dem Image-Namen abgeleitet (z. B. PL_10_16_1060.swi -> 10.16.1060). Fuer Neustart-Phasen angeben.
    [Alias('Version6100Welle1')][string]$VersionAccessWelle1 = '',
    [Alias('Version6100Welle2')][string]$VersionAccessWelle2 = '',
    [string]$VersionCore = '',

    [string]$Only = '',
    [string]$Gruppe = '',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- Vorbereitung
$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$logDir = Join-Path (Get-Location) 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
Start-Transcript -Path (Join-Path $logDir ("CX-Wartung_{0}_{1}.log" -f $Phase, $stamp)) | Out-Null

if (-not (Get-Module -ListAvailable -Name Posh-SSH)) {
    Write-Host 'Installiere Posh-SSH ...'
    Install-Module -Name Posh-SSH -Scope CurrentUser -Force
}
Import-Module Posh-SSH

$all = Import-Csv -Path $SwitchCsv -Delimiter ';'
$switches = @($all | Where-Object { $_.Aktiv -match '^(ja|yes|1|true)$' })
if ($Only)   { $switches = @($switches | Where-Object { $_.IP -eq $Only }) }
if ($Gruppe) { $switches = @($switches | Where-Object { $_.Gruppe -eq $Gruppe }) }
if ($switches.Count -eq 0) { throw "Keine aktiven Switches (Filter: '$Only') in $SwitchCsv." }

$script:Cred = $null
if (-not $DryRun) { $script:Cred = Get-Credential -Message 'Admin-Zugang Aruba CX' }

# Rolle aus Spalte Typ: Core oder Access (6100, 6000, 6200 ... = Access)
function Test-Access($Sw) { return ($Sw.Typ -ne 'Core') }
function Test-Core($Sw)   { return ($Sw.Typ -eq 'Core') }

# Version aus Image-Namen ableiten: PL_10_16_1060.swi -> 10.16.1060
function Get-VersionFromImage([string]$Image) {
    if ($Image -match '(\d+)_(\d+)_(\d+)') { return "$($Matches[1]).$($Matches[2]).$($Matches[3])" }
    return ''
}
function Resolve-Version([string]$Version, [string]$Image, [string]$ParamName) {
    if ($Version) { return $Version }
    $v = Get-VersionFromImage $Image
    if ($v) { return $v }
    throw "Parameter -$ParamName (z. B. 10.16.1060) oder das zugehoerige Image fehlt."
}
function Assert-Param([string]$Value, [string]$ParamName) {
    if (-not $Value) { throw "Parameter -$ParamName fehlt fuer Phase $Phase." }
}

# Prompt am Ende der Ausgabe, z. B. "SW-ACCESS-01# " oder "SW-ACCESS-01(config)# "
$PromptRx = '(?:^|\n)[\w.\-]+(\([\w\-/]+\))?# ?$'
$YesNoRx  = '\(y/n\)\??\s*$'

# ---------------------------------------------------------------- Hilfsfunktionen
function Write-Ok   ($t) { Write-Host "OK      $t" -ForegroundColor Green }
function Write-Step ($t) { Write-Host "`n=== $t" -ForegroundColor Cyan }

function Get-CleanText([string]$t) {
    return ($t -replace '\x1B\[[0-9;?]*[A-Za-z]', '' -replace "`r", '')
}

function Confirm-Go([string]$Text) {
    if ($DryRun) { return }
    $a = Read-Host "$Text  -> Zum Fortfahren JA eingeben"
    if ($a -cne 'JA') { throw 'Abgebrochen durch Benutzer.' }
}

function Read-Until {
    param($Stream, [string[]]$Patterns, [int]$TimeoutSec = 60)
    $buf = ''
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $chunk = $Stream.Read()
        if ($chunk) {
            $buf += $chunk
            $clean = Get-CleanText $buf
            foreach ($p in $Patterns) {
                if ($clean -match $p) { return [pscustomobject]@{ Text = $clean; Match = $p } }
            }
        }
        else { Start-Sleep -Milliseconds 300 }
    }
    $tail = (Get-CleanText $buf)
    if ($tail.Length -gt 300) { $tail = $tail.Substring($tail.Length - 300) }
    throw "Timeout nach $TimeoutSec s. Letzte Ausgabe: $tail"
}

function Open-CX([string]$Ip) {
    $s  = New-SSHSession -ComputerName $Ip -Credential $script:Cred -AcceptKey -ConnectionTimeout 20 -ErrorAction Stop
    $st = New-SSHShellStream -SSHSession $s -Columns 250 -Rows 100
    $c  = [pscustomobject]@{ IP = $Ip; Session = $s; Stream = $st }
    $null = Read-Until $st @($PromptRx) 30
    $null = Invoke-CX $c 'no page' 20
    return $c
}

function Close-CX($Conn) {
    if (-not $Conn) { return }
    try { $Conn.Stream.Dispose() } catch { }
    try { Remove-SSHSession -SSHSession $Conn.Session -ErrorAction SilentlyContinue | Out-Null } catch { }
}

function Invoke-CX {
    param($Conn, [string]$Command, [int]$TimeoutSec = 60, [string]$Answer = 'y')
    $Conn.Stream.WriteLine($Command)
    $out = ''
    for ($i = 0; $i -lt 6; $i++) {
        $r = Read-Until $Conn.Stream @($PromptRx, $YesNoRx) $TimeoutSec
        $out += $r.Text
        if ($r.Match -eq $YesNoRx) {
            Write-Host "        Rueckfrage bei '$Command' -> '$Answer'"
            $Conn.Stream.WriteLine($Answer)
            continue
        }
        return $out
    }
    throw "Zu viele Rueckfragen bei '$Command'"
}

function Assert-NoCliError([string]$Out, [string]$Command) {
    # Nur echte CLI-Fehler. Nicht "% Total % Received ..." (Fortschrittsanzeige beim copy).
    $bad = ($Out -split "`n") | Where-Object { $_ -match '^\s*(%\s*(Invalid|Command incomplete|Unknown|Ambiguous)|Invalid input|Error|ERROR|Failed|failed|Command incomplete|Unknown command)' }
    if ($bad) { throw "Fehler bei '$Command': $($bad -join ' | ')" }
}

function Get-CXImages($Conn) {
    $t = Invoke-CX $Conn 'show images' 30
    $parts = $t -split 'Secondary Image'
    $pri = '?'; $sec = '?'; $def = '?'
    if ($parts[0] -match 'Version\s*:\s*(\S+)') { $pri = $Matches[1] }
    if ($parts.Count -gt 1 -and $parts[1] -match 'Version\s*:\s*(\S+)') { $sec = $Matches[1] }
    if ($t -match 'Default Image\s*:\s*(\S+)') { $def = $Matches[1] }
    $priVer = ($parts[0] -match 'SHA-256\s*:\s*Verifying')
    $secVer = ($parts.Count -gt 1 -and $parts[1] -match 'SHA-256\s*:\s*Verifying')
    return [pscustomobject]@{ Primary = $pri; Secondary = $sec; Default = $def; PrimaryVerifying = $priVer; SecondaryVerifying = $secVer }
}

function Get-PartitionVersion($Images, [string]$Partition) {
    if ($Partition -eq 'primary') { return $Images.Primary } else { return $Images.Secondary }
}

function Test-PartitionVerifying($Images, [string]$Partition) {
    if ($Partition -eq 'primary') { return [bool]$Images.PrimaryVerifying } else { return [bool]$Images.SecondaryVerifying }
}

# Wartet, bis der Switch die SHA-256-Pruefung des Images abgeschlossen hat (laeuft nach dem copy im Hintergrund)
function Wait-ImageVerified($Conn, [string]$Partition, [int]$TimeoutMin = 15) {
    $deadline = (Get-Date).AddMinutes($TimeoutMin)
    while ((Get-Date) -lt $deadline) {
        $img = Get-CXImages $Conn
        if (-not (Test-PartitionVerifying $img $Partition)) { return $img }
        Write-Host "        $Partition wird noch verifiziert ..."
        Start-Sleep -Seconds 20
    }
    throw "Verifizierung von $Partition nach $TimeoutMin Minuten nicht abgeschlossen."
}

function Set-CXDefaultSecondary($Sw, [string]$ExpectSecondary) {
    if ($DryRun) { Write-Host "[DryRun] $($Sw.IP): pruefe secondary = $ExpectSecondary, dann boot set-default secondary"; return }
    $c = Open-CX $Sw.IP
    try {
        $pre = Get-CXImages $c
        if ($pre.Secondary -notmatch [regex]::Escape($ExpectSecondary) -or $pre.SecondaryVerifying) {
            throw "ABBRUCH: $($Sw.Name) secondary = $($pre.Secondary) (Verifizierung laeuft: $($pre.SecondaryVerifying)), erwartet $ExpectSecondary fertig verifiziert. Erst Stage1 abschliessen."
        }
        $o = Invoke-CX $c 'boot set-default secondary' 60
        Assert-NoCliError $o 'boot set-default secondary'
        $img = Get-CXImages $c
        if ($img.Default -ne 'secondary') { throw "$($Sw.Name): Default Image ist '$($img.Default)' statt secondary" }
        Write-Ok "$($Sw.Name): Default Image = secondary ($($img.Secondary)), laeuft weiter mit primary bis zum Neustart"
    }
    finally { Close-CX $c }
}

function Start-CXBoot([string]$Ip, [string]$Partition) {
    # Nach dem Neustart eines Nachbarn kann STP kurz umschalten -> Verbindung mehrfach versuchen
    $c = $null
    for ($t = 1; $t -le 4 -and -not $c; $t++) {
        try { $c = Open-CX $Ip }
        catch {
            if ($t -eq 4) { throw }
            Write-Host "        $Ip nicht erreichbar, neuer Versuch in 15 s ..."
            Start-Sleep -Seconds 15
        }
    }
    try {
        $c.Stream.WriteLine("boot system $Partition")
        for ($i = 0; $i -lt 4; $i++) {
            try { $r = Read-Until $c.Stream @($YesNoRx, $PromptRx) 60 }
            catch { break }   # Verbindung weg / keine Ausgabe mehr = Neustart laeuft
            if ($r.Match -eq $YesNoRx) {
                Write-Host "        Rueckfrage -> 'y'"
                $c.Stream.WriteLine('y')
            }
            else { throw "Kein Neustart ausgeloest. Ausgabe: $($r.Text)" }
        }
    }
    finally { Close-CX $c }
}

function Wait-CXOnline([string]$Ip, [string]$ExpectVersion, [int]$TimeoutMin = 25) {
    Start-Sleep -Seconds 90
    $deadline = (Get-Date).AddMinutes($TimeoutMin)
    while ((Get-Date) -lt $deadline) {
        $c = $null
        try {
            $c = Open-CX $Ip
            $v = Invoke-CX $c 'show version' 30
            Close-CX $c
            $line = (($v -split "`n") | Where-Object { $_ -match '^\s*Version\s*:' } | Select-Object -First 1)
            if ($v -match [regex]::Escape($ExpectVersion)) { Write-Ok "$Ip wieder online: $line"; return $true }
            Write-Warning "$Ip online, aber falsche Version: $line (erwartet $ExpectVersion)"
            return $false
        }
        catch { Close-CX $c; Start-Sleep -Seconds 20 }
    }
    Write-Warning "$Ip nach $TimeoutMin Minuten nicht wieder erreichbar."
    return $false
}

# Gibt nur die Switches zurueck, die wirklich neu starten muessen.
# Wer schon mit $ExpectVersion oder $FinalVersion laeuft, wird uebersprungen (verhindert Downgrade nach dem Pilot).
function Test-BootTargets($List, [string]$Partition, [string]$ExpectVersion, [string]$FinalVersion = '') {
    Write-Step "Vorabpruefung: $Partition muss $ExpectVersion enthalten"
    $todo = @()
    foreach ($sw in $List) {
        if ($DryRun) { Write-Host "[DryRun] $($sw.IP): pruefe laufende Version und $Partition = $ExpectVersion"; $todo += $sw; continue }
        $c = Open-CX $sw.IP
        try { $img = Get-CXImages $c; $ver = Invoke-CX $c 'show version' 30 } finally { Close-CX $c }
        $running = '?'
        if ($ver -match 'Version\s*:\s*(\S+)') { $running = $Matches[1] }
        if ($running -match [regex]::Escape($ExpectVersion) -or ($FinalVersion -and $running -match [regex]::Escape($FinalVersion))) {
            Write-Ok "$($sw.Name): laeuft bereits mit $running -> wird uebersprungen"
            continue
        }
        $v = Get-PartitionVersion $img $Partition
        if ($v -notmatch [regex]::Escape($ExpectVersion)) {
            throw "ABBRUCH: $($sw.Name) $Partition = $v, erwartet $ExpectVersion. Es wurde NICHTS neu gestartet."
        }
        if (Test-PartitionVerifying $img $Partition) {
            throw "ABBRUCH: $($sw.Name) $Partition wird noch verifiziert. Spaeter erneut starten. Es wurde NICHTS neu gestartet."
        }
        Write-Ok "$($sw.Name): $Partition = $v (laeuft mit $running)"
        $todo += $sw
    }
    return $todo
}

function Invoke-BootWave($List, [string]$Partition, [string]$ExpectVersion, [string]$FinalVersion = '') {
    $List = @(Test-BootTargets $List $Partition $ExpectVersion $FinalVersion)
    if ($List.Count -eq 0) { Write-Host 'Kein Switch muss neu gestartet werden.'; return }
    $groups = $List | Group-Object Gruppe | Sort-Object { [int]$_.Name }
    foreach ($g in $groups) {
        Write-Step "Gruppe $($g.Name): $(($g.Group | ForEach-Object { $_.Name }) -join ', ')"
        if ($DryRun) {
            foreach ($sw in $g.Group) { Write-Host "[DryRun] $($sw.IP): boot system $Partition -> erwartet $ExpectVersion" }
            continue
        }
        Confirm-Go "NEUSTART von $($g.Count) Switch(es) in Gruppe $($g.Name)."
        foreach ($sw in $g.Group) {
            Write-Host "  NEUSTART: $($sw.Name) ($($sw.IP))" -ForegroundColor Yellow
            Start-CXBoot $sw.IP $Partition
        }
        $failed = @()
        foreach ($sw in $g.Group) {
            if (-not (Wait-CXOnline $sw.IP $ExpectVersion)) { $failed += $sw.Name }
        }
        if ($failed.Count -gt 0) {
            throw "ABBRUCH nach Gruppe $($g.Name): $($failed -join ', ') nicht ok. Weitere Gruppen wurden NICHT gestartet."
        }
    }
}

function Invoke-Stage($Sw, [string]$Image, [string]$Partition, [string]$ExpectVersion) {
    if (-not $Image) { throw "Kein Image fuer $($Sw.Name) angegeben (Parameter fehlt)." }
    $cmd = "copy tftp://$Tftp/$Image $Partition vrf default"
    if ($DryRun) { Write-Host "[DryRun] $($Sw.IP): $cmd  (erwartet $ExpectVersion)"; return }
    $c = Open-CX $Sw.IP
    try {
        $before = Get-CXImages $c
        Write-Host "  $($Sw.Name) vorher: primary=$($before.Primary) secondary=$($before.Secondary)"
        $vb = Get-PartitionVersion $before $Partition
        if ($vb -match [regex]::Escape($ExpectVersion)) {
            Write-Ok "$($Sw.Name): $Partition = $vb ist schon vorhanden, kein Upload noetig"
            return
        }
        Write-Host "  Kopiere $Image -> $Partition (kann einige Minuten dauern) ..."
        $start = Get-Date
        $out = Invoke-CX $c $cmd 1800
        $dauer = [int]((Get-Date) - $start).TotalSeconds
        # Massgeblich ist die Versionspruefung danach, nicht der Ausgabetext (enthaelt Fortschrittsanzeige)
        $after = Wait-ImageVerified $c $Partition
        $v = Get-PartitionVersion $after $Partition
        if ($v -notmatch [regex]::Escape($ExpectVersion)) {
            $tail = (($out -split "`n") | Where-Object { $_.Trim() } | Select-Object -Last 5) -join ' | '
            throw "$($Sw.Name): $Partition = '$v' statt $ExpectVersion. Letzte Ausgabe: $tail"
        }
        Write-Ok "$($Sw.Name): $Partition = $v  ($dauer s)"
    }
    finally { Close-CX $c }
}

function Invoke-ConfigBlock($Sw, [string[]]$Commands) {
    if ($DryRun) {
        Write-Host "[DryRun] $($Sw.Name) ($($Sw.IP)):"
        $Commands | ForEach-Object { Write-Host "    $_" }
        return
    }
    $c = Open-CX $Sw.IP
    try {
        foreach ($cmd in $Commands) {
            $o = Invoke-CX $c $cmd 60
            Assert-NoCliError $o $cmd
        }
    }
    finally { Close-CX $c }
}

function Compress-VlanList([int[]]$Ids) {
    $Ids = @($Ids | Sort-Object -Unique)
    $parts = @(); $start = $Ids[0]; $prev = $Ids[0]
    for ($i = 1; $i -lt $Ids.Count; $i++) {
        if ($Ids[$i] -eq $prev + 1) { $prev = $Ids[$i]; continue }
        if ($start -eq $prev) { $parts += "$start" } else { $parts += "$start-$prev" }
        $start = $Ids[$i]; $prev = $Ids[$i]
    }
    if ($start -eq $prev) { $parts += "$start" } else { $parts += "$start-$prev" }
    return ($parts -join ',')
}

# ---------------------------------------------------------------- Phasen
try {
    Write-Step "Phase $Phase  (DryRun: $([bool]$DryRun))  Ziele: $(($switches | ForEach-Object { $_.Name }) -join ', ')"

    switch ($Phase) {

        'Backup' {
            $dir = Join-Path (Get-Location) (Join-Path 'backup' $stamp)
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $fail = @()
            foreach ($sw in $switches) {
                if ($DryRun) { Write-Host "[DryRun] $($sw.IP): show running-config / lldp / version / images / transceiver / interface brief / system"; continue }
                # Nur lesend: ein nicht erreichbarer Switch stoppt das Backup NICHT, er wird am Ende gemeldet
                try {
                    $c = Open-CX $sw.IP
                    try {
                        $run  = Invoke-CX $c 'show running-config' 120
                        $lldp = Invoke-CX $c 'show lldp neighbor-info' 60
                        $ver  = Invoke-CX $c 'show version' 30
                        $img  = Invoke-CX $c 'show images' 30
                        $xcvr = Invoke-CX $c 'show interface transceiver' 60
                        $intb = Invoke-CX $c 'show interface brief' 60
                        $sys  = Invoke-CX $c 'show system' 30
                    }
                    finally { Close-CX $c }
                    if ($run -notmatch 'Current configuration') { throw "running-config unvollstaendig" }
                    $base = Join-Path $dir ("{0}_{1}" -f $sw.Name, $sw.IP)
                    $run  | Set-Content "$base.cli"       -Encoding UTF8
                    $lldp | Set-Content "$base`_lldp.txt" -Encoding UTF8
                    ($ver + "`n" + $img) | Set-Content "$base`_info.txt" -Encoding UTF8
                    $xcvr | Set-Content "$base`_xcvr.txt" -Encoding UTF8
                    $intb | Set-Content "$base`_intbrief.txt" -Encoding UTF8
                    $sys  | Set-Content "$base`_system.txt" -Encoding UTF8
                    Write-Ok "$($sw.Name) gesichert"
                }
                catch {
                    Write-Host ("FEHLER  {0} ({1}): {2}" -f $sw.Name, $sw.IP, $_.Exception.Message) -ForegroundColor Red
                    $fail += "$($sw.Name) ($($sw.IP))"
                }
            }
            if ($fail.Count -gt 0) { Write-Host "Nicht gesichert: $($fail -join ', ')" -ForegroundColor Red }
            Write-Host "Ablage: $dir"
        }

        'Stage1' {
            Assert-Param $Tftp 'Tftp'
            foreach ($sw in $switches) {
                if (Test-Core $sw) { Invoke-Stage $sw $ImageCore 'secondary' (Resolve-Version $VersionCore $ImageCore 'VersionCore') }
                else { Invoke-Stage $sw $ImageAccessWelle1 'secondary' (Resolve-Version $VersionAccessWelle1 $ImageAccessWelle1 'VersionAccessWelle1') }
            }
        }

        'Stage2' {
            Assert-Param $Tftp 'Tftp'
            Assert-Param $VersionAccessWelle1 'VersionAccessWelle1'
            $v2 = Resolve-Version $VersionAccessWelle2 $ImageAccessWelle2 'VersionAccessWelle2'
            foreach ($sw in ($switches | Where-Object { Test-Access $_ })) {
                # Schutz vor ungeplantem Neustart: ERST Default auf secondary (Welle 1), DANN primary ueberschreiben.
                # So zeigt der Default nie auf eine Partition, die gerade beschrieben wird.
                Set-CXDefaultSecondary $sw $VersionAccessWelle1
                Invoke-Stage $sw $ImageAccessWelle2 'primary' $v2
            }
        }

        'Welle1' {
            Assert-Param $VersionAccessWelle1 'VersionAccessWelle1'
            $list = @($switches | Where-Object { Test-Access $_ })
            Invoke-BootWave $list 'secondary' $VersionAccessWelle1 $VersionAccessWelle2
        }

        'Welle2' {
            Assert-Param $VersionAccessWelle2 'VersionAccessWelle2'
            $list = @($switches | Where-Object { Test-Access $_ })
            Invoke-BootWave $list 'primary' $VersionAccessWelle2
        }

        'Cores' {
            Assert-Param $VersionCore 'VersionCore'
            $cores = @($switches | Where-Object { Test-Core $_ })
            $cores = @(Test-BootTargets $cores 'secondary' $VersionCore)
            foreach ($sw in $cores) {
                Write-Step "Core $($sw.Name)"
                if ($DryRun) { Write-Host "[DryRun] $($sw.IP): boot system secondary -> erwartet $VersionCore"; continue }
                Confirm-Go "NEUSTART Core $($sw.Name). Der andere Core bleibt online."
                Write-Host "  NEUSTART: $($sw.Name) ($($sw.IP))" -ForegroundColor Yellow
                Start-CXBoot $sw.IP 'secondary'
                if (-not (Wait-CXOnline $sw.IP $VersionCore)) {
                    throw "ABBRUCH: $($sw.Name) nicht ok. Zweiter Core wurde NICHT neu gestartet."
                }
            }
        }

        'Hostname' {
            foreach ($sw in $switches) {
                if ($sw.Name.Length -gt 32 -or $sw.Name -notmatch '^[A-Za-z0-9_-]+$') { throw "Name ungueltig: '$($sw.Name)'" }
            }
            Confirm-Go "Hostnamen auf $($switches.Count) Switch(es) gemaess switches.csv setzen."
            foreach ($sw in $switches) {
                Write-Step "$($sw.IP) -> $($sw.Name)"
                Invoke-ConfigBlock $sw @('configure terminal', "hostname $($sw.Name)", 'end', 'write memory')
                if ($DryRun) { continue }
                $c = Open-CX $sw.IP
                try { $h = Invoke-CX $c 'show running-config | include hostname' 30 } finally { Close-CX $c }
                if ($h -notmatch ('hostname\s+' + [regex]::Escape($sw.Name))) { throw "$($sw.IP): Hostname nicht gesetzt" }
                Write-Ok "$($sw.IP): hostname $($sw.Name)"
            }
        }

        'Basis' {
            Assert-Param $Gateway 'Gateway'
            Assert-Param $Dns 'Dns'
            Confirm-Go "Gateway $Gateway, DNS $Dns, NTP $Ntp, Zeitzone $Timezone auf $($switches.Count) Switch(es) setzen."
            foreach ($sw in $switches) {
                Write-Step "$($sw.Name): Gateway / DNS / NTP / Zeitzone"
                Invoke-ConfigBlock $sw @(
                    'configure terminal',
                    "ip route 0.0.0.0/0 $Gateway",
                    "ip dns server-address $Dns",
                    "no ntp server $Ntp",
                    "ntp server $Ntp iburst",
                    'ntp enable',
                    "clock timezone $Timezone",
                    'end',
                    'write memory')
                if ($DryRun) { continue }
                $c = Open-CX $sw.IP
                try { $rt = Invoke-CX $c 'show ip route' 30 } finally { Close-CX $c }
                if ($rt -notmatch '0\.0\.0\.0/0' -or $rt -notmatch [regex]::Escape($Gateway)) {
                    throw "$($sw.Name): Default-Route auf $Gateway nicht in 'show ip route' gefunden."
                }
                Write-Ok "$($sw.Name): Default-Route via $Gateway aktiv"
            }
        }

        'Passwort' {
            # Neues Passwort fuer den angemeldeten User. Wird nie ausgegeben oder geloggt. Nach jedem Switch: Login-Test mit dem neuen Passwort.
            if ($DryRun) {
                foreach ($sw in $switches) { Write-Host "[DryRun] $($sw.Name) ($($sw.IP)): user <angemeldeter User> group administrators password plaintext ********  / write memory / Login-Test" }
                break
            }
            $user = $script:Cred.UserName
            if ($user -notmatch '^[A-Za-z0-9_.-]+$') { throw "Benutzername ungueltig: '$user'" }
            $p1 = Read-Host "Neues Passwort fuer '$user'" -AsSecureString
            $p2 = Read-Host 'Neues Passwort wiederholen' -AsSecureString
            $t1 = [System.Net.NetworkCredential]::new('', $p1).Password
            $t2 = [System.Net.NetworkCredential]::new('', $p2).Password
            if ($t1 -cne $t2) { throw 'Passwoerter stimmen nicht ueberein. Nichts geaendert.' }
            if ($t1.Length -lt 8) { throw 'Passwort zu kurz (mind. 8 Zeichen). Nichts geaendert.' }
            if ($t1 -match '[\s\?"]') { throw 'Passwort darf keine Leerzeichen, ? oder " enthalten (CLI). Nichts geaendert.' }
            Remove-Variable t2
            $newCred = [pscredential]::new($user, $p1)
            Confirm-Go "Passwort fuer '$user' auf $($switches.Count) Switch(es) aendern. Bei einem Fehler stoppt das Skript, die restlichen behalten das alte Passwort."
            foreach ($sw in $switches) {
                Write-Step "$($sw.Name): Passwort aendern"
                $c = Open-CX $sw.IP
                try {
                    $null = Invoke-CX $c 'configure terminal' 30
                    # direkt in den Stream, damit der Befehl nirgends ausgegeben wird
                    $c.Stream.WriteLine("user $user group administrators password plaintext $t1")
                    try { $r = Read-Until $c.Stream @($PromptRx) 30 }
                    catch { throw "$($sw.Name): keine Antwort nach Passwort-Befehl (Timeout). Ausgabe nicht angezeigt, da Passwort enthalten." }
                    if ($r.Text -match '(?m)^\s*%|Invalid|Error|failed') { throw "$($sw.Name): CLI hat das Passwort abgelehnt (Komplexitaet?). Ausgabe nicht angezeigt, da Passwort enthalten." }
                    $null = Invoke-CX $c 'end' 30
                    $o = Invoke-CX $c 'write memory' 120
                    Assert-NoCliError $o 'write memory'
                }
                finally { Close-CX $c }
                # Login-Test mit neuem Passwort
                $old = $script:Cred; $script:Cred = $newCred
                try {
                    $t = Open-CX $sw.IP; Close-CX $t
                }
                catch { $script:Cred = $old; throw "$($sw.Name): Login mit NEUEM Passwort fehlgeschlagen! Mit altem Passwort pruefen. Abbruch." }
                $script:Cred = $old
                Write-Ok "$($sw.Name): neues Passwort aktiv (Login getestet)"
            }
            Remove-Variable t1
            Write-Host 'Fertig. Ab jetzt beim Skriptstart das NEUE Passwort eingeben.' -ForegroundColor Yellow
        }

        'Inventar' {
            # Rack -> snmp-server system-location, Inventar-Nr. -> snmp-server system-contact. Leere Zellen werden uebersprungen.
            function Get-Cell($v) { if ($v) { return $v.Trim() } else { return '' } }
            $list = @($switches | Where-Object { (Get-Cell $_.Rack) -or (Get-Cell $_.Inventar) })
            if ($list.Count -eq 0) { throw "Keine Werte in $SwitchCsv (Spalten 'Rack' / 'Inventar')." }
            foreach ($sw in $list) {
                foreach ($v in @((Get-Cell $sw.Rack), (Get-Cell $sw.Inventar))) {
                    if ($v -and $v -notmatch '^[A-Za-z0-9_-]+$') { throw "$($sw.Name): Wert ungueltig (nur Buchstaben, Ziffern, - und _): '$v'" }
                }
            }
            $noInv = @($switches | Where-Object { -not (Get-Cell $_.Inventar) })
            if ($noInv.Count -gt 0) { Write-Host "Ohne Inventar-Nr. (nur Rack): $(($noInv | ForEach-Object { $_.Name }) -join ', ')" -ForegroundColor Yellow }
            Confirm-Go "Rack (system-location) und Inventar-Nr. (system-contact) auf $($list.Count) Switch(es) setzen."
            foreach ($sw in $list) {
                $rack = Get-Cell $sw.Rack; $inv = Get-Cell $sw.Inventar
                Write-Step "$($sw.Name): Rack '$rack'  Inventar '$inv'"
                $cmds = @('configure terminal')
                if ($rack) { $cmds += "snmp-server system-location $rack" }
                if ($inv)  { $cmds += "snmp-server system-contact $inv" }
                $cmds += 'end'; $cmds += 'write memory'
                Invoke-ConfigBlock $sw $cmds
                if ($DryRun) { continue }
                $c = Open-CX $sw.IP
                try { $r = Invoke-CX $c 'show running-config | include system-' 30 } finally { Close-CX $c }
                if ($rack -and $r -notmatch ('system-location\s+' + [regex]::Escape($rack))) { throw "$($sw.Name): system-location nicht gesetzt." }
                if ($inv  -and $r -notmatch ('system-contact\s+'  + [regex]::Escape($inv)))  { throw "$($sw.Name): system-contact nicht gesetzt." }
                Write-Ok "$($sw.Name): $rack / $inv"
            }
        }

        'Banner' {
            Confirm-Go "Leeren Login-Banner auf $($switches.Count) Switch(es) setzen."
            foreach ($sw in $switches) {
                Write-Step "$($sw.Name): Banner entfernen"
                if ($DryRun) {
                    Write-Host "[DryRun] $($sw.IP): configure terminal / banner motd ^ (leer) ^ / no banner exec / end / write memory"
                    continue
                }
                $c = Open-CX $sw.IP
                try {
                    Invoke-CX $c 'configure terminal' 30 | Out-Null
                    # Leerer motd ersetzt den Default-Text ("RESTRICTED RIGHTS LEGEND ... Please register").
                    # banner motd ^  -> CLI wartet auf Text -> sofort ^ beendet die Eingabe.
                    $c.Stream.WriteLine('banner motd ^')
                    Start-Sleep -Seconds 2
                    $c.Stream.WriteLine('^')
                    try { $r = Read-Until $c.Stream @($PromptRx) 30 }
                    catch { throw "$($sw.Name): keine Antwort nach 'banner motd' (Timeout)." }
                    Assert-NoCliError $r.Text 'banner motd ^'
                    # Exec-Banner (nach Login) entfernen; falls die CLI ein Trennzeichen verlangt, mit ^ wiederholen.
                    $o = Invoke-CX $c 'no banner exec' 30
                    if ($o -match '(?m)^\s*%|Invalid input|Command incomplete') { $null = Invoke-CX $c 'no banner exec ^' 30 }
                    Invoke-CX $c 'end' 30 | Out-Null
                    $o = Invoke-CX $c 'write memory' 120
                    Assert-NoCliError $o 'write memory'
                    $chk = (Invoke-CX $c 'show banner motd' 30) + (Invoke-CX $c 'show banner exec' 30)
                }
                finally { Close-CX $c }
                if ($chk -match 'register your products') { throw "$($sw.Name): Default-Banner noch aktiv. Ausgabe von 'show banner motd' pruefen." }
                Write-Ok "$($sw.Name): Banner entfernt"
            }
        }

        'STP' {
            $ordered  = @($switches | Sort-Object @{ Expression = { [int]$_.STP } }, Typ)
            $rootPrio = [int]$ordered[0].STP
            foreach ($sw in $ordered) {
                $p = [int]$sw.STP
                if ($p % 4096 -ne 0 -or $p -lt 0 -or $p -gt 61440) { throw "$($sw.Name): STP-Wert $p ungueltig (Vielfaches von 4096, max 61440)" }
            }
            Confirm-Go "STP-Priorities auf $($ordered.Count) Switch(es) setzen. Erwartete Root-Priority: $rootPrio."
            foreach ($sw in $ordered) {
                $p = [int]$sw.STP
                $mult = [int]($p / 4096)
                Write-Step "$($sw.Name): Priority $p (Multiplikator $mult)"
                Invoke-ConfigBlock $sw @('configure terminal', "spanning-tree priority $mult", 'end', 'write memory')
                if ($DryRun) { continue }
                Start-Sleep -Seconds 5
                $c = Open-CX $sw.IP
                try { $st = Invoke-CX $c 'show spanning-tree' 30 } finally { Close-CX $c }
                $bp = -1; $rp = -1
                if ($st -match 'Bridge ID\s+Priority\s*:\s*(\d+)') { $bp = [int]$Matches[1] }
                if ($st -match 'Root ID\s+Priority\s*:\s*(\d+)')   { $rp = [int]$Matches[1] }
                if ($bp -ne $p)        { throw "$($sw.Name): Bridge-Priority ist $bp statt $p. Ausgabe von 'show spanning-tree' pruefen." }
                if ($rp -ne $rootPrio) { throw "$($sw.Name): Root-Priority ist $rp statt $rootPrio. Root steht nicht auf dem Core!" }
                Write-Ok "$($sw.Name): Bridge $bp, Root $rp"
            }
        }

        'VLAN' {
            $vlans = @(Import-Csv -Path $VlanCsv -Delimiter ';')
            foreach ($v in $vlans) {
                if (-not ($v.ID -match '^\d+$') -or [int]$v.ID -lt 2 -or [int]$v.ID -gt 4094) { throw "VLAN-ID ungueltig: $($v.ID)" }
                if ($v.Name.Length -gt 32 -or $v.Name -notmatch '^[A-Za-z0-9_-]+$') { throw "VLAN-Name ungueltig: '$($v.Name)'" }
            }
            $dupId   = $vlans | Group-Object ID   | Where-Object { $_.Count -gt 1 }
            $dupName = $vlans | Group-Object Name | Where-Object { $_.Count -gt 1 }
            if ($dupId -or $dupName) { throw "Doppelte VLAN-IDs oder -Namen in $VlanCsv" }

            $ids     = @($vlans | ForEach-Object { [int]$_.ID })
            $allowed = Compress-VlanList (@(1) + $ids)
            $trunks  = @()
            if (Test-Path $TrunkCsv) { $trunks = @(Import-Csv -Path $TrunkCsv -Delimiter ';') }
            Write-Host "VLANs: $($vlans.Count)   Trunk allowed: $allowed"

            Confirm-Go "VLANs + Trunks auf $($switches.Count) Switch(es) konfigurieren."
            foreach ($sw in $switches) {
                $cmds = @('configure terminal')
                foreach ($v in $vlans) { $cmds += "vlan $($v.ID)"; $cmds += "name $($v.Name)"; $cmds += 'exit' }
                $ports = @($trunks | Where-Object { $_.IP -eq $sw.IP } |
                           ForEach-Object { $_.Ports -split ',' } |
                           ForEach-Object { $_.Trim() } | Where-Object { $_ })
                foreach ($port in $ports) {
                    $cmds += "interface $port"; $cmds += 'vlan trunk native 1'; $cmds += "vlan trunk allowed $allowed"; $cmds += 'exit'
                }
                $cmds += 'end'; $cmds += 'write memory'
                Write-Step "$($sw.Name): $($vlans.Count) VLANs, Trunk-Ports: $(if ($ports) { $ports -join ', ' } else { 'keine' })"
                Invoke-ConfigBlock $sw $cmds
                if ($DryRun) { continue }
                $c = Open-CX $sw.IP
                try { $sv = Invoke-CX $c 'show vlan' 30 } finally { Close-CX $c }
                $missing = @($ids | Where-Object { $sv -notmatch "(?m)^\s*$_\s" })
                if ($missing.Count -gt 0) { throw "$($sw.Name): VLANs fehlen nach dem Push: $($missing -join ', ')" }
                Write-Ok "$($sw.Name): alle $($ids.Count) VLANs vorhanden"
            }
        }
    }
    Write-Host "`nPhase $Phase abgeschlossen." -ForegroundColor Green
}
catch {
    Write-Host "`nFEHLER: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Skript gestoppt. Log liegt unter .\logs\' -ForegroundColor Red
}
finally {
    Stop-Transcript | Out-Null
}
