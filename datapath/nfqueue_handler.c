#include "nfqueue_handler.h"
d2k_pipeline_result d2k_nfqueue_handle(d2k_pipeline *p,
    const uint8_t *payload, size_t len, uint64_t now) {
    return d2k_pipeline_packet(p,payload,len,now);
}
#ifdef D2K_WITH_LIBNFQ
#include <arpa/inet.h>
#include <libnetfilter_queue/libnetfilter_queue.h>
int d2k_nfq_callback(struct nfq_q_handle *qh, struct nfgenmsg *msg,
                     struct nfq_data *data, void *opaque) {
    (void)msg;
    d2k_nfq_callback_ctx *ctx=opaque;
    struct nfqnl_msg_packet_hdr *hdr=nfq_get_msg_packet_hdr(data);
    if (!hdr || !ctx || !ctx->pipeline || !ctx->now_ns) return -1;
    uint8_t *payload=NULL; int len=nfq_get_payload(data,&payload);
    /* Metadata-only captures fail open. Full-copy mode is required for strict
     * policy: advertised IP length is validated before state mutation. */
    d2k_pipeline_result r={D2K_NF_ACCEPT,D2K_PIPE_BYPASS,0,0};
    if (len>0) r=d2k_nfqueue_handle(ctx->pipeline,payload,(size_t)len,ctx->now_ns(ctx->clock_ctx));
    ctx->last_result=r; ctx->last_packet_id=ntohl(hdr->packet_id);
    int rc=nfq_set_verdict(qh,ntohl(hdr->packet_id),r.verdict,0,NULL);
    if (rc<0 && ctx->verdict_failures!=UINT64_MAX) ctx->verdict_failures++;
    return rc;
}
#endif
