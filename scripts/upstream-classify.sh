#!/bin/sh
set -eu

path="${1:-}"

case "$path" in
  .github/*)
    category="automation"; risk="high"
    ;;
  *mips*)
    category="mips-portability"; risk="high"
    ;;
  *sched*|*datapath*|*packet*|*conntrack*)
    category="datapath"; risk="high"
    ;;
  *controller*|*candidate*|*volume*)
    category="controller"; risk="high"
    ;;
  *probe*|*probing*|*health*)
    category="probing"; risk="high"
    ;;
  *tls*|*quic*|*network*|*transport*)
    category="networking-tls"; risk="high"
    ;;
  *telegram*|*tunnel*)
    category="telegram-tunnel"; risk="high"
    ;;
  *config*|*cli*|*command*)
    category="config-cli"; risk="medium"
    ;;
  *_test.go|*_test.c|*tests/*)
    category="tests"; risk="low"
    ;;
  *.md|docs/*)
    category="docs"; risk="low"
    ;;
  *)
    category="unknown"; risk="high"
    ;;
esac

printf '%s\t%s\t%s\n' "$category" "$risk" "$path"
