# Unified FlowKey ABI — Vertical 1 Step 3

## Scope

This document freezes the canonical d2k_key representation used by the C datapath for IPv4 and IPv6 flows. A flow is identified by an unordered endpoint pair; packet direction is carried separately by init_low / dir_known.

## Canonical structure

The ABI is defined in datapath/include/d2k_track.h:

~~~c
typedef struct {
    uint8_t  family;
    union {
        struct in_addr v4;
        struct in6_addr v6;
    } low_addr;
    union {
        struct in_addr v4;
        struct in6_addr v6;
    } high_addr;
    uint16_t low_port;
    uint16_t high_port;
} d2k_key;
~~~

family is D2K_KEY_IPV4 (4) or D2K_KEY_IPV6 (6).

## Layout contract

On the supported 32-bit MIPS and AArch64 C ABIs the tested layout is:

| Member | Offset | Size |
|---|---:|---:|
| family | 0 | 1 |
| padding before low_addr | 1–3 | 3 |
| low_addr | 4 | 16 |
| high_addr | 20 | 16 |
| low_port | 36 | 2 |
| high_port | 38 | 2 |
| sizeof(d2k_key) | — | 40 |

The IPv4 member occupies the first four bytes of each address union; the IPv6 member occupies all sixteen bytes.

The Step 3 E2E test (datapath/test_flowkey_e2e.c) asserts these offsets and size at build/run time. This prevents accidental padding or member reordering from silently changing the C ABI.

## Access rules

Use the family-specific union member only after checking family:

- IPv4: key.low_addr.v4, key.high_addr.v4
- IPv6: key.low_addr.v6, key.high_addr.v6
- Wire-byte access for IPv6 addresses: key.low_addr.v6.s6_addr and key.high_addr.v6.s6_addr

Do not access the removed legacy members:

- low_ip
- high_ip
- low_ip6
- high_ip6

Control-event serialization follows the same rule. IPv6 events copy exactly 16 address bytes from v6.s6_addr; IPv4 events copy exactly 4 bytes from v4.

## Canonicalization and bidirectional matching

d2k_key_make() and d2k_key_make6() compare endpoint address bytes and ports in network order and place the lower endpoint in low_* and the other endpoint in high_*.

For a packet A→B and its reverse B→A:

1. Both calls produce byte-identical d2k_key values.
2. The returned direction indicator is inverted.
3. d2k_track_get() therefore returns the same d2k_flow.
4. One TCP connection occupies one flow-table entry.

This is tested independently for IPv4 and IPv6 by test_flowkey_e2e.

## IPv6 TCP checksum evidence

During CI #209, after the legacy ABI consumers were corrected, test_wire exposed an independent defect in the IPv6 TCP checksum helper. The helper was iterating 32 bytes for each IPv6 address although an IPv6 address is 16 bytes. That caused an out-of-bounds read and an incorrect pseudo-header sum.

The correction is intentionally minimal:

~~~c
for (i = 0; i < 16; i += 2)
    sum += ((uint32_t)p[i] << 8) | p[i + 1];
~~~

The same bound is used for both source and destination addresses.

The existing test_wire and test-ipv6-pipeline checks validate the resulting checksum rather than merely checking that a checksum field was populated.

## Verification commands

From repository root:

~~~sh
cd datapath
make test-flowkey-e2e
make test-ipv6-pipeline
make check
~~~

CI additionally runs the sanitizer suite, Go format/vet/race checks, target-architecture builds, and ShellCheck.

## Evidence ledger

- PR #64: IPv6 pipeline and checksum test introduced; merged to main.
- PR #65: IPv6 NFQUEUE pipeline integration and unified flow-key prerequisites; merged.
- PR #66: remaining ctlsrv.c legacy flow-key consumers replaced; merge SHA 8478ce4d033d69ba13cb6ea0fa5c1991a078a8d3.
- CI #209: Go, 9-architecture build, and ShellCheck passed; C gate failed in test-wire on IPv6 TCP checksum.
- PR #67: corrected the 16-byte IPv6 address iteration in the checksum pseudo-header; merged as 4a1e366d779e82878262d0f217868f240747bf15.

Final Vertical 1 completion is contingent on a green post-merge main CI run covering the complete gate set, including make test-ipv6-pipeline and the Step 3 E2E test.
