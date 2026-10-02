/* Bounded, single-owner TCP/UDP observation tracker. No packet-path allocation. */
#ifndef D2K_SESSION_TRACKER_H
#define D2K_SESSION_TRACKER_H

#include "include/d2k_track.h"

enum d2k_tcp_state {
    D2K_TCP_UNKNOWN = 0,
    D2K_TCP_SYN_SENT,
    D2K_TCP_SYN_RECV,
    D2K_TCP_ESTABLISHED,
    D2K_TCP_FIN_WAIT,
    D2K_TCP_CLOSE_WAIT,
    D2K_TCP_CLOSED,
    D2K_TCP_RST
};

enum { D2K_TRACKER_TCP = 6, D2K_TRACKER_UDP = 17 };
enum {
    D2K_TCP_FIN = 0x01, D2K_TCP_SYN = 0x02,
    D2K_TCP_RESET = 0x04, D2K_TCP_ACK = 0x10
};

/* struct d2k_session is already the opaque packet engine in d2k_session.h.
 * This distinct record keeps that API and the 40-byte d2k_key ABI unchanged.
 * Observation metadata is NOT a wire ABI. Masks use bit 0=low, bit 1=high. */
typedef struct d2k_tracked_session {
    d2k_key key;
    uint64_t first_ns, last_ns;
    enum d2k_tcp_state tcp_state;
    uint32_t syn_end[2], fin_end[2];
    uint8_t protocol;
    uint8_t initiator_low, role_known;
    uint8_t syn_seen, syn_acked, fin_seen, fin_acked;
} d2k_tracked_session;

typedef struct {
    uint64_t tcp_open_ns;       /* UNKNOWN and incomplete handshake */
    uint64_t tcp_established_ns;
    uint64_t tcp_closing_ns;
    uint64_t tcp_terminal_ns;   /* CLOSED/RST retained for observation */
    uint64_t udp_idle_ns;
} d2k_tracker_timeouts;

typedef struct {
    uint32_t seq, ack, payload_len; /* host order, from a validated TCP header */
    uint8_t flags;
    uint8_t src_is_low;            /* return value of d2k_key_make[6] */
} d2k_tcp_observation;

typedef struct d2k_session_tracker d2k_session_tracker;

void d2k_session_tracker_defaults(d2k_tracker_timeouts *timeouts);
/* NULL timeouts uses defaults; all supplied timeouts must be nonzero.
 * capacity is a hard session limit; invalid/overflowing sizes return NULL.
 * All memory is allocated here. One caller owns updates; no internal locks. */
d2k_session_tracker *d2k_session_tracker_new(size_t capacity,
                                           const d2k_tracker_timeouts *timeouts);
void d2k_session_tracker_free(d2k_session_tracker *tracker);

/* Identity is (protocol, canonical d2k_key), not d2k_key alone.
 * Native padding and unused IPv4 union bytes are normalized internally.
 * Borrowed pointers survive mutations of OTHER sessions, but not their own
 * remove/expire/reuse or tracker destruction. Never modify returned records. */
const d2k_tracked_session *d2k_session_tracker_find(
    const d2k_session_tracker *tracker, uint8_t protocol, const d2k_key *key);
const d2k_tracked_session *d2k_session_tracker_add(
    d2k_session_tracker *tracker, uint8_t protocol, const d2k_key *key,
    uint64_t now_ns);
int d2k_session_tracker_remove(d2k_session_tracker *tracker, uint8_t protocol,
                               const d2k_key *key);

/* Get/add and update; NULL on invalid input or capacity refusal.
 * TCP state is passive evidence, NOT TCP endpoint/window/RST validation.
 * ACK advances handshake/close only when it exactly acknowledges the peer's
 * observed SYN/FIN sequence end (including payload, with unsigned wrap).
 * SYN retransmissions do not regress established/closing state. A fresh
 * SYN without ACK can reuse a terminal record. Midstream stays UNKNOWN.
 * Older timestamps never regress time or state. No clocks are called here. */
const d2k_tracked_session *d2k_session_tracker_tcp(
    d2k_session_tracker *tracker, const d2k_key *key,
    const d2k_tcp_observation *packet, uint64_t now_ns);
const d2k_tracked_session *d2k_session_tracker_udp(
    d2k_session_tracker *tracker, const d2k_key *key, uint64_t now_ns);

/* Maintenance O(capacity), expiry at idle >= timeout. No unsigned underflow
 * on a backwards clock. expire does not move surviving records. */
size_t d2k_session_tracker_expire(d2k_session_tracker *tracker, uint64_t now_ns);
/* Callback borrows the expiring record immediately before removal; it MUST
 * NOT mutate the tracker or retain that pointer. */
size_t d2k_session_tracker_expire_notify(d2k_session_tracker *tracker, uint64_t now_ns,
    void (*notify)(void *, const d2k_tracked_session *, uint64_t), void *ctx);
size_t d2k_session_tracker_count(const d2k_session_tracker *tracker);
size_t d2k_session_tracker_capacity(const d2k_session_tracker *tracker);
uint64_t d2k_session_tracker_refusals(const d2k_session_tracker *tracker);
/* Single-owner O(capacity) read-only walk; callback must not mutate tracker. */
void d2k_session_tracker_visit(const d2k_session_tracker *tracker,
    void (*visit)(void *, const d2k_tracked_session *), void *ctx);
size_t d2k_session_tracker_memory_bytes(const d2k_session_tracker *tracker);

#endif
