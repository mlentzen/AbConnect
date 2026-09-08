# abconnect-proxy betreiben

## 1. Geheimnisse anlegen

Der ABS-API-Key entsteht im Audiobookshelf-Webinterface unter
*Settings → Users → API Keys*. Der zweite Token ist frei gewählt und schützt
die Strecke Uhr → Proxy; er wird später in den App-Einstellungen der Uhr
eingetragen.

```sh
printf '%s' 'abs-api-key-hier' | podman secret create abs-api-key -
openssl rand -hex 24 | tee /dev/tty | podman secret create abconnect-token -
```

## 2. Units installieren

`ABS_URL` in `deploy/abconnect-proxy.container` auf die eigene Instanz
anpassen, dann:

```sh
./deploy/install.sh
```

Das Skript legt vier Units ab und startet den Dienst. Ein Handbuild entfällt:
das Image entsteht beim ersten Start aus `proxy/Containerfile`.

| Unit | Ort | Zweck |
|---|---|---|
| `abconnect-proxy.build` | `~/.config/containers/systemd/` | baut das Image aus dem Checkout |
| `abconnect-proxy.container` | `~/.config/containers/systemd/` | der Dienst selbst |
| `abconnect-proxy-rebuild.path` | `~/.config/systemd/user/` | beobachtet die Branch-Spitze |
| `abconnect-proxy-rebuild.service` | `~/.config/systemd/user/` | baut neu und startet neu |

Zwei Zeilen sind maschinenabhängig — der Build-Kontext und die beobachtete
Ref-Datei. Beide trägt das Skript aus dem tatsächlichen Ort des Checkouts und
dem ausgecheckten Branch ein; im Repo stehen nur Vorgabewerte. Nach einem
Branch-Wechsel oder einem verschobenen Checkout also einfach erneut ausführen.

## 3. Automatischer Rebuild

`abconnect-proxy-rebuild.path` beobachtet `.git/refs/heads/<branch>`. Jeder
Commit, `git pull` oder Checkout auf diesem Branch löst einen Rebuild und einen
Neustart des Containers aus — nicht schon das Speichern einer Datei, sodass ein
halbfertiger Stand nicht ausgeliefert wird.

Von Hand anstoßen, ohne auf einen Commit zu warten:

```sh
systemctl --user start abconnect-proxy-rebuild
```

Nachsehen, was passiert ist:

```sh
systemctl --user status abconnect-proxy-rebuild.path
journalctl --user -u abconnect-proxy-build -n 50
```

Zwei Dinge, die auffallen können:

* Ein fehlgeschlagener Build reißt den Container mit, weil dieser den
  Build-Dienst per `Requires=` einbindet. Ein kaputter Commit legt den Dienst
  also still, statt still das alte Image weiterlaufen zu lassen. Wer das anders
  will, ersetzt in `abconnect-proxy.container` `Requires=` durch `Wants=`.
* `git gc` bzw. `git pack-refs` kann die beobachtete Ref-Datei entfernen. Der
  Watcher fängt sich wieder, sobald sie neu entsteht; ein Commit unmittelbar
  danach kann aber durchrutschen. Dann hilft der Aufruf von Hand.

## 4. Prüfen

```sh
curl -s localhost:18543/healthz | python3 -m json.tool
```

Der Dienst hört im Container auf 8080, veröffentlicht wird aber
`127.0.0.1:18543` — 8080 ist auf diesem Rechner bereits belegt. Der
Healthcheck im Container prüft weiterhin 8080; nur die Host-Seite ändert sich.

`audiobookshelf: "ok"` heißt: Adresse stimmt und der API-Key wird akzeptiert.
Alles andere ist eine Fehlkonfiguration, die hier auffällt statt erst beim
ersten Sync der Uhr.

Ein Buch von Hand vorbereiten und ansehen:

```sh
TOKEN=$(podman secret inspect --showsecret abconnect-token | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["SecretData"])')
curl -s -H "Authorization: Bearer $TOKEN" localhost:18543/v1/books | python3 -m json.tool
curl -s -X POST -H "Authorization: Bearer $TOKEN" localhost:18543/v1/books/<ID>/prepare
curl -s -H "Authorization: Bearer $TOKEN" localhost:18543/v1/books/<ID>/status
curl -s -H "Authorization: Bearer $TOKEN" localhost:18543/v1/books/<ID>/segments | python3 -m json.tool
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
