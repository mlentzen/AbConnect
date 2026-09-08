# AbConnect

Audiobookshelf als Connect IQ Audio Provider für Garmin-Musikuhren.

Die App synchronisiert Hörbücher aus einer selbst gehosteten
[Audiobookshelf](https://www.audiobookshelf.org/)-Instanz auf die Uhr, spielt sie
offline über den System-Mediaplayer ab und schreibt den Hörfortschritt zurück.

Status: **Planung**. Der Umsetzungsplan steht in [docs/PLAN.md](docs/PLAN.md).

## Aufbau

AbConnect besteht aus zwei Teilen:

- **`abconnect-proxy`** — Docker-Container neben Audiobookshelf. Schneidet `.m4b`
  verlustfrei kapitelweise in Segmente, die die Uhr abspielen kann, liefert
  schlanke JSON-Antworten und hält den ABS-API-Key.
- **Connect-IQ-App** — App vom Typ `audio-content-provider-app`, die Segmente
  herunterlädt, abspielt und den Fortschritt puffert.

## Voraussetzungen

- Audiobookshelf ≥ 2.26 mit API-Key
- `abconnect-proxy`, per HTTPS mit gültigem CA-Zertifikat erreichbar
  (Garmin-Geräte lehnen selbstsignierte Zertifikate ab)
- Garmin-Uhr mit Musikspeicher und WLAN — Zielgerät zunächst fēnix 7X Pro
