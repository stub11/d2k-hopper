# Gate 4 — TLS ClientHello & QUIC Initial parsing

## Scope

Gate 4 starts from the fresh Gate 3 `main` baseline and covers protocol-level parsing for:

- TLS 1.3 ClientHello records carried over TCP;
- ClientHello fragmentation across TCP payloads;
- SNI extraction with strict bounds checking;
- ClientHello without SNI;
- malformed/truncated TLS records;
- QUIC Initial packet detection and bounded parsing;
- QUIC CRYPTO frame extraction from Initial packets;
- extraction of the embedded TLS ClientHello from QUIC CRYPTO data;
- QUIC Initial packet-number/header validation without assuming a fixed packet layout.

## Acceptance evidence

The gate will require deterministic unit vectors plus integration evidence showing:

1. valid TLS ClientHello is recognized;
2. SNI offsets/lengths are correct;
3. fragmented and truncated inputs never produce out-of-bounds anchors;
4. non-TLS and non-ClientHello records are rejected as anchors without being treated as parser failures;
5. valid QUIC Initial packets are recognized;
6. CRYPTO data can be reassembled from Initial packets;
7. an embedded TLS ClientHello can be parsed after QUIC CRYPTO reassembly;
8. malformed QUIC varints, frame lengths, and packet boundaries are rejected safely;
9. all Gate 4 tests pass in CI on the supported targets.

## Baseline

Gate 4 is branched from the fresh Gate 3 `main` baseline after successful Run #50 / Gate 3 merge.

Existing TLS parsing tests in `datapath/test_tls.c` are retained as the starting regression suite; QUIC Initial parsing will be added without weakening the existing TLS bounds checks.
