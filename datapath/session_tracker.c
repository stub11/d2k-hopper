#include "session_tracker.h"

#include <stdlib.h>
#include <string.h>

#define NONE SIZE_MAX
#define NS UINT64_C(1000000000)
#define ABI_CHECK(name, expr) typedef char abi_##name[(expr) ? 1 : -1]
ABI_CHECK(key_size, sizeof(d2k_key) == 40);
ABI_CHECK(family, offsetof(d2k_key, family) == 0);
ABI_CHECK(low_addr, offsetof(d2k_key, low_addr) == 4);
ABI_CHECK(high_addr, offsetof(d2k_key, high_addr) == 20);
ABI_CHECK(low_port, offsetof(d2k_key, low_port) == 36);
ABI_CHECK(high_port, offsetof(d2k_key, high_port) == 38);
ABI_CHECK(alignment, offsetof(struct { char c; d2k_key k; }, k) == 4);

struct tracker_slot {
    d2k_tracked_session session;
    size_t next;                /* bucket chain or free list */
    uint8_t used;
};

struct d2k_session_tracker {
    struct tracker_slot *slots;
    size_t *buckets;
    size_t capacity, bucket_count, count, free_head;
    uint64_t refusals;
    d2k_tracker_timeouts timeouts;
};

static int normalize(d2k_key *out, const d2k_key *in, uint8_t protocol) {
    if (!in || (protocol != D2K_TRACKER_TCP && protocol != D2K_TRACKER_UDP) ||
        (in->family != D2K_KEY_IPV4 && in->family != D2K_KEY_IPV6)) return 0;
    memset(out, 0, sizeof *out);
    out->family = in->family;
    size_t bytes = in->family == D2K_KEY_IPV4 ? 4 : 16;
    memcpy(&out->low_addr, &in->low_addr, bytes);
    memcpy(&out->high_addr, &in->high_addr, bytes);
    memcpy(&out->low_port, &in->low_port, 2);
    memcpy(&out->high_port, &in->high_port, 2);
    return 1;
}

static size_t bucket(const d2k_session_tracker *t, const d2k_key *key,
                      uint8_t protocol) {
    const uint8_t *p = (const uint8_t *)key;
    uint32_t h = (UINT32_C(2166136261) ^ protocol) * UINT32_C(16777619);
    for (size_t i = 0; i < sizeof *key; i++) h = (h ^ p[i]) * UINT32_C(16777619);
    return (size_t)h & (t->bucket_count - 1);
}

static size_t lookup(const d2k_session_tracker *t, const d2k_key *key,
                      uint8_t protocol) {
    for (size_t i = t->buckets[bucket(t, key, protocol)]; i != NONE;
         i = t->slots[i].next) {
        const d2k_tracked_session *s = &t->slots[i].session;
        if (s->protocol == protocol && memcmp(&s->key, key, sizeof *key) == 0)
            return i;
    }
    return NONE;
}

void d2k_session_tracker_defaults(d2k_tracker_timeouts *v) {
    if (!v) return;
    v->tcp_open_ns = 30 * NS;
    v->tcp_established_ns = 300 * NS;
    v->tcp_closing_ns = 30 * NS;
    v->tcp_terminal_ns = 5 * NS;
    v->udp_idle_ns = 30 * NS;
}

d2k_session_tracker *d2k_session_tracker_new(size_t capacity,
                                           const d2k_tracker_timeouts *timeouts) {
    d2k_tracker_timeouts v;
    if (timeouts) v = *timeouts; else d2k_session_tracker_defaults(&v);
    if (!capacity || capacity > SIZE_MAX / 2 ||
        capacity > SIZE_MAX / sizeof(struct tracker_slot) ||
        !v.tcp_open_ns || !v.tcp_established_ns || !v.tcp_closing_ns ||
        !v.tcp_terminal_ns || !v.udp_idle_ns) return NULL;
    size_t buckets = 2;
    while (buckets < capacity * 2) {
        if (buckets > SIZE_MAX / 2) return NULL;
        buckets *= 2;
    }
    if (buckets > SIZE_MAX / sizeof(size_t)) return NULL;
    d2k_session_tracker *t = calloc(1, sizeof *t);
    if (!t) return NULL;
    t->slots = calloc(capacity, sizeof *t->slots);
    t->buckets = malloc(buckets * sizeof *t->buckets);
    if (!t->slots || !t->buckets) { d2k_session_tracker_free(t); return NULL; }
    t->capacity = capacity; t->bucket_count = buckets;
    t->timeouts = v; t->free_head = 0;
    for (size_t i = 0; i < buckets; i++) t->buckets[i] = NONE;
    for (size_t i = 0; i < capacity; i++)
        t->slots[i].next = i + 1 < capacity ? i + 1 : NONE;
    return t;
}

