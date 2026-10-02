#include "session_tracker.h"
/* Prove the new record can coexist with the existing opaque packet engine. */
#include "include/d2k_session.h"

#include <stdio.h>
#include <string.h>

static int fails;
#define CHECK(c, msg) do { if (!(c)) { printf("FAIL: %s\n", msg); fails++; } } while (0)

static d2k_key key(int family, uint16_t port, int reverse) {
    uint8_t a[16] = {1,2,3,4}, b[16] = {5,6,7,8};
    uint8_t ap[2] = {(uint8_t)(port >> 8), (uint8_t)port}, bp[2] = {0x01,0xbb};
    d2k_key k;
    if (family == 6) { a[0] = b[0] = 0x20; a[15] = 1; b[15] = 2; }
    if (family == 4)
        d2k_key_make(&k, reverse ? b : a, reverse ? a : b,
                      reverse ? bp : ap, reverse ? ap : bp);
    else
        d2k_key_make6(&k, reverse ? b : a, reverse ? a : b,
                       reverse ? bp : ap, reverse ? ap : bp);
    return k;
}

static const d2k_tracked_session *tcp(d2k_session_tracker *t, const d2k_key *k,
                                     int low, uint8_t flags, uint32_t seq,
                                     uint32_t ack, uint32_t payload, uint64_t now) {
    d2k_tcp_observation p;
    memset(&p, 0, sizeof p);
    p.src_is_low = (uint8_t)low; p.flags = flags;
    p.seq = seq; p.ack = ack; p.payload_len = payload;
    return d2k_session_tracker_tcp(t, k, &p, now);
}

static const d2k_tracked_session *handshake(d2k_session_tracker *t,
                                           const d2k_key *k, int initiator,
                                           uint64_t now) {
    const d2k_tracked_session *s = tcp(t,k,initiator,D2K_TCP_SYN,100,0,0,now);
    CHECK(s && s->tcp_state == D2K_TCP_SYN_SENT, "SYN_SENT");
    s = tcp(t,k,!initiator,D2K_TCP_SYN|D2K_TCP_ACK,200,101,0,now+1);
    CHECK(s && s->tcp_state == D2K_TCP_SYN_RECV, "SYN_RECV");
    s = tcp(t,k,initiator,D2K_TCP_ACK,101,201,0,now+2);
    CHECK(s && s->tcp_state == D2K_TCP_ESTABLISHED, "ESTABLISHED");
    return s;
}

