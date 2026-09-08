# abconnect-proxy

Companion server between Audiobookshelf and the Connect IQ app.

It downloads an `.m4b` via the ABS API, cuts it losslessly into chapter-wise
segments of 10–20 minutes and deletes the source file again right away. The
watch only gets lean JSON responses and finished segments; the ABS API key
stays here.

Why at all: a single `.m4b` on the watch is one track spanning twelve hours
with no chapter navigation, and Connect IQ aborts large JSON responses anyway.
Details in [../docs/PLAN.md](../docs/PLAN.md).

## Development

```sh
python3 -m venv .venv && .venv/bin/pip install -e '.[dev]'
.venv/bin/python -m pytest
```

The tests need `ffmpeg` and `ffprobe` on the `PATH` — they create real m4b
files with chapter markers, cut them and verify the result with `ffprobe`.
Without ffmpeg these tests are skipped, the rest runs.

Operation and configuration: [../deploy/README.md](../deploy/README.md).
