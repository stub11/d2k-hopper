#include "d2k_pipeline.h"
#include <stdlib.h>
#include <string.h>

struct d2k_pipeline {
    d2k_session_tracker *tracker;
    d2k_session_event *events;
    size_t cap, head, count;
    uint64_t sequence, dropped;
    int enforce;
    d2k_tracked_session *snapshot;
    size_t snapshot_capacity, snapshot_count, snapshot_cursor;
    uint64_t dump_id, dump_cut, watermark;
    unsigned dump_phase;

};
static void increment(uint64_t *n) { if (*n != UINT64_MAX) (*n)++; }
static uint16_t be16(const uint8_t *p) { return (uint16_t)((uint16_t)p[0]<<8 | p[1]); }
static uint32_t be32(const uint8_t *p) {
    return (uint32_t)p[0]<<24 | (uint32_t)p[1]<<16 | (uint32_t)p[2]<<8 | p[3];
}
static void put64(uint8_t *p, uint64_t n) {
    for (unsigned i=0; i<8; i++) { p[7-i]=(uint8_t)n; n >>= 8; }
}
static void emit(d2k_pipeline *p, uint16_t type, const d2k_tracked_session *s,
                 uint8_t old, uint8_t next, uint8_t reason, uint64_t now) {
    if (p->sequence == UINT64_MAX) { increment(&p->dropped); return; }
    p->sequence++;
    if (p->count == p->cap) { increment(&p->dropped); return; }
    size_t tail = (p->head + p->count) % p->cap;
    d2k_session_event *e = &p->events[tail];
    memset(e,0,sizeof *e); e->type=type; e->key=s->key; e->protocol=s->protocol;
    e->at_ns=now; e->old_state=old; e->new_state=next; e->reason=reason;
    e->sequence=p->sequence; e->dropped=p->dropped; p->count++;
}
d2k_pipeline *d2k_pipeline_new(size_t capacity, size_t events, int enforce,
                               const d2k_tracker_timeouts *timeouts) {
    if (!events || events > SIZE_MAX/sizeof(d2k_session_event) || events > SIZE_MAX/2 ||
        capacity > SIZE_MAX/sizeof(d2k_tracked_session))
        return NULL;
    d2k_pipeline *p=calloc(1,sizeof *p);
    if (!p) return NULL;
    p->tracker=d2k_session_tracker_new(capacity,timeouts);
    p->events=calloc(events,sizeof *p->events);
    p->snapshot=calloc(capacity,sizeof *p->snapshot);
    p->snapshot_capacity=capacity; p->watermark=UINT64_MAX;
    if (!p->tracker || !p->events || !p->snapshot) { d2k_pipeline_free(p); return NULL; }
    p->cap=events; p->enforce=!!enforce; return p;
}
void d2k_pipeline_free(d2k_pipeline *p) {
    if (!p) return;
    d2k_session_tracker_free(p->tracker); free(p->events); free(p->snapshot); free(p);
}

/* 1 = validated transport, 0 = unsupported/fragment bypass, -1 = malformed.
 * Read wire bytes only: unaligned packets are valid input on MIPS as well.
 * IP fragmentation is not reassembled here and must not seed a partial flow. */
