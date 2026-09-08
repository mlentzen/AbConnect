# AbConnect — Audiobookshelf als Connect IQ Audio Provider

Planungsdokument. Stand: 2026-09-08.

Ziel: eine Monkey-C-App vom Typ `audio-content-provider-app`, die Hörbücher aus
einer selbst gehosteten [Audiobookshelf](https://www.audiobookshelf.org/)-Instanz
auf die Garmin-Uhr synchronisiert, offline abspielt und den Hörfortschritt
zurückschreibt.

**Zielumgebung (festgelegt):** aktuelle ABS-Version (≥ 2.26, API-Keys verfügbar),
Bibliothek überwiegend als Einzeldatei-`.m4b`, Testgerät **fēnix 7X Pro**
(Connect IQ Device-ID `fenix7xpro`, API Level 5.2).

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

Diese Punkte bestimmen die Architektur — sie sind nicht verhandelbar:

1. **Kein Streaming.** Der Mediaplayer spielt ausschließlich Dateien, die vorher
   über `Communications.makeWebRequest(..., {:responseType => HTTP_RESPONSE_CONTENT_TYPE_AUDIO,
   :mediaEncoding => ...})` in den verschlüsselten Media-Cache geschrieben wurden.
   AbConnect ist eine Download-App, kein Streaming-Client.
2. **Codecs:** nur `ENCODING_MP3`, `ENCODING_M4A`, `ENCODING_WAV`, `ENCODING_ADTS`.
   Kein Opus, kein FLAC, kein HLS.
3. **HTTPS-Pflicht auf Hardware.** Das Gerät akzeptiert nur TLS mit einer von einer
   bekannten CA signierten Kette. Self-signed-Zertifikate scheitern (im Simulator
   über *Settings → Use Device HTTPS Requirements* abschaltbar, auf der Uhr nicht).
4. **JSON-Antworten sind eng limitiert.** `makeWebRequest` bricht bei großen
   Antworten mit `-402` (zu groß) bzw. `-403` (Speicher) ab; in der Praxis wird es
   schon im niedrigen zweistelligen KB-Bereich kritisch. Eine ungefilterte
   ABS-Bibliotheksantwort ist damit nicht verarbeitbar.
5. **Object Store: 8 KB pro Wert.** Verschachtelte Strukturen sprengen das Limit
   sofort. → flache Maps, kurze Schlüssel, ein Key pro Buch statt einer globalen Struktur.
6. **App-Größe** möglichst unter 128 KB.

### 1.3 Relevante API-Details (verifiziert in den Toybox-Docs)

Drei Funde, die den Unterschied zwischen „Musikplayer" und „brauchbarer
Hörbuch-App" ausmachen:

* **`Media.Content(contentRef, contentMetadata)`** — Metadaten (title, artist,
  album, genre, trackNumber) sind vom App-Code setzbar. Wir sind *nicht* auf
  korrekte Tags in den Audiodateien angewiesen.
* **`Media.ActiveContent(contentRef, metadata, playbackStartPos)`** — Subklasse von
  `Media.Content` mit Startposition in Sekunden. Damit ist echtes Resume mitten im
  Kapitel möglich: der `ContentIterator` gibt für den aktuellen Track ein
  `ActiveContent` mit gespeicherter Position zurück.
* **`PlaybackProfile.skipForwardTimeDelta` / `skipBackwardTimeDelta`** — Standard 30 s,
  für Hörbücher anpassbar (30 s vor / 15 s zurück).

Weiteres: `Media.setAlbumArt()`, `Media.getCacheStatistics()` (freier Speicher),
`Media.deleteCachedItem(ref)`, `Media.resetContentCache()`.

`Media.SyncDelegate` ist deprecated (Entfernung nach System 9). Da die fēnix 7X Pro
API Level 5.2 bietet, setzen wir `minSdkVersion` auf 5.0 und implementieren
ausschließlich gegen **`Communications.SyncDelegate`** (ab API 3.1.0). Kein Fallback nötig.

### 1.4 Audiobookshelf-API

Auth: **API-Key** (ABS ≥ 2.26), Header `Authorization: Bearer <key>`, bei GET
alternativ `?token=<key>`. Erzeugt im Admin-UI unter Settings → Users → API Keys,
erbt die Rechte des zugeordneten Users, optionales Ablaufdatum. Praktikabler als
der JWT-Access/Refresh-Flow, weil kein interaktiver Login stattfindet.

Genutzte Endpunkte (vom Proxy, nicht von der Uhr):

| Zweck | Endpunkt |
|---|---|
| Bibliotheken | `GET /api/libraries` |
| Buchliste | `GET /api/libraries/{id}/items?limit&page&sort&minified=1` |
| Buchdetails inkl. `media.audioFiles[]`, `media.chapters[]` | `GET /api/items/{id}?expanded=1&include=progress` |
| Laufende Bücher | `GET /api/me/items-in-progress` |
| Datei-Download | `GET /api/items/{id}/file/{ino}/download` |
| Cover | `GET /api/items/{id}/cover?width=...&format=jpeg` |
| Fortschritt schreiben / lesen | `PATCH` bzw. `GET /api/me/progress/{libraryItemId}` |

> Exakte Pfade und Feldnamen sind gegen die Zielinstanz zu verifizieren — ABS hat
> Auth und Sessions in 2.26 umgebaut. Ein Smoke-Test-Skript ist Teil von M1.

Bewusst **nicht** genutzt: `POST /api/items/{id}/play` und die Session-/HLS-Endpunkte.
Die liefern Transcoding-Streams, die das Gerät nicht abspielen kann. Fortschritt
läuft direkt über `/api/me/progress`.

---

## 2. Zentrale Designentscheidungen

### E1 — `abconnect-proxy` ist Kernkomponente, nicht Beiwerk

Eine Einzeldatei-`.m4b` ist auf der Uhr direkt nicht sinnvoll nutzbar: ein Track
für 12 Stunden, keine Kapitelnavigation, ein einziger mehrere hundert MB großer
Download, dessen Abbruch alles kostet. Da die Bibliothek überwiegend aus `.m4b`
besteht, wird der Proxy zur Voraussetzung — er wandert von „optional, Phase 2"
an den Anfang der Roadmap.

Der Proxy löst dabei **drei** Probleme auf einmal:

1. **Kapitelschnitt.** `ffmpeg -ss <start> -to <ende> -i buch.m4b -map_chapters -1 -c copy kapitel.m4a`
   schneidet verlustfrei per Stream-Copy — kein Re-Encode, Laufzeit im
   Sekundenbruchteil, Ergebnis ist AAC im MP4-Container und damit `ENCODING_M4A`.
   Weil nicht transkodiert wird, braucht es kein Vorwärmen und keine Job-Queue;
   der Schnitt passiert im Request.
2. **Schlanke JSON-Antworten.** Die Uhr sieht nie eine ABS-Antwort, sondern flache,
   auf das Nötige reduzierte Listen (siehe Constraint 1.2.4).
3. **Angriffsfläche.** Nur der Proxy muss per HTTPS mit gültigem Zertifikat nach
   außen; die ABS-Instanz kann intern bleiben. Der ABS-API-Key liegt im Proxy,
   nicht auf der Uhr.

**Segmentnormalisierung:** ABS-Kapitel schwanken stark. Zielgröße 10–20 min:
Kapitel unter 3 min werden mit dem Folgekapitel zusammengefasst, Kapitel über
25 min am festen Raster geteilt (Teil 1/2/…). Bei 64 kbps ergibt das ~5–10 MB pro
Segment — klein genug, dass ein Abbruch billig ist und die unbekannte
`makeWebRequest`-Dateigrenze keine Rolle spielt. Bücher ohne Kapitelmarken werden
rein zeitbasiert in 15-min-Blöcke geschnitten.

**Proxy-API (Vertrag zur Uhr):**

| Endpunkt | Zweck |
|---|---|
| `GET /v1/books?page=&q=` | flache Liste: `id`, Titel, Autor, Segmentanzahl, Gesamtdauer, Fortschritt |
| `GET /v1/books/{id}/segments` | Segmentliste: Index, Titel, Dauer, Bytes |
| `GET /v1/books/{id}/seg/{n}.m4a` | verlustfreier ffmpeg-Ausschnitt, on-disk gecacht |
| `GET /v1/books/{id}/cover.jpg?w=` | verkleinertes Cover |
| `POST /v1/progress` | Batch-Upload, Umrechnung Segment-Offset → absolute Buchzeit, Weitergabe an ABS |

Auth Uhr → Proxy: eigenes statisches Token im Header, unabhängig vom ABS-Key.
Auslieferung als Docker-Container neben ABS.

### E2 — Ein Segment = ein „Song"

Die Uhr denkt in Tracks. Jedes Segment wird ein Track, das Buch ist das „Album",
der Autor der „Artist", der Segmentindex die `trackNumber`. Damit funktionieren
Next/Previous, Fortschrittsanzeige und Resume ohne Sonderlogik.

Die Uhr rechnet **nie** in absoluten Buchzeiten. Sie kennt nur
`(Segmentindex, Offset im Segment)`; die Umrechnung in ABS-`currentTime` macht der
Proxy anhand der Segmenttabelle. Das hält die Logik auf dem Gerät klein und die
Segmentierung serverseitig änderbar.

### E3 — Konfiguration über App-Settings

`proxyUrl` und `proxyToken` kommen aus den Connect-IQ-App-Einstellungen (Eingabe in
Garmin Connect Mobile). Kein OAuth: ABS ist kein OAuth-Provider für
Drittanwendungen, und der `makeOAuthRequest`-Weg aus MonkeyMusic bräuchte einen
zusätzlichen Redirect-Dienst.

### E4 — Fortschritt wird gepuffert, nicht live gepusht

Während der Wiedergabe ist kein WLAN aktiv. `ContentDelegate.onSong()` liefert
`(refId, event, playbackPosition)`; wir schreiben `(bookId, segIdx, sek, ts)` flach
in den Object Store und pushen die Queue beim nächsten Sync an `POST /v1/progress`.
Umgekehrt holt der Sync den Serverstand, damit Weiterhören auf dem Handy auf der
Uhr ankommt. Konfliktregel: **jüngerer Zeitstempel gewinnt**.

### E5 — Sync ist deltabasiert und abbruchfest

Der Object Store hält den lokalen Bestand. Der Sync berechnet `toDownload` /
`toDelete` aus der Auswahl. Ein abgebrochener Sync verliert nur das gerade laufende
Segment, nicht das Buch. Option „abgeschlossene Bücher automatisch löschen".

### E6 — Multi-File-Bücher später, nicht zuerst

Bücher, die in ABS bereits als mehrere MP3/M4A-Dateien vorliegen, könnten ohne
Proxy direkt geladen werden. Da sie hier die Ausnahme sind, führt der Proxy sie
einfach durch (Segmente = vorhandene Dateien). Ein proxyloser Direktmodus ist
Backlog, kein Milestone.

---

## 3. Architektur

```
proxy/                       abconnect-proxy (Python/FastAPI + ffmpeg, Docker)
  abs_client.py              ABS-REST, API-Key, Caching der Item-Metadaten
  segmenter.py               Kapitel -> normalisierte Segmenttabelle (10-20 min)
  cutter.py                  ffmpeg -ss/-to -c copy, on-disk Cache, LRU
  api.py                     /v1/* Vertrag zur Uhr
  progress.py                Segment-Offset <-> absolute Buchzeit, Push an ABS

source/                      Connect-IQ-App (Monkey C)
  AbConnectApp.mc            AudioContentProviderApp: die vier Delegates/Views
  Constants.mc               Property-Keys, Enums, Schema-Version

  net/
    ProxyClient.mc           /v1-Aufrufe, Token-Header
    RequestQueue.mc          serielle Request-Kette + Context-Injection

  sync/
    SyncDelegate.mc          Communications.SyncDelegate: Plan -> Delete -> Download -> Progress
    SyncPlanner.mc           Delta Auswahl vs. lokaler Bestand
    Downloader.mc            makeWebRequest mit :mediaEncoding, Retry, Fortschritt

  ui/
    SyncConfigView.mc        Buchliste (CheckboxMenu), Paging
    PlaybackConfigView.mc    lokale Bücher, „fortsetzen" / „von vorn"
    ProgressView.mc
    ErrorView.mc             lesbare Fehler statt stiller Abbrüche

  playback/
    ContentDelegate.mc       Iterator liefern, onSong -> Progress-Puffer
    ContentIterator.mc       Reihenfolge, Metadaten, ActiveContent mit Startposition
    ProgressStore.mc         flacher Puffer + Flush-API

resources/                   Strings (de/en), Icons, settings.xml (proxyUrl, proxyToken, Optionen)
manifest.xml                 type=audio-content-provider-app, fenix7xpro, minSdkVersion 5.0
monkey.jungle
```

Datenfluss:

```
ABS  <--API-Key--  abconnect-proxy  <--HTTPS+Token--  fenix 7X Pro

Sync-Config:   GET /v1/books            -> CheckboxMenu -> Store: SEL
Sync:          GET /v1/books/{id}/segments -> Delta
               GET /v1/books/{id}/seg/{n}.m4a -> Media-Cache (ENCODING_M4A)
               GET /v1/books/{id}/cover.jpg   -> makeImageRequest
               POST /v1/progress  <- Store: PRG        -> ABS /api/me/progress
Playback:      Store -> ContentIterator -> ActiveContent(ref, meta, startPos)
               onSong(pos) -> Store: PRG
```

### Object-Store-Layout (8-KB-Grenze pro Wert)

| Key | Inhalt |
|---|---|
| `SEL` | Array ausgewählter Buch-IDs |
| `LOC_<bookId>` | flache Map `refId -> "segIdx\|dauer"` — **ein Key pro Buch** |
| `BOOK_<bookId>` | Titel, Autor, Segmentanzahl, Cover-Status (kurze Strings) |
| `PRG` | flache Map `bookId -> "segIdx\|sek\|ts"`, nur für lokal vorhandene Bücher |
| `VER` | Schema-Version → bei Mismatch `clearProperties()` + `resetContentCache()` |

Der Key-pro-Buch-Zuschnitt ist der Hauptgrund, warum Provider-Apps nicht am
8-KB-Limit scheitern.

---

## 4. Risiken

| # | Risiko | Wirkung | Gegenmaßnahme |
|---|---|---|---|
| R1 | TLS-Kette wird vom Gerät abgelehnt | Sync unmöglich | Proxy hinter Reverse Proxy mit Let's Encrypt; Setup-Check-Screen mit klarer Meldung; im Simulator HTTPS-Requirement abschaltbar |
| R2 | `.m4b` mit fehlenden/kaputten Kapitelmarken | Segmentierung unbrauchbar | Fallback auf zeitbasierte 15-min-Blöcke; Prüfung in M1 gegen die echte Bibliothek |
| R3 | ffmpeg-Stream-Copy erzeugt Datei, die die Uhr ablehnt | kompletter Ansatz kippt | **Spike in M0** vor allem anderen: ein Segment von Hand schneiden und auf der fēnix abspielen |
| R4 | Unbekannte `makeWebRequest`-Dateigrenze | Sync bricht auf Hardware ab, im Simulator nicht | 5–10-MB-Segmente halten weit darunter; Grenze im M0-Spike empirisch bestimmen |
| R5 | 8-KB-Property-Limit bei großer Bibliothek | Datenverlust/Absturz | Layout oben; Serialisierungstest mit 500 Büchern |
| R6 | ABS-API-Änderungen (2.26er Auth-Umbau) | Proxy bricht | Versionscheck beim Start, Smoke-Test-Skript im Repo |
| R7 | Proxy als zusätzliche Betriebskomponente | Einstiegshürde, Wartung | Ein Docker-Container, eine Compose-Datei, Beispiel für Reverse-Proxy-Konfiguration |
| R8 | fēnix 7 Pro **ohne WLAN**-Variante | Sync über BLE unpraktikabel langsam | Nur WLAN-Varianten unterstützen, in der Store-Beschreibung nennen |
| R9 | Store-Freigabe für Audio-Provider-Apps | Release verzögert | Review-Anforderungen früh prüfen, Sideload-Weg dokumentieren |

---

## 5. Roadmap

**M0 — Machbarkeits-Spike (zuerst, klein, entscheidet alles)**
Ein Buch der echten Bibliothek von Hand mit ffmpeg `-c copy` in ein Segment
schneiden, per Mini-HTTP-Server ausliefern, mit einer Wegwerf-App auf der
fēnix 7X Pro herunterladen und abspielen. Beantwortet R3 und R4, bevor Code
entsteht. Parallel: App-Gerüst mit allen vier Delegates als Stubs, Build für
`fenix7xpro` grün, CI-Job der kompiliert.

**M1 — `abconnect-proxy` v1**
ABS-Client mit API-Key, Metadaten-Cache, Kapitel→Segment-Normalisierung,
`/v1/books`, `/v1/books/{id}/segments`, `/v1/books/{id}/seg/{n}.m4a` mit
On-Disk-Cache, `/v1/.../cover.jpg`. Dazu ein Smoke-Test gegen die echte Instanz,
der die ABS-Endpunkte verifiziert, und ein Report über die Kapitelqualität der
Bibliothek (R2). *Ergebnis: `curl` liefert ein abspielbares Segment.*

**M2 — Sync-Konfiguration und Sync**
`settings.xml` (proxyUrl, proxyToken), `ProxyClient`, Buchliste mit Paging als
`CheckboxMenu` mit Vorauswahl, `Communications.SyncDelegate` mit Delta-Planer,
serielle Downloads mit `:mediaEncoding => Media.ENCODING_M4A`,
`notifySyncProgress`/`notifySyncComplete`, `deleteCachedItem`, Cover via
`makeImageRequest`, Speicherprüfung über `getCacheStatistics()` vor dem Sync.
*Ergebnis: ein Buch liegt vollständig auf der Uhr.*

**M3 — Wiedergabe**
`ContentDelegate` + `ContentIterator`, Metadaten aus dem Store statt aus Tags,
`PlaybackProfile` mit Hörbuch-Skips (30 s / 15 s), `ActiveContent` mit
Startposition, Playback-Konfiguration mit „fortsetzen" / „von vorn".
*Ergebnis: Segmente laufen in richtiger Reihenfolge, Resume funktioniert.*

**M4 — Fortschritt bidirektional**
`onSong`-Puffer, Flush an `POST /v1/progress`, Umrechnung im Proxy, Serverstand
beim Sync einlesen, Konfliktregel jüngster Zeitstempel, „abgeschlossene löschen".
*Ergebnis: Handy und Uhr bleiben synchron.*

**M5 — Härtung & Release**
Fehlerpfade (401, Proxy offline, Speicher voll, Sync-Abbruch), Strings de/en,
Store-Migration über `VER`, Icons, Compose-Datei und Setup-Doku für den Proxy,
Store-Einreichung bzw. Sideload-Anleitung.

**Backlog** (kein Milestone): weitere Geräte über `fenix7xpro` hinaus,
proxyloser Direktmodus für Multi-File-Bibliotheken (E6), optionales Re-Encode auf
niedrigere Bitrate, Podcast-Unterstützung.

---

## 6. Zielgerät und Test

Zielgerät: **fēnix 7X Pro** (`fenix7xpro`, API Level 5.2, 32 GB Speicher).
`minSdkVersion` 5.0. Erst nach M5 weitere Geräte — jedes zusätzliche Gerät kostet
Layout- und Testaufwand ohne neue Funktion.

Testebenen:
1. **Simulator** — Funktionslogik, alle vier Modi, HTTPS-Requirement testweise aus.
2. **Proxy-Tests** — Segmentierung und Schnitt gegen echte `.m4b`-Dateien,
   außerhalb von Monkey C, schnell und automatisierbar.
3. **Hardware** — ab M0 im Spiel und ab M2 verpflichtend: TLS, Dateigrößen,
   Speicher und Codec-Akzeptanz lassen sich im Simulator nicht validieren.

---

## 7. Offene Punkte

1. Wie zuverlässig sind die Kapitelmarken in der Bibliothek? Entscheidet, wie oft
   der zeitbasierte Fallback greift (Messung in M1).
2. Wo läuft der Proxy — auf demselben Host wie ABS oder getrennt? Bestimmt
   Compose-Setup und Zugriff aufs Medienverzeichnis (direkter Dateizugriff wäre
   schneller als der Umweg über die ABS-Download-API).
3. Podcasts aus ABS mitnehmen oder auf Bücher beschränken?
4. Veröffentlichung im Connect IQ Store oder nur Sideload?

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
