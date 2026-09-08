# AbConnect — Audiobookshelf als Connect IQ Audio Provider

Planungsdokument. Stand: 2026-09-08.

Ziel: eine Monkey-C-App vom Typ `audio-content-provider-app`, die Hörbücher aus
einer selbst gehosteten [Audiobookshelf](https://www.audiobookshelf.org/)-Instanz
auf Garmin-Musikuhren synchronisiert, offline abspielt und den Hörfortschritt
zurückschreibt.

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
   → ABS muss hinter einem Reverse Proxy mit z. B. Let's-Encrypt-Zertifikat liegen
   und aus dem WLAN erreichbar sein, in dem die Uhr synchronisiert.
4. **Object Store: 8 KB pro Wert.** Verschachtelte Strukturen sprengen das Limit
   sofort. → flache Maps, kurze Schlüssel, Aufteilung über mehrere Properties.
5. **App-Größe** sollte unter 128 KB bleiben, damit Nutzer mehrere Apps installieren
   können. Grafiken und Strings entsprechend sparsam.
6. **Nur Musik-Geräte.** Uhren ohne Musikspeicher unterstützen den App-Typ nicht.

### 1.3 Relevante API-Details (verifiziert in den Toybox-Docs)

Drei Punkte, die den Unterschied zwischen „Musikplayer" und „brauchbarer
Hörbuch-App" ausmachen:

* **`Media.Content(contentRef, contentMetadata)`** — Metadaten (title, artist,
  album, genre, trackNumber) können vom App-Code gesetzt werden. Wir sind also
  *nicht* auf korrekte ID3-Tags in den ABS-Dateien angewiesen.
* **`Media.ActiveContent(contentRef, metadata, playbackStartPos)`** — Subklasse von
  `Media.Content` mit Startposition in Sekunden. Damit ist echtes Resume mitten im
  Kapitel möglich; der `ContentIterator` gibt für den aktuellen Track ein
  `ActiveContent` mit gespeicherter Position zurück.
* **`PlaybackProfile.skipForwardTimeDelta` / `skipBackwardTimeDelta`** — Standard 30 s,
  für Hörbücher konfigurierbar (z. B. 30 s vor / 15 s zurück).

Weiteres: `Media.setAlbumArt()` für Cover, `Media.getCacheStatistics()` für freien
Speicher, `Media.deleteCachedItem(ref)` zum Löschen, `Media.resetContentCache()` für
Full-Reset.

**`Media.SyncDelegate` ist deprecated** (Entfernung nach System 9 angekündigt).
Wir implementieren gegen **`Communications.SyncDelegate`** (API 3.1.0) und halten
über ein `has`-Guard einen Fallback bereit, solange minSdkVersion < 3.1 unterstützt
werden soll.

### 1.4 Audiobookshelf-API

Auth (ABS ≥ 2.26): **API-Key**, Header `Authorization: Bearer <key>`, bei
GET-Requests alternativ `?token=<key>`. Wird im Admin-UI unter
Settings → Users → API Keys erzeugt, hat optionales Ablaufdatum und erbt die
Rechte des zugeordneten Users. Für uns deutlich praktikabler als der
JWT-Access/Refresh-Flow, weil auf der Uhr kein Login-Formular existiert.

Verwendete Endpunkte:

| Zweck | Endpunkt |
|---|---|
| Bibliotheken | `GET /api/libraries` |
| Buchliste | `GET /api/libraries/{id}/items?limit&page&sort&minified=1` |
| Buchdetails inkl. `media.audioFiles[]` | `GET /api/items/{id}?expanded=1&include=progress` |
| Laufende Bücher | `GET /api/me/items-in-progress` |
| Einzeldatei-Download | `GET /api/items/{id}/file/{ino}/download` |
| Cover | `GET /api/items/{id}/cover?width=...&format=jpeg` |
| Fortschritt schreiben | `PATCH /api/me/progress/{libraryItemId}` mit `{currentTime, duration, progress, isFinished}` |
| Fortschritt lesen | `GET /api/me/progress/{libraryItemId}` |

> Die exakten Pfade und Feldnamen sind gegen die Version der Zielinstanz zu
> verifizieren — ABS hat die Auth- und Session-Endpunkte in 2.26 umgebaut. Ein
> Smoke-Test-Skript gegen eine echte Instanz ist Teil von M1.

Bewusst **nicht** genutzt: `POST /api/items/{id}/play` und die Session-/HLS-
Endpunkte. Die liefern Transcoding-Streams, die das Gerät nicht abspielen kann,
und erzeugen serverseitig Sessions, die wir offline ohnehin nicht sauber pflegen
können. Fortschritt geht direkt über `/api/me/progress`.

---

## 2. Zentrale Designentscheidungen

### E1 — Ein Kapitel = ein „Song"

Die Uhr denkt in Tracks. Jede ABS-Audiodatei eines Buchs wird ein Track, das Buch
ist das „Album", der Autor der „Artist", `trackNumber` die Reihenfolge. Damit
funktionieren Next/Previous, Fortschrittsanzeige und Resume ohne Sonderlogik.

### E2 — Nur Multi-File-Bücher in Phase 1

Ein Buch als einzelne 800-MB-`.m4b` ist auf der Uhr unbrauchbar: nicht teilbar,
oft jenseits sinnvoller Dateigrößen, und ein Abbruch beim Download kostet alles.
Phase 1 filtert Bücher, deren `media.audioFiles` mehrere Dateien mit Codec MP3
oder AAC/M4A enthält. Einzeldatei-Bücher werden in der Liste als „nicht
unterstützt" markiert statt still zu fehlen.

Phase 2 (optional, siehe M6): **Companion-Proxy** `abconnect-proxy` — ein kleiner
Dienst vor ABS, der `.m4b` anhand der Kapitelmarken in MP3-Häppchen (~10–15 min)
schneidet, Bitrate auf 64 kbps mono normalisiert und Tags setzt. Das löst
gleichzeitig Codec-, Größen- und Metadatenprobleme. Bewusst als separates,
optionales Deployment — die App muss ohne ihn funktionieren.

### E3 — Konfiguration über App-Settings, nicht auf der Uhr

`serverUrl` und `apiKey` kommen aus den Connect-IQ-App-Einstellungen (in Garmin
Connect Mobile bzw. Garmin Express eingetippt). Kein OAuth: ABS ist kein
OAuth-Provider für Drittanwendungen, und der `makeOAuthRequest`-Weg aus
MonkeyMusic würde einen zusätzlichen Redirect-Dienst erfordern.

### E4 — Fortschritt wird gepuffert, nicht live gepusht

Während der Wiedergabe ist keine WLAN-Verbindung aktiv. `ContentDelegate.onSong()`
liefert `(refId, event, playbackPosition)`; wir schreiben Position + Zeitstempel
flach in den Object Store und pushen die Queue beim nächsten Sync gegen
`/api/me/progress`. Beim Sync wird umgekehrt der Serverstand geholt, damit
Weiterhören auf dem Handy auf der Uhr ankommt. Konfliktregel: **jüngerer
Zeitstempel gewinnt**.

### E5 — Sync ist deltabasiert

Der Object Store hält, welche Tracks lokal liegen. Sync berechnet
`toDownload` / `toDelete` aus der Auswahl des Nutzers. Zusatzoption
„abgeschlossene Bücher automatisch löschen" hält den Speicher frei.

---

## 3. Architektur

```
source/
  AbConnectApp.mc          AudioContentProviderApp: liefert die vier Delegates/Views
  Constants.mc             Property-Keys, Enums, Versionsstempel für Store-Migration

  abs/
    AbsClient.mc           REST-Aufrufe, Bearer-Header, Basis-URL
    AbsModels.mc           Parsen von JSON -> flache Records (Book, Track)
    RequestQueue.mc        serielle Request-Kette + Context-Injection (vgl. RequestDelegate)

  sync/
    SyncDelegate.mc        Communications.SyncDelegate: Plan -> Delete -> Download -> Progress-Push
    SyncPlanner.mc         Delta-Berechnung Auswahl vs. lokaler Bestand
    Downloader.mc          makeWebRequest mit mediaEncoding, Retry, Fortschrittsmeldung

  ui/
    SyncConfigView.mc      Bibliothek -> Buchliste (CheckboxMenu), Paging
    PlaybackConfigView.mc  lokale Bücher, Auswahl + „von vorn / fortsetzen"
    ErrorView.mc           lesbare Fehler statt stiller Abbrüche
    ProgressView.mc

  playback/
    ContentDelegate.mc     Iterator liefern, onSong/onPlaybackComplete -> Progress-Buffer
    ContentIterator.mc     Reihenfolge, Metadaten, ActiveContent mit Startposition
    ProgressStore.mc       flacher Puffer + Flush-API

resources/                 Strings (de/en), Icons, settings.xml (serverUrl, apiKey, Optionen)
manifest.xml
monkey.jungle
```

Datenfluss:

```
Sync-Config:   ABS /api/libraries + /items  ->  CheckboxMenu  ->  Store: SELECTION
Sync:          SELECTION vs. LOCAL -> delete(Media) + download(/file/{ino}/download)
                                   -> Cover via makeImageRequest -> Store: LOCAL
                                   -> PROGRESS_QUEUE  ->  PATCH /api/me/progress
Playback:      LOCAL + PROGRESS -> ContentIterator -> ActiveContent(ref, meta, startPos)
               onSong(pos) -> PROGRESS_QUEUE
```

### Object-Store-Layout (8-KB-Grenze beachten)

| Key | Inhalt | Grenzen |
|---|---|---|
| `SEL` | Array ausgewählter Buch-IDs | ~150 IDs, unkritisch |
| `LOC_<bookId>` | flache Map `refId -> "trackIdx|dauer"` | ein Key **pro Buch**, nicht ein globaler |
| `BOOK_<bookId>` | Titel, Autor, Cover-Status, Trackanzahl | kurze Strings, ggf. gekürzt |
| `PRG` | flache Map `bookId -> "trackIdx|sek|ts"` | Wachstum begrenzen: nur Bücher mit lokalem Bestand |
| `VER` | Schema-Version → bei Mismatch `clearProperties()` + `resetContentCache()` | |

Bewusst ein Key pro Buch statt einer globalen Struktur: das ist der Hauptgrund,
warum Provider-Apps am 8-KB-Limit scheitern.

---

## 4. Risiken

| # | Risiko | Wirkung | Gegenmaßnahme |
|---|---|---|---|
| R1 | TLS-Kette wird vom Gerät abgelehnt | Sync unmöglich | Doku: Reverse Proxy + Let's Encrypt; Setup-Check-Screen mit klarer Fehlermeldung |
| R2 | Einzeldatei-`.m4b` | Großteil mancher Bibliotheken nicht nutzbar | E2: Filter + sichtbare Kennzeichnung, Phase 2 Proxy |
| R3 | Unbekannte Limits für Dateigröße/-anzahl pro Gerät | Sync bricht auf Hardware ab, im Simulator nicht | Früher Hardware-Test in M2; Dateien > X MB überspringen und melden |
| R4 | 8-KB-Property-Limit bei großen Bibliotheken | Datenverlust/Absturz | Layout oben; Serialisierungstest mit 500 Büchern |
| R5 | ABS-API-Änderungen (2.26 Auth-Umbau) | Client bricht | Versionscheck beim ersten Request, Smoke-Test-Skript im Repo |
| R6 | Sync-Zeitfenster/WLAN-Timeout bei GB-Downloads | Teil-Sync | Resume-fähige Delta-Logik: abgebrochener Sync verliert nur den laufenden Track |
| R7 | Store-Freigabe für Audio-Provider-Apps | Release verzögert | Review-Anforderungen früh prüfen; Sideload-Weg dokumentieren |

---

## 5. Roadmap

**M0 — Gerüst (klein halten)**
SDK + Simulator, `manifest.xml` mit `audio-content-provider-app`, App-Klasse mit
allen vier Delegates als Stubs, Build für `fr645m` grün, `monkey.jungle`,
CI-Job der kompiliert.

**M1 — ABS-Client + Sync-Konfiguration**
`settings.xml` (serverUrl, apiKey), `AbsClient` mit Bearer-Auth, Bibliotheks- und
Buchliste mit Paging, `CheckboxMenu` mit Vorauswahl aus dem Store, Fehlerview für
401/404/TLS. Dazu ein Shell-/Python-Smoke-Test, der die genutzten Endpunkte gegen
eine echte Instanz verifiziert. *Ergebnis: Auswahl landet im Object Store.*

**M2 — Sync**
`Communications.SyncDelegate`, Delta-Planer, serielle Downloads mit
`:mediaEncoding`, `notifySyncProgress`/`notifySyncComplete`, Löschen über
`deleteCachedItem`, Cover via `makeImageRequest`. **Erster Test auf echter
Hardware** — hier zeigen sich R1 und R3. *Ergebnis: Buch liegt auf der Uhr.*

**M3 — Wiedergabe**
`ContentDelegate` + `ContentIterator`, Metadaten aus dem Store statt aus ID3,
`PlaybackProfile` mit Hörbuch-Skips, `ActiveContent` mit Startposition,
Playback-Konfiguration („fortsetzen" / „von vorn"). *Ergebnis: Kapitel spielt in
richtiger Reihenfolge, Resume funktioniert.*

**M4 — Fortschritt**
`onSong`-Puffer, Flush beim Sync via `PATCH /api/me/progress`, Serverstand beim
Sync einlesen, Konfliktregel jüngster Zeitstempel, „abgeschlossene löschen".
*Ergebnis: Handy und Uhr bleiben synchron.*

**M5 — Härtung & Release**
Weitere Geräte (venu2, fenix7, fr965 …), Speicherprüfung über
`getCacheStatistics()` vor dem Sync, Strings de/en, Store-Migration über `VER`,
Icon-Sets, Store-Einreichung bzw. Sideload-Anleitung.

**M6 — optional: `abconnect-proxy`**
Kapitelweises Segmentieren und Transcodieren von `.m4b` (E2). Eigener
Container, eigenes Verzeichnis im Repo, kein Zwang für Nutzer.

---

## 6. Zielgeräte und Test

Primär: Forerunner 645 Music (kleinster gemeinsamer Nenner, auch die Garmin-Referenz).
Danach: Venu 2/3, Fenix 7/8 Serie, Forerunner 265/965, Vívoactive 5.

Testebenen:
1. **Simulator** — Funktionslogik, alle vier Modi, HTTPS-Anforderung testweise aus.
2. **Smoke-Test gegen echte ABS-Instanz** — API-Verträge, außerhalb von Monkey C.
3. **Hardware** — ab M2 verpflichtend; TLS, Dateigrößen und Speicher lassen sich
   im Simulator nicht validieren.

---

## 7. Offene Punkte

1. Welche ABS-Version läuft auf der Zielinstanz (< oder ≥ 2.26)? Bestimmt den Auth-Pfad.
2. Wie sind die Bibliotheken beschaffen — überwiegend Multi-File-MP3 oder Einzeldatei-`.m4b`?
   Entscheidet, ob M6 optional bleibt oder Pflicht wird.
3. Welche Uhr steht real zum Testen zur Verfügung? Setzt `minSdkVersion` und die
   Geräteliste im Manifest.
4. Podcasts aus ABS mit aufnehmen oder auf Bücher beschränken?
5. Veröffentlichung im Connect IQ Store oder nur Sideload?

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
* [Audiobookshelf API Reference](https://api.audiobookshelf.org/) ·
  [API Keys](https://audiobookshelf.org/docs/documentation/server-management/api-keys/)
