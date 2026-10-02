/* Component microbench; integer arithmetic only, no allocations in timed loops.
 * Reports raw elapsed ns and exact owned allocation bytes, not a router SLA. */
#define _POSIX_C_SOURCE 200809L
#include "d2k_pipeline.h"
#include <time.h>
#include <sys/resource.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <inttypes.h>

typedef struct { d2k_key key; uint8_t packet[48]; size_t len; } sample;
static volatile uint64_t sink;
static uint64_t now(void) {
    struct timespec ts;if(clock_gettime(CLOCK_MONOTONIC,&ts)!=0)abort();
    return (uint64_t)ts.tv_sec*UINT64_C(1000000000)+(uint64_t)ts.tv_nsec;
}
static void prepare(sample *s,size_t i) {
    memset(s,0,sizeof *s);uint8_t *b=s->packet;int family=(i&1) ? 6 : 4;
    size_t off=family==4 ? 20 : 40;s->len=off+8;
    uint32_t n=(uint32_t)i+2;
    if(family==4) {
        b[0]=0x45;b[3]=28;b[8]=64;b[9]=17;b[12]=b[16]=10;b[15]=1;
        b[17]=(uint8_t)(n>>16);b[18]=(uint8_t)(n>>8);b[19]=(uint8_t)n;
    } else {
        b[0]=0x60;b[5]=8;b[6]=17;b[7]=64;b[8]=b[24]=0x20;b[9]=b[25]=1;
        b[23]=1;b[36]=(uint8_t)(n>>24);b[37]=(uint8_t)(n>>16);b[38]=(uint8_t)(n>>8);b[39]=(uint8_t)n;
    }
    b[off]=0x04;b[off+1]=0xd2;b[off+3]=53;b[off+5]=8;
    if(family==4)d2k_key_make(&s->key,b+12,b+16,b+off,b+off+2);
    else d2k_key_make6(&s->key,b+8,b+24,b+off,b+off+2);
}
int main(int argc,char **argv) {
    size_t capacity=131072,iterations=1048576;
    if(argc>3)return 2;
    if(argc>1){char *end;unsigned long n=strtoul(argv[1],&end,10);if(*end || !n || n>1000000)return 2;capacity=(size_t)n;}
    if(argc>2){char *end;unsigned long n=strtoul(argv[2],&end,10);if(*end || !n || n>100000000)return 2;iterations=(size_t)n;}
    sample *samples=calloc(capacity,sizeof *samples);
    d2k_session_tracker *t=d2k_session_tracker_new(capacity,NULL);
    d2k_pipeline *p=d2k_pipeline_new(capacity,256,1,NULL);
    if(!samples || !t || !p){free(samples);d2k_session_tracker_free(t);d2k_pipeline_free(p);return 1;}
    for(size_t i=0;i<capacity;i++) {
        prepare(&samples[i],i);
        if(!d2k_session_tracker_udp(t,&samples[i].key,1) ||
           !d2k_pipeline_packet(p,samples[i].packet,samples[i].len,1).tracked)abort();
    }
    d2k_session_event event;while(d2k_pipeline_pop(p,&event)) {}
    if(d2k_session_tracker_count(t)!=capacity || d2k_pipeline_count(p)!=capacity)abort();
    printf("{\"sessions\":%zu,\"iterations\":%zu,\"rounds\":[",capacity,iterations);
    for(unsigned round=0;round<5;round++) {
        uint64_t sum=0,start=now();size_t idx=0;
        for(size_t i=0;i<iterations;i++) {idx=(idx+1009)%capacity;const d2k_tracked_session *s=d2k_session_tracker_find(t,17,&samples[idx].key);if(!s)abort();sum+=s->last_ns;}
        uint64_t lookup=now()-start;sink=sum;sum=0;idx=0;start=now();
        for(size_t i=0;i<iterations;i++) {idx=(idx+1009)%capacity;const d2k_tracked_session *s=d2k_session_tracker_udp(t,&samples[idx].key,2+round);if(!s)abort();sum+=s->last_ns;}
        uint64_t update=now()-start;sink=sum;sum=0;idx=0;start=now();
        for(size_t i=0;i<iterations;i++) {idx=(idx+1009)%capacity;d2k_pipeline_result r=d2k_pipeline_packet(p,samples[idx].packet,samples[idx].len,2+round);if(!r.tracked || r.verdict!=D2K_NF_ACCEPT)abort();sum+=r.tracked;}
        uint64_t packets=now()-start;sink=sum;
        printf("%s{\"lookup_ns\":%" PRIu64 ",\"update_ns\":%" PRIu64 ",\"pipeline_ns\":%" PRIu64 "}",round ? "," : "",lookup,update,packets);
    }
    struct rusage usage;if(getrusage(RUSAGE_SELF,&usage)!=0)abort();
    printf("],\"tracker_bytes\":%zu,\"pipeline_bytes\":%zu,\"record_bytes\":%zu,\"process_maxrss_kib\":%ld}\n",
        d2k_session_tracker_memory_bytes(t),d2k_pipeline_memory_bytes(p),sizeof(d2k_tracked_session),usage.ru_maxrss);
    free(samples);d2k_session_tracker_free(t);d2k_pipeline_free(p);return 0;
}
