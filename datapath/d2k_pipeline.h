#ifndef D2K_PIPELINE_H
#define D2K_PIPELINE_H
#include "session_tracker.h"
#include "include/d2k_nl.h"
#include "include/d2k_ctl.h"

#define EVENT_SESSION_CREATED 0x0020
#define EVENT_STATE_CHANGED   0x0021
#define EVENT_SESSION_CLOSED  0x0022
#define D2K_SESSION_EVENT_VERSION 1
#define D2K_SESSION_EVENT_LEN 72
#define D2K_CMD_SESSION_DUMP 0x008a
#define EVENT_DUMP_BEGIN 0x0023
#define EVENT_DUMP_ROW 0x0024
#define EVENT_DUMP_END 0x0025
#define EVENT_SESSION_WATERMARK 0x0026
#define D2K_DUMP_HEADER_LEN 32
#define D2K_DUMP_RECORD_LEN 80
#define D2K_DUMP_ROW_LEN (D2K_DUMP_HEADER_LEN+D2K_DUMP_RECORD_LEN)
enum d2k_close_reason { D2K_CLOSE_NONE, D2K_CLOSE_FIN, D2K_CLOSE_RST, D2K_CLOSE_TIMEOUT };
enum d2k_pipeline_reason {
    D2K_PIPE_OK, D2K_PIPE_BYPASS, D2K_PIPE_MALFORMED,
    D2K_PIPE_FLAGS, D2K_PIPE_PRE_HANDSHAKE, D2K_PIPE_TERMINAL,
    D2K_PIPE_CAPACITY, D2K_PIPE_BAD_ACK, D2K_PIPE_STALE
};
typedef struct {
    uint16_t type;
    d2k_key key;
    uint64_t at_ns, sequence, dropped;
    uint8_t protocol, old_state, new_state, reason;
} d2k_session_event;
typedef struct {
    uint32_t verdict; /* NF_ACCEPT=1 / NF_DROP=0, not d2k_verdict */
    enum d2k_pipeline_reason reason;
    uint8_t state, tracked;
} d2k_pipeline_result;
typedef struct d2k_pipeline d2k_pipeline;
/* Fixed allocations at init, single owner. NULL timeouts uses tracker defaults.
 * enforce=0 observes without changing verdicts; enforce=1 is explicit strict
 * observed-handshake policy, not TCP window/checksum/RST authentication. */
d2k_pipeline *d2k_pipeline_new(size_t capacity, size_t event_capacity, int enforce,
                               const d2k_tracker_timeouts *timeouts);
void d2k_pipeline_free(d2k_pipeline *p);
d2k_pipeline_result d2k_pipeline_packet(d2k_pipeline *p, const uint8_t *packet,
                                      size_t len, uint64_t now_ns);
size_t d2k_pipeline_expire(d2k_pipeline *p, uint64_t now_ns);
int d2k_pipeline_pop(d2k_pipeline *p, d2k_session_event *event);
size_t d2k_pipeline_count(const d2k_pipeline *p);
size_t d2k_pipeline_pending(const d2k_pipeline *p);
uint64_t d2k_pipeline_event_drops(const d2k_pipeline *p);
uint64_t d2k_pipeline_refusals(const d2k_pipeline *p);
/* Explicit byte encoding: no native struct/padding on wire. */
void d2k_session_event_encode(const d2k_session_event *e,
                             uint8_t body[D2K_SESSION_EVENT_LEN]);
void d2k_pipeline_pump(d2k_pipeline *p, d2k_ctl *ctl);
/* Snapshot captures ALL records (including retained terminal sessions) at one
 * single-owner cut. Buffer allocated at pipeline init, never packet/command
 * allocation. Full dump is O(capacity); asynchronous sending is <=32 frames
 * per pump. A busy dump rejects restart; caller retries on bounded timeout. */
int d2k_pipeline_dump_start(d2k_pipeline *p, uint64_t request_id);
int d2k_pipeline_command(d2k_pipeline *p, uint16_t type, const uint8_t *body, size_t len);
size_t d2k_pipeline_dump_count(const d2k_pipeline *p);
const d2k_tracked_session *d2k_pipeline_dump_at(const d2k_pipeline *p, size_t index);
uint64_t d2k_pipeline_sequence(const d2k_pipeline *p);
size_t d2k_pipeline_memory_bytes(const d2k_pipeline *p);
void d2k_snapshot_record_encode(const d2k_tracked_session *s, uint8_t body[D2K_DUMP_RECORD_LEN]);
#endif
