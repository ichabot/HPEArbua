# CX-Wartung

[← Zur Übersicht aller Tools](../../README.md)

Automatisiert Wartungsarbeiten an HPE Aruba Networking CX Switches über SSH: Firmware-Updates in Wellen, Backups und Grundkonfiguration. Jede Aufgabe ist eine eigene **Phase**, die einzeln gestartet und danach geprüft wird.

## Voraussetzungen

- Windows PowerShell 5.1 oder PowerShell 7 (im Einsatz getestet mit PowerShell 7)
- Modul [Posh-SSH](https://www.powershellgallery.com/packages/Posh-SSH). Fehlt es, installiert das Skript es beim ersten Start für den aktuellen Benutzer.
- SSH-Zugang mit Administratorrechten auf allen Switches
- Für Firmware-Updates: TFTP-Server im Management-Netz (z. B. Tftpd64) mit den `.swi`-Images im Stammverzeichnis

## Schnellstart

```powershell
# Arbeitsordner für den Kunden anlegen (kopiert Beispiel-CSVs)
& "$HOME\Tools\HPEArbua\tools\CX-Wartung\New-CXWorkspace.ps1" -Path C:\Kunden\Musterfirma\Switches
cd C:\Kunden\Musterfirma\Switches
# switches.csv anpassen, dann:
& "$HOME\Tools\HPEArbua\tools\CX-Wartung\CX-Wartung.ps1" -Phase Backup -DryRun
& "$HOME\Tools\HPEArbua\tools\CX-Wartung\CX-Wartung.ps1" -Phase Backup
```

Tipp: Für kürzere Aufrufe einen Alias setzen.

```powershell
Set-Alias cxw "$HOME\Tools\HPEArbua\tools\CX-Wartung\CX-Wartung.ps1"
cxw -Phase Backup
```

## Eingabedateien

Alle Dateien liegen im Arbeitsordner, Trennzeichen ist das Semikolon. Vorlagen stehen in [`examples/`](examples/).

### switches.csv (Pflicht)

| Spalte | Bedeutung |
|---|---|
| `IP` | Management-IP |
| `Name` | Hostname (Phase `Hostname` setzt ihn), max. 32 Zeichen, nur `A-Z a-z 0-9 - _` |
| `Typ` | `Core` oder `Access`. Alles außer `Core` gilt als Access (z. B. `6100`, `6000`). Bestimmt, welches Image und welche Neustart-Phase greift. |
| `STP` | Spanning-Tree-Priority: Vielfaches von 4096, 0 bis 61440. Der niedrigste Wert muss der gewünschte Root sein. |
| `Gruppe` | Frei wählbare Nummer. Neustart-Phasen arbeiten Gruppe für Gruppe ab, `-Gruppe` filtert darauf. |
| `Aktiv` | `ja` / `nein`. Nur aktive Zeilen werden bearbeitet. |
| `Inventar` | optional, Inventarnummer → `snmp-server system-contact` |
| `Rack` | optional, Standort/Rack → `snmp-server system-location` |

Die Reihenfolge der Zeilen ist die Bearbeitungsreihenfolge innerhalb einer Gruppe.

### vlans.csv (nur Phase VLAN)

`ID;Name`. IDs 2 bis 4094, Namen max. 32 Zeichen ohne Leerzeichen.

### trunks.csv (nur Phase VLAN)

`IP;Ports`. Kommagetrennte Ports je Switch (z. B. `1/1/49,1/1/50`). Diese Ports werden zu Trunks mit `native 1` und allen VLANs aus `vlans.csv` plus VLAN 1. **Achtung:** `vlan trunk native` macht aus einem Access-Port einen Trunk.

## Phasen

| Phase | Wirkung | Neustart |
|---|---|---|
| `Backup` | Sichert running-config, LLDP-Nachbarn, Version, Images, Transceiver, Interface-Übersicht und `show system` nach `.\backup\<Zeitstempel>\`. Nur lesend; nicht erreichbare Switches werden am Ende gemeldet. | nein |
| `Stage1` | Access: Image Welle 1 → **secondary**. Core: Core-Image → **secondary**. Überspringt Switches, auf denen die Version schon liegt, und wartet auf die SHA-Prüfung. | nein |
| `Stage2` | Access: erst `boot set-default secondary`, danach Image Welle 2 → **primary**. | nein |
| `Welle1` | Access: `boot system secondary` | **ja** |
| `Welle2` | Access: `boot system primary` | **ja** |
| `Cores` | Cores einzeln nacheinander: `boot system secondary`. Beim zweiten Core erst nach erfolgreichem ersten. | **ja** |
| `Hostname` | `hostname <Name>` aus der CSV | nein |
| `Basis` | Default-Route, DNS, NTP (`iburst`), Zeitzone; prüft die Default-Route | nein |
| `Banner` | Leerer Login-Banner (ersetzt den HPE-Standardtext), entfernt den Exec-Banner | nein |
| `Inventar` | `Rack` → system-location, `Inventar` → system-contact | nein |
| `STP` | `spanning-tree priority` aus der CSV; prüft danach Bridge- und Root-Priority | nein |
| `VLAN` | VLANs anlegen, Trunk-Ports setzen, prüft `show vlan` | nein |
| `Passwort` | Neues Passwort für den angemeldeten Benutzer. Abfrage zweimal verdeckt, nie im Log. Nach jedem Switch Login-Test mit dem neuen Passwort, beim ersten Fehler Abbruch. | nein |

Jede ändernde Phase speichert mit `write memory`.

## Parameter

| Parameter | Standard | Verwendung |
|---|---|---|
| `-Phase` | – | Pflicht |
| `-DryRun` | aus | Zeigt nur, was passieren würde. Keine Verbindung, keine Änderung. |
| `-Only <IP>` | – | Nur dieser Switch |
| `-Gruppe <n>` | – | Nur diese Gruppe |
| `-SwitchCsv`, `-VlanCsv`, `-TrunkCsv` | `.\switches.csv` usw. | Andere Dateinamen |
| `-Tftp` | – | Pflicht für `Stage1`/`Stage2` |
| `-ImageAccessWelle1`, `-ImageAccessWelle2`, `-ImageCore` | – | Dateinamen der Images auf dem TFTP-Server |
| `-VersionAccessWelle1`, `-VersionAccessWelle2`, `-VersionCore` | aus Image-Name | Erwartete Version, z. B. `10.16.1060`. Bei Stage-Phasen aus dem Dateinamen abgeleitet (`PL_10_16_1060.swi` → `10.16.1060`), bei Neustart-Phasen anzugeben. |
| `-Gateway`, `-Dns` | – | Pflicht für `Basis` |
| `-Ntp` | `pool.ntp.org` | `Basis` |
| `-Timezone` | `europe/berlin` | `Basis` |

## Ablauf Firmware-Update

Vorher in den Release Notes den **Upgrade-Pfad** prüfen. Ältere Versionen brauchen teils eine Zwischenversion. Dafür gibt es zwei Wellen.

**Mit Zwischenversion** (z. B. Access 10.11 → 10.13 → 10.16, Cores direkt):

```powershell
cxw -Phase Backup
cxw -Phase Stage1 -Tftp 10.0.0.5 -ImageAccessWelle1 PL_10_13_1190.swi -ImageCore FL_10_16_1060.swi
cxw -Phase Stage2 -Tftp 10.0.0.5 -ImageAccessWelle2 PL_10_16_1060.swi -VersionAccessWelle1 10.13
# --- Wartungsfenster ---
cxw -Phase Welle1 -VersionAccessWelle1 10.13 -VersionAccessWelle2 10.16 -Gruppe 1
cxw -Phase Welle2 -VersionAccessWelle2 10.16 -Gruppe 1
cxw -Phase Cores  -VersionCore 10.16
```

**Ohne Zwischenversion:** nur `Stage1` und `Welle1` mit der Zielversion, `Stage2` und `Welle2` entfallen.

Die Stage-Phasen starten nichts neu und können vorab im laufenden Betrieb erfolgen. Jede Phase zuerst mit `-DryRun` und danach mit `-Only <IP>` an einem Switch testen.

## Sicherheitsnetz

- **Vorabprüfung:** Vor jedem Neustart prüft das Skript auf allen Zielen, ob die Ziel-Partition die erwartete und fertig verifizierte Version enthält. Passt ein Switch nicht, bricht es ab, bevor irgendein Switch neu startet.
- **Kein Downgrade:** Switches, die schon mit der Zielversion laufen, werden übersprungen.
- **Bestätigung:** Vor jedem Neustart und jeder Gruppe muss `JA` eingegeben werden (Groß-/Kleinschreibung beachten).
- **Gruppenweise:** Fällt nach einer Gruppe ein Switch aus oder kommt mit falscher Version hoch, startet keine weitere Gruppe.
- **Fallback:** Auf der jeweils anderen Partition bleibt eine ältere Version liegen (bei zwei Wellen die Zwischenversion), auf die per `boot system` zurückgewechselt werden kann.
- **Log:** Jeder Lauf schreibt ein Transcript nach `.\logs\`.

## Praxistipps

- Alle Switches einer Gruppe starten **nahezu gleichzeitig** neu. Gruppen so schneiden, dass der Admin-PC während des Neustarts weiter die übrigen Switches erreicht (Cores immer als eigene Gruppe bzw. über `-Phase Cores`).
- Nach dem Kopieren prüft der Switch das Image im Hintergrund (`SHA-256: Verifying`). Das Skript wartet darauf. Ein Neustart auf eine Partition im Verifying-Zustand wird verweigert.
- Neuere Hardware-Revisionen setzen teils eine Mindestversion voraus und lehnen ältere Images ab (z. B. CX 6000 R8N89**B** erst ab 10.16). Bei einem Fehler beim Kopieren zuerst die Release Notes zur Hardware prüfen.
- Ändert sich die IP eines Switches, passt der gespeicherte SSH-Hostkey nicht mehr: `Remove-SSHTrustedHost <IP>`.
- `-Gruppe` und `-Only` lassen sich kombinieren, um eine Phase gezielt zu wiederholen.
- Die Passwort-Phase setzt das Kennwort mit `user <name> group administrators password plaintext …`. Für Konten in einer anderen Gruppe ist sie nicht gedacht.