static int transport(const uint8_t *b, size_t n, d2k_key *key,
                     uint8_t *proto, d2k_tcp_observation *tcp) {
    if (!b || !n) return -1;
    size_t off, end; int family; const uint8_t *src, *dst;
    if ((b[0]>>4)==4) {
        if (n<20) return -1;
        off=(size_t)(b[0]&15)*4; end=be16(b+2);
        if (off<20 || off>end || end>n) return -1;
        if (be16(b+6)&0x3fff) return 0;
        *proto=b[9]; family=4; src=b+12; dst=b+16;
    } else if ((b[0]>>4)==6) {
        if (n<40) return -1;
        end=40+(size_t)be16(b+4); if (end>n) return -1;
        *proto=b[6]; off=40; family=6; src=b+8; dst=b+24;
        unsigned extensions=0;
        while (*proto==0 || *proto==43 || *proto==60 || *proto==44 || *proto==51) {
            if (++extensions>8 || end-off<8) return -1;
            size_t size;
            if (*proto==44) return 0; /* includes first/atomic fragments */
            if (*proto==51) return 0; /* AH/IPsec is not this policy's scope */
            size=((size_t)b[off+1]+1)*8;
            if (size>end-off) return -1;
            *proto=b[off]; off+=size;
        }
    } else return -1;
    if (*proto!=6 && *proto!=17) return 0;
    size_t need=*proto==6 ? 20 : 8;
    if (end-off<need) return -1;
    size_t hdr;
    if (*proto==6) {
        hdr=(size_t)(b[off+12]>>4)*4;
        if (hdr<20 || hdr>end-off) return -1;
        tcp->flags=b[off+13]; tcp->seq=be32(b+off+4); tcp->ack=be32(b+off+8);
        tcp->payload_len=(uint32_t)(end-off-hdr);
    } else {
        hdr=be16(b+off+4); if (hdr<8 || hdr!=end-off) return -1;
    }
    tcp->src_is_low=(uint8_t)(family==4 ?
        d2k_key_make(key,src,dst,b+off,b+off+2) :
        d2k_key_make6(key,src,dst,b+off,b+off+2));
    return 1;
}
static enum d2k_pipeline_reason policy(const d2k_tracked_session *s,
                                      const d2k_tcp_observation *o) {
    uint8_t f=o->flags;
    if ((f&D2K_TCP_SYN) && (f&(D2K_TCP_FIN|D2K_TCP_RESET))) return D2K_PIPE_FLAGS;
    if ((f&D2K_TCP_FIN) && (f&D2K_TCP_RESET)) return D2K_PIPE_FLAGS;
    if (!(f&(D2K_TCP_SYN|D2K_TCP_ACK|D2K_TCP_RESET)) ||
        ((f&(D2K_TCP_FIN|0x08)) && !(f&D2K_TCP_ACK))) return D2K_PIPE_FLAGS;
    int terminal=s && (s->tcp_state==D2K_TCP_CLOSED || s->tcp_state==D2K_TCP_RST);
    if (terminal && (f&(D2K_TCP_SYN|D2K_TCP_ACK))!=D2K_TCP_SYN) return D2K_PIPE_TERMINAL;
    if (terminal) s=NULL; /* fresh bare SYN can reuse a terminal tuple */
    unsigned side=o->src_is_low ? 0u : 1u, peer=side^1u;
    uint8_t peer_bit=(uint8_t)(1u<<peer);
    if ((f&(D2K_TCP_SYN|D2K_TCP_ACK))==(D2K_TCP_SYN|D2K_TCP_ACK) &&
        (!s || !(s->syn_seen&peer_bit) || o->ack!=s->syn_end[peer])) return D2K_PIPE_BAD_ACK;
    if ((f&D2K_TCP_ACK) && s && s->tcp_state<D2K_TCP_ESTABLISHED &&
        (s->syn_seen&peer_bit) && o->ack!=s->syn_end[peer]) return D2K_PIPE_BAD_ACK;
    if (s && s->tcp_state>=D2K_TCP_ESTABLISHED && (f&D2K_TCP_SYN) &&
        (!(s->syn_seen&(1u<<side)) || s->syn_end[side]!=o->seq+o->payload_len+UINT32_C(1)))
        return D2K_PIPE_FLAGS;
    int established=s && s->tcp_state>=D2K_TCP_ESTABLISHED;
    int establishes=s && s->syn_seen==3 && (f&D2K_TCP_ACK) &&
        o->ack==s->syn_end[peer] && (s->syn_acked|peer_bit)==3;
    if ((o->payload_len || (f&D2K_TCP_FIN)) && !established && !establishes)
        return D2K_PIPE_PRE_HANDSHAKE;
    if (s && o->payload_len && (s->fin_seen&(1u<<side))) return D2K_PIPE_TERMINAL;
    return D2K_PIPE_OK;
}
d2k_pipeline_result d2k_pipeline_packet(d2k_pipeline *p, const uint8_t *b,
                                      size_t n, uint64_t now) {
    d2k_pipeline_result r={D2K_NF_ACCEPT,D2K_PIPE_BYPASS,0,0};
    if (!p) return r;
    d2k_key key; d2k_tcp_observation o; memset(&o,0,sizeof o); uint8_t proto=0;
    int parsed=transport(b,n,&key,&proto,&o);
    if (parsed<=0) {
        if (parsed<0) { r.reason=D2K_PIPE_MALFORMED; if (p->enforce) r.verdict=D2K_NF_DROP; }
        return r;
    }
    const d2k_tracked_session *before=d2k_session_tracker_find(p->tracker,proto,&key);
    if (before && now<before->last_ns) { r.reason=D2K_PIPE_STALE; return r; }
    if (proto==6) {
        r.reason=policy(before,&o);
        if (r.reason!=D2K_PIPE_OK && p->enforce) { r.verdict=D2K_NF_DROP; return r; }
        /* Invalid flag sets cannot seed observation records either. */
        if (r.reason==D2K_PIPE_FLAGS) return r;
    } else r.reason=D2K_PIPE_OK;
    uint8_t old=before ? (uint8_t)before->tcp_state : D2K_TCP_UNKNOWN;
    int created=!before || (proto==6 && (old==D2K_TCP_CLOSED || old==D2K_TCP_RST) &&
        (o.flags&(D2K_TCP_SYN|D2K_TCP_ACK))==D2K_TCP_SYN);
    const d2k_tracked_session *s=proto==6 ?
        d2k_session_tracker_tcp(p->tracker,&key,&o,now) :
        d2k_session_tracker_udp(p->tracker,&key,now);
    if (!s) { r.reason=D2K_PIPE_CAPACITY; return r; } /* fail-open on resource refusal */
    r.tracked=1; r.state=(uint8_t)s->tcp_state;
    if (created) {
        old=D2K_TCP_UNKNOWN;
        emit(p,EVENT_SESSION_CREATED,s,old,old,D2K_CLOSE_NONE,now);
    }
    if (proto==6 && old!=s->tcp_state) {
        emit(p,EVENT_STATE_CHANGED,s,old,(uint8_t)s->tcp_state,D2K_CLOSE_NONE,now);
        if (s->tcp_state==D2K_TCP_CLOSED || s->tcp_state==D2K_TCP_RST)
            emit(p,EVENT_SESSION_CLOSED,s,old,(uint8_t)s->tcp_state,
                 s->tcp_state==D2K_TCP_RST ? D2K_CLOSE_RST : D2K_CLOSE_FIN,now);
    }
    return r;
}
static void expired(void *ctx, const d2k_tracked_session *s, uint64_t now) {
    /* FIN/RST already produced CLOSED; terminal retention expiry is removal,
     * not a second close event. UDP has no TCP state. */
    if (s->tcp_state!=D2K_TCP_CLOSED && s->tcp_state!=D2K_TCP_RST)
        emit(ctx,EVENT_SESSION_CLOSED,s,(uint8_t)s->tcp_state,
             s->protocol==6 ? D2K_TCP_CLOSED : D2K_TCP_UNKNOWN,D2K_CLOSE_TIMEOUT,now);
}
size_t d2k_pipeline_expire(d2k_pipeline *p, uint64_t now) {
    return p ? d2k_session_tracker_expire_notify(p->tracker,now,expired,p) : 0;
}
int d2k_pipeline_pop(d2k_pipeline *p, d2k_session_event *e) {
    if (!p || !e || !p->count) return 0;
    *e=p->events[p->head]; p->head=(p->head+1)%p->cap; p->count--; return 1;
}
size_t d2k_pipeline_count(const d2k_pipeline *p) { return p ? d2k_session_tracker_count(p->tracker) : 0; }
size_t d2k_pipeline_pending(const d2k_pipeline *p) { return p ? p->count : 0; }
uint64_t d2k_pipeline_event_drops(const d2k_pipeline *p) { return p ? p->dropped : 0; }
uint64_t d2k_pipeline_refusals(const d2k_pipeline *p) { return p ? d2k_session_tracker_refusals(p->tracker) : 0; }
void d2k_session_event_encode(const d2k_session_event *e, uint8_t b[D2K_SESSION_EVENT_LEN]) {
    memset(b,0,D2K_SESSION_EVENT_LEN);
    b[0]=D2K_SESSION_EVENT_VERSION; b[1]=e->key.family; b[2]=e->protocol;
    b[3]=e->old_state; b[4]=e->new_state; b[5]=e->reason;
    put64(b+8,e->at_ns); put64(b+16,e->sequence);
    b[24]=e->key.family;
    size_t addr=e->key.family==4 ? 4 : 16;
    memcpy(b+28,&e->key.low_addr,addr); memcpy(b+44,&e->key.high_addr,addr);
    memcpy(b+60,&e->key.low_port,2); memcpy(b+62,&e->key.high_port,2);
    put64(b+64,e->dropped);
}
static void put32(uint8_t *b, uint32_t n) {
    b[0]=(uint8_t)(n>>24); b[1]=(uint8_t)(n>>16); b[2]=(uint8_t)(n>>8); b[3]=(uint8_t)n;
}
void d2k_snapshot_record_encode(const d2k_tracked_session *s, uint8_t b[D2K_DUMP_RECORD_LEN]) {
    memset(b,0,D2K_DUMP_RECORD_LEN); b[0]=s->key.family;
    size_t addr=s->key.family==4 ? 4 : 16;
    memcpy(b+4,&s->key.low_addr,addr); memcpy(b+20,&s->key.high_addr,addr);
    memcpy(b+36,&s->key.low_port,2); memcpy(b+38,&s->key.high_port,2);
    b[40]=s->protocol; b[41]=(uint8_t)s->tcp_state;
    b[42]=s->initiator_low; b[43]=s->role_known; b[44]=s->syn_seen;
    b[45]=s->syn_acked; b[46]=s->fin_seen; b[47]=s->fin_acked;
    put64(b+48,s->first_ns); put64(b+56,s->last_ns);
    for (unsigned i=0;i<2;i++) { put32(b+64+4*i,s->syn_end[i]); put32(b+72+4*i,s->fin_end[i]); }
}
static void capture(void *ctx, const d2k_tracked_session *s) {
    d2k_pipeline *p=ctx;
    if (p->snapshot_count<p->snapshot_capacity) p->snapshot[p->snapshot_count++]=*s;
}
int d2k_pipeline_dump_start(d2k_pipeline *p, uint64_t id) {
    if (!p || !id || p->dump_phase) return 0;
    p->snapshot_count=p->snapshot_cursor=0;
    d2k_session_tracker_visit(p->tracker,capture,p);
    p->dump_id=id; p->dump_cut=p->sequence; p->dump_phase=1; return 1;
}
int d2k_pipeline_command(d2k_pipeline *p, uint16_t type, const uint8_t *b, size_t n) {
    if (type!=D2K_CMD_SESSION_DUMP) return 0;
    if (n!=16 || !b || b[0]!=1) return 1;
    for (unsigned i=1;i<8;i++) if (b[i]) return 1;
    uint64_t id=0; for (unsigned i=8;i<16;i++) id=(id<<8)|b[i];
    (void)d2k_pipeline_dump_start(p,id); return 1;
}
size_t d2k_pipeline_dump_count(const d2k_pipeline *p) { return p ? p->snapshot_count : 0; }
const d2k_tracked_session *d2k_pipeline_dump_at(const d2k_pipeline *p,size_t i) {
    return p && i<p->snapshot_count ? &p->snapshot[i] : NULL;
}
uint64_t d2k_pipeline_sequence(const d2k_pipeline *p) { return p ? p->sequence : 0; }
size_t d2k_pipeline_memory_bytes(const d2k_pipeline *p) {
    return p ? sizeof *p+d2k_session_tracker_memory_bytes(p->tracker)+
        p->cap*sizeof *p->events+p->snapshot_capacity*sizeof *p->snapshot : 0;
}
static void dump_header(uint8_t *b,uint64_t id,uint64_t seq,uint64_t aux) {
    memset(b,0,D2K_DUMP_HEADER_LEN); b[0]=1;
    put64(b+8,id); put64(b+16,seq); put64(b+24,aux);
}
void d2k_pipeline_pump(d2k_pipeline *p, d2k_ctl *ctl) {
    if (!p || !ctl) return;
    if (d2k_ctl_peer_fd(ctl)<0) { p->dump_phase=0; p->watermark=UINT64_MAX; return; }
    unsigned budget=32;
    while (p->dump_phase && budget>1) {
        budget--;
        uint8_t b[D2K_DUMP_ROW_LEN]; size_t len=D2K_DUMP_HEADER_LEN; uint16_t type;
        uint64_t aux=p->snapshot_count;
        if (p->dump_phase==1) type=EVENT_DUMP_BEGIN;
        else if (p->snapshot_cursor<p->snapshot_count) {
            type=EVENT_DUMP_ROW; aux=p->snapshot_cursor; len=sizeof b;
            d2k_snapshot_record_encode(&p->snapshot[p->snapshot_cursor],b+D2K_DUMP_HEADER_LEN);
        } else type=EVENT_DUMP_END;
        dump_header(b,p->dump_id,p->dump_cut,aux);
        if (d2k_ctl_try_event(ctl,type,b,len)!=1) return;
        if (type==EVENT_DUMP_BEGIN) p->dump_phase=2;
        else if (type==EVENT_DUMP_ROW) p->snapshot_cursor++;
        else { p->dump_phase=0; p->watermark=UINT64_MAX; }
    }
    if (p->dump_phase) return;
    /* Keep ring entries until accepted by the one-frame control buffer. */
    while (budget>1 && p->count) {
        budget--;
        uint8_t b[D2K_SESSION_EVENT_LEN]; d2k_session_event e=p->events[p->head];
        d2k_session_event_encode(&e,b);
        if (d2k_ctl_try_event(ctl,e.type,b,sizeof b)!=1) return;
        (void)d2k_pipeline_pop(p,&e);
    }
    /* Watermark catches loss at the TAIL even if no later event is produced. */
    if (!p->count && p->watermark!=p->sequence) {
        uint8_t b[D2K_DUMP_HEADER_LEN]; dump_header(b,0,p->sequence,p->dropped);
        if (d2k_ctl_try_event(ctl,EVENT_SESSION_WATERMARK,b,sizeof b)==1) p->watermark=p->sequence;
    }
}
