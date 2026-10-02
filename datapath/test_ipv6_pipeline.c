#include <assert.h>
#include <arpa/inet.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "d2k_track.h"
#include "d2k_tls.h"
#include "d2k_wire.h"
#include "ipv6.h"

static size_t make_client_hello(uint8_t *out, size_t cap)
{
    static const uint8_t sni_ext[] = {
        0x00, 0x00, 0x00, 0x0c,
        0x00, 0x0a, 0x00, 0x00, 0x07,
        'e', 'x', 'a', 'm', 'p', 'l', 'e'
    };
    const size_t hs_len = 59;
    const size_t record_len = 4 + hs_len;
    assert(cap >= 5 + record_len);

    size_t o = 0;
    out[o++] = 0x16;
    out[o++] = 0x03;
    out[o++] = 0x03;
    out[o++] = (uint8_t)(record_len >> 8);
    out[o++] = (uint8_t)record_len;
    out[o++] = 0x01;
    out[o++] = (uint8_t)(hs_len >> 16);
    out[o++] = (uint8_t)(hs_len >> 8);
    out[o++] = (uint8_t)hs_len;
    out[o++] = 0x03;
    out[o++] = 0x03;
    memset(out + o, 0x42, 32);
    o += 32;
    out[o++] = 0x00;
    out[o++] = 0x00;
    out[o++] = 0x02;
    out[o++] = 0x13;
    out[o++] = 0x01;
    out[o++] = 0x01;
    out[o++] = 0x00;
    out[o++] = 0x00;
    out[o++] = sizeof sni_ext;
    memcpy(out + o, sni_ext, sizeof sni_ext);
    o += sizeof sni_ext;
    assert(o == 5 + record_len);
    return o;
}

static size_t make_ipv6_tcp(uint8_t *pkt, size_t cap)
{
    uint8_t hello[128];
    size_t hello_len = make_client_hello(hello, sizeof hello);
    const size_t tcp_off = 40;
    const size_t tcp_len = 20 + hello_len;
    const size_t total = tcp_off + tcp_len;
    assert(cap >= total);

    memset(pkt, 0, total);
    pkt[0] = 0x60;
    pkt[6] = IPPROTO_TCP;
    pkt[7] = 64;
    static const uint8_t src[16] = {
        0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1
    };
    static const uint8_t dst[16] = {
        0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2
    };
    memcpy(pkt + 8, src, 16);
    memcpy(pkt + 24, dst, 16);

    uint16_t plen = htons((uint16_t)(total - 40));
    memcpy(pkt + 4, &plen, sizeof plen);

    pkt[tcp_off + 0] = 0x30;
    pkt[tcp_off + 1] = 0x39;
    pkt[tcp_off + 2] = 0x01;
    pkt[tcp_off + 3] = 0xbb;
    pkt[tcp_off + 12] = 0x50;
    pkt[tcp_off + 13] = 0x18;
    memcpy(pkt + tcp_off + 20, hello, hello_len);

    uint16_t csum = d2k_tcp_checksum_ipv6(
        (const struct in6_addr *)(pkt + 8),
        (const struct in6_addr *)(pkt + 24),
        pkt + tcp_off,
        tcp_len);
    uint16_t csum_be = htons(csum);
    memcpy(pkt + tcp_off + 16, &csum_be, sizeof csum_be);
    return total;
}

static void test_parser_tls_and_key(void)
{
    uint8_t pkt[256];
    struct d2k_ip6_info ip6;
    d2k_tls_info tls;
    d2k_key key;
    size_t len = make_ipv6_tcp(pkt, sizeof pkt);

    assert(d2k_parse_ipv6(pkt, len, &ip6) == D2K_IP6_TCP);
    assert(ip6.tcph != NULL);
    assert(ip6.payload != NULL);
    assert(ip6.payload_len > 0);
    assert(d2k_tls_parse(ip6.payload, ip6.payload_len, &tls) == 0);
    assert(tls.is_client_hello);
    assert(tls.have_sni);
    assert(tls.sni_len == 7);
    assert(memcmp(ip6.payload + tls.sni_off, "example", 7) == 0);

    assert(d2k_key_make6(&key, pkt + 8, pkt + 24,
                         pkt + 40, pkt + 42) == 1);
    assert(key.family == D2K_KEY_IPV6);
    assert(memcmp(key.low_ip6, pkt + 8, 16) == 0);
    assert(memcmp(key.high_ip6, pkt + 24, 16) == 0);
    puts("PASS IPv6 parser/TLS SNI/128-bit flow key");
}

static void test_checksum(void)
{
    uint8_t pkt[256];
    size_t len = make_ipv6_tcp(pkt, sizeof pkt);
    assert(d2k_wire_tcp_checksum_ok(pkt, len));

    uint16_t old;
    memcpy(&old, pkt + 64, sizeof old);
    pkt[68] ^= 0x01;
    assert(!d2k_wire_tcp_checksum_ok(pkt, len));
    pkt[68] ^= 0x01;
    assert(d2k_wire_tcp_checksum_ok(pkt, len));
    (void)old;
    puts("PASS IPv6 TCP checksum");
}

static void test_extension_header(void)
{
    uint8_t pkt[256];
    size_t len = make_ipv6_tcp(pkt, sizeof pkt);
    memmove(pkt + 48, pkt + 40, len - 40);
    memset(pkt + 40, 0, 8);
    pkt[6] = IPPROTO_HOPOPTS;
    pkt[40] = IPPROTO_TCP;
    pkt[41] = 0;
    uint16_t plen = htons((uint16_t)(len + 8 - 40));
    memcpy(pkt + 4, &plen, sizeof plen);

    struct d2k_ip6_info info;
    assert(d2k_parse_ipv6(pkt, len + 8, &info) == D2K_IP6_TCP);
    assert((const uint8_t *)info.tcph == pkt + 48);
    puts("PASS IPv6 extension header");
}

int main(void)
{
    test_parser_tls_and_key();
    test_checksum();
    test_extension_header();
    puts("IPv6 pipeline tests passed.");
    return 0;
}
