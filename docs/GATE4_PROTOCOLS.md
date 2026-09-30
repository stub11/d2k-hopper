# Gate 4 — TLS ClientHello & QUIC Initial Parsing

Gate 4 starts from main commit `37d4e157b189e0ffe16d5e54004efb1d6694b871`, after Gate 3 NFQUEUE verification.

## Scope

- Parse TLS records carried over TCP and identify TLS ClientHello.
- Extract the ClientHello structural fields needed by the datapath without terminating TLS.
- Parse QUIC long-header Initial packets.
- Validate packet bounds and variable-length integer encodings.
- Keep parsers allocation-light and deterministic for datapath use.
- Add positive and malformed-input fixtures.
- Add CI evidence for both TLS ClientHello and QUIC Initial paths.

## Acceptance evidence

Gate 4 is not complete until CI demonstrates:

1. valid TLS ClientHello is recognized and parsed;
2. malformed/truncated TLS input is rejected safely;
3. valid QUIC Initial is recognized and parsed;
4. malformed/truncated QUIC input is rejected safely;
5. parser tests pass without crashes or out-of-bounds reads;
6. evidence is recorded in this document.

Implementation and fixtures will be added incrementally on this branch.