static void lifecycle(int family, int initiator, int passive_close) {
    d2k_session_tracker *t = d2k_session_tracker_new(4, NULL);
    CHECK(t != NULL, "tracker allocation"); if (!t) return;
    d2k_key k = key(family, 50000, 0), rev = key(family, 50000, 1);
    const d2k_tracked_session *s = handshake(t,&k,initiator,10);
    CHECK(s == d2k_session_tracker_find(t,D2K_TRACKER_TCP,&rev), "reverse flow match");
    CHECK(s && memcmp(&s->key,&k,sizeof k) == 0, "unchanged FlowKey bytes");
    CHECK(d2k_session_tracker_count(t) == 1, "one TCP session");
    s = tcp(t,&rev,initiator,D2K_TCP_SYN,100,0,0,13);
    CHECK(s && s->tcp_state == D2K_TCP_ESTABLISHED, "old SYN cannot regress state");
    int first = passive_close ? !initiator : initiator;
    s = tcp(t,&k,first,D2K_TCP_FIN|D2K_TCP_ACK,300,0,7,14);
    enum d2k_tcp_state closing = passive_close ? D2K_TCP_CLOSE_WAIT : D2K_TCP_FIN_WAIT;
    CHECK(s && s->tcp_state == closing, "FIN direction selects closing state");
    s = tcp(t,&k,!first,D2K_TCP_ACK,400,301,0,15);
    CHECK(s && s->fin_acked == 0, "ACK must include FIN payload length");
    s = tcp(t,&k,!first,D2K_TCP_ACK,400,308,0,16);
    CHECK(s && s->tcp_state == closing, "one FIN ACK does not close session");
    s = tcp(t,&rev,first,D2K_TCP_FIN|D2K_TCP_ACK,300,0,7,17);
    CHECK(s && s->tcp_state == closing, "FIN retransmission is idempotent");
    s = tcp(t,&k,!first,D2K_TCP_FIN|D2K_TCP_ACK,400,308,0,18);
    CHECK(s && s->tcp_state == closing, "wait for the second FIN ACK");
    s = tcp(t,&k,first,D2K_TCP_ACK,308,400,0,19);
    CHECK(s && s->tcp_state == closing, "stale ACK cannot close session");
    s = tcp(t,&k,first,D2K_TCP_ACK,308,401,0,20);
    CHECK(s && s->tcp_state == D2K_TCP_CLOSED, "both FINs acknowledged -> CLOSED");
    s = tcp(t,&k,first,D2K_TCP_ACK,308,401,0,21);
    CHECK(s && s->tcp_state == D2K_TCP_CLOSED, "terminal ACK does not reopen");
    s = tcp(t,&k,initiator,D2K_TCP_SYN,800,0,0,22);
    CHECK(s && s->tcp_state == D2K_TCP_SYN_SENT && s->first_ns == 22,
          "terminal tuple reuse starts a clean handshake");
    s = tcp(t,&k,!initiator,D2K_TCP_RESET|D2K_TCP_ACK,0,0,0,23);
    CHECK(s && s->tcp_state == D2K_TCP_RST, "RST terminates handshake");
    CHECK(d2k_session_tracker_remove(t,D2K_TRACKER_TCP,&rev) == 1, "remove reverse key");
    CHECK(d2k_session_tracker_count(t) == 0, "remove count");
    s = handshake(t,&k,initiator,30);
    s = tcp(t,&k,initiator,D2K_TCP_RESET,0,0,0,33);
    CHECK(s && s->tcp_state == D2K_TCP_RST, "RST terminates established flow");
    d2k_session_tracker_free(t);
}

static void handshake_edges(void) {
    d2k_session_tracker *t = d2k_session_tracker_new(4,NULL);
    CHECK(t != NULL,"edge tracker"); if (!t) return;
    d2k_key k = key(6,12345,0);
    const d2k_tracked_session *s = tcp(t,&k,1,D2K_TCP_ACK,10,20,0,1);
    CHECK(s && s->tcp_state == D2K_TCP_UNKNOWN,"midstream is not proof of handshake");
    s = tcp(t,&k,1,D2K_TCP_SYN,UINT32_MAX,0,0,2);
    CHECK(s && s->tcp_state == D2K_TCP_SYN_SENT,"wrapped SYN");
    s = tcp(t,&k,0,D2K_TCP_SYN|D2K_TCP_ACK,20,UINT32_MAX,0,3);
    CHECK(s && s->syn_acked == 0,"wrong SYN ACK ignored");
    s = tcp(t,&k,0,D2K_TCP_SYN|D2K_TCP_ACK,20,0,0,4);
    s = tcp(t,&k,1,D2K_TCP_ACK,0,21,0,5);
    CHECK(s && s->tcp_state == D2K_TCP_ESTABLISHED,"handshake sequence wrap");
    s = tcp(t,&k,1,D2K_TCP_FIN|D2K_TCP_ACK,UINT32_MAX,21,0,6);
    s = tcp(t,&k,0,D2K_TCP_FIN|D2K_TCP_ACK,21,0,0,7);
    s = tcp(t,&k,1,D2K_TCP_ACK,0,22,0,8);
    CHECK(s && s->tcp_state == D2K_TCP_CLOSED,"FIN sequence wrap");
    d2k_session_tracker_remove(t,D2K_TRACKER_TCP,&k);
    s = tcp(t,&k,1,D2K_TCP_SYN,100,0,0,10);
    s = tcp(t,&k,0,D2K_TCP_SYN,200,0,0,11);
    s = tcp(t,&k,1,D2K_TCP_SYN|D2K_TCP_ACK,100,201,0,12);
    s = tcp(t,&k,0,D2K_TCP_SYN|D2K_TCP_ACK,200,101,0,13);
    CHECK(s && s->tcp_state == D2K_TCP_ESTABLISHED,"simultaneous open");
    s = tcp(t,&k,1,D2K_TCP_FIN|D2K_TCP_ACK,101,201,0,14);
    s = tcp(t,&k,0,D2K_TCP_FIN|D2K_TCP_ACK,201,101,0,15);
    CHECK(s && s->tcp_state != D2K_TCP_CLOSED,"simultaneous FINs need ACKs");
    s = tcp(t,&k,1,D2K_TCP_ACK,102,202,0,16);
    s = tcp(t,&k,0,D2K_TCP_ACK,202,102,0,17);
    CHECK(s && s->tcp_state == D2K_TCP_CLOSED,"simultaneous close");
    d2k_session_tracker_free(t);
}

