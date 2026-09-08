# AbConnect

Audiobookshelf als Connect IQ Audio Provider für Garmin-Musikuhren.

Hörbücher aus einer selbst gehosteten
[Audiobookshelf](https://www.audiobookshelf.org/)-Instanz landen auf der Uhr,
laufen offline über den System-Mediaplayer und der Hörfortschritt geht zurück
an den Server.

## Aufbau

```
Audiobookshelf  <--API-Key--  abconnect-proxy  <--Token--  fēnix 7X Pro
                (lädt die m4b)                 (lädt Segmente)
```

**[`proxy/`](proxy/README.md)** — Container neben Audiobookshelf, betrieben als
Podman-Quadlet. Lädt eine `.m4b` über die ABS-API, schneidet sie verlustfrei
kapitelweise in Segmente von 10–20 Minuten, löscht die Quelldatei sofort wieder
und hält den ABS-API-Key serverseitig.

**[`app/`](app/README.md)** — Connect-IQ-App vom Typ
`audio-content-provider-app`, die Segmente lädt, abspielt und den Fortschritt
puffert.

Was auf die Uhr kommt, entscheidet die Audiobookshelf-Playlist **`Garmin`**:
Buch hineinlegen, es erscheint; herausnehmen, es verschwindet. Der Hörfortschritt
geht beim Pausieren über Bluetooth und beim Sync über WLAN zurück an den Server.

Warum ein Proxy dazwischen: eine einzelne `.m4b` wäre auf der Uhr ein Track über
zwölf Stunden ohne Kapitelnavigation, und Connect IQ bricht große
JSON-Antworten ohnehin ab. Die Begründungen im Einzelnen stehen in
[docs/PLAN.md](docs/PLAN.md).

## Stand

| Teil | Zustand |
|---|---|
| `abconnect-proxy` | funktionsfähig, 155 Tests grün (inkl. echtem ffmpeg-Schnitt) |
| Connect-IQ-App | übersetzt sauber, **noch nie auf Hardware gelaufen** |
| Hardware-Spike (M0) | **offen** — die entscheidende offene Frage |

Der Spike aus M0 steht noch aus: ein per Stream-Copy geschnittenes Segment auf
der fēnix 7X Pro abspielen. Lehnt das Gerät solche Dateien ab, trägt der ganze
Ansatz nicht — das gehört vor jede weitere Arbeit.

## Loslegen

```sh
# Proxy: Tests
python3 -m venv .venv && .venv/bin/pip install -e './proxy[dev]'
.venv/bin/python -m pytest proxy/tests

# Proxy: installieren und betreiben -> deploy/README.md
./deploy/install.sh

# App bauen -> app/README.md
CIQ_HOME=/pfad/zum/sdk ./app/build.sh
```

## Voraussetzungen

- Audiobookshelf ≥ 2.26 mit API-Key
- `abconnect-proxy` per HTTPS erreichbar
- Garmin-Uhr mit Musikspeicher und WLAN — Zielgerät zunächst fēnix 7X Pro
