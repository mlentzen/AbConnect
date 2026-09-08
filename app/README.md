# AbConnect (Connect-IQ-App)

App vom Typ `audio-content-provider-app` für die fēnix 7X Pro. Sie lädt
Hörbuch-Segmente von [abconnect-proxy](../proxy/README.md), spielt sie über den
System-Mediaplayer ab und merkt sich den Hörfortschritt.

## Aufbau

Connect IQ startet die App in vier getrennten Modi, jeder als eigener App-Start
ohne gemeinsamen Laufzeitzustand. Was einen Modus überdauern muss, liegt im
Object Store — flach, weil jeder Wert dort auf 8 KB begrenzt ist.

| Datei | Modus |
|---|---|
| `ui/SyncConfigView.mc` | Sync-Konfiguration: zeigt die Playlist und ihren Zustand |
| `sync/SyncDelegate.mc` | Sync: Fortschritt melden, Playlist lesen, spiegeln |
| `ui/PlaybackConfigView.mc` | Playback-Konfiguration: welches Buch |
| `playback/ContentDelegate.mc`, `ContentIterator.mc` | Playback |

Ausgewählt wird nicht auf der Uhr, sondern in Audiobookshelf: die Playlist
`Garmin` ist die Sollvorgabe, der Sync spiegelt sie. Fehlt die Playlist oder ist
der Server nicht erreichbar, wird nichts gelöscht.

Zwei Details machen daraus eine Hörbuch- statt einer Musik-App:
`Media.ContentMetadata` wird selbst gesetzt (die Segmenttitel kommen aus dem
Store, nicht aus den Tags der Datei), und das laufende Segment kommt als
`Media.ActiveContent` mit Startposition zurück — nur so setzt der Player mitten
im Kapitel fort.

## Bauen

```sh
CIQ_HOME=/pfad/zum/sdk ./build.sh
```

Nötig sind das Connect-IQ-SDK, ein Entwicklerschlüssel (`CIQ_KEY`, Standard
`~/.ciq/developer_key`) und ein Geräteprofil für `fenix7xpro`.

`build.sh` liest eine `.env` neben dem Skript. Stehen dort `PROXY_URL` und
`PROXY_TOKEN`, landen sie als `source/BuildDefaults.mc` im Build und die App
läuft ohne weiteres Zutun los. Die Datei wird bei jedem Build neu erzeugt und
ist nicht eingecheckt — sie enthält das Token. Was in den Einstellungen der
Telefon-App steht, hat weiterhin Vorrang.

Die echten Geräteprofile lädt nur der SDK-Manager nach einem Garmin-Login. Wer
den nicht hat, kann mit `python3 ../tools/stub_device.py` ein **Ersatzprofil**
erzeugen. Damit lässt sich übersetzen und typprüfen — Speicherlimits, Layout und
Verhalten auf der Uhr sagt ein solcher Build aber nichts.

## Stand

Übersetzt sauber gegen SDK 9.2 bei Typprüfung Stufe 2 (informative). **Noch nie
auf Hardware gelaufen** — der Spike aus M0 des [Plans](../docs/PLAN.md) steht aus.

Offen:
- Typprüfung Stufe 3 (strict): 27 Meldungen, alle zu generischen Typparametern
  von `Storage`, `Dictionary` und `Method`.
- Launcher-Icon ist ein transparenter Platzhalter.
- Playlist-Ansicht zeigt bis zu 100 Bücher ohne Blättern.
- Der Fortschritts-Push beim Pausieren ist ungetestet: ob die Uhr während der
  Wiedergabe überhaupt eine Telefonverbindung hält, zeigt erst die Hardware.
