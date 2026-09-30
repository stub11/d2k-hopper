#ifndef D2K_QUIC_H
#define D2K_QUIC_H
#include <stddef.h>
#include <stdint.h>
typedef struct {
    int is_initial;
    uint32_t version;
    uint8_t dcid_len, scid_len;
    uint8_t dcid[20], scid[20];
    size_t header_len;
    uint64_t token_len, payload_len;
} d2k_quic_info;
int d2k_quic_parse(const uint8_t *b, size_t len, d2k_quic_info *out);
#endif