static void table_and_udp(void) {
    d2k_session_tracker *t = d2k_session_tracker_new(2,NULL);
    CHECK(t != NULL,"UDP tracker"); if (!t) return;
    d2k_key k = key(4,5000,0), rev = key(4,5000,1), other = key(6,5000,0);
    const d2k_tracked_session *u = d2k_session_tracker_udp(t,&k,100);
    CHECK(u && u->protocol == D2K_TRACKER_UDP,"IPv4 UDP create");
    CHECK(d2k_session_tracker_udp(t,&rev,110) == u,"UDP reverse touch");
    const d2k_tracked_session *s = d2k_session_tracker_add(t,D2K_TRACKER_TCP,&k,100);
    CHECK(s && s != u,"TCP/UDP identical endpoint separation");
    CHECK(d2k_session_tracker_add(t,D2K_TRACKER_TCP,&rev,101) == s,"duplicate TCP add");
    CHECK(d2k_session_tracker_count(t) == 2,"bounded count");
    CHECK(!d2k_session_tracker_udp(t,&other,111),"capacity refusal");
    CHECK(d2k_session_tracker_refusals(t) == 1,"refusal counter");
    CHECK(d2k_session_tracker_remove(t,D2K_TRACKER_TCP,&rev),"remove TCP");
    CHECK(d2k_session_tracker_find(t,D2K_TRACKER_UDP,&rev) == u,"other pointers stable");
    CHECK(d2k_session_tracker_udp(t,&other,111) != NULL,"IPv6 UDP and slot reuse");
    CHECK(!d2k_session_tracker_remove(t,D2K_TRACKER_TCP,&k),"missing delete");
    d2k_key padded = k;
    memset((uint8_t *)&padded + 1,0xa5,3);
    memset((uint8_t *)&padded.low_addr + 4,0xa5,12);
    memset((uint8_t *)&padded.high_addr + 4,0xa5,12);
    CHECK(d2k_session_tracker_find(t,D2K_TRACKER_UDP,&padded) == u,
          "native padding and IPv4 tail do not change identity");
    CHECK(memcmp(&u->key,&k,sizeof k) == 0,"stored padding normalized");
    d2k_session_tracker_free(t);

    t = d2k_session_tracker_new(2,NULL);
    CHECK(t != NULL,"family tracker"); if (!t) return;
    d2k_key v6 = k; v6.family = D2K_KEY_IPV6;
    u = d2k_session_tracker_udp(t,&k,1);
    s = d2k_session_tracker_udp(t,&v6,1);
    CHECK(u && s && u != s,"IPv4 and IPv6 byte-identical endpoints remain separate");
    d2k_session_tracker_free(t);
}

