# AbConnect

Audiobookshelf als Connect IQ Audio Provider für Garmin-Musikuhren.

Die App synchronisiert Hörbücher aus einer selbst gehosteten
[Audiobookshelf](https://www.audiobookshelf.org/)-Instanz auf die Uhr, spielt sie
offline über den System-Mediaplayer ab und schreibt den Hörfortschritt zurück.

Status: **Planung**. Der Umsetzungsplan steht in [docs/PLAN.md](docs/PLAN.md).

## Voraussetzungen (geplant)

- Audiobookshelf-Server, per HTTPS mit gültigem CA-Zertifikat erreichbar
  (Garmin-Geräte lehnen selbstsignierte Zertifikate ab)
- API-Key aus Audiobookshelf (Settings → Users → API Keys)
- Garmin-Uhr mit Musikspeicher
