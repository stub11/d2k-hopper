# D2K для Hopper 3810 — Руководство

## Быстрая установка через SSH в Entware
```bash
(f=$(mktemp) && curl -fsSL --connect-timeout 10 --max-time 120 \
  https://raw.githubusercontent.com/stub11/d2k-hopper/main/scripts/install.sh \
  -o "$f" && sh "$f"; r=$?; rm -f "$f"; exit "$r")
```