static void timeouts(void) {
    const d2k_tracker_timeouts v = {10,20,30,4,5};
    for (int kind = 0; kind < 7; kind++) {
        d2k_session_tracker *t = d2k_session_tracker_new(2,&v);
        CHECK(t != NULL,"timeout tracker"); if (!t) return;
        d2k_key k = key(kind % 2 ? 6 : 4,1000,0);
        const d2k_tracked_session *s;
        uint64_t idle;
        if (kind == 0) { s = d2k_session_tracker_udp(t,&k,100); idle = 5; }
        else if (kind == 1) { s = tcp(t,&k,1,D2K_TCP_SYN,1,0,0,100); idle = 10; }
        else {
            s = handshake(t,&k,1,98); idle = 20;
            if (kind == 3 || kind == 4) {
                s = tcp(t,&k,kind == 3,D2K_TCP_FIN|D2K_TCP_ACK,101,201,0,100); idle = 30;
            } else if (kind == 5) { s = tcp(t,&k,0,D2K_TCP_RESET,0,0,0,100); idle = 4; }
            else if (kind == 6) {
                tcp(t,&k,1,D2K_TCP_FIN|D2K_TCP_ACK,101,201,0,100);
                tcp(t,&k,0,D2K_TCP_FIN|D2K_TCP_ACK,201,102,0,100);
                s = tcp(t,&k,1,D2K_TCP_ACK,102,202,0,100); idle = 4;
                CHECK(s && s->tcp_state == D2K_TCP_CLOSED,"closed terminal timeout");
            }
        }
        CHECK(s && s->last_ns == 100,"last time recorded");
        CHECK(d2k_session_tracker_expire(t,99) == 0,"backwards clock does not underflow");
        CHECK(d2k_session_tracker_expire(t,100+idle-1) == 0,"before idle boundary");
        CHECK(d2k_session_tracker_expire(t,100+idle) == 1,"exact idle boundary");
        CHECK(d2k_session_tracker_count(t) == 0,"eviction count");
        CHECK(!d2k_session_tracker_find(t,kind == 0 ? D2K_TRACKER_UDP : D2K_TRACKER_TCP,&k),
              "eviction removes lookup");
        d2k_session_tracker_free(t);
    }
    d2k_session_tracker *t = d2k_session_tracker_new(2,&v);
    CHECK(t != NULL,"clock tracker"); if (!t) return;
    d2k_key k = key(6,2000,0);
    const d2k_tracked_session *s = handshake(t,&k,1,98);
    s = tcp(t,&k,0,D2K_TCP_RESET,0,0,0,99);
    CHECK(s && s->tcp_state == D2K_TCP_ESTABLISHED && s->last_ns == 100,
          "stale observation changes neither state nor time");
    d2k_session_tracker_remove(t,D2K_TRACKER_TCP,&k);
    s = d2k_session_tracker_udp(t,&k,UINT64_MAX-5);
    CHECK(d2k_session_tracker_udp(t,&k,UINT64_MAX-6) == s,"old UDP touch");
    CHECK(s && s->last_ns == UINT64_MAX-5,"old touch cannot regress timestamp");
    s = d2k_session_tracker_udp(t,&k,UINT64_MAX-2);
    CHECK(d2k_session_tracker_expire(t,UINT64_MAX) == 0,"touch refresh at clock limit");
    d2k_session_tracker_free(t);
}

static void churn(void) {
    d2k_session_tracker *t = d2k_session_tracker_new(16,NULL);
    CHECK(t != NULL,"churn tracker"); if (!t) return;
    uint8_t present[64] = {0};
    size_t count = 0;
    uint32_t rng = 1234;
    for (unsigned step = 0; step < 2000; step++) {
        rng = rng * UINT32_C(1664525) + UINT32_C(1013904223);
        unsigned i = (rng >> 16) % 64;
        d2k_key k = key(i % 2 ? 6 : 4,(uint16_t)(2000+i),0);
        if (rng & UINT32_C(0x80000000)) {
            int removed = d2k_session_tracker_remove(t,D2K_TRACKER_UDP,&k);
            CHECK(removed == present[i],"churn delete agrees with model");
            if (present[i]) { present[i] = 0; count--; }
        } else {
            const d2k_tracked_session *s = d2k_session_tracker_udp(t,&k,step);
            CHECK((s != NULL) == (present[i] || count < 16),"churn bounded insert");
            if (s && !present[i]) { present[i] = 1; count++; }
        }
        CHECK(d2k_session_tracker_count(t) == count,"churn count agrees with model");
        for (unsigned j = 0; j < 64; j++) {
            d2k_key r = key(j % 2 ? 6 : 4,(uint16_t)(2000+j),1);
            CHECK((d2k_session_tracker_find(t,D2K_TRACKER_UDP,&r) != NULL) == present[j],
                  "churn preserves bucket chains and reverse matching");
        }
    }
    CHECK(d2k_session_tracker_expire(t,UINT64_MAX) == count,"expire entire chained table");
    CHECK(d2k_session_tracker_count(t) == 0,"all slots recovered");
    d2k_session_tracker_free(t);
}

