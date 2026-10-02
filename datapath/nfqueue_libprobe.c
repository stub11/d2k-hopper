/* Isolated Linux integration lab: real libnetfilter_queue callback/verdicts.
 * Not a replacement router daemon; do not install this test harness. */
#include "nfqueue_handler.h"
#include <libnetfilter_queue/libnetfilter_queue.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/socket.h>
#include <poll.h>
#include <inttypes.h>
#include <errno.h>
#include <signal.h>
static volatile sig_atomic_t stopped;
static void stop(int sig) {(void)sig;stopped=1;}
typedef struct { d2k_nfq_callback_ctx callback; unsigned packets; } lab;
static uint64_t monotonic(void *opaque) {
    (void)opaque;struct timespec ts;
    if(clock_gettime(CLOCK_MONOTONIC,&ts)!=0) abort();
    return (uint64_t)ts.tv_sec*UINT64_C(1000000000)+(uint64_t)ts.tv_nsec;
}
static int callback(struct nfq_q_handle *q,struct nfgenmsg *msg,struct nfq_data *data,void *opaque) {
    lab *l=opaque;int rc=d2k_nfq_callback(q,msg,data,&l->callback);
    if(rc<0)return rc;
    d2k_pipeline_result r=l->callback.last_result;
    printf("V %u %u %u %u\n",l->callback.last_packet_id,r.verdict,r.state,(unsigned)r.reason);
    d2k_session_event e;
    while(d2k_pipeline_pop(l->callback.pipeline,&e)) {
        printf("E %u %u %u %u %u %" PRIu64 "\n",e.type,e.protocol,e.new_state,e.reason,e.key.family,e.sequence);
        uint8_t body[D2K_SESSION_EVENT_LEN];d2k_session_event_encode(&e,body);
        printf("EV %u ",e.type);for(size_t i=0;i<sizeof body;i++)printf("%02x",body[i]);puts("");
    }
    l->packets++;fflush(stdout);return rc;
}
int main(int argc,char **argv) {
    if(argc!=3)return 2;
    char *end;unsigned long queue=strtoul(argv[1],&end,10);
    if(*end || queue>65535)return 2;
    unsigned long count=strtoul(argv[2],&end,10);if(*end || count>10000)return 2;
    signal(SIGTERM,stop);signal(SIGINT,stop);
    lab l;memset(&l,0,sizeof l);l.callback.now_ns=monotonic;
    l.callback.pipeline=d2k_pipeline_new(64,64,1,NULL);
    if(!l.callback.pipeline)return 1;
    struct nfq_handle *h=nfq_open();struct nfq_q_handle *q=NULL;int status=1;
    if(!h)goto out;
    /* Never unbind other consumers or change firewall rules here. */
    q=nfq_create_queue(h,(uint16_t)queue,callback,&l);
    if(!q || nfq_set_mode(q,2,65535)<0 || nfq_set_queue_maxlen(q,128)<0 ||
       nfq_set_queue_flags(q,1,1)<0)goto out;
    puts("ready");fflush(stdout);
    uint8_t buf[131072];
    while(!stopped && (!count || l.packets<count)) {
        struct pollfd fd={nfq_fd(h),POLLIN,0};
        int rc=poll(&fd,1,count ? 10000 : 100);if(rc<0 && errno==EINTR)continue;
        if(!count && rc==0)continue;
        if(rc<=0)goto out;
        ssize_t n=recv(fd.fd,buf,sizeof buf,0);
        if(n<=0 || nfq_handle_packet(h,(char *)buf,(int)n)<0)goto out;
    }
    if(l.callback.verdict_failures || d2k_pipeline_event_drops(l.callback.pipeline))goto out;
    if(!count) {
        if(!d2k_pipeline_dump_start(l.callback.pipeline,1))goto out;
        printf("CUT %" PRIu64 "\n",d2k_pipeline_sequence(l.callback.pipeline));
        for(size_t i=0;i<d2k_pipeline_dump_count(l.callback.pipeline);i++) {
            uint8_t body[D2K_DUMP_RECORD_LEN];
            d2k_snapshot_record_encode(d2k_pipeline_dump_at(l.callback.pipeline,i),body);
            printf("ROW ");for(size_t j=0;j<sizeof body;j++)printf("%02x",body[j]);puts("");
        }
        fflush(stdout);
    }
    status=0;
out:
    if(status)fprintf(stderr,"NFQUEUE lab failed: %s, packets=%u\n",strerror(errno),l.packets);
    if(q)nfq_destroy_queue(q);
    if(h)nfq_close(h);
    d2k_pipeline_free(l.callback.pipeline);return status;
}
