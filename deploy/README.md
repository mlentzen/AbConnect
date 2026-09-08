# abconnect-proxy betreiben

## 1. Image bauen

```sh
podman build -t abconnect-proxy:latest ./proxy
```

## 2. Geheimnisse anlegen

Der ABS-API-Key entsteht im Audiobookshelf-Webinterface unter
*Settings → Users → API Keys*. Der zweite Token ist frei gewählt und schützt
die Strecke Uhr → Proxy; er wird später in den App-Einstellungen der Uhr
eingetragen.

```sh
printf '%s' 'abs-api-key-hier' | podman secret create abs-api-key -
openssl rand -hex 24 | tee /dev/tty | podman secret create abconnect-token -
```

## 3. Quadlet einhängen

```sh
cp deploy/abconnect-proxy.container ~/.config/containers/systemd/
# ABS_URL an die eigene Instanz anpassen
systemctl --user daemon-reload
systemctl --user start abconnect-proxy
```

## 4. Prüfen

```sh
curl -s localhost:8080/healthz | python3 -m json.tool
```

`audiobookshelf: "ok"` heißt: Adresse stimmt und der API-Key wird akzeptiert.
Alles andere ist eine Fehlkonfiguration, die hier auffällt statt erst beim
ersten Sync der Uhr.

Ein Buch von Hand vorbereiten und ansehen:

```sh
TOKEN=$(podman secret inspect --showsecret abconnect-token | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["SecretData"])')
curl -s -H "Authorization: Bearer $TOKEN" localhost:8080/v1/books | python3 -m json.tool
curl -s -X POST -H "Authorization: Bearer $TOKEN" localhost:8080/v1/books/<ID>/prepare
curl -s -H "Authorization: Bearer $TOKEN" localhost:8080/v1/books/<ID>/status
curl -s -H "Authorization: Bearer $TOKEN" localhost:8080/v1/books/<ID>/segments | python3 -m json.tool
```

## Konfiguration

| Variable | Pflicht | Default | Bedeutung |
|---|---|---|---|
| `ABS_URL` | ja | — | Basis-URL der ABS-Instanz |
| `ABS_API_KEY` | ja | — | ABS-API-Key |
| `ABCONNECT_TOKEN` | ja | — | Token für die Uhr; Komma-Liste für Rotation |
| `CACHE_DIR` | — | `/var/cache/abconnect` | Segmente und Cover |
| `WORK_DIR` | — | `/var/tmp/abconnect` | Quelldatei während des Prepare-Jobs |
| `CACHE_MAX_BYTES` | — | 200 GiB | Notbremse für die Verdrängung |
| `RELEASE_TTL_DAYS` | — | 30 | wie lange freigegebene Bücher liegen bleiben |
| `SEGMENT_TARGET_SECONDS` | — | 900 | Zielgröße eines Segments |
| `SEGMENT_MIN_SECONDS` | — | 180 | darunter wird verschmolzen |
| `SEGMENT_MAX_SECONDS` | — | 1500 | darüber wird geteilt |
| `COVER_URL_TTL_SECONDS` | — | 21600 | Gültigkeit der signierten Cover-URLs |
| `LOG_LEVEL` | — | INFO | |

## Token wechseln, ohne die Uhr auszusperren

`ABCONNECT_TOKEN` akzeptiert eine Komma-Liste. Neuen Token voranstellen, Dienst
neu starten, in den App-Einstellungen der Uhr eintragen, danach den alten aus
der Liste entfernen.
