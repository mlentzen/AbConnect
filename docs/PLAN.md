# AbConnect — Audiobookshelf als Connect IQ Audio Provider

Planungsdokument. Stand: 2026-09-08.

Ziel: eine Monkey-C-App vom Typ `audio-content-provider-app`, die Hörbücher aus
einer selbst gehosteten [Audiobookshelf](https://www.audiobookshelf.org/)-Instanz
auf die Garmin-Uhr synchronisiert, offline abspielt und den Hörfortschritt
zurückschreibt.

**Zielumgebung (festgelegt):**

* Aktuelle ABS-Version (≥ 2.26, API-Keys verfügbar)
* Bibliothek überwiegend Einzeldatei-`.m4b` **mit** Kapitelmarken
* Testgerät fēnix 7X Pro (`fenix7xpro`, API Level 5.2)
* HTTPS mit gültigen Zertifikaten ist gegeben
* Companion-Server läuft als **Podman-Quadlet** im bestehenden Stack —
  **ohne gemeinsames Dateisystem mit ABS** und **ohne einkompilierte
  Serveradresse oder Schlüssel**

---

## 1. Rahmenbedingungen

### 1.1 Wie ein Audio Content Provider funktioniert

Connect IQ startet die App in **vier getrennten Modi** (jeder Modus ist ein
eigener App-Start, es gibt keinen gemeinsamen Laufzeitzustand):

| Modus | Einstieg | Aufgabe |
|---|---|---|
| Sync-Konfiguration | `getSyncConfigurationView()` | Nutzer wählt aus, was heruntergeladen werden soll |
| Sync | `getSyncDelegate()` | System aktiviert WLAN, App lädt Dateien herunter |
| Playback-Konfiguration | `getPlaybackConfigurationView()` | Nutzer wählt aus, was abgespielt wird |
| Playback | `getContentDelegate()` | System-Mediaplayer spielt ab, App liefert Iterator + Events |

App-Klasse erbt von `Application.AudioContentProviderApp`. Manifest:
`type="audio-content-provider-app"`, Permission `Communications`.

Referenzimplementierung: `garmin/connectiq-apps` → `audio-provider/monkeymusic`.

### 1.2 Harte Plattform-Constraints

1. **Kein Streaming.** Der Mediaplayer spielt ausschließlich Dateien, die vorher
   über `Communications.makeWebRequest(..., {:responseType => HTTP_RESPONSE_CONTENT_TYPE_AUDIO,
   :mediaEncoding => ...})` in den verschlüsselten Media-Cache geschrieben wurden.
   AbConnect ist eine Download-App, kein Streaming-Client.
2. **Codecs:** nur `ENCODING_MP3`, `ENCODING_M4A`, `ENCODING_WAV`, `ENCODING_ADTS`.
   Kein Opus, kein FLAC, kein HLS.
3. **JSON-Antworten sind eng limitiert.** `makeWebRequest` bricht bei großen
   Antworten mit `-402` (zu groß) bzw. `-403` (Speicher) ab; kritisch wird es schon
   im niedrigen zweistelligen KB-Bereich. Eine ungefilterte ABS-Bibliotheksantwort
   ist damit nicht verarbeitbar.
4. **Object Store: 8 KB pro Wert.** Flache Maps, kurze Schlüssel, ein Key pro Buch
   statt einer globalen Struktur.
5. **App-Größe** möglichst unter 128 KB.

TLS ist in dieser Umgebung kein Thema — Zertifikate sind gültig, die
Geräteanforderung (Kette von bekannter CA) ist erfüllt.

### 1.3 Relevante API-Details (verifiziert in den Toybox-Docs)

* **`Media.Content(contentRef, contentMetadata)`** — Metadaten (title, artist,
  album, genre, trackNumber) sind vom App-Code setzbar. Wir sind *nicht* auf Tags
  in den Audiodateien angewiesen.
* **`Media.ActiveContent(contentRef, metadata, playbackStartPos)`** — Subklasse von
  `Media.Content` mit Startposition in Sekunden. Ermöglicht echtes Resume mitten im
  Segment: der `ContentIterator` gibt für den aktuellen Track ein `ActiveContent`
  mit gespeicherter Position zurück.
* **`PlaybackProfile.skipForwardTimeDelta` / `skipBackwardTimeDelta`** — Standard 30 s,
  für Hörbücher auf 30 s vor / 15 s zurück gesetzt.

Weiteres: `Media.setAlbumArt()`, `Media.getCacheStatistics()`,
`Media.deleteCachedItem(ref)`, `Media.resetContentCache()`.

`Media.SyncDelegate` ist deprecated (Entfernung nach System 9). Da die fēnix 7X Pro
API Level 5.2 bietet, setzen wir `minSdkVersion` auf 5.0 und implementieren
ausschließlich gegen **`Communications.SyncDelegate`** (ab API 3.1.0).

### 1.4 Audiobookshelf-API

Auth: **API-Key** (ABS ≥ 2.26), Header `Authorization: Bearer <key>`. Erzeugt unter
Settings → Users → API Keys, erbt die Rechte des zugeordneten Users. Der Key liegt
ausschließlich im Proxy, nie auf der Uhr.

Genutzte Endpunkte (vom Proxy, nicht von der Uhr):

| Zweck | Endpunkt |
|---|---|
| Bibliotheken | `GET /api/libraries` |
| Buchliste | `GET /api/libraries/{id}/items?limit&page&sort&minified=1` |
| Buchdetails inkl. `media.audioFiles[]`, `media.chapters[]` | `GET /api/items/{id}?expanded=1&include=progress` |
| Laufende Bücher | `GET /api/me/items-in-progress` |
| **Datei-Download** | `GET /api/items/{id}/file/{ino}/download` |
| Cover | `GET /api/items/{id}/cover?width=...&format=jpeg` |
| Fortschritt schreiben / lesen | `PATCH` bzw. `GET /api/me/progress/{libraryItemId}` |

> Exakte Pfade und Feldnamen sind gegen die Zielinstanz zu verifizieren — ABS hat
> Auth und Sessions in 2.26 umgebaut. Ein Smoke-Test-Skript ist Teil von M1.

Bewusst **nicht** genutzt: `POST /api/items/{id}/play` und die Session-/HLS-Endpunkte.
Die liefern Transcoding-Streams, die das Gerät nicht abspielen kann.

---

## 2. Zentrale Designentscheidungen

### E1 — `abconnect-proxy` ist Kernkomponente

Eine Einzeldatei-`.m4b` ist auf der Uhr direkt nicht nutzbar: ein Track über zwölf
Stunden, keine Kapitelnavigation, ein einziger mehrere hundert MB großer Download,
dessen Abbruch alles kostet. Da die Bibliothek überwiegend aus `.m4b` besteht, ist
der Proxy Voraussetzung, nicht Beiwerk.

Er löst drei Probleme auf einmal:

1. **Kapitelschnitt.** `ffmpeg -ss <start> -to <ende> -i buch.m4b -map_chapters -1 -c copy seg.m4a`
   schneidet verlustfrei per Stream-Copy — kein Re-Encode, Ergebnis ist AAC im
   MP4-Container und damit `ENCODING_M4A`.
2. **Schlanke JSON-Antworten.** Die Uhr sieht nie eine ABS-Antwort, sondern flache,
   reduzierte Listen (siehe 1.2.3).
3. **Geheimnisse bleiben serverseitig.** Der ABS-API-Key liegt im Proxy; die Uhr
   kennt nur Proxy-URL und ein eigenes Token.

### E2 — Vorbereitung pro Buch, nicht pro Segment

Der Proxy hat **keinen Zugriff auf das ABS-Medienverzeichnis**. Um zu schneiden,
muss er die `.m4b` erst über `GET /api/items/{id}/file/{ino}/download` holen. Damit
ist Schneiden im Request ausgeschlossen — sonst würde jedes einzelne Segment einen
300-MB-Download auslösen.

Stattdessen ein **Prepare-Job pro Buch**:

```
prepare(bookId):
  1. Metadaten + Kapitel von ABS holen
  2. .m4b nach WORK_DIR herunterladen
  3. ffprobe: Kapitel verifizieren (Fallback: 15-min-Raster)
  4. Segmenttabelle normalisieren
  5. alle Segmente per -c copy schneiden -> CACHE_DIR/<bookId>/
  6. Cover holen und verkleinern
  7. .m4b löschen            <- sofort, nicht am Jobende
  8. Status = ready
```

Ausgelöst wird der Job **beim Ankreuzen in der Sync-Konfiguration**, nicht beim
Sync. Bis die Uhr am Ladegerät synchronisiert, ist das Buch in aller Regel fertig.
Der Sync fragt nur den Status ab und lädt, was `ready` ist; alles andere meldet er
als „wird noch vorbereitet" statt zu blockieren.

Schritt 7 ist bewusst früh: nach dem Schnitt hält der Proxy nur noch die Segmente,
deren Gesamtgröße dank Stream-Copy ungefähr der Quelldatei entspricht. Der
Spitzenbedarf von ~2× Buchgröße besteht nur während des Jobs.

### E3 — Konfiguration ausschließlich zur Laufzeit

Im Image steht **keine** ABS-Adresse und kein Schlüssel. Alles kommt aus der
Umgebung, Geheimnisse über Podman-Secrets:

| Variable | Pflicht | Bedeutung |
|---|---|---|
| `ABS_URL` | ja | Basis-URL der ABS-Instanz (stackintern erreichbar) |
| `ABS_API_KEY` | ja | ABS-API-Key, als Podman-Secret eingehängt |
| `ABCONNECT_TOKEN` | ja | Token für Uhr → Proxy, unabhängig vom ABS-Key |
| `CACHE_DIR` | — | Segment-Cache, Default `/var/cache/abconnect` |
| `WORK_DIR` | — | transienter Platz für die `.m4b` während des Jobs |
| `CACHE_MAX_BYTES` | — | Obergrenze, darüber LRU-Verdrängung |
| `SEGMENT_TARGET_SECONDS` / `_MIN_` / `_MAX_` | — | Segmentnormalisierung, Default 900 / 180 / 1500 |
| `LOG_LEVEL` | — | |

Der Start bricht mit klarer Meldung ab, wenn eine Pflichtvariable fehlt — kein
stiller Betrieb mit Defaults. `GET /healthz` prüft zusätzlich, ob ABS erreichbar
ist und der Key akzeptiert wird; damit schlägt eine Fehlkonfiguration im
Quadlet-Healthcheck auf, nicht erst beim ersten Sync.

Beispiel-Quadlet (`~/.config/containers/systemd/abconnect-proxy.container`):

```ini
[Unit]
Description=AbConnect proxy
After=audiobookshelf.service

[Container]
Image=ghcr.io/mlentzen/abconnect-proxy:latest
Environment=ABS_URL=https://audiobookshelf.internal
Secret=abs-api-key,type=env,target=ABS_API_KEY
Secret=abconnect-token,type=env,target=ABCONNECT_TOKEN
Volume=abconnect-cache:/var/cache/abconnect
Volume=abconnect-work:/var/tmp/abconnect
PublishPort=8080:8080
HealthCmd=/usr/bin/curl -fsS http://localhost:8080/healthz

[Install]
WantedBy=default.target
```

### E4 — Segmentnormalisierung

Kapitelmarken sind vorhanden, ABS-Kapitel schwanken aber stark in der Länge.
Zielgröße 10–20 min: Kapitel unter 3 min werden mit dem Folgekapitel
zusammengefasst, Kapitel über 25 min am festen Raster geteilt (Teil 1/2/…).
Fehlen Kapitelmarken oder sind sie unbrauchbar (Zeiten außerhalb der Dauer,
nicht monoton, nur ein Kapitel über das ganze Buch), greift der **Fallback: reines
15-min-Raster**. Bei 64 kbps ergibt das ~5–10 MB pro Segment — klein genug, dass
ein Abbruch billig ist und die unbekannte `makeWebRequest`-Dateigrenze nicht greift.

### E5 — Ein Segment = ein „Song"

Jedes Segment wird ein Track, das Buch ist das „Album", der Autor der „Artist",
der Segmentindex die `trackNumber`. Next/Previous, Fortschrittsanzeige und Resume
funktionieren damit ohne Sonderlogik.

Die Uhr rechnet **nie** in absoluten Buchzeiten. Sie kennt nur
`(Segmentindex, Offset im Segment)`; die Umrechnung in ABS-`currentTime` macht der
Proxy anhand der Segmenttabelle. Das hält die Gerätelogik klein und die
Segmentierung serverseitig änderbar.

### E6 — Fortschritt wird gepuffert, nicht live gepusht

Während der Wiedergabe ist kein WLAN aktiv. `ContentDelegate.onSong()` liefert
`(refId, event, playbackPosition)`; wir schreiben `(bookId, segIdx, sek, ts)` flach
in den Object Store und pushen die Queue beim nächsten Sync an `POST /v1/progress`.
Umgekehrt holt der Sync den Serverstand, damit Weiterhören auf dem Handy auf der
Uhr ankommt. Konfliktregel: **jüngerer Zeitstempel gewinnt**.

### E7 — Sync ist deltabasiert und abbruchfest

Der Object Store hält den lokalen Bestand. Der Sync berechnet `toDownload` /
`toDelete` aus der Auswahl. Ein Abbruch verliert nur das laufende Segment, nicht
das Buch. Option „abgeschlossene Bücher automatisch löschen".

### E8 — Multi-File-Bücher laufen mit, ohne Sonderweg

Bücher, die in ABS bereits als mehrere MP3/M4A-Dateien vorliegen, behandelt der
Proxy identisch: Prepare lädt die Dateien, die Segmenttabelle entspricht den
vorhandenen Dateien, geschnitten wird nur, wenn eine Datei über `SEGMENT_MAX` liegt.

---

## 3. Architektur

```
proxy/                       abconnect-proxy (Python/FastAPI + ffmpeg, Podman)
  config.py                  Env-Validierung beim Start, keine Defaults für Secrets
  abs_client.py              ABS-REST mit API-Key, Metadaten-Cache
  segmenter.py               Kapitel -> normalisierte Segmenttabelle, 15-min-Fallback
  preparer.py                Job: download -> ffprobe -> cut -> m4b löschen -> ready
  cache.py                   CACHE_DIR-Verwaltung, LRU gegen CACHE_MAX_BYTES, Pinning
  api.py                     /v1/* Vertrag zur Uhr, /healthz
  progress.py                Segment-Offset <-> absolute Buchzeit, Push an ABS

source/                      Connect-IQ-App (Monkey C)
  AbConnectApp.mc            AudioContentProviderApp: die vier Delegates/Views
  Constants.mc               Property-Keys, Enums, Schema-Version

  net/
    ProxyClient.mc           /v1-Aufrufe, Token-Header
    RequestQueue.mc          serielle Request-Kette + Context-Injection

  sync/
    SyncDelegate.mc          Communications.SyncDelegate
    SyncPlanner.mc           Delta Auswahl vs. lokaler Bestand, Status-Filter
    Downloader.mc            makeWebRequest mit :mediaEncoding, Retry, Fortschritt

  ui/
    SyncConfigView.mc        Buchliste (CheckboxMenu), löst prepare aus, zeigt Status
    PlaybackConfigView.mc    lokale Bücher, „fortsetzen" / „von vorn"
    ProgressView.mc
    ErrorView.mc

  playback/
    ContentDelegate.mc       Iterator liefern, onSong -> Progress-Puffer
    ContentIterator.mc       Reihenfolge, Metadaten, ActiveContent mit Startposition
    ProgressStore.mc         flacher Puffer + Flush-API

resources/                   Strings (de/en), Icons, settings.xml (proxyUrl, proxyToken)
manifest.xml                 type=audio-content-provider-app, fenix7xpro, minSdkVersion 5.0
monkey.jungle
deploy/                      Quadlet-Unit, Beispiel-Secrets, Setup-Doku
```

### Proxy-API (Vertrag zur Uhr)

| Endpunkt | Zweck |
|---|---|
| `GET /v1/books?page=&q=` | flache Liste: `id`, Titel, Autor, Dauer, Status, Fortschritt |
| `POST /v1/books/{id}/prepare` | Job anstoßen (idempotent), Antwort sofort |
| `GET /v1/books/{id}/status` | `pending` \| `preparing` (+ Prozent) \| `ready` \| `error` (+ Grund) |
| `GET /v1/books/{id}/segments` | Segmentliste: Index, Titel, Dauer, Bytes — nur bei `ready` |
| `GET /v1/books/{id}/seg/{n}.m4a` | fertiges Segment aus dem Cache |
| `GET /v1/books/{id}/cover.jpg?w=` | verkleinertes Cover |
| `POST /v1/books/{id}/release` | Uhr meldet: Buch nicht mehr benötigt → Cache darf verdrängen |
| `POST /v1/progress` | Batch-Upload, Umrechnung auf Buchzeit, Weitergabe an ABS |
| `GET /healthz` | Konfiguration + ABS-Erreichbarkeit |

Alle `/v1`-Endpunkte verlangen `Authorization: Bearer $ABCONNECT_TOKEN`.

### Datenfluss

```
ABS  <--API-Key, HTTPS--  abconnect-proxy  <--Token, HTTPS--  fenix 7X Pro
        (Download der m4b)                   (Segmente)

Sync-Config:   GET  /v1/books                  -> CheckboxMenu -> Store: SEL
               POST /v1/books/{id}/prepare     -> Job läuft im Hintergrund
Sync:          GET  /v1/books/{id}/status      -> nur ready wird geladen
               GET  /v1/books/{id}/segments    -> Delta gegen lokalen Bestand
               GET  /v1/books/{id}/seg/{n}.m4a -> Media-Cache (ENCODING_M4A)
               GET  /v1/books/{id}/cover.jpg   -> makeImageRequest
               POST /v1/progress               <- Store: PRG  -> ABS /api/me/progress
               POST /v1/books/{id}/release     -> für abgewählte Bücher
Playback:      Store -> ContentIterator -> ActiveContent(ref, meta, startPos)
               onSong(pos) -> Store: PRG
```

### Cache-Haushalt im Proxy

* `CACHE_DIR/<bookId>/` hält Segmente + Cover, Größe ≈ Quelldatei.
* `WORK_DIR` hält die `.m4b` nur während des Jobs; Löschung direkt nach dem Schnitt,
  auch im Fehlerfall (`try/finally`).
* Bücher in der aktuellen Auswahl der Uhr sind **gepinnt** und werden nicht
  verdrängt; `release` hebt den Pin auf.
* Darüber hinaus LRU gegen `CACHE_MAX_BYTES`. Ein verdrängtes Buch geht zurück auf
  `pending` und wird bei Bedarf neu vorbereitet.
* Vor dem Start eines Jobs wird geprüft, ob Quellgröße + Segmente ins Budget passen;
  sonst `error` mit klarer Meldung statt vollgelaufener Platte.

### Object-Store-Layout auf der Uhr (8-KB-Grenze pro Wert)

| Key | Inhalt |
|---|---|
| `SEL` | Array ausgewählter Buch-IDs |
| `LOC_<bookId>` | flache Map `refId -> "segIdx\|dauer"` — **ein Key pro Buch** |
| `BOOK_<bookId>` | Titel, Autor, Segmentanzahl, Cover-Status (kurze Strings) |
| `PRG` | flache Map `bookId -> "segIdx\|sek\|ts"`, nur für lokal vorhandene Bücher |
| `VER` | Schema-Version → bei Mismatch `clearProperties()` + `resetContentCache()` |

---

## 4. Risiken

| # | Risiko | Wirkung | Gegenmaßnahme |
|---|---|---|---|
| R1 | ffmpeg-Stream-Copy erzeugt Datei, die die Uhr ablehnt | Ansatz kippt komplett | **Spike in M0** vor allem anderen: Segment von Hand schneiden und auf der fēnix abspielen |
| R2 | Prepare-Job dauert länger als die Geduld beim Sync | Buch fehlt beim Sync | Auslösung schon beim Ankreuzen (E2); Sync zeigt Status statt zu blockieren |
| R3 | Plattenplatz im Stack | Job schlägt fehl, Volume läuft voll | `CACHE_MAX_BYTES` + LRU + Pinning; Vorabprüfung; `.m4b` sofort nach Schnitt löschen |
| R4 | Netzlast ABS → Proxy bei jedem Prepare | langsam bei großen Büchern | einmalig pro Buch statt pro Segment; Backlog: `ffmpeg` per HTTP-Range direkt gegen die ABS-URL, falls Range zuverlässig unterstützt wird |
| R5 | Kapitelmarken doch unbrauchbar (nicht monoton, außerhalb der Dauer) | falsche Segmentgrenzen | Validierung in `segmenter.py`, automatischer 15-min-Fallback, Report in M1 |
| R6 | Unbekannte `makeWebRequest`-Dateigrenze | Sync bricht auf Hardware ab, im Simulator nicht | 5–10-MB-Segmente halten weit darunter; Grenze im M0-Spike bestimmen |
| R7 | 8-KB-Property-Limit bei großer Bibliothek | Datenverlust/Absturz | Key-pro-Buch-Layout; Serialisierungstest mit 500 Büchern |
| R8 | ABS-API-Änderungen (2.26er Auth-Umbau) | Proxy bricht | Versionscheck beim Start, `/healthz`, Smoke-Test im Repo |
| R9 | fēnix 7 Pro **ohne WLAN**-Variante | Sync über BLE unpraktikabel langsam | Nur WLAN-Varianten unterstützen, in der Beschreibung nennen |
| R10 | Store-Freigabe für Audio-Provider-Apps | Release verzögert | Review-Anforderungen früh prüfen, Sideload-Weg dokumentieren |

---

## 5. Roadmap

**M0 — Machbarkeits-Spike (zuerst, klein, entscheidet alles)**
Ein Buch der echten Bibliothek von Hand mit ffmpeg `-c copy` schneiden, per
Mini-HTTP-Server ausliefern, mit einer Wegwerf-App auf der fēnix 7X Pro laden und
abspielen. Beantwortet R1 und R6, bevor Code entsteht. Parallel: App-Gerüst mit
allen vier Delegates als Stubs, Build für `fenix7xpro` grün, CI kompiliert.

**M1 — `abconnect-proxy` v1**
Env-Validierung und `/healthz`, ABS-Client mit API-Key, Kapitelvalidierung und
Segmentnormalisierung inkl. 15-min-Fallback, Prepare-Job mit Download → Schnitt →
sofortiges Löschen der `.m4b`, Cache mit LRU und Pinning, `/v1/books`,
`/status`, `/segments`, `/seg/{n}.m4a`, `/cover.jpg`, `/release`. Dazu ein
Smoke-Test gegen die echte Instanz und ein Report über die Kapitelqualität der
Bibliothek (R5). *Ergebnis: `curl` liefert ein abspielbares Segment, Quadlet läuft.*

**M2 — Sync-Konfiguration und Sync**
`settings.xml` (proxyUrl, proxyToken), `ProxyClient`, Buchliste mit Paging als
`CheckboxMenu` — Ankreuzen löst `prepare` aus, Status wird angezeigt.
`Communications.SyncDelegate` mit Delta-Planer und Status-Filter, serielle
Downloads mit `:mediaEncoding => Media.ENCODING_M4A`, `notifySyncProgress` /
`notifySyncComplete`, `deleteCachedItem`, Cover via `makeImageRequest`,
Speicherprüfung über `getCacheStatistics()` vor dem Sync.
*Ergebnis: ein Buch liegt vollständig auf der Uhr.*

**M3 — Wiedergabe**
`ContentDelegate` + `ContentIterator`, Metadaten aus dem Store statt aus Tags,
`PlaybackProfile` mit Hörbuch-Skips (30 s / 15 s), `ActiveContent` mit
Startposition, Playback-Konfiguration mit „fortsetzen" / „von vorn".
*Ergebnis: Segmente laufen in richtiger Reihenfolge, Resume funktioniert.*

**M4 — Fortschritt bidirektional**
`onSong`-Puffer, Flush an `POST /v1/progress`, Umrechnung im Proxy, Serverstand
beim Sync einlesen, Konfliktregel jüngster Zeitstempel, „abgeschlossene löschen"
inklusive `release`. *Ergebnis: Handy und Uhr bleiben synchron.*

**M5 — Härtung & Release**
Fehlerpfade (401, Proxy offline, Prepare-Fehler, Speicher voll, Sync-Abbruch),
Strings de/en, Store-Migration über `VER`, Icons, `deploy/` mit Quadlet-Unit,
Secret-Anlage und Setup-Doku, Store-Einreichung bzw. Sideload-Anleitung.

**Backlog:** weitere Geräte über `fenix7xpro` hinaus, ffmpeg per HTTP-Range statt
Vollabzug (R4), optionales Re-Encode auf niedrigere Bitrate, Podcast-Unterstützung.

---

## 6. Zielgerät und Test

Zielgerät: fēnix 7X Pro (`fenix7xpro`, API Level 5.2, 32 GB). `minSdkVersion` 5.0.
Weitere Geräte erst nach M5 — jedes zusätzliche kostet Layout- und Testaufwand ohne
neue Funktion.

Testebenen:
1. **Simulator** — Funktionslogik, alle vier Modi.
2. **Proxy-Tests** — Segmentierung, Kapitelvalidierung und Schnitt gegen echte
   `.m4b`-Dateien; schnell, automatisierbar, außerhalb von Monkey C.
3. **Hardware** — ab M0 im Spiel, ab M2 verpflichtend: Dateigrößen, Speicher und
   Codec-Akzeptanz lassen sich im Simulator nicht validieren.

---

## 7. Offene Punkte

1. Wie groß darf der Segment-Cache im Stack werden (`CACHE_MAX_BYTES`)? Bestimmt,
   wie oft neu vorbereitet werden muss.
2. Podcasts aus ABS mitnehmen oder auf Bücher beschränken?
3. Veröffentlichung im Connect IQ Store oder nur Sideload?

---

## Quellen

* [garmin/connectiq-apps — audio-provider/monkeymusic](https://github.com/garmin/connectiq-apps/tree/master/audio-provider/monkeymusic)
* [Toybox.Media API](https://developer.garmin.com/connect-iq/api-docs/Toybox/Media.html) —
  [Content](https://developer.garmin.com/connect-iq/api-docs/Toybox/Media/Content.html),
  [ActiveContent](https://developer.garmin.com/connect-iq/api-docs/Toybox/Media/ActiveContent.html),
  [ContentIterator](https://developer.garmin.com/connect-iq/api-docs/Toybox/Media/ContentIterator.html),
  [PlaybackProfile](https://developer.garmin.com/connect-iq/api-docs/Toybox/Media/PlaybackProfile.html)
* [Toybox.Communications.SyncDelegate](https://developer.garmin.com/connect-iq/api-docs/Toybox/Communications/SyncDelegate.html)
* [Creating Music Apps in Connect IQ 3](https://www.garmin.com/en-US/blog/developer/creating-music-apps-3x/)
* [Connect IQ Compatible Devices](https://developer.garmin.com/connect-iq/compatible-devices/)
* [Audiobookshelf API Reference](https://api.audiobookshelf.org/) ·
  [API Keys](https://audiobookshelf.org/docs/documentation/server-management/api-keys/)
* [M4B verlustfrei nach Kapiteln schneiden](https://orsolabs.dev/audiobo/guides/split-m4b-into-chapters/) ·
  [m4b-tool](https://github.com/sandreas/m4b-tool)
* [Podman Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
