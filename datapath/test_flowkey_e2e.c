/* test_flowkey_e2e.c — dual-stack end-to-end validation of canonical flow keys. */
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "d2k_track.h"

/* C99 compile-time assertions also run in gcc-warn cross builds. */
#define ABI_ASSERT(name, cond) typedef char abi_##name[(cond) ? 1 : -1]
ABI_ASSERT(family, offsetof(d2k_key, family) == 0);
ABI_ASSERT(low_addr, offsetof(d2k_key, low_addr) == 4);
ABI_ASSERT(high_addr, offsetof(d2k_key, high_addr) == 20);
ABI_ASSERT(low_port, offsetof(d2k_key, low_port) == 36);
ABI_ASSERT(high_port, offsetof(d2k_key, high_port) == 38);
ABI_ASSERT(size, sizeof(d2k_key) == 40);
ABI_ASSERT(alignment, offsetof(struct { char c; d2k_key key; }, key) == 4);

static int fails;
#define CHECK(cond, msg) do {     if (!(cond)) { printf("FAIL: %s\n", msg); fails++; } } while (0)

static void check_ipv4(void) {
    const uint8_t a[4] = {192, 168, 1, 67};
    const uint8_t b[4] = {1, 2, 3, 4};
    const uint8_t ap[2] = {0xc0, 0x00};
    const uint8_t bp[2] = {0x01, 0xbb};
    d2k_key ab, ba;

    memset(&ab, 0xa5, sizeof ab);
    memset(&ba, 0x5a, sizeof ba);
    int ab_low = d2k_key_make(&ab, a, b, ap, bp);
    int ba_low = d2k_key_make(&ba, b, a, bp, ap);

    CHECK(ab.family == D2K_KEY_IPV4, "IPv4 key family");
    CHECK(memcmp(&ab, &ba, sizeof ab) == 0, "IPv4 reverse direction changed key");
    CHECK(ab_low != ba_low, "IPv4 direction marker did not invert");
    CHECK(ab.low_port != ab.high_port, "IPv4 ports were not preserved");
    CHECK(ab_low == 0 && ba_low == 1, "IPv4 byte-order canonicalization");
    CHECK(memcmp(&ab.low_addr.v4, b, 4) == 0, "IPv4 low_addr.v4 bytes");
    CHECK(memcmp(&ab.high_addr.v4, a, 4) == 0, "IPv4 high_addr.v4 bytes");
    uint8_t expected[40] = {D2K_KEY_IPV4};
    memcpy(expected + 4, b, 4);
    memcpy(expected + 20, a, 4);
    memcpy(expected + 36, bp, 2);
    memcpy(expected + 38, ap, 2);
    CHECK(memcmp(&ab, expected, sizeof ab) == 0,
          "IPv4 exact ABI bytes, union tails, padding and port pairing");

    d2k_table *t = d2k_track_new(16);
    CHECK(t != NULL, "IPv4 tracking table");
    if (!t) return;

    d2k_flow *fwd = d2k_track_get(t, &ab, 100);
    d2k_flow *rev = d2k_track_get(t, &ba, 200);
    CHECK(fwd != NULL && rev != NULL, "IPv4 flow lookup");
    CHECK(fwd == rev, "IPv4 reverse packet created a second flow");
    CHECK(d2k_track_count(t) == 1, "IPv4 one connection occupied two flows");
    d2k_track_free(t);
}

