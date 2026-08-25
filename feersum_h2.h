/* feersum_h2.h - HTTP/2 support via nghttp2; TLS-only (no h2c) */

#ifndef FEERSUM_H2_H
#define FEERSUM_H2_H

#ifdef FEERSUM_HAS_H2

#ifndef FEERSUM_HAS_TLS
#error "FEERSUM_HAS_H2 requires FEERSUM_HAS_TLS (H2 is TLS-only)"
#endif

#include <nghttp2/nghttp2.h>

#define FEER_H2_MAX_CONCURRENT_STREAMS 100

#define FEER_H2_MAX_HEADER_LIST_SIZE (64 * 1024)

/* Rapid-reset guard: over this many peer RSTs within the window close the conn */
#define FEER_H2_RST_FLOOD_THRESHOLD 200
#define FEER_H2_RST_FLOOD_WINDOW    10.0

/* tls_wbuf cap: h2_send_cb returns WOULDBLOCK past it so frames stay queued and
 * nghttp2's own outbound-queue flood detection can fire */
#define FEER_H2_MAX_WBUF (16 * 1024 * 1024)

/* Silent read_timeout intervals with output pending before a conn counts as stalled */
#define FEER_H2_STALL_STRIKES 3

/* Stream back-pointer lives in pseudo_conn->read_ev_timer.data; NULL once freed */
#define H2_STREAM_FROM_PC(pc) \
    ((struct feer_h2_stream *)(pc)->read_ev_timer.data)

/* Only pointers to feer_conn / feer_req here: both types are still incomplete
 * at this include point */
struct feer_h2_stream {
    struct feer_h2_stream *next;
    struct feer_conn      *parent;      /* the real TLS connection */
    struct feer_conn      *pseudo_conn; /* fake feer_conn handed to Perl handlers */
    int32_t                stream_id;

    struct feer_req       *req;
    SV                    *body_buf;
    AV                    *trailers;    /* flat name/value pairs */

    SV *h2_method;
    SV *h2_path;
    SV *h2_scheme;
    SV *h2_authority;

    /* Extended CONNECT tunnel (RFC 8441) */
    SV *h2_protocol;
    unsigned int is_tunnel:1;
    unsigned int tunnel_established:1;
    unsigned int tunnel_swallow_response:1; /* swallow HTTP/1.1 response for PSGI transparency */
    unsigned int tunnel_pending_shutdown:1; /* DATA+END_STREAM arrived before tunnel_established */
    unsigned int tunnel_eof_sent:1;        /* shutdown(SHUT_WR) already done on sv[0] */

    int tunnel_sv0;                 /* internal end (Feersum ev_io) */
    int tunnel_sv1;                 /* handler end (psgix.io) */
    struct ev_io tunnel_read_w;     /* sv[0] readable: app wrote to sv[1] */
    struct ev_io tunnel_write_w;    /* sv[0] writable: drain tunnel_wbuf */
    SV *tunnel_wbuf;                /* H2 DATA pending write to sv[0] */
    size_t tunnel_wbuf_pos;

    SV                    *resp_body;       /* whole body for non-streaming responses */
    size_t                 resp_body_pos;
    SV                    *resp_wbuf;       /* streaming write buffer */
    size_t                 resp_wbuf_pos;
    SV                    *resp_message;    /* saved for deferred submit */
    SV                    *resp_headers;    /* saved for deferred submit */
    unsigned int           resp_eof:1;      /* streaming close() called */
    /* write() calls from poll_cb, zero-length ones included: the pump must tell
     * "wrote nothing" from "wrote an empty string" */
    unsigned int           writes_seen;
    unsigned int           rst_by_us:1;     /* server-initiated RST; exempt from the rapid-reset guard */
    unsigned int           body_overflow:1; /* body exceeded max_body_len; never dispatch */
    int                    limit_status;    /* nonzero: answer with this status instead of dispatching */
};

/* Prototypes taking struct feer_conn * live in feersum_core.h, after the struct */

#endif /* FEERSUM_HAS_H2 */
#endif /* FEERSUM_H2_H */
