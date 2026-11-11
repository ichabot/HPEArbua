# HPEArbua

PowerShell-Werkzeuge für **HPE Aruba Networking CX** Switches (AOS-CX): Firmware-Updates in Wartungsfenstern, Backups und wiederkehrende Konfigurationsaufgaben über SSH. Dazu ein herstellerunabhängiger Netzwerkplan per SNMP/LLDP.

Die Tools sind für den Einsatz in beliebigen Kundenumgebungen gebaut. Sie enthalten keine Umgebungsdaten. Alles Kundenspezifische (Switch-Liste, VLANs, Backups, Logs) liegt in einem eigenen Arbeitsordner pro Kunde.

## Tools

| Tool | Zweck |
|---|---|
| [CX-Wartung](tools/CX-Wartung/) | Firmware-Updates in Wellen mit Vorabprüfung, Backup, Hostname, Gateway/DNS/NTP, STP-Prioritäten, VLANs/Trunks, Banner, Inventar, Passwortwechsel |
| [LLDP-Netzplan](tools/LLDP-Netzplan/) | Liest per SNMP die LLDP-Nachbarn aller Switche und erzeugt einen Netzwerkplan (HTML, draw.io, CSV) mit Port-zu-Port-Verbindungen, Geschwindigkeit und Medium je Link (`10G LWL`, `10G DAC`, `1G Kupfer`). Verortet Endgeräte über die MAC-Tabellen und zählt aktive Ports und Endgeräte je Switch. Nur lesend, herstellerunabhängig. |

Weitere Tools folgen jeweils in einem eigenen Ordner unter `tools/`.

## Installation und Update

Auf dem Admin-PC in PowerShell (Windows PowerShell 5.1 oder PowerShell 7):

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/ichabot/HPEArbua/main/Install.ps1)))
```

Das lädt den aktuellen Stand nach `%USERPROFILE%\Tools\HPEArbua` und hebt die Download-Sperre der Skripte auf. Derselbe Befehl aktualisiert eine bestehende Installation. Anderer Zielordner:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/ichabot/HPEArbua/main/Install.ps1))) -Path D:\Tools\HPEArbua
```

Ohne Internet am Kunden-PC: Repository als ZIP herunterladen (**Code → Download ZIP**), entpacken, dann einmal `Get-ChildItem -Recurse | Unblock-File` im Ordner ausführen.

Falls die Ausführungsrichtlinie Skripte blockiert, nur für die aktuelle Sitzung freigeben:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

## Arbeitsweise pro Kunde

1. **Arbeitsordner anlegen.** Er bekommt die Beispiel-CSVs als Vorlage:
   ```powershell
   & "$HOME\Tools\HPEArbua\tools\CX-Wartung\New-CXWorkspace.ps1" -Path C:\Kunden\Musterfirma\Switches
   ```
2. **CSVs anpassen** (Switch-Liste, ggf. VLANs und Trunks).
3. **Im Arbeitsordner arbeiten.** Die Tools lesen die CSVs aus dem aktuellen Ordner und schreiben Backups und Logs dorthin:
   ```powershell
   cd C:\Kunden\Musterfirma\Switches
   & "$HOME\Tools\HPEArbua\tools\CX-Wartung\CX-Wartung.ps1" -Phase Backup
   ```

Das Tool-Verzeichnis bleibt dadurch frei von Kundendaten und lässt sich jederzeit per Update überschreiben.

## Aufbau des Repositorys

```
HPEArbua/
├── Install.ps1                 Download / Update der Tools
├── LICENSE
├── README.md
└── tools/
    ├── CX-Wartung/
    │   ├── CX-Wartung.ps1      das Tool
    │   ├── New-CXWorkspace.ps1 Arbeitsordner für einen Kunden anlegen
    │   ├── README.md           Doku zum Tool
    │   └── examples/           Beispiel-CSVs mit fiktiven Daten
    └── LLDP-Netzplan/
        ├── Get-LldpTopology.ps1 das Tool
        ├── README.md            Doku zum Tool
        └── examples/            Beispielplan mit fiktiven Daten
```

## Regeln für neue Tools

- Jedes Tool bekommt einen eigenen Ordner unter `tools/` mit eigener `README.md` und, wenn es Eingabedateien braucht, einem Ordner `examples/` mit fiktiven Daten.
- Keine Kundendaten im Repository: keine echten IPs, Hostnamen, Seriennummern, Zugangsdaten. Die `.gitignore` blockt `backup/`, `logs/`, `*.csv` außerhalb von `examples/`, `*.swi`, `*.cli`, `*.html` und `*.drawio`.
- Eingaben aus dem aktuellen Arbeitsordner lesen, Ausgaben dorthin schreiben.
- Ändernde Aktionen: `-DryRun` anbieten, vor kritischen Schritten mit `JA` bestätigen lassen, bei Fehlern stoppen, Log schreiben.
- Zugangsdaten nur abfragen (`Get-Credential`), nie speichern oder loggen.

## Hinweis

CX-Wartung greift schreibend auf produktive Netzwerkgeräte zu und kann Neustarts auslösen. Vor dem ersten Einsatz in einer Umgebung jede Phase mit `-DryRun` und dann mit `-Only <IP>` an einem einzelnen Switch testen. Nutzung auf eigene Verantwortung.

## Lizenz

MIT, siehe [LICENSE](LICENSE).
