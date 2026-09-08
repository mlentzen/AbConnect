# AbConnect

Audiobookshelf als Connect IQ Audio Provider für Garmin-Musikuhren.

Die App synchronisiert Hörbücher aus einer selbst gehosteten
[Audiobookshelf](https://www.audiobookshelf.org/)-Instanz auf die Uhr, spielt sie
offline über den System-Mediaplayer ab und schreibt den Hörfortschritt zurück.

Status: **Planung**. Der Umsetzungsplan steht in [docs/PLAN.md](docs/PLAN.md).

## Aufbau

AbConnect besteht aus zwei Teilen:

- **`abconnect-proxy`** — Container neben Audiobookshelf, betrieben als
  Podman-Quadlet. Lädt eine `.m4b` über die ABS-API, schneidet sie verlustfrei
  kapitelweise in Segmente, die die Uhr abspielen kann, und löscht die Quelldatei
  direkt danach wieder. Liefert der Uhr schlanke JSON-Antworten und hält den
  ABS-API-Key serverseitig.
- **Connect-IQ-App** — App vom Typ `audio-content-provider-app`, die Segmente
  herunterlädt, abspielt und den Fortschritt puffert.

## Voraussetzungen

- Audiobookshelf ≥ 2.26 mit API-Key
- `abconnect-proxy` per HTTPS erreichbar
- Garmin-Uhr mit Musikspeicher und WLAN — Zielgerät zunächst fēnix 7X Pro

## Konfiguration des Proxy

Ausschließlich zur Laufzeit, nichts ist im Image hinterlegt. Pflichtvariablen:
`ABS_URL`, `ABS_API_KEY` (Podman-Secret), `ABCONNECT_TOKEN` (Uhr → Proxy).
Optional: `CACHE_DIR`, `WORK_DIR`, `CACHE_MAX_BYTES`, `SEGMENT_TARGET_SECONDS`.
Fehlt eine Pflichtvariable, startet der Container nicht. Beispiel-Quadlet in
[docs/PLAN.md](docs/PLAN.md#e3--konfiguration-ausschließlich-zur-laufzeit).
