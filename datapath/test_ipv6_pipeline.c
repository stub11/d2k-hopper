/* test_ipv6_pipeline.c — IPv6 parser, flow-key, split emission and checksum pipeline. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "d2k_track.h"
#include "d2k_wire.h"
#include "ipv6.h"

static int fails;

#define CHECK(cond, msg) \
    do { \
        if (!(cond)) { \
            printf("FAIL: %s\n", msg); \
            fails++; \
        } \
    } while (0)

static void wr16(uint8_t *p, uint16_t v)
{
    p[0] = (uint8_t)(v >> 8);
    p[1] = (uint8_t)v;
}

static void wr32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)(v >> 24);
    p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >> 8);
    p[3] = (uint8_t)v;
}

static size_t build_tcp(uint8_t *tcp, uint8_t flags, const uint8_t *payload,
                        size_t payload_len)
{
    memset(tcp, 0, 20 + payload_len);
    wr16(tcp + 0, 40000);
    wr16(tcp + 2, 443);
    wr32(tcp + 4, 1000);
    wr32(tcp + 8, 2000);
    tcp[12] = 0x50;
    tcp[13] = flags;
    wr16(tcp + 14, 64240);
    if (payload_len != 0) {
        memcpy(tcp + 20, payload, payload_len);
    }
    return 20 + payload_len;
}

static size_t build_ipv6(uint8_t *pkt, uint8_t next_header, const uint8_t *ext,
                         size_t ext_len, const uint8_t *tcp, size_t tcp_len)
{
    static const uint8_t src[16] = {
        0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1
    };
    static const uint8_t dst[16] = {
        0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2
    };
    size_t payload_len = ext_len + tcp_len;

    memset(pkt, 0, 40 + payload_len);
    pkt[0] = 0x60;
    wr16(pkt + 4, (uint16_t)payload_len);
    pkt[6] = next_header;
    pkt[7] = 64;
    memcpy(pkt + 8, src, 16);
    memcpy(pkt + 24, dst, 16);
    if (ext_len != 0) {
        memcpy(pkt + 40, ext, ext_len);
    }
    memcpy(pkt + 40 + ext_len, tcp, tcp_len);
    return 40 + payload_len;
}

static void test_parser_and_key(void)
{
    static const uint8_t payload[] = {
        0x16, 0x03, 0x01, 0x00, 0x03, 0x01, 0x00, 0x00
    };
    uint8_t tcp[64];
    uint8_t pkt[256];
    size_t tcp_len = build_tcp(tcp, 0x18, payload, sizeof payload);

    size_t n = build_ipv6(pkt, 6, NULL, 0, tcp, tcp_len);
    struct d2k_ip6_info info;
    int rc = d2k_parse_ipv6(pkt, n, &info);
    CHECK(rc == D2K_IP6_TCP, "plain IPv6 TCP was not parsed");
    CHECK(info.payload_len == sizeof payload, "plain IPv6 payload length is wrong");
    CHECK(info.hop_limit == 64, "IPv6 hop limit is wrong");

    d2k_key key;
    int low = d2k_key_make6(&key, pkt + 8, pkt + 24, pkt + 40, pkt + 42);
    CHECK(key.family == D2K_KEY_IPV6, "IPv6 key family is wrong");
    CHECK(low == 1, "IPv6 canonical direction is wrong");
    CHECK(memcmp(key.low_addr.v6.s6_addr, pkt + 8, 16) == 0,
          "IPv6 low address was not stored");
    CHECK(memcmp(key.high_addr.v6.s6_addr, pkt + 24, 16) == 0,
          "IPv6 high address was not stored");

    uint8_t hop[8] = {IPPROTO_TCP, 0, 1, 0, 0, 0, 0, 0};
    n = build_ipv6(pkt, IPPROTO_HOPOPTS, hop, sizeof hop, tcp, tcp_len);
    rc = d2k_parse_ipv6(pkt, n, &info);
    CHECK(rc == D2K_IP6_TCP, "Hop-by-Hop IPv6 TCP was not parsed");
    CHECK(info.payload_len == sizeof payload, "Hop-by-Hop payload length is wrong");

    uint8_t frag[8] = {IPPROTO_TCP, 0, 0, 0, 0, 0, 0, 0};
    n = build_ipv6(pkt, IPPROTO_FRAGMENT, frag, sizeof frag, tcp, tcp_len);
    rc = d2k_parse_ipv6(pkt, n, &info);
    CHECK(rc == D2K_IP6_TCP, "first IPv6 fragment was not parsed");

    frag[2] = 0;
    frag[3] = 8;
    n = build_ipv6(pkt, IPPROTO_FRAGMENT, frag, sizeof frag, tcp, tcp_len);
    rc = d2k_parse_ipv6(pkt, n, &info);
    CHECK(rc == D2K_IP6_ERR, "non-first IPv6 fragment was incorrectly parsed as TCP");
}

static void test_checksum_and_split_wire(void)
{
    d2k_conn c;
    memset(&c, 0, sizeof c);
    c.family = D2K_KEY_IPV6;
    static const uint8_t src[16] = {
        0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1
    };
    static const uint8_t dst[16] = {
        0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2
    };
    memcpy(c.src_ip6, src, 16);
    memcpy(c.dst_ip6, dst, 16);

    uint8_t sp[2] = {0x9c, 0x40};
    uint8_t dp[2] = {0x01, 0xbb};
    memcpy(&c.src_port, sp, 2);
    memcpy(&c.dst_port, dp, 2);
    c.ack = 2000;
    c.window = 64240;
    c.ttl = 64;

    static const uint8_t payload[] = {0xde, 0xad, 0xbe, 0xef, 0x11};
    d2k_emit e;
    memset(&e, 0, sizeof e);
    e.seq = 1000;
    e.bytes = payload;
    e.len = sizeof payload;

    uint8_t pkt[256];
    size_t n = d2k_wire_build(&c, &e, pkt, sizeof pkt);
    CHECK(n == 40 + 20 + sizeof payload, "IPv6 split fixture has wrong length");
    CHECK(d2k_wire_tcp_checksum_ok(pkt, n), "IPv6 TCP checksum is invalid");

    struct in6_addr s6;
    struct in6_addr d6;
    memcpy(&s6, src, sizeof s6);
    memcpy(&d6, dst, sizeof d6);
    uint8_t tcp_copy[128];
    memcpy(tcp_copy, pkt + 40, n - 40);
    tcp_copy[16] = 0;
    tcp_copy[17] = 0;
    uint16_t expected = d2k_tcp_checksum_ipv6(&s6, &d6, tcp_copy, n - 40);
    CHECK(expected == 0x0111, "IPv6 checksum helper does not match the independent fixture");
    CHECK(expected == (uint16_t)(((uint16_t)pkt[56] << 8) | pkt[57]),
          "wire builder did not use the IPv6 checksum helper");

    e.seq_shift = -10000;
    n = d2k_wire_build(&c, &e, pkt, sizeof pkt);
    CHECK(n != 0 && d2k_wire_tcp_checksum_ok(pkt, n),
          "IPv6 split/sequence transformation broke checksum");

    e.poison = D2K_POISON_BADSUM;
    n = d2k_wire_build(&c, &e, pkt, sizeof pkt);
    CHECK(n != 0 && !d2k_wire_tcp_checksum_ok(pkt, n),
          "IPv6 bad-checksum transformation was not detectable");
}

int main(void)
{
    test_parser_and_key();
    test_checksum_and_split_wire();

    if (fails != 0) {
        printf("FAILURES: %d\n", fails);
        return 1;
    }
    printf("IPv6 pipeline: all checks passed\n");
    return 0;
}