void d2k_session_tracker_free(d2k_session_tracker *t) {
    if (!t) return;
    free(t->buckets); free(t->slots); free(t);
}

const d2k_tracked_session *d2k_session_tracker_find(
    const d2k_session_tracker *t, uint8_t protocol, const d2k_key *key) {
    d2k_key k;
    if (!t || !normalize(&k, key, protocol)) return NULL;
    size_t i = lookup(t, &k, protocol);
    return i == NONE ? NULL : &t->slots[i].session;
}

static d2k_tracked_session *get(d2k_session_tracker *t, uint8_t protocol,
                               const d2k_key *key, uint64_t now_ns) {
    d2k_key k;
    if (!t || !normalize(&k, key, protocol)) return NULL;
    size_t i = lookup(t, &k, protocol);
    if (i != NONE) return &t->slots[i].session;
    if (t->free_head == NONE) {
        if (t->refusals != UINT64_MAX) t->refusals++;
        return NULL;
    }
    i = t->free_head;
    struct tracker_slot *slot = &t->slots[i];
    t->free_head = slot->next;
    memset(&slot->session, 0, sizeof slot->session);
    slot->session.key = k; slot->session.protocol = protocol;
    slot->session.first_ns = slot->session.last_ns = now_ns;
    size_t b = bucket(t, &k, protocol);
    slot->next = t->buckets[b]; t->buckets[b] = i; slot->used = 1;
    t->count++;
    return &slot->session;
}

const d2k_tracked_session *d2k_session_tracker_add(
    d2k_session_tracker *t, uint8_t protocol, const d2k_key *key, uint64_t now_ns) {
    return get(t, protocol, key, now_ns);
}

static void erase(d2k_session_tracker *t, size_t *link, size_t i) {
    struct tracker_slot *slot = &t->slots[i];
    *link = slot->next;
    memset(&slot->session, 0, sizeof slot->session);
    slot->used = 0; slot->next = t->free_head; t->free_head = i;
    t->count--;
}

int d2k_session_tracker_remove(d2k_session_tracker *t, uint8_t protocol,
                               const d2k_key *key) {
    d2k_key k;
    if (!t || !normalize(&k, key, protocol)) return 0;
    size_t *link = &t->buckets[bucket(t, &k, protocol)];
    while (*link != NONE) {
        size_t i = *link;
        struct tracker_slot *slot = &t->slots[i];
        if (slot->session.protocol == protocol &&
            memcmp(&slot->session.key, &k, sizeof k) == 0) {
            erase(t, link, i); return 1;
        }
        link = &slot->next;
    }
    return 0;
}

