#include "nfqueue_handler.h"
#include <stdio.h>
#include <string.h>
static int fails;
#define CHECK(c,m) do { if (!(c)) { printf("FAIL %s\n",m); fails++; } } while (0)
static void put16(uint8_t *p, unsigned v) { p[0]=(uint8_t)(v>>8);p[1]=(uint8_t)v; }
static void put32(uint8_t *p, uint32_t v) {
    p[0]=(uint8_t)(v>>24);p[1]=(uint8_t)(v>>16);p[2]=(uint8_t)(v>>8);p[3]=(uint8_t)v;
}
static size_t packet(uint8_t *b, int family, int reverse, int udp, unsigned flags,
                     uint32_t seq, uint32_t ack, size_t payload) {
    memset(b,0,128); size_t ip=family==4?20:40, l4=udp?8:20, n=ip+l4+payload;
    if (family==4) {
        b[0]=0x45;put16(b+2,(unsigned)n);b[9]=udp?17:6;
        b[12]=reverse?2:1;b[16]=reverse?1:2;
    } else {
        b[0]=0x60;put16(b+4,(unsigned)(n-40));b[6]=udp?17:6;
        b[8]=b[24]=0x20;b[23]=reverse?2:1;b[39]=reverse?1:2;
    }
    put16(b+ip,reverse?443:1234);put16(b+ip+2,reverse?1234:443);
    if (udp) put16(b+ip+4,(unsigned)(8+payload));
    else { put32(b+ip+4,seq);put32(b+ip+8,ack);b[ip+12]=0x50;b[ip+13]=(uint8_t)flags; }
    return n;
}
static d2k_pipeline_result feed_packet(d2k_pipeline *p,int family,int rev,int udp,
    unsigned flags,uint32_t seq,uint32_t ack,size_t data,uint64_t now) {
    uint8_t b[128];size_t n=packet(b,family,rev,udp,flags,seq,ack,data);
    return d2k_nfqueue_handle(p,b,n,now);
}
static void handshake(d2k_pipeline *p,int f,uint64_t now) {
    CHECK(feed_packet(p,f,0,0,D2K_TCP_SYN,100,0,0,now).state==D2K_TCP_SYN_SENT,"SYN state");
    CHECK(feed_packet(p,f,1,0,D2K_TCP_SYN|D2K_TCP_ACK,200,101,0,now+1).state==D2K_TCP_SYN_RECV,"SYNACK state");
    CHECK(feed_packet(p,f,0,0,D2K_TCP_ACK,101,201,0,now+2).state==D2K_TCP_ESTABLISHED,"ACK establishes");
}
static void lifecycle(int family) {
    d2k_pipeline *p=d2k_pipeline_new(8,64,1,NULL);
    CHECK(p,"pipeline init");if (!p) return;
    CHECK(feed_packet(p,family,0,0,D2K_TCP_ACK,101,201,5,0).verdict==D2K_NF_DROP,"midstream data drop");
    CHECK(d2k_pipeline_count(p)==0,"rejected data never creates session");
    CHECK(feed_packet(p,family,0,0,D2K_TCP_SYN|D2K_TCP_FIN,100,0,0,0).verdict==D2K_NF_DROP,"SYN FIN drop");
    CHECK(feed_packet(p,family,0,0,D2K_TCP_FIN|D2K_TCP_RESET,0,0,0,0).verdict==D2K_NF_DROP,"FIN RST drop");
    CHECK(feed_packet(p,family,0,0,D2K_TCP_SYN,100,0,0,1).verdict==D2K_NF_ACCEPT,"SYN accept");
    CHECK(feed_packet(p,family,1,0,D2K_TCP_SYN|D2K_TCP_ACK,200,102,0,2).verdict==D2K_NF_DROP,"bad SYN ACK");
    CHECK(feed_packet(p,family,0,0,D2K_TCP_ACK,101,201,2,2).verdict==D2K_NF_DROP,"early data drop");
    CHECK(feed_packet(p,family,1,0,D2K_TCP_SYN|D2K_TCP_ACK,200,101,0,3).state==D2K_TCP_SYN_RECV,"proper SYN ACK");
    CHECK(feed_packet(p,family,0,0,D2K_TCP_ACK,101,202,0,4).verdict==D2K_NF_DROP,"wrong final ACK");
    CHECK(feed_packet(p,family,0,0,D2K_TCP_ACK,101,201,5,5).state==D2K_TCP_ESTABLISHED,"final ACK with data");
    CHECK(feed_packet(p,family,1,0,D2K_TCP_ACK,201,106,5,6).verdict==D2K_NF_ACCEPT,"reverse data accept");
    CHECK(feed_packet(p,family,0,0,D2K_TCP_FIN|D2K_TCP_ACK,106,206,0,7).state==D2K_TCP_FIN_WAIT,"FIN wait");
    CHECK(feed_packet(p,family,1,0,D2K_TCP_ACK,206,107,0,8).state==D2K_TCP_FIN_WAIT,"half close not CLOSED");
    CHECK(feed_packet(p,family,1,0,D2K_TCP_FIN|D2K_TCP_ACK,206,107,0,9).state==D2K_TCP_FIN_WAIT,"second FIN");
    CHECK(feed_packet(p,family,0,0,D2K_TCP_ACK,107,207,0,10).state==D2K_TCP_CLOSED,"full FIN close");
    CHECK(feed_packet(p,family,0,0,D2K_TCP_ACK,107,207,5,11).verdict==D2K_NF_DROP,"closed data drop");
    unsigned created=0,changed=0,closed=0;uint64_t last=0;d2k_session_event e;
    while (d2k_pipeline_pop(p,&e)) {
        CHECK(e.sequence==last+1,"event ordering");last=e.sequence;
        CHECK(e.key.family==family && e.protocol==6,"event identity");
        created+=e.type==EVENT_SESSION_CREATED;changed+=e.type==EVENT_STATE_CHANGED;
        closed+=e.type==EVENT_SESSION_CLOSED;
        if (e.type==EVENT_SESSION_CLOSED) CHECK(e.reason==D2K_CLOSE_FIN,"FIN close reason");
        uint8_t wire[72];d2k_session_event_encode(&e,wire);
        CHECK(wire[0]==1 && wire[1]==family && wire[24]==family && wire[25]==0,"explicit key format");
    }
    CHECK(created==1 && changed==5 && closed==1,"exact lifecycle event counts");
    CHECK(feed_packet(p,family,0,0,D2K_TCP_SYN,300,0,0,12).state==D2K_TCP_SYN_SENT,"terminal tuple reuse");
    CHECK(feed_packet(p,family,1,0,D2K_TCP_RESET|D2K_TCP_ACK,0,301,0,13).state==D2K_TCP_RST,"RST close");
    unsigned resets=0;while(d2k_pipeline_pop(p,&e)) resets+=e.type==EVENT_SESSION_CLOSED && e.reason==D2K_CLOSE_RST;
    CHECK(resets==1,"one RST event");
    CHECK(d2k_pipeline_expire(p,UINT64_MAX)==1,"terminal retained then expired");
    CHECK(!d2k_pipeline_pop(p,&e),"no duplicate terminal close on retention expiry");
    d2k_pipeline_free(p);
}
static void bounds(void) {
    const d2k_tracker_timeouts limits={10,10,10,2,5};
    d2k_pipeline *p=d2k_pipeline_new(1,1,1,&limits);
    CHECK(p,"bounded init");if (!p)return;
    CHECK(feed_packet(p,4,0,1,0,0,0,5,10).tracked,"UDP creation");
    CHECK(feed_packet(p,4,1,1,0,0,0,5,11).tracked,"UDP reverse same slot");
    CHECK(d2k_pipeline_count(p)==1,"UDP bidirectional count");
    CHECK(feed_packet(p,6,0,1,0,0,0,0,11).verdict==D2K_NF_ACCEPT,"capacity fail-open");
    CHECK(d2k_pipeline_refusals(p)==1,"capacity refusal counted");
    CHECK(d2k_pipeline_expire(p,15)==0,"UDP idle refreshed");
    CHECK(d2k_pipeline_expire(p,16)==1,"UDP idle boundary");
    CHECK(d2k_pipeline_event_drops(p)==1,"full ring drop counted");
    d2k_session_event e;CHECK(d2k_pipeline_pop(p,&e) && e.sequence==1,"oldest ring event retained");
    feed_packet(p,6,0,1,0,0,0,0,17);CHECK(d2k_pipeline_pop(p,&e) && e.sequence==3 && e.dropped==1,"gap and loss counter visible");
    d2k_pipeline_free(p);
    p=d2k_pipeline_new(8,64,0,NULL);CHECK(p,"observe init");if(!p)return;
    CHECK(feed_packet(p,4,0,0,D2K_TCP_ACK,0,0,10,0).verdict==D2K_NF_ACCEPT,"observe preserves midstream traffic");
    uint8_t b[130];size_t n=packet(b,6,0,0,D2K_TCP_SYN,0,0,0);
    for(size_t cut=0;cut<n;cut++) CHECK(d2k_nfqueue_handle(p,b,cut,0).verdict==D2K_NF_ACCEPT,"observe malformed fail-open");
    d2k_pipeline_free(p);p=d2k_pipeline_new(8,64,1,NULL);CHECK(p,"strict bounds init");if(!p)return;
    for(size_t cut=0;cut<n;cut++) CHECK(d2k_nfqueue_handle(p,b,cut,0).verdict==D2K_NF_DROP,"strict malformed bounds");
    /* Unaligned complete packet, extensions, transport errors, fragments. */
    uint8_t aligned[128];n=packet(aligned,6,0,0,D2K_TCP_SYN,10,0,0);
    memcpy(b+1,aligned,n);CHECK(d2k_nfqueue_handle(p,b+1,n,1).tracked,"unaligned IPv6 reads");
    n=packet(b,6,0,1,0,0,0,2);b[6]=0;memmove(b+48,b+40,n-40);memset(b+40,0,8);b[40]=17;put16(b+4,(unsigned)(n-40+8));
    CHECK(d2k_nfqueue_handle(p,b,n+8,2).tracked,"IPv6 UDP extension header");
    b[6]=44;CHECK(d2k_nfqueue_handle(p,b,n+8,3).reason==D2K_PIPE_BYPASS,"fragments bypass without false session");
    n=packet(b,4,0,1,0,0,0,0);put16(b+24,7);
    CHECK(d2k_nfqueue_handle(p,b,n,4).verdict==D2K_NF_DROP,"bad UDP length");
    n=packet(b,4,0,0,D2K_TCP_SYN,0,0,0);b[32]=0x40;
    CHECK(d2k_nfqueue_handle(p,b,n,4).verdict==D2K_NF_DROP,"short TCP header");
    d2k_pipeline_free(p);
    CHECK(!d2k_pipeline_new(1,0,0,NULL),"zero ring rejected");
    CHECK(!d2k_pipeline_new(1,SIZE_MAX,0,NULL),"ring overflow rejected");
}
static void pressure(void) {
    d2k_pipeline *p=d2k_pipeline_new(2,8,1,NULL);CHECK(p,"pressure init");if(!p)return;
    d2k_session_event e;
    for(unsigned i=0;i<2000;i++) {
        handshake(p,i%2?4:6,(uint64_t)i*10);
        feed_packet(p,i%2?4:6,1,0,D2K_TCP_RESET,0,0,0,(uint64_t)i*10+3);
        while(d2k_pipeline_pop(p,&e)) {}
    }
    CHECK(d2k_pipeline_count(p)==2 && d2k_pipeline_event_drops(p)==0,"bounded load no event loss when drained");
    CHECK(d2k_pipeline_expire(p,UINT64_MAX)==2,"load cleanup");d2k_pipeline_free(p);
}
int main(void) {
    lifecycle(4);lifecycle(6);bounds();pressure();
    if(fails) return 1;
    puts("stateful pipeline: PASS (verdicts, dual-stack, events, bounds, pressure)");return 0;
}
