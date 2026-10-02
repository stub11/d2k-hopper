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

The structure has alignment 4 and no tail padding. It is an anonymous C
structure typedef named `d2k_key`, not a `struct d2k_key` tag. Do not add
`packed`: the address unions require their natural alignment.

The Step 3 E2E test (`datapath/test_flowkey_e2e.c`) asserts the offsets, size
and alignment at compile time in C99, including cross builds. Runtime checks
verify exact member bytes, endpoint/port pairing, zero IPv4 union tails and
zero padding after construction from poisoned storage. Both constructors
clear all 40 bytes before setting fields; hashing and equality inspect the
complete object representation.

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

### Go / C / kernel boundaries

`d2k_key` is internal to the userspace C datapath. The kernel supplies IP
packets through NFQUEUE; it does not exchange a native `d2k_key` object with
Go or C. Go communicates with C through the explicit control-socket format
in `docs/decisions/0004-control-socket.md`, not a cast or native structure dump.

| Event key body | Low address | High address | Low port | High port | Size |
|---|---|---|---|---|---:|
| IPv4 | 0..3 | 4..7 | 8..9 | 10..11 | 12 |
| IPv6 | 0..15 | 16..31 | 32..33 | 34..35 | 36 |

Offsets here are relative to the event body after the six-byte frame header:
`[payload length u32 BE][type u16 BE]`; payload length includes type plus body.
The event type conveys the family; the C family byte, union tails and padding
are never serialized. Addresses and C port fields retain network-order bytes.
Go copies addresses into `[4]byte`/`[16]byte` and decodes ports with
`binary.BigEndian.Uint16` into host-order values. Go `Key.Family` is 4 or 6;
`Key6` remains available for IPv6 compatibility. A native Go struct layout is
not the C ABI and must never be used for this protocol via `unsafe`.

IPv6 event variants must decode their payloads just like their IPv4 variants
(`Hello`, `Suspect`, `Refused`, `Shape`, `Exchange`). A valid key alone does
not prove that the event's name or exchange evidence arrived.

## Canonicalization and bidirectional matching

d2k_key_make() and d2k_key_make6() compare endpoint address bytes and ports in network order and place the lower endpoint in low_* and the other endpoint in high_*.

For a packet A→B and its reverse B→A:

1. Both calls produce byte-identical d2k_key values.
2. The returned direction indicator is inverted.
3. d2k_track_get() therefore returns the same d2k_flow.
4. One TCP connection occupies one flow-table entry.

This is tested independently for IPv4 and IPv6 by `test_flowkey_e2e`, including
identical-address port tie breaking in network byte order and family isolation
when all remaining key bytes coincide. Identical endpoints select the low side
in both directions; the direction-inversion claim assumes distinct endpoints.

`internal/control/bridge_test.go:TestDualStackFlowKeyE2E` additionally exercises
real synthesized SYN/SYN-ACK/ClientHello/reply/RST packets through the C session,
journal, C socket encoder and Go decoder. It checks both addresses, both ports,
family, SNI and reverse exchange evidence, one flow for both directions, and
removal by reverse RST. `ctlprobe hello6` selects IPv6; `reply` and `rst` use
the last flow's family; `flows` exposes the session count for this test.

These tests use synthetic packets and local sockets. They do not constitute
physical Hopper NFQUEUE or on-device traffic evidence.

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
make san
cd ..
gofmt -l .
go vet ./...
D2K_REQUIRE_LAB=1 go test -race -count=1 ./...
sh scripts/build.sh
~~~

CI additionally runs the sanitizer suite, Go format/vet/race checks, target-architecture builds, and ShellCheck.

## Evidence ledger

- PR #64: IPv6 pipeline and checksum test introduced; merged to main.
- PR #65: IPv6 NFQUEUE pipeline integration and unified flow-key prerequisites; merged.
- PR #66: remaining ctlsrv.c legacy flow-key consumers replaced; merge SHA 8478ce4d033d69ba13cb6ea0fa5c1991a078a8d3.
- CI #209: Go, 9-architecture build, and ShellCheck passed; C gate failed in test-wire on IPv6 TCP checksum.
- PR #67: corrected the 16-byte IPv6 address iteration; actual merge SHA
  `ef8cdfaf502d0c765e1f06c9e0b58b9553bd1efa` (GitHub PR metadata).
- PR #67 CI run `36979347264`: Go, nine Go architectures and ShellCheck passed;
  C failed in `test_track.c` (missing assert declaration); not a green closure.
- PR #68: initial Step 3 tests/docs; merged as
  `7263718b7f515d01942d738749b8ef16dd88f3a3`. CI run `36979457437` also failed
  the C gate. No post-merge CI existed for this exact main SHA at audit time.
- Step 3 corrective change: use always-on endian-neutral checks in test_track;
  exact ABI packing and compile-time layout checks; real dual-stack Go/C E2E;
  complete IPv6 event decoding; add ipv6.h to object header dependencies so
  incremental rebuilds cannot retain the old checksum helper.

Architecture scope: `scripts/build.sh` produces nine Go binaries (arm64, arm,
amd64, mips, mipsle, mips64le, ppc64, riscv64, 386). The C warning gate compiles
the datapath for native x86-64, AArch64 and MIPSel; it is not a nine-target C
execution test.

Final Vertical 1 completion is contingent on a green post-merge main CI run covering the complete gate set, including make test-ipv6-pipeline and the Step 3 E2E test.