static void invalid(void) {
    d2k_tracker_timeouts v; d2k_session_tracker_defaults(&v);
    CHECK(v.udp_idle_ns > 0,"default UDP timeout");
    CHECK(!d2k_session_tracker_new(0,NULL),"zero capacity rejected");
    CHECK(!d2k_session_tracker_new(SIZE_MAX,NULL),"capacity overflow rejected");
    v.udp_idle_ns = 0;
    CHECK(!d2k_session_tracker_new(1,&v),"zero timeout rejected");
    d2k_session_tracker *t = d2k_session_tracker_new(1,NULL);
    CHECK(t != NULL,"invalid tracker"); if (!t) return;
    d2k_key k = key(4,1234,0), bad = k; bad.family = 3;
    CHECK(!d2k_session_tracker_add(t,1,&k,0),"unsupported protocol");
    CHECK(!d2k_session_tracker_udp(t,&bad,0),"bad address family");
    CHECK(!d2k_session_tracker_udp(t,NULL,0),"null key");
    CHECK(!d2k_session_tracker_tcp(t,&k,NULL,0),"null observation");
    CHECK(!tcp(t,&k,2,D2K_TCP_SYN,0,0,0,0),"invalid direction");
    CHECK(!tcp(t,&k,1,D2K_TCP_SYN|D2K_TCP_FIN,0,0,0,0),"contradictory SYN/FIN");
    CHECK(!tcp(t,&k,1,D2K_TCP_SYN|D2K_TCP_RESET,0,0,0,0),"contradictory SYN/RST");
    CHECK(!tcp(t,&k,1,D2K_TCP_SYN,0,0,UINT32_MAX,0),"sequence length bound");
    CHECK(d2k_session_tracker_count(t) == 0,"invalid input never allocates a slot");
    CHECK(d2k_session_tracker_refusals(t) == 0,"invalid input is not capacity refusal");
    CHECK(d2k_session_tracker_capacity(t) == 1,"hard capacity");
    d2k_session_tracker_free(t); d2k_session_tracker_free(NULL);
    CHECK(!d2k_session_tracker_find(NULL,6,&k),"null find");
    CHECK(!d2k_session_tracker_udp(NULL,&k,0),"null update");
    CHECK(!d2k_session_tracker_remove(NULL,6,&k),"null remove");
    CHECK(d2k_session_tracker_count(NULL) == 0 && d2k_session_tracker_capacity(NULL) == 0 &&
          d2k_session_tracker_refusals(NULL) == 0 && d2k_session_tracker_expire(NULL,0) == 0,
          "null introspection");
}

int main(void) {
    for (int family = 4; family <= 6; family += 2)
        for (int initiator = 0; initiator <= 1; initiator++)
            for (int passive = 0; passive <= 1; passive++) lifecycle(family,initiator,passive);
    handshake_edges(); table_and_udp(); timeouts(); churn(); invalid();
    if (fails) { printf("session tracker: %d failures\n",fails); return 1; }
    puts("session tracker: PASS (dual-stack TCP/UDP, handshake, FIN/RST, expiry, bounded churn)");
    return 0;
}
