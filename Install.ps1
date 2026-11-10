<#
.SYNOPSIS
  Laedt die Tools aus dem Repository ichabot/HPEArbua herunter bzw. aktualisiert sie.

.DESCRIPTION
  - Laedt den aktuellen Stand (Branch main) als ZIP von GitHub.
  - Kopiert die Dateien nach -Path (Standard: $HOME\Tools\HPEArbua). Vorhandene Dateien werden ueberschrieben,
    zusaetzliche Dateien im Zielordner bleiben erhalten.
  - Entfernt die Download-Sperre (Unblock-File), damit die Skripte ohne Rueckfrage laufen.
  Kundendaten gehoeren NICHT in diesen Ordner, sondern in einen eigenen Arbeitsordner pro Kunde.

.EXAMPLE
  irm https://raw.githubusercontent.com/ichabot/HPEArbua/main/Install.ps1 | iex

.EXAMPLE
  .\Install.ps1 -Path D:\Tools\HPEArbua
#>
[CmdletBinding()]
param(
    [string]$Path   = (Join-Path $HOME 'Tools\HPEArbua'),
    [string]$Branch = 'main'
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$url  = "https://github.com/ichabot/HPEArbua/archive/refs/heads/$Branch.zip"
$tmp  = Join-Path ([IO.Path]::GetTempPath()) ("HPEArbua_" + [guid]::NewGuid().ToString('N'))
$zip  = "$tmp.zip"

try {
    Write-Host "Lade $url ..."
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    $src = Get-ChildItem -Path $tmp -Directory | Select-Object -First 1
    if (-not $src) { throw 'ZIP-Inhalt unerwartet (kein Ordner gefunden).' }

    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    Copy-Item -Path (Join-Path $src.FullName '*') -Destination $Path -Recurse -Force
    if ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows) {
        Get-ChildItem -Path $Path -Recurse -File | Unblock-File
    }

    Write-Host "Installiert/aktualisiert: $Path" -ForegroundColor Green
    Write-Host ''
    Write-Host 'Arbeitsordner fuer einen Kunden anlegen:'
    Write-Host "  & '$Path\tools\CX-Wartung\New-CXWorkspace.ps1' -Path C:\Kunden\<Kunde>\Switches"
}
finally {
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
