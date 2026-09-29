#!/bin/sh
set -eu

find . -type f -name '*.c' -not -path './.git/*' -exec grep -El 'pipe[[:space:]]*\([^;]*\)[[:space:]]*(!=[[:space:]]*0|\|\|)' {} + |
while IFS= read -r file; do
  python3 - "$file" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
n = re.sub(r'(pipe\s*\([^;\n]*\))\s*!=\s*0', r'\1 < 0', s)
n = re.sub(r'(pipe\s*\([^;\n]*\))\s*\|\|', r'\1 < 0 ||', n)
if n != s:
    open(p, 'w', encoding='utf-8').write(n)
PY
done

git diff --check
if git diff --quiet -- '*.c'; then
  echo 'upstream-adapt: no MIPS pipe-return patterns needed adaptation'
else
  echo "upstream-adapt: normalized pipe() failure checks to '< 0'"
fi
