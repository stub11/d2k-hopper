/* datapath/ipv6.h — bounded IPv6/TCP parser for d2kd datapath. */
#ifndef D2K_IPV6_H
#define D2K_IPV6_H

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <netinet/in.h>
#include <netinet/ip6.h>
#include <netinet/tcp.h>

#define D2K_IP6_ERR (-1)
#define D2K_IP6_OTHER 0
#define D2K_IP6_TCP 1
#define D2K_IP6_MAX_EXT_HEADERS 8

struct d2k_ip6_info {
    const struct ip6_hdr *ip6h;
    const struct tcphdr *tcph;
    const uint8_t *payload;
    size_t payload_len;
    uint8_t hop_limit;
};

static inline int d2k_parse_ipv6(const uint8_t *data, size_t len,
                                 struct d2k_ip6_info *info)
{
    if (!data || !info || len < sizeof(struct ip6_hdr))
        return D2K_IP6_ERR;

    const struct ip6_hdr *ip6 = (const struct ip6_hdr *)data;
    if ((ip6->ip6_vfc >> 4) != 6)
        return D2K_IP6_ERR;

    info->ip6h = ip6;
    info->hop_limit = ip6->ip6_hlim;
    info->tcph = NULL;
    info->payload = NULL;
    info->payload_len = 0;

    /* Never parse bytes outside the IPv6 payload advertised by the packet. */
    size_t ip6_len = (size_t)ntohs(ip6->ip6_plen);
    if (ip6_len > len - sizeof(struct ip6_hdr))
        return D2K_IP6_ERR;
    size_t end = sizeof(struct ip6_hdr) + ip6_len;
    uint8_t nxt = ip6->ip6_nxt;
    size_t off = sizeof(struct ip6_hdr);
    int ext_count = 0;

    while (1) {
        switch (nxt) {
        case IPPROTO_HOPOPTS:
        case IPPROTO_ROUTING:
        case IPPROTO_DSTOPTS: {
            if (++ext_count > D2K_IP6_MAX_EXT_HEADERS || off + 8 > end)
                return D2K_IP6_ERR;
            size_t hlen = ((size_t)data[off + 1] + 1u) * 8u;
            if (hlen > end - off)
                return D2K_IP6_ERR;
            nxt = data[off];
            off += hlen;
            break;
        }
        case IPPROTO_FRAGMENT: {
            if (++ext_count > D2K_IP6_MAX_EXT_HEADERS || off + 8 > end)
                return D2K_IP6_ERR;
            /* Fragment offset is bits 3..15 of the big-endian field at +2.
             * Non-first fragments cannot contain a complete TCP header. */
            uint16_t frag = (uint16_t)data[off + 2] << 8 | data[off + 3];
            if ((frag & 0xfff8u) != 0)
                return D2K_IP6_ERR;
            nxt = data[off];
            off += 8;
            break;
        }
        case IPPROTO_TCP:
            goto found_tcp;
        case IPPROTO_UDP:
        case IPPROTO_ICMPV6:
        case IPPROTO_NONE:
        default:
            return D2K_IP6_OTHER;
        }
    }

found_tcp:
    if (off + 20u > end)
        return D2K_IP6_ERR;

    /* Read data-offset from the wire bytes instead of a bit-field: this avoids
     * implementation/endian assumptions and unaligned struct access on MIPS. */
    uint8_t doff_byte = data[off + 12];
    size_t tcp_hdr_len = (size_t)(doff_byte >> 4) * 4u;
    if (tcp_hdr_len < 20u || tcp_hdr_len > end - off)
        return D2K_IP6_ERR;

    info->tcph = (const struct tcphdr *)(data + off);
    off += tcp_hdr_len;
    if (off < end) {
        info->payload = data + off;
        info->payload_len = end - off;
    }
    return D2K_IP6_TCP;
}

static inline uint16_t d2k_tcp_checksum_ipv6(const struct in6_addr *src,
                                             const struct in6_addr *dst,
                                             const uint8_t *tcp_data,
                                             size_t tcp_len)
{
    uint32_t sum = 0;
    const uint8_t *p = (const uint8_t *)src;
    size_t i;
    for (i = 0; i < 32; i += 2)
        sum += ((uint32_t)p[i] << 8) | p[i + 1];
    p = (const uint8_t *)dst;
    for (i = 0; i < 32; i += 2)
        sum += ((uint32_t)p[i] << 8) | p[i + 1];
    sum += (uint32_t)(tcp_len >> 16);
    sum += (uint32_t)(tcp_len & 0xffffu);
    sum += IPPROTO_TCP;

    for (i = 0; i + 1 < tcp_len; i += 2)
        sum += ((uint32_t)tcp_data[i] << 8) | tcp_data[i + 1];
    if (tcp_len & 1u)
        sum += (uint32_t)tcp_data[tcp_len - 1] << 8;
    while (sum >> 16)
        sum = (sum & 0xffffu) + (sum >> 16);
    return (uint16_t)~sum;
}

#endif /* D2K_IPV6_H */
