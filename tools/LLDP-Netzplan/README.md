# LLDP-Netzplan

Fragt Switche per SNMP ab, liest deren LLDP-Nachbarn aus und erzeugt daraus einen Netzwerkplan: welcher Switch hängt über welchen Port an welchem anderen, mit welcher Geschwindigkeit und über welches Medium (z. B. `10G LWL`, `10G DAC`, `1G Kupfer`). Das Tool liest nur und ändert nichts an den Geräten.

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
| `<Name>_links.csv` | Gerät A, Port A, Port B, Gerät B, Link-Typ (Geschwindigkeit, Medium, Detail wie `10GBASE-SR` oder `SFP+DAC3`) und ob beide Seiten den Link gemeldet haben |
| `<Name>_devices.csv` | Alle gefundenen Geräte mit IP, Typ, Chassis-ID und Beschreibung |

Die Ausgabe enthält Kundendaten und gehört in den Arbeitsordner des Kunden. Die `.gitignore` blockt `*.html`, `*.drawio` und `*.csv` im Repository.

## So liest man den Plan

- Jede Linie ist ein LLDP-Nachbarschaftsverhältnis, die Beschriftung an den Enden nennt den Port auf der jeweiligen Seite.
- In der Mitte der Linie steht der Link-Typ, z. B. `10G LWL`. Die Farbe zeigt das Medium, die Strichstärke die Geschwindigkeit; die Legende steht unter dem Plan.
- Mehrere Linien zwischen zwei Geräten sind einzelne physische Links, typischerweise ein LAG. Sind sie gleichartig, tragen sie eine gemeinsame Beschriftung wie `2× 10G DAC`.
- Gestrichelte Geräte wurden von einem Nachbarn per LLDP gemeldet, haben selbst aber nicht auf SNMP geantwortet. Der Port auf deren Seite stammt dann aus der Meldung des Nachbarn.
- Der Gerätetyp (Switch, Router/Firewall, Access Point, Telefon) kommt aus den LLDP-Capabilities.

## Geschwindigkeit und Medium

Für jeden Port mit LLDP-Nachbar fragt das Tool zusätzlich ab:

| Angabe | Quelle |
|---|---|
| Geschwindigkeit | IF-MIB `ifHighSpeed`, ersatzweise `ifSpeed`. Das ist die ausgehandelte Geschwindigkeit. |
| Medium, erste Wahl | Typ des gesteckten Transceivers aus den HPE-MIBs: `HP-ICF-TRANSCEIVER-MIB` (ArubaOS-Switch/ProCurve) und `ARUBAWIRED-PM-MIB` (AOS-CX) |
| Medium, zweite Wahl | MAU-Typ des Ports aus der LLDP-802.3-Erweiterung oder der MAU-MIB, z. B. `1000BASE-T`, `10GBASE-SR` |
| Medium, dritte Wahl | MAU-Typ, den der Nachbar per LLDP für sein Ende meldet |

Daraus wird eine dieser Angaben:

| Angabe | Bedeutung |
|---|---|
| `LWL` | Glasfaser (SR, LR, SX, LX, BiDi …) |
| `DAC` | Direct-Attach-Kabel (Twinax) |
| `AOC` | aktives optisches Kabel |
| `Kupfer` | Twisted Pair (RJ45) |
| `SFP` | steckbares Modul, Medium nicht erkennbar |
| ohne Zusatz | das Gerät liefert keine Angabe zum Medium |

Der Standard kennt für 10G-DAC in SFP+-Ports keinen eigenen MAU-Typ. `10G DAC` erscheint deshalb nur, wenn der Switch den Transceiver-Typ über eine der beiden HPE-MIBs liefert. Bei anderen Herstellern steht an solchen Links `10G SFP`. Ab 25G gibt es eigene MAU-Typen für DAC.

Melden beide Enden gleich verlässlich unterschiedliche Medien (z. B. Medienkonverter), stehen beide im Plan: `1G LWL/Kupfer`.

## Grenzen

- Ohne LLDP keine Nachbarn. Geräte, die nur CDP sprechen, tauchen ohne Verbindungen auf.
- SNMP v3 wird nicht unterstützt.
- Unmanaged Switche und Medienkonverter sind für LLDP unsichtbar. Hängen zwei Switche über so ein Gerät zusammen, zeigt der Plan sie als direkt verbunden.
- Portnamen werden so übernommen, wie das Gerät sie per LLDP meldet. Lange Namen wie `GigabitEthernet1/0/1` werden zu `Gi1/0/1` gekürzt.

## Teststand

Bisher gegen simulierte Switche mit verschiedenen Port-Namensschemata unter PowerShell 7 getestet (v2c und v1). Der Einsatz an echter Hardware und unter Windows PowerShell 5.1 steht noch aus.

Das gilt besonders für die Medium-Erkennung: Die OIDs stammen aus den MIB-Dateien, die Typbezeichnungen echter Transceiver (`SFP+SR`, `SFP+DAC3`, `1000SX` …) werden per Mustererkennung eingeordnet. Welche Texte ein bestimmter Switch tatsächlich liefert, zeigt die Spalte `Detail` in der Link-CSV.
