# Gate 4 — TLS ClientHello & QUIC Initial Lab

## Result

**PASS — QEMU Malta / MIPS soft-float**

Verified workflow run: **36739567418** (job **109970091627**)
Artifact: **gate4-protocols-evidence**, ID **11110211057**
Artifact SHA-256: `81d4154275390374b98669ad88def6ff4a9550f59663e97669de36c04b7c3f48`

## Serial evidence

```text
TLS_VALID: PASS SNI=example.com
TLS_TRUNCATED: PASS rejected safely
QUIC_VALID: PASS version=1 DCID=0102030405060708 SCID=090a0b0c
QUIC_TRUNCATED: PASS rejected safely
GATE4_RESULT=SUCCESS
```

The output appeared in the QEMU Malta serial log; the test binary exited successfully. No SIGSEGV/SIGBUS, parser assertion failure, kernel panic, OOM, or infinite-loop condition was observed in the successful run.

## Implementation

- `datapath/quic.c`: QUIC long-header Initial parser with fixed/header-form checks, QUIC v1/v2 version recognition, DCID/SCID extraction, QUIC varint decoding, and bounds checks before every read/copy/advance.
- `datapath/include/d2k_quic.h`: parsed QUIC metadata structure.
- `datapath/test_parsers.c`: deterministic TLS valid/truncated and QUIC valid/truncated fixtures.
- `scripts/build-mips-parser-test.sh`: MIPS32 little-endian soft-float build using `zig cc -target mipsel-linux.1.1.82-musleabi`.
- `scripts/gate4-protocols-test.sh`: Debian Malta QEMU harness and serial-result assertion.
- `.github/workflows/gate4-protocols.yml`: CI workflow with a 10-minute job timeout.

## Acceptance checklist

- [x] Valid TLS ClientHello recognized and SNI `example.com` extracted.
- [x] Truncated TLS rejected safely.
- [x] Valid QUIC v1 Initial recognized and DCID/SCID extracted.
- [x] Truncated QUIC rejected safely.
- [x] MIPS soft-float binary executed inside Debian Malta QEMU.
- [x] Serial evidence contains `GATE4_RESULT=SUCCESS`.
