#include "d2k_pipeline.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static void udp(uint8_t *b,int family,unsigned port) {
    memset(b,0,48);
    unsigned ip=family==4 ? 20 : 40;
    if (family==4) {b[0]=0x45;b[3]=28;b[9]=17;b[12]=10;b[15]=1;b[16]=10;b[19]=2;}
    else {b[0]=0x60;b[5]=8;b[6]=17;b[8]=b[24]=0x20;b[9]=b[25]=1;b[23]=1;b[39]=2;}
    b[ip]=(uint8_t)(port>>8);b[ip+1]=(uint8_t)port;b[ip+3]=53;b[ip+5]=8;
}
static uint64_t u64(const uint8_t *b) {uint64_t n=0;for(unsigned i=0;i<8;i++)n=(n<<8)|b[i];return n;}
int main(void) {
    d2k_pipeline *p=d2k_pipeline_new(4,1,1,NULL);assert(p);
    uint8_t b[48];udp(b,4,1000);assert(d2k_pipeline_packet(p,b,28,10).tracked);
    udp(b,6,1001);assert(d2k_pipeline_packet(p,b,48,11).tracked);
    assert(d2k_pipeline_sequence(p)==2 && d2k_pipeline_event_drops(p)==1);
    assert(d2k_pipeline_dump_start(p,7));assert(!d2k_pipeline_dump_start(p,8));
    assert(d2k_pipeline_dump_count(p)==2);
    udp(b,4,1000);d2k_pipeline_packet(p,b,28,12);
    udp(b,4,1002);d2k_pipeline_packet(p,b,28,13);
    assert(d2k_pipeline_count(p)==3 && d2k_pipeline_dump_count(p)==2);
    for(size_t i=0;i<2;i++) {
        const d2k_tracked_session *s=d2k_pipeline_dump_at(p,i);assert(s);
        uint8_t wire[D2K_DUMP_RECORD_LEN];d2k_snapshot_record_encode(s,wire);
        assert(wire[0]==s->key.family && wire[40]==17 && wire[41]==0);
        assert(wire[1]==0 && wire[2]==0 && wire[3]==0);
        assert(u64(wire+48)==s->first_ns && u64(wire+56)==s->last_ns);
        assert(s->last_ns<=11); /* mutation after cut never leaks into dump */
    }
    assert(!d2k_pipeline_dump_at(p,2));
    assert(d2k_pipeline_memory_bytes(p)>4*sizeof(d2k_tracked_session));
    d2k_pipeline_free(p);
    assert(!d2k_pipeline_new(SIZE_MAX,1,1,NULL));
    puts("session resync: PASS (real ring loss, immutable full snapshot, metadata, bounds)");
    return 0;
}
