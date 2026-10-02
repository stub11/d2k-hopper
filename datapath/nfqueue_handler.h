#ifndef D2K_NFQUEUE_HANDLER_H
#define D2K_NFQUEUE_HANDLER_H
#include "d2k_pipeline.h"
d2k_pipeline_result d2k_nfqueue_handle(d2k_pipeline *pipeline,
    const uint8_t *payload, size_t len, uint64_t now_ns);
#ifdef D2K_WITH_LIBNFQ
struct nfq_q_handle;
struct nfgenmsg;
struct nfq_data;
typedef struct {
    d2k_pipeline *pipeline;
    uint64_t (*now_ns)(void *);
    void *clock_ctx;
    uint64_t verdict_failures;
    d2k_pipeline_result last_result;
    uint32_t last_packet_id;
} d2k_nfq_callback_ctx;
int d2k_nfq_callback(struct nfq_q_handle *, struct nfgenmsg *, struct nfq_data *, void *);
#endif
#endif