const d2k_tracked_session *d2k_session_tracker_tcp(
    d2k_session_tracker *t, const d2k_key *key,
    const d2k_tcp_observation *p, uint64_t now_ns) {
    if (!p || p->src_is_low > 1 || p->payload_len > UINT32_C(0x7fffffff) ||
        ((p->flags & D2K_TCP_SYN) && (p->flags & (D2K_TCP_FIN | D2K_TCP_RESET))))
        return NULL;
    d2k_tracked_session *s = get(t, D2K_TRACKER_TCP, key, now_ns);
    if (!s || now_ns < s->last_ns) return s;
    s->last_ns = now_ns;
    int terminal = s->tcp_state == D2K_TCP_CLOSED || s->tcp_state == D2K_TCP_RST;
    if (terminal && (p->flags & (D2K_TCP_SYN | D2K_TCP_ACK)) == D2K_TCP_SYN) {
        d2k_key k = s->key;
        memset(s, 0, sizeof *s); s->key = k; s->protocol = D2K_TRACKER_TCP;
        s->first_ns = s->last_ns = now_ns;
    } else if (terminal) return s;
    if (p->flags & D2K_TCP_RESET) { s->tcp_state = D2K_TCP_RST; return s; }

    unsigned side = p->src_is_low ? 0u : 1u, peer = side ^ 1u;
    uint8_t bit = (uint8_t)(1u << side), other = (uint8_t)(1u << peer);
    if (p->flags & D2K_TCP_SYN) {
        if (s->tcp_state >= D2K_TCP_ESTABLISHED) return s;
        uint32_t end = p->seq + p->payload_len + UINT32_C(1);
        if ((s->syn_seen & bit) && s->syn_end[side] != end) return s;
        if (!s->role_known) {
            s->initiator_low = (p->flags & D2K_TCP_ACK) ? !p->src_is_low : p->src_is_low;
            s->role_known = 1;
        }
        s->syn_seen |= bit; s->syn_end[side] = end;
        if (p->flags & D2K_TCP_ACK) s->tcp_state = D2K_TCP_SYN_RECV;
        else if (s->tcp_state == D2K_TCP_UNKNOWN) s->tcp_state = D2K_TCP_SYN_SENT;
    }
    if (p->flags & D2K_TCP_ACK) {
        if ((s->syn_seen & other) && p->ack == s->syn_end[peer]) s->syn_acked |= other;
        if ((s->fin_seen & other) && p->ack == s->fin_end[peer]) s->fin_acked |= other;
    }
    if (s->tcp_state < D2K_TCP_ESTABLISHED && s->syn_seen == 3 && s->syn_acked == 3)
        s->tcp_state = D2K_TCP_ESTABLISHED;
    if ((p->flags & D2K_TCP_FIN) && s->tcp_state >= D2K_TCP_ESTABLISHED) {
        uint32_t end = p->seq + p->payload_len + UINT32_C(1);
        if (!(s->fin_seen & bit)) { s->fin_end[side] = end; s->fin_seen |= bit; }
        if (s->tcp_state == D2K_TCP_ESTABLISHED)
            s->tcp_state = p->src_is_low == s->initiator_low ?
                           D2K_TCP_FIN_WAIT : D2K_TCP_CLOSE_WAIT;
    }
    if (s->fin_seen == 3 && s->fin_acked == 3) s->tcp_state = D2K_TCP_CLOSED;
    return s;
}

const d2k_tracked_session *d2k_session_tracker_udp(
    d2k_session_tracker *t, const d2k_key *key, uint64_t now_ns) {
    d2k_tracked_session *s = get(t, D2K_TRACKER_UDP, key, now_ns);
    if (s && now_ns >= s->last_ns) s->last_ns = now_ns;
    return s;
}

static uint64_t idle_limit(const d2k_session_tracker *t, const d2k_tracked_session *s) {
    if (s->protocol == D2K_TRACKER_UDP) return t->timeouts.udp_idle_ns;
    switch (s->tcp_state) {
    case D2K_TCP_ESTABLISHED: return t->timeouts.tcp_established_ns;
    case D2K_TCP_FIN_WAIT: case D2K_TCP_CLOSE_WAIT: return t->timeouts.tcp_closing_ns;
    case D2K_TCP_CLOSED: case D2K_TCP_RST: return t->timeouts.tcp_terminal_ns;
    default: return t->timeouts.tcp_open_ns;
    }
}

size_t d2k_session_tracker_expire(d2k_session_tracker *t, uint64_t now_ns) {
    return d2k_session_tracker_expire_notify(t, now_ns, NULL, NULL);
}

size_t d2k_session_tracker_expire_notify(d2k_session_tracker *t, uint64_t now_ns,
    void (*notify)(void *, const d2k_tracked_session *, uint64_t), void *ctx) {
    if (!t) return 0;
    size_t removed = 0;
    /* Walk each chain once; repeated keyed removes would be quadratic when
     * many keys collide. Unlink in place without moving surviving slots. */
    for (size_t b = 0; b < t->bucket_count; b++) {
        size_t *link = &t->buckets[b];
        while (*link != NONE) {
            size_t i = *link;
            const d2k_tracked_session *s = &t->slots[i].session;
            if (now_ns >= s->last_ns && now_ns - s->last_ns >= idle_limit(t, s)) {
                if (notify) notify(ctx, s, now_ns);
                erase(t, link, i); removed++;
            } else link = &t->slots[i].next;
        }
    }
    return removed;
}

size_t d2k_session_tracker_count(const d2k_session_tracker *t) { return t ? t->count : 0; }
size_t d2k_session_tracker_capacity(const d2k_session_tracker *t) { return t ? t->capacity : 0; }
uint64_t d2k_session_tracker_refusals(const d2k_session_tracker *t) { return t ? t->refusals : 0; }
