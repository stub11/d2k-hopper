/* Real portable C packet pipeline + existing AF_UNIX event transport.
 * stdin carries complete raw IP packets as hex; stdout carries verdicts.
 * Test harness only, never part of the router daemon. */
#include "nfqueue_handler.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <inttypes.h>
#include <signal.h>
static int digit(char c) {
    if (c>='0' && c<='9') return c-'0';
    if (c>='a' && c<='f') return c-'a'+10;
    if (c>='A' && c<='F') return c-'A'+10;
    return -1;
}
int main(int argc, char **argv) {
    if (argc!=3) return 2;
    signal(SIGPIPE,SIG_IGN);
    char err[200]; d2k_ctl *ctl=d2k_ctl_open(argv[1],err,sizeof err);
    if (!ctl) { fprintf(stderr,"%s\n",err); return 1; }
    const d2k_tracker_timeouts limits={50,50,50,5,50};
    d2k_pipeline *p=d2k_pipeline_new(16,64,strcmp(argv[2],"enforce")==0,&limits);
    if (!p) { d2k_ctl_close(ctl); return 1; }
    puts("ready"); fflush(stdout);
    char line[131200]; uint8_t packet[65536];
    while (fgets(line,sizeof line,stdin)) {
        if (strcmp(line,"quit\n")==0) break;
        d2k_ctl_accept(ctl);
        if (strncmp(line,"packet ",7)!=0 && strncmp(line,"expire ",7)!=0) {
            puts("error"); fflush(stdout); continue;
        }
        d2k_pipeline_result r={D2K_NF_ACCEPT,D2K_PIPE_BYPASS,0,0};
        char *end; unsigned long long now=strtoull(line+7,&end,10);
        if (strncmp(line,"packet ",7)==0 && end!=line+7 && *end==' ') {
            char *hex=end+1; size_t len=strcspn(hex,"\r\n");
            if (len%2 || len/2>sizeof packet) { puts("error"); fflush(stdout); continue; }
            int valid=1;
            for (size_t i=0;i<len/2;i++) {
                int hi=digit(hex[i*2]),lo=digit(hex[i*2+1]);
                if (hi<0 || lo<0) { valid=0; break; }
                packet[i]=(uint8_t)(hi*16+lo);
            }
            if (!valid) { puts("error"); fflush(stdout); continue; }
            r=d2k_nfqueue_handle(p,packet,len/2,(uint64_t)now);
        } else if (strncmp(line,"expire ",7)==0 && end!=line+7) {
            d2k_pipeline_expire(p,(uint64_t)now);
        } else { puts("error"); fflush(stdout); continue; }
        size_t events=d2k_pipeline_pending(p);
        if (d2k_ctl_peer_fd(ctl)<0) { puts("error");fflush(stdout);continue; }
        d2k_pipeline_pump(p,ctl);
        d2k_ctl_flush(ctl);
        printf("%u %u %u %zu %zu %" PRIu64 "\n",r.verdict,r.state,(unsigned)r.reason,
            events,d2k_pipeline_count(p),d2k_pipeline_event_drops(p)); fflush(stdout);
    }
    d2k_pipeline_free(p); d2k_ctl_close(ctl); return 0;
}
