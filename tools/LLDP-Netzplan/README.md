# LLDP-Netzplan

Fragt Switche per SNMP ab, liest deren LLDP-Nachbarn aus und erzeugt daraus einen Netzwerkplan: welcher Switch hängt über welchen Port an welchem anderen. Das Tool liest nur und ändert nichts an den Geräten.

Es arbeitet über die Standard-LLDP-MIB und ist damit herstellerunabhängig (Aruba CX, ArubaOS-Switch/ProCurve, Instant On, Cisco, Comware, Netgear …).

![Beispielplan mit fiktiven Daten](examples/netzplan-beispiel.png)

## Voraussetzungen

- Windows PowerShell 5.1 oder PowerShell 7. Keine Module nötig, SNMP v2c/v1 ist im Skript selbst umgesetzt.
- SNMP-Lesezugriff auf die Switche (UDP 161) vom Admin-PC aus
- LLDP auf den Switchen aktiv

## Schnellstart

```powershell
cd C:\Kunden\Musterfirma\Switches
& "$HOME\Tools\HPEArbua\tools\LLDP-Netzplan\Get-LldpTopology.ps1" 192.168.10.0/24 -Name Musterfirma
```

Als Ziel reicht ein Netz oder ein einzelner Core-Switch. Switche, die ein abgefragtes Gerät per LLDP als Nachbarn meldet, werden automatisch mit abgefragt, auch wenn sie in einem anderen Netz liegen.

```powershell
# Start am Core, zwei Communities probieren
Get-LldpTopology.ps1 10.0.0.1 -Community public,kunde123 -Name Musterfirma

# Nur die genannten Geräte, ohne Nachziehen der Nachbarn
Get-LldpTopology.ps1 10.0.0.1,10.0.0.2 -NoCrawl
```

## Parameter

| Parameter | Bedeutung | Standard |
|---|---|---|
| `-Target` | IP-Adressen, Hostnamen oder Netze in CIDR-Schreibweise (`/16` bis `/32`), mehrere mit Komma | Pflicht |
| `-Community` | SNMP-Community. Mehrere werden der Reihe nach probiert. | `public` |
| `-Name` | Titel des Plans und Präfix der Ausgabedateien | `netzplan` |
| `-OutDir` | Zielordner für die Ausgabe | aktueller Ordner |
| `-NoCrawl` | per LLDP gefundene Nachbar-Switche nicht automatisch abfragen | aus |
| `-IncludeEndpoints` | Access Points, Telefone und sonstige Nachbarn auch in die draw.io-Datei aufnehmen | aus |
| `-V1` | SNMP v1 statt v2c | aus |
| `-TimeoutMs` / `-Retries` | Wartezeit je Anfrage und Anzahl Wiederholungen | `1500` / `1` |
| `-Port` | SNMP-Port | `161` |

Mehrere Communities funktionieren beim Aufruf in der PowerShell-Konsole. Bei `powershell.exe -File …` kommt `a,b` als eine einzige Community an.

## Ausgabe

Alle Dateien landen im aktuellen Ordner bzw. in `-OutDir`:

| Datei | Inhalt |
|---|---|
| `<Name>.html` | Interaktiver Plan für den Browser, läuft offline. Knoten verschieben, zoomen, Klick auf ein Gerät zeigt dessen Portbelegung. APs, Telefone und Sonstiges sind einblendbar. Export als SVG. |
| `<Name>.drawio` | Derselbe Plan zum Nachbearbeiten in draw.io / diagrams.net |
| `<Name>_links.csv` | Gerät A, Port A, Port B, Gerät B und ob beide Seiten den Link gemeldet haben |
| `<Name>_devices.csv` | Alle gefundenen Geräte mit IP, Typ, Chassis-ID und Beschreibung |

Die Ausgabe enthält Kundendaten und gehört in den Arbeitsordner des Kunden. Die `.gitignore` blockt `*.html`, `*.drawio` und `*.csv` im Repository.

## So liest man den Plan

- Jede Linie ist ein LLDP-Nachbarschaftsverhältnis, die Beschriftung an den Enden nennt den Port auf der jeweiligen Seite.
- Mehrere Linien zwischen zwei Geräten sind einzelne physische Links, typischerweise ein LAG.
- Gestrichelte Geräte wurden von einem Nachbarn per LLDP gemeldet, haben selbst aber nicht auf SNMP geantwortet. Der Port auf deren Seite stammt dann aus der Meldung des Nachbarn.
- Der Gerätetyp (Switch, Router/Firewall, Access Point, Telefon) kommt aus den LLDP-Capabilities.

## Grenzen

- Ohne LLDP keine Nachbarn. Geräte, die nur CDP sprechen, tauchen ohne Verbindungen auf.
- SNMP v3 wird nicht unterstützt.
- Unmanaged Switche und Medienkonverter sind für LLDP unsichtbar. Hängen zwei Switche über so ein Gerät zusammen, zeigt der Plan sie als direkt verbunden.
- Portnamen werden so übernommen, wie das Gerät sie per LLDP meldet. Lange Namen wie `GigabitEthernet1/0/1` werden zu `Gi1/0/1` gekürzt.

## Teststand

Bisher gegen simulierte Switche mit verschiedenen Port-Namensschemata unter PowerShell 7 getestet (v2c und v1). Der Einsatz an echter Hardware und unter Windows PowerShell 5.1 steht noch aus.