static void check_ipv6(void) {
    const uint8_t a[16] = {
        0x20,0x01,0x0d,0xb8,0,0,0,0,0,0,0,0,0,0,0,1
    };
    const uint8_t b[16] = {
        0x20,0x01,0x0d,0xb8,0,0,0,0,0,0,0,0,0,0,0,2
    };
    const uint8_t ap[2] = {0x01, 0xbb};
    const uint8_t bp[2] = {0xc0, 0x00};
    d2k_key ab, ba;

    memset(&ab, 0xa5, sizeof ab);
    memset(&ba, 0x5a, sizeof ba);
    int ab_low = d2k_key_make6(&ab, a, b, ap, bp);
    int ba_low = d2k_key_make6(&ba, b, a, bp, ap);

    CHECK(ab.family == D2K_KEY_IPV6, "IPv6 key family");
    CHECK(memcmp(&ab, &ba, sizeof ab) == 0, "IPv6 reverse direction changed key");
    CHECK(ab_low != ba_low, "IPv6 direction marker did not invert");
    CHECK(ab.low_port != ab.high_port, "IPv6 ports were not preserved");
    CHECK(ab_low == 1 && ba_low == 0, "IPv6 byte-order canonicalization");
    CHECK(memcmp(ab.low_addr.v6.s6_addr, a, 16) == 0, "IPv6 low_addr.v6 bytes");
    CHECK(memcmp(ab.high_addr.v6.s6_addr, b, 16) == 0, "IPv6 high_addr.v6 bytes");
    uint8_t expected[40] = {D2K_KEY_IPV6};
    memcpy(expected + 4, a, 16);
    memcpy(expected + 20, b, 16);
    memcpy(expected + 36, ap, 2);
    memcpy(expected + 38, bp, 2);
    CHECK(memcmp(&ab, expected, sizeof ab) == 0,
          "IPv6 exact ABI bytes, padding and port pairing");

    d2k_table *t = d2k_track_new(16);
    CHECK(t != NULL, "IPv6 tracking table");
    if (!t) return;

    d2k_flow *fwd = d2k_track_get(t, &ab, 100);
    d2k_flow *rev = d2k_track_get(t, &ba, 200);
    CHECK(fwd != NULL && rev != NULL, "IPv6 flow lookup");
    CHECK(fwd == rev, "IPv6 reverse packet created a second flow");
    CHECK(d2k_track_count(t) == 1, "IPv6 one connection occupied two flows");
    d2k_track_free(t);
}

static void check_port_tie_and_family(void) {
    const uint8_t a[16] = {1, 2, 3, 4};
    const uint8_t b[16] = {5, 6, 7, 8};
    /* Host integer order reverses these on little-endian machines. */
    const uint8_t lp[2] = {0x01, 0xff}, hp[2] = {0x02, 0x00};
    d2k_key fwd, rev, v4, v6;
    for (int family = 4; family <= 6; family += 2) {
        int (*make_key)(d2k_key *, const uint8_t *, const uint8_t *,
                       const uint8_t *, const uint8_t *) =
            family == 4 ? d2k_key_make : d2k_key_make6;
        CHECK(make_key(&fwd, a, a, hp, lp) == 0, "same address: higher port");
        CHECK(make_key(&rev, a, a, lp, hp) == 1, "same address: lower port");
        CHECK(memcmp(&fwd, &rev, sizeof fwd) == 0, "same address reverse key");
        CHECK(memcmp(&fwd.low_port, lp, 2) == 0, "same address low port bytes");
        CHECK(memcmp(&fwd.high_port, hp, 2) == 0, "same address high port bytes");
    }
    d2k_key_make(&v4, a, b, lp, hp);
    d2k_key_make6(&v6, a, b, lp, hp);
    CHECK(memcmp((const uint8_t *)&v4 + 1, (const uint8_t *)&v6 + 1, 39) == 0,
          "family-isolation fixture has identical endpoint bytes");
    d2k_table *t = d2k_track_new(16);
    CHECK(t != NULL, "dual-stack tracking table");
    if (!t) return;
    d2k_flow *f4 = d2k_track_get(t, &v4, 100);
    d2k_flow *f6 = d2k_track_get(t, &v6, 200);
    CHECK(f4 != NULL && f6 != NULL && f4 != f6, "IPv4/IPv6 family isolation");
    CHECK(d2k_track_count(t) == 2, "dual-stack flow count");
    d2k_track_free(t);
}

static void check_layout(void) {
    CHECK(offsetof(d2k_key, family) == 0, "d2k_key.family offset");
    CHECK(offsetof(d2k_key, low_addr) == 4, "d2k_key.low_addr alignment");
    CHECK(offsetof(d2k_key, high_addr) == 20, "d2k_key.high_addr alignment");
    CHECK(offsetof(d2k_key, low_port) == 36, "d2k_key.low_port offset");
    CHECK(offsetof(d2k_key, high_port) == 38, "d2k_key.high_port offset");
    CHECK(sizeof(d2k_key) == 40, "d2k_key size");
}

int main(void) {
    check_layout();
    check_ipv4();
    check_ipv6();
    check_port_tie_and_family();

    if (fails) {
        printf("FAILURES: %d\n", fails);
        return 1;
    }
    printf("dual-stack flow-key E2E: all checks passed\n");
    return 0;
}
