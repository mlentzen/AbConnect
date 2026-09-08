# abconnect-proxy

Companion-Server zwischen Audiobookshelf und der Connect-IQ-App.

Er lädt eine `.m4b` über die ABS-API, schneidet sie verlustfrei kapitelweise in
Segmente von 10–20 Minuten und löscht die Quelldatei sofort wieder. Die Uhr
bekommt nur schlanke JSON-Antworten und fertige Segmente; der ABS-API-Key
bleibt hier.

Warum überhaupt: eine einzelne `.m4b` ist auf der Uhr ein Track über zwölf
Stunden ohne Kapitelnavigation, und Connect IQ bricht große JSON-Antworten
ohnehin ab. Details in [../docs/PLAN.md](../docs/PLAN.md).

## Entwicklung

```sh
python3 -m venv .venv && .venv/bin/pip install -e '.[dev]'
.venv/bin/python -m pytest
```

Die Tests brauchen `ffmpeg` und `ffprobe` im `PATH` — sie erzeugen echte
m4b-Dateien mit Kapitelmarken, schneiden sie und prüfen das Ergebnis mit
`ffprobe` nach. Ohne ffmpeg werden diese Tests übersprungen, der Rest läuft.

Betrieb und Konfiguration: [../deploy/README.md](../deploy/README.md).
