# HPEArbua

PowerShell-Werkzeuge für Netzwerke mit **HPE Aruba Networking** Switches. Jedes Tool liegt in einem eigenen Ordner unter [`tools/`](tools/) und hat dort seine eigene Dokumentation.

Die Tools sind für den Einsatz in beliebigen Kundenumgebungen gebaut. Sie enthalten keine Umgebungsdaten. Alles Kundenspezifische (Switch-Listen, Backups, Logs, Netzpläne) liegt in einem eigenen Arbeitsordner pro Kunde.

## Tools

| Tool | Zweck | Zugriff | Doku |
|---|---|---|---|
| **CX-Wartung** | Wartungsarbeiten an AOS-CX-Switches über SSH: Firmware-Updates in Wellen, Backup, Hostname, Gateway/DNS/NTP, STP-Prioritäten, VLANs/Trunks, Banner, Inventar, Passwortwechsel | schreibend | [tools/CX-Wartung](tools/CX-Wartung/README.md) |
| **LLDP-Netzplan** | Netzwerkplan per SNMP/LLDP: welcher Switch hängt über welchen Port an welchem, mit Geschwindigkeit und Medium je Link. Verortet Endgeräte über die MAC-Tabellen und zählt aktive Ports und Endgeräte je Switch. Herstellerunabhängig. | nur lesend | [tools/LLDP-Netzplan](tools/LLDP-Netzplan/README.md) |

Was die Tools brauchen:

| Tool | Voraussetzungen |
|---|---|
| CX-Wartung | SSH-Zugang mit Adminrechten, Modul Posh-SSH (wird bei Bedarf installiert), für Firmware-Updates ein TFTP-Server |
| LLDP-Netzplan | SNMP-Lesezugriff (v2c oder v1), LLDP auf den Switches aktiv, keine Module |

Beide laufen unter Windows PowerShell 5.1 und PowerShell 7.

## Schnellstart

**Alle Tools installieren** (Details unter [Installation und Update](#installation-und-update)):

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/ichabot/HPEArbua/main/Install.ps1)))
```

**Netzplan eines Kunden erzeugen:**

```powershell
mkdir C:\Kunden\Musterfirma\Netzplan; cd C:\Kunden\Musterfirma\Netzplan
& "$HOME\Tools\HPEArbua\tools\LLDP-Netzplan\Get-LldpTopology.ps1" 192.168.10.0/24 -Name Musterfirma
```

Mehr dazu, auch der Weg ohne Installation: [LLDP-Netzplan → Ausführen](tools/LLDP-Netzplan/README.md#ausführen).

**Backup aller CX-Switches eines Kunden ziehen:**

```powershell
& "$HOME\Tools\HPEArbua\tools\CX-Wartung\New-CXWorkspace.ps1" -Path C:\Kunden\Musterfirma\Switches
cd C:\Kunden\Musterfirma\Switches      # switches.csv anpassen
& "$HOME\Tools\HPEArbua\tools\CX-Wartung\CX-Wartung.ps1" -Phase Backup -DryRun
```

Mehr dazu: [CX-Wartung → Schnellstart](tools/CX-Wartung/README.md#schnellstart).

## Installation und Update

Auf dem Admin-PC in PowerShell:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/ichabot/HPEArbua/main/Install.ps1)))
```

Das lädt den aktuellen Stand nach `%USERPROFILE%\Tools\HPEArbua` und hebt die Download-Sperre der Skripte auf. Derselbe Befehl aktualisiert eine bestehende Installation.

| Fall | Vorgehen |
|---|---|
| Anderer Zielordner | `& ([scriptblock]::Create((irm https://raw.githubusercontent.com/ichabot/HPEArbua/main/Install.ps1))) -Path D:\Tools\HPEArbua` |
| Kein Internet am Kunden-PC | Repository als ZIP laden (**Code → Download ZIP**), entpacken, im Ordner einmal `Get-ChildItem -Recurse \| Unblock-File` ausführen |
| Ausführungsrichtlinie blockiert Skripte | Nur für die aktuelle Sitzung freigeben: `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` |
| Nur ein einzelnes Skript gebraucht | Direkt-Download, siehe Doku des jeweiligen Tools |

## Arbeitsweise pro Kunde

1. **Arbeitsordner anlegen**, z. B. `C:\Kunden\Musterfirma\Switches`. Für CX-Wartung legt `New-CXWorkspace.ps1` ihn samt Beispiel-CSVs an.
2. **Im Arbeitsordner arbeiten.** Die Tools lesen ihre Eingaben aus dem aktuellen Ordner und schreiben Backups, Logs und Netzpläne dorthin.
3. **Tool-Ordner unangetastet lassen.** Er bleibt frei von Kundendaten und lässt sich jederzeit per Update überschreiben.

## Aufbau des Repositorys

```
HPEArbua/
├── Install.ps1                  Download / Update aller Tools
├── LICENSE
├── README.md                    diese Übersicht
└── tools/
    ├── CX-Wartung/
    │   ├── CX-Wartung.ps1       das Tool
    │   ├── New-CXWorkspace.ps1  Arbeitsordner für einen Kunden anlegen
    │   ├── README.md            Doku zum Tool
    │   └── examples/            Beispiel-CSVs mit fiktiven Daten
    └── LLDP-Netzplan/
        ├── Get-LldpTopology.ps1 das Tool
        ├── README.md            Doku zum Tool
        └── examples/            Beispielplan mit fiktiven Daten
```

## Regeln für neue Tools

- Jedes Tool bekommt einen eigenen Ordner unter `tools/` mit eigener `README.md` und, wenn es Eingabedateien braucht, einem Ordner `examples/` mit fiktiven Daten.
- Das Tool kommt in die Tabelle unter [Tools](#tools) und in den [Aufbau des Repositorys](#aufbau-des-repositorys).
- Keine Kundendaten im Repository: keine echten IPs, Hostnamen, Seriennummern, Zugangsdaten. Die `.gitignore` blockt `backup/`, `logs/`, `*.csv` außerhalb von `examples/`, `*.swi`, `*.cli`, `*.html` und `*.drawio`.
- Eingaben aus dem aktuellen Arbeitsordner lesen, Ausgaben dorthin schreiben.
- Ändernde Aktionen: `-DryRun` anbieten, vor kritischen Schritten mit `JA` bestätigen lassen, bei Fehlern stoppen, Log schreiben.
- Zugangsdaten nur abfragen (`Get-Credential`), nie speichern oder loggen.

## Hinweis

CX-Wartung greift schreibend auf produktive Netzwerkgeräte zu und kann Neustarts auslösen. Vor dem ersten Einsatz in einer Umgebung jede Phase mit `-DryRun` und dann mit `-Only <IP>` an einem einzelnen Switch testen.

LLDP-Netzplan sendet ausschließlich SNMP-Leseanfragen. Beim ersten Einsatz trotzdem mit einem einzelnen Switch beginnen.

Nutzung auf eigene Verantwortung.

## Lizenz

MIT, siehe [LICENSE](LICENSE).
