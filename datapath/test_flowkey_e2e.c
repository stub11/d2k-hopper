/* test_flowkey_e2e.c — dual-stack end-to-end validation of canonical flow keys. */
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "d2k_track.h"

static int fails;
#define CHECK(cond, msg) do {     if (!(cond)) { printf("FAIL: %s\n", msg); fails++; } } while (0)

static void check_ipv4(void) {
    const uint8_t a[4] = {192, 168, 1, 67};
    const uint8_t b[4] = {1, 2, 3, 4};
    const uint8_t ap[2] = {0xc0, 0x00};
    const uint8_t bp[2] = {0x01, 0xbb};
    d2k_key ab, ba;

    int ab_low = d2k_key_make(&ab, a, b, ap, bp);
    int ba_low = d2k_key_make(&ba, b, a, bp, ap);

    CHECK(ab.family == D2K_KEY_IPV4, "IPv4 key family");
    CHECK(memcmp(&ab, &ba, sizeof ab) == 0, "IPv4 reverse direction changed key");
    CHECK(ab_low != ba_low, "IPv4 direction marker did not invert");
    CHECK(ab.low_port != ab.high_port, "IPv4 ports were not preserved");

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

    int ab_low = d2k_key_make6(&ab, a, b, ap, bp);
    int ba_low = d2k_key_make6(&ba, b, a, bp, ap);

    CHECK(ab.family == D2K_KEY_IPV6, "IPv6 key family");
    CHECK(memcmp(&ab, &ba, sizeof ab) == 0, "IPv6 reverse direction changed key");
    CHECK(ab_low != ba_low, "IPv6 direction marker did not invert");
    CHECK(ab.low_port != ab.high_port, "IPv6 ports were not preserved");

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

    if (fails) {
        printf("FAILURES: %d\n", fails);
        return 1;
    }
    printf("dual-stack flow-key E2E: all checks passed\n");
    return 0;
}
