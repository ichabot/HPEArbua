<#
.SYNOPSIS
  Legt einen Arbeitsordner fuer eine Kundenumgebung an und kopiert die Beispiel-CSVs hinein.

.EXAMPLE
  .\New-CXWorkspace.ps1 -Path C:\Kunden\Musterfirma\Switches
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Path
)
$ErrorActionPreference = 'Stop'

$examples = Join-Path $PSScriptRoot 'examples'
New-Item -ItemType Directory -Path $Path -Force | Out-Null

foreach ($f in Get-ChildItem -Path $examples -Filter *.csv) {
    $target = Join-Path $Path $f.Name
    if (Test-Path $target) {
        Write-Host "vorhanden, nicht ueberschrieben: $target" -ForegroundColor Yellow
    }
    else {
        Copy-Item $f.FullName $target
        Write-Host "angelegt: $target" -ForegroundColor Green
    }
}

$tool = Join-Path $PSScriptRoot 'CX-Wartung.ps1'
Write-Host ''
Write-Host 'Naechste Schritte:'
Write-Host "  1. switches.csv (und bei Bedarf vlans.csv, trunks.csv) in $Path anpassen"
Write-Host "  2. cd '$Path'"
Write-Host "  3. & '$tool' -Phase Backup -DryRun"
