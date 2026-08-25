#ifndef FEERSUM_CORE_H
#define FEERSUM_CORE_H

#include "EVAPI.h"

#define PERL_NO_GET_CONTEXT
#include "ppport.h"
#include <stdbool.h>
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/ip.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <sys/uio.h>
#include <sys/stat.h>
#include <time.h>
#include <stdarg.h>
#include <sys/ioctl.h>
#ifdef __linux__
#include <sys/sendfile.h>
#endif

/* Kernel send-queue depth for the write deadline's drain check.  NetBSD is
 * excluded: with FIONWRITE the deadline never fires there. */
#if (defined(__linux__) && defined(TIOCOUTQ)) || defined(SO_NWRITE) \
 || (defined(FIONWRITE) && !defined(__NetBSD__))
# define FEERSUM_HAS_OUTQ 1
#endif

#ifdef FEERSUM_HAS_TLS
#include "feersum_tls.h"
#endif
#ifdef FEERSUM_HAS_H2
#include "feersum_h2.h"
#endif
#include "picohttpparser-git/picohttpparser.h"

///////////////////////////////////////////////////////////////
// constants

#define FEER_MAX_LISTENERS 16
#ifndef MAX_HEADERS
# define MAX_HEADERS 64
#endif
#ifndef MAX_HEADER_NAME_LEN
# define MAX_HEADER_NAME_LEN 128
#endif
#ifndef MAX_URI_LEN
# define MAX_URI_LEN 8192
#endif
#ifndef MAX_BODY_LEN
# define MAX_BODY_LEN 67108864
#endif
#ifndef MAX_CHUNK_COUNT
# define MAX_CHUNK_COUNT 100000
#endif
/* Cap on the upfront reservation for a declared Content-Length body. */
#ifndef BODY_PREGROW_MAX
# define BODY_PREGROW_MAX (64 * 1024)
#endif
/* One unterminated chunk-size / trailer line; nothing else bounds that phase. */
#ifndef MAX_CHUNK_SIZE_LINE
# define MAX_CHUNK_SIZE_LINE 1024
#endif
#ifndef MAX_TRAILER_LINE
# define MAX_TRAILER_LINE 8192
#endif
#ifndef MAX_TRAILER_HEADERS
# define MAX_TRAILER_HEADERS 64
#endif
#ifndef MAX_READ_BUF
# define MAX_READ_BUF 67108864
#endif

#define CHUNK_STATE_PARSE_SIZE  -1
#define CHUNK_STATE_NEED_CRLF   -3

#define READ_BUFSZ 4096
#define IO_PUMP_BUFSZ 4096
#define READ_GROW_FACTOR 4
#define READ_TIMEOUT 5.0
#define HEADER_TIMEOUT 10.0
#define WRITE_TIMEOUT 0.0
/* Lingering-close bounds: seconds total, bytes drained. */
#define LINGER_TIMEOUT 5.0
#define LINGER_MAX_BYTES (256 * 1024)
/* Linger cap on the shutdown path; a retiring worker waits on it. */
#define FEER_SHUTDOWN_LINGER_MAX 0.5
/* Pacing for a write poll_cb that declined: MIN * 2^backoff, clamped to MAX. */
#define FEER_POLL_RETRY_MIN 0.001
#define FEER_POLL_RETRY_MAX 0.1
#define FEER_POLL_RETRY_BACKOFF_CAP 7
#define DEFAULT_MAX_ACCEPT_PER_LOOP 64
#define MAX_PIPELINE_DEPTH 15
#define FEERSUM_IOMATRIX_SIZE 64

#define PROXY_V1_PREFIX "PROXY "
#define PROXY_V1_PREFIX_LEN 6
#define PROXY_V1_MAX_LINE 108

#define PROXY_V2_SIG "\x0D\x0A\x0D\x0A\x00\x0D\x0A\x51\x55\x49\x54\x0A"
#define PROXY_V2_SIG_LEN 12
#define PROXY_V2_HDR_MIN 16
#define PROXY_V2_ADDR_V4_LEN 12
#define PROXY_V2_ADDR_V6_LEN 36
#define PROXY_V2_ADDR_UNIX_LEN 216  /* 2 x 108-byte paths */
#define PROXY_V2_VERSION 0x20
#define PROXY_V2_CMD_LOCAL 0x00
#define PROXY_V2_CMD_PROXY 0x01
#define PROXY_V2_FAM_UNSPEC 0x00
#define PROXY_V2_FAM_INET 0x10
#define PROXY_V2_FAM_INET6 0x20
#define PROXY_V2_FAM_UNIX 0x30

#define PP2_TYPE_ALPN           0x01
#define PP2_TYPE_AUTHORITY      0x02
#define PP2_TYPE_CRC32C         0x03
#define PP2_TYPE_NOOP           0x04
#define PP2_TYPE_UNIQUE_ID      0x05
#define PP2_TYPE_SSL            0x20
/* pp2_tlv_ssl.client bit: the TLV's presence alone does not mean TLS. */
#define PP2_CLIENT_SSL          0x01
#define PP2_TYPE_NETNS          0x30

#define FEER_TUNNEL_BUFSZ 16384
#define FEER_TUNNEL_MAX_WBUF (16 * 1024 * 1024)

#define DATE_HEADER_LENGTH 37
#define DATE_VALUE_LENGTH  (DATE_HEADER_LENGTH - 6 - 2)
#define HEADER_KEY_BUFSZ (5 + MAX_HEADER_NAME_LEN)

///////////////////////////////////////////////////////////////
// enums

enum feer_respond_state {
    RESPOND_NOT_STARTED = 0,
    RESPOND_NORMAL = 1,
    RESPOND_STREAMING = 2,
    RESPOND_SHUTDOWN = 3
};

enum feer_receive_state {
    RECEIVE_WAIT = 0,
    RECEIVE_HEADERS = 1,
    RECEIVE_BODY = 2,
    RECEIVE_STREAMING = 3,
    RECEIVE_SHUTDOWN = 4,
    RECEIVE_CHUNKED = 5,
    RECEIVE_PROXY_HEADER = 6
};

enum feer_header_norm_style {
    HEADER_NORM_SKIP = 0,
    HEADER_NORM_UPCASE_DASH = 1,
    HEADER_NORM_LOCASE_DASH = 2,
    HEADER_NORM_UPCASE = 3,
    HEADER_NORM_LOCASE = 4
};

///////////////////////////////////////////////////////////////
// macros

#ifdef __GNUC__
# define likely(x)   __builtin_expect(!!(x), 1)
# define unlikely(x) __builtin_expect(!!(x), 0)
#else
# define likely(x)   (x)
# define unlikely(x) (x)
#endif

#define CLOSE_SENDFILE_FD(c) do { \
    if ((c)->sendfile_fd >= 0) { \
        if (unlikely(close((c)->sendfile_fd) < 0)) \
            trouble("close(sendfile_fd) fd=%d: %s\n", (c)->sendfile_fd, strerror(errno)); \
        (c)->sendfile_fd = -1; \
    } \
} while (0)

#ifndef HAS_ACCEPT4
#ifdef __GLIBC_PREREQ
#if __GLIBC_PREREQ(2, 10)
    #define HAS_ACCEPT4 1
#endif
#endif
#endif

#ifndef HAS_ACCEPT4
    #ifdef __NR_accept4
        #define HAS_ACCEPT4 1
    #endif
#endif

#ifndef CRLF
#define CRLF "\015\012"
#endif
#define CRLFx2 CRLF CRLF

#ifndef SOL_TCP
 #define SOL_TCP IPPROTO_TCP
#endif

#if Size_t_size == LONGSIZE
# define Sz_f "l"
# define Sz_t long
#elif Size_t_size == 8 && defined HAS_QUAD && QUADKIND == QUAD_IS_LONG_LONG
# define Sz_f "ll"
# define Sz_t long long
#else
# define Sz_f ""
# define Sz_t int
#endif

#define Sz_uf Sz_f"u"
#define Sz_xf Sz_f"x"
#define Ssz_df Sz_f"d"
#define Sz unsigned Sz_t
#define Ssz Sz_t

#define WARN_PREFIX "Feersum: "

#ifndef DEBUG
 #define INLINE_UNLESS_DEBUG inline
#else
 #define INLINE_UNLESS_DEBUG
#endif

#define trouble(f_, ...) warn(WARN_PREFIX f_, ##__VA_ARGS__)

#ifdef DEBUG
# define trace(f_, ...) \
    warn("%s:%-4d [%d] " f_, __FILE__, __LINE__, (int)getpid(), ##__VA_ARGS__)
# define trace2(f_, ...) \
    warn("%s:%-4d [%d] " f_, __FILE__, __LINE__, (int)getpid(), ##__VA_ARGS__)
# define trace3(f_, ...) \
    warn("%s:%-4d [%d] " f_, __FILE__, __LINE__, (int)getpid(), ##__VA_ARGS__)
#else
# define trace(f_, ...)
# define trace2(f_, ...)
# define trace3(f_, ...)
#endif

#ifdef DEBUG
# define RESPOND_STR(_n,_s) do { \
    switch(_n) { \
    case RESPOND_NOT_STARTED: _s = "NOT_STARTED(0)"; break; \
    case RESPOND_NORMAL:      _s = "NORMAL(1)"; break; \
    case RESPOND_STREAMING:   _s = "STREAMING(2)"; break; \
    case RESPOND_SHUTDOWN:    _s = "SHUTDOWN(3)"; break; \
    default:                  _s = "UNKNOWN"; break; \
    } \
} while (0)

# define RECEIVE_STR(_n,_s) do { \
    switch(_n) { \
    case RECEIVE_WAIT:         _s = "WAIT(0)"; break; \
    case RECEIVE_HEADERS:      _s = "HEADERS(1)"; break; \
    case RECEIVE_BODY:         _s = "BODY(2)"; break; \
    case RECEIVE_STREAMING:    _s = "STREAMING(3)"; break; \
    case RECEIVE_SHUTDOWN:     _s = "SHUTDOWN(4)"; break; \
    case RECEIVE_CHUNKED:      _s = "CHUNKED(5)"; break; \
    case RECEIVE_PROXY_HEADER: _s = "PROXY(6)"; break; \
    default:                   _s = "UNKNOWN"; break; \
    } \
} while (0)

# define change_responding_state(c, _to) do { \
    enum feer_respond_state __to = (_to); \
    enum feer_respond_state __from = (c)->responding; \
    const char *_from_str, *_to_str; \
    if (likely(__from != __to)) { \
        RESPOND_STR((c)->responding, _from_str); \
        RESPOND_STR(__to, _to_str); \
        trace2("==> responding state %d: %s to %s\n", (c)->fd,_from_str,_to_str); \
        (c)->responding = __to; \
    } \
} while (0)
# define change_receiving_state(c, _to) do { \
    enum feer_receive_state __to = (_to); \
    enum feer_receive_state __from = (c)->receiving; \
    const char *_from_str, *_to_str; \
    if (likely(__from != __to)) { \
        RECEIVE_STR((c)->receiving, _from_str); \
        RECEIVE_STR(__to, _to_str); \
        trace2("==> receiving state %d: %s to %s\n", (c)->fd,_from_str,_to_str); \
        (c)->receiving = __to; \
    } \
} while (0)
#else
# define change_responding_state(c, _to) do { (c)->responding = (_to); } while (0)
# define change_receiving_state(c, _to) do { (c)->receiving = (_to); } while (0)
#endif

#define dCONN struct feer_conn *c = (struct feer_conn *)w->data
#define IsArrayRef(_x) (SvROK(_x) && SvTYPE(SvRV(_x)) == SVt_PVAV)
#define IsCodeRef(_x) (SvROK(_x) && SvTYPE(SvRV(_x)) == SVt_PVCV)
#define ASSERT_EV_LOOP_INITIALIZED() \
    assert(feersum_ev_loop != NULL && "feersum_ev_loop not initialized - call accept_on_fd first")

#define feer_clear_remote_cache(_c) STMT_START { \
    if ((_c)->remote_addr) { SvREFCNT_dec((_c)->remote_addr); (_c)->remote_addr = NULL; } \
    if ((_c)->remote_port) { SvREFCNT_dec((_c)->remote_port); (_c)->remote_port = NULL; } \
} STMT_END

/* RFC 9110 6.4.1 */
#define http_status_no_body(code) \
    ((code) == 204 || (code) == 205 || (code) == 304 || \
     (100 <= (code) && (code) <= 199))

///////////////////////////////////////////////////////////////
// structs

struct rinq {
    struct rinq *next,*prev;
    void *ref;
};

struct iomatrix {
    unsigned offset;
    unsigned count;
    struct iovec iov[FEERSUM_IOMATRIX_SIZE];
    SV *sv[FEERSUM_IOMATRIX_SIZE];
};

struct feer_req {
    SV *buf;
    const char* method;
    size_t method_len;
    const char* uri;
    size_t uri_len;
    int minor_version;
    size_t num_headers;
    SV* path;
    SV* query;
#ifdef FEERSUM_HAS_H2
    SV* h2_method_sv;
    SV* h2_uri_sv;
#endif
    /* Must stay last: FEER_REQ_ALLOC zeroes only up to here. */
    struct phr_header headers[MAX_HEADERS];
};

struct feer_conn {
    SV *self;
    int fd;
    enum feer_respond_state responding;
    enum feer_receive_state receiving;
    bool is_keepalive;
    int reqs;
    SV *rbuf;
    struct rinq *wbuf_rinq;
    size_t wbuf_len;
    struct feer_req *req;
    struct feer_server *server;
    struct feer_listen *listener;

    double       cached_read_timeout;
    double       cached_write_timeout;
    unsigned int cached_max_conn_reqs;
    bool         cached_is_tcp;
    bool         cached_keepalive_default;
    bool         cached_use_reverse_proxy;
    size_t       cached_max_read_buf;
    size_t       cached_max_body_len;
    size_t       cached_max_uri_len;
    size_t       cached_wbuf_low_water;
    ssize_t pipelined;
    ssize_t expected_cl;
    ssize_t received_cl;

    unsigned int in_callback;
    unsigned int pipeline_depth;
    /* Bumped by every Writer write, zero-length included; only change is
     * compared around a poll_cb, so wrap is fine. */
    unsigned int poll_writes_seen;
    unsigned int is_http11:1;
    unsigned int poll_write_cb_is_io_handle:1;
    unsigned int auto_cl:1;
    unsigned int no_resp_body:1;   /* HEAD: emit headers, suppress body bytes */
    /* HEAD: the app's own Content-Length, not to be replaced by the measured one */
    unsigned int app_content_length:1;
    /* Request declared a body length (Content-Length or chunked); only then
     * may reads be clamped at expected_cl in RECEIVE_SHUTDOWN. */
    unsigned int body_framed:1;
    unsigned int use_chunked:1;
    /* raw streaming body held to the app's Content-Length: resp_cl_owed */
    unsigned int resp_cl_enforced:1;
    unsigned int expect_continue:1;
    unsigned int receive_chunked:1;
    unsigned int io_taken:1;
    /* The app's IO handle owns the close of c->fd (io_taken alone does not
     * imply this: tunnels set it while Feersum keeps the fd). */
    unsigned int fd_given_away:1;
    /* close_notify already written; never encrypt a second alert */
    unsigned int tls_alert_sent:1;
    /* Close by lingering (feer_arm_linger), not by a bare close() */
    unsigned int want_linger_close:1;
    unsigned int proxy_proto_version:2;
    unsigned int proxy_ssl:1;
    /* Lingering close in progress: FIN sent, read side draining before close() */
    unsigned int closing_linger:1;
    /* Handler running under G_EVAL: new_feer_conn_handle pins the writer */
    unsigned int pin_writer:1;
    /* write_ev_timer is armed as a paced poll_cb retry, not the deadline;
     * every site that arms the deadline or stops the timer must clear it. */
    unsigned int poll_retry_pending:1;
    unsigned int poll_retry_backoff:4;
    /* Consecutive write-deadline checks with no send-queue drain; one is not
     * proof the peer stopped, ACKs arrive in clumps. */
    unsigned int outq_stalls:2;

    /* Send-queue depth at the last write-deadline check; 0 = no sample */
    int prev_outq;

    /* Same sample for the idle-keepalive reap, kept apart from prev_outq */
    int prev_read_outq;

    struct ev_io read_ev_io;
    struct ev_io write_ev_io;
    struct ev_timer read_ev_timer;
    struct ev_timer header_ev_timer;
    struct ev_timer write_ev_timer;

    struct sockaddr_storage sa;

    SV *poll_write_cb;
    SV *poll_read_cb;
    SV *ext_guard;
    /* Extra ref on the writer created inside a guarded callback: a die there
     * unwinds the app's lexicals before the G_EVAL catch, and the writer's
     * DESTROY would seal a truncated response as complete. */
    SV *pinned_writer;
    /* Copies for access_log: req->method/uri point into the reused rbuf */
    SV *log_method;
    SV *log_uri;
    double req_start;

    SV *remote_addr;
    SV *remote_port;
    AV *trailers;

    SV *proxy_tlvs;

    int sendfile_fd;
    off_t sendfile_off;
    size_t sendfile_remain;
    size_t resp_cl_owed;

    /* Bytes a lingering close may still drain */
    size_t linger_left;

    uint16_t proxy_dst_port;
    struct rinq *idle_rinq_node;

    ssize_t chunk_remaining;
    unsigned int chunk_count;
    unsigned int trailer_count;

#ifdef FEERSUM_HAS_TLS
    ptls_t         *tls;
    struct feer_tls_ctx_ref *tls_ctx_ref;
    ptls_buffer_t   tls_wbuf;
    uint8_t        *tls_rbuf;
    size_t          tls_rbuf_len;
    unsigned int    tls_handshake_done:1;
    /* Alert owed for an undecryptable record; sent fatal in place of close_notify */
    uint8_t         tls_fatal_alert;

    int             tls_tunnel_sv0;
    int             tls_tunnel_sv1;
    struct ev_io    tls_tunnel_read_w;
    struct ev_io    tls_tunnel_write_w;
    SV             *tls_tunnel_wbuf;
    size_t          tls_tunnel_wbuf_pos;
    unsigned int    tls_tunnel:1;
    /* App closed its tunnel end; flush the queued ciphertext before shutting down */
    unsigned int    tls_tunnel_eof:1;
#endif
#ifdef FEERSUM_HAS_H2
    nghttp2_session       *h2_session;
    struct feer_h2_stream *h2_streams;
    unsigned int           is_h2_stream:1;
    unsigned int           h2_goaway_sent:1;
    /* On the parent: a stream's write pump stopped on its iteration budget,
     * so the write watcher must stay armed to re-enter it. */
    unsigned int           h2_pump_pending:1;
    /* Last stream closed during shutdown; close once tls_wbuf is flushed, not
     * in the nghttp2 callback */
    unsigned int           h2_close_pending:1;
    uint8_t                h2_invalid_frames;
    /* Peer-silent intervals in a row with response bytes the peer would not take */
    uint8_t                h2_stall_strikes;
    uint32_t               h2_rst_count;      /* CVE-2023-44487 rapid reset mitigation */
    ev_tstamp              h2_rst_window_start;
#endif
};

#ifdef FEERSUM_HAS_TLS
/* Refcounted ptls_context_t: connections keep the old context alive across a
 * set_tls rotation or accept_on_fd reuse of the listener. */
struct feer_tls_ctx_ref {
    ptls_context_t *ctx;
    int refcount;
};

#define FEER_MAX_SNI_ENTRIES 32

struct feer_sni_entry {
    char *hostname;          /* NUL-terminated hostname (lowercase) */
    struct feer_tls_ctx_ref *ctx_ref;
};
#endif

/* feer_listen.pause_flags: accept_w stays stopped while any bit is set */
#define FEER_PAUSE_USER   (1u << 0)  /* user pause_accept (sticky) */
#define FEER_PAUSE_CAP    (1u << 1)  /* max_connections at capacity */
#define FEER_PAUSE_EMFILE (1u << 2)  /* fd table exhausted (1s backoff) */

struct feer_listen {
    struct feer_server *server;
    int                 fd;
    ev_io               accept_w;
    ev_timer            emfile_w;
    bool                is_tcp;
    unsigned int        pause_flags;
    SV                 *server_name;
    SV                 *server_port;
#ifdef FEERSUM_HAS_TLS
    struct feer_tls_ctx_ref *tls_ctx_ref;  /* default context */
    struct feer_sni_entry    sni_entries[FEER_MAX_SNI_ENTRIES];
    int                      n_sni_entries;
#endif
};

struct feer_server {
    SV *self;
    struct feer_listen listeners[FEER_MAX_LISTENERS];
    int                n_listeners;
    SV   *request_cb_cv;
    bool  request_cb_is_psgi;
    SV   *shutdown_cb_cv;
    bool  shutting_down;
    /* Retire the worker after this many requests */
    UV    max_requests;
    SV   *max_requests_cb_cv;
    /* Fired before the retirement drain starts; the drain itself has no deadline */
    SV   *retire_begin_cb_cv;
    bool  retire_pending;
    /* (method, uri, elapsed_seconds) once each response is fully flushed */
    SV   *access_log_cb_cv;
    int   active_conns;
    /* H2 pseudo-conns within active_conns; max_connections counts sockets only */
    int   active_h2_streams;
    UV    total_requests;
    double       read_timeout;
    double       header_timeout;
    double       write_timeout;
    double       linger_timeout;
    unsigned int max_connection_reqs;
    bool         is_keepalive;
    int          read_priority;
    int          write_priority;
    int          accept_priority;
    int          max_accept_per_loop;
    int          max_connections;
    size_t       max_read_buf;
    size_t       max_body_len;
    size_t       max_uri_len;
    size_t       wbuf_low_water;
    bool         use_reverse_proxy;
    bool         use_proxy_protocol;
    bool         psgix_io;
    bool         multiprocess;
    /* Graceful shutdown accepts a TCP listener's queued clients before closing it */
    bool         drain_accept_queue;
#ifdef FEERSUM_HAS_H2
    int          max_h2_concurrent_streams;
    /* Cap on undispatched request-body bytes across all H2 streams; 0 = off */
    size_t       max_h2_conn_body;
#endif
    bool         watchers_initialized;
    ev_prepare       ep;
    ev_check         ec;
    struct ev_idle   ei;
    struct rinq     *request_ready_rinq;
    struct rinq     *idle_keepalive_rinq;
};

typedef struct feer_conn feer_conn_handle;

///////////////////////////////////////////////////////////////
// externs

extern char header_key_buf[];
extern const unsigned char ascii_lower[];
extern const unsigned char ascii_upper[];
extern const unsigned char ascii_upper_dash[];
extern const unsigned char ascii_lower_dash[];
extern const unsigned char hex_decode_table[];
extern char DATE_BUF[];
extern HV *feer_stash, *feer_conn_stash;
extern HV *feer_conn_reader_stash, *feer_conn_writer_stash;
extern MGVTBL psgix_io_vtbl;
extern struct feer_server *default_server;
extern struct ev_loop *feersum_ev_loop;
extern AV *psgi_ver;
extern SV *psgi_serv10, *psgi_serv11;
extern SV *method_GET, *method_POST, *method_HEAD, *method_PUT, *method_PATCH, *method_DELETE, *method_OPTIONS;
extern SV *status_200, *status_201, *status_204, *status_301, *status_302, *status_304;
extern SV *status_400, *status_404, *status_500;
extern SV *empty_query_sv;
extern SV *psgi_env_version;
extern SV *psgi_env_errors;
extern ev_timer date_timer;
extern int date_timer_refs;

///////////////////////////////////////////////////////////////
// prototypes

typedef void (*conn_read_cb_t)(EV_P_ ev_io *, int);

static struct rinq *rinq_push (struct rinq **head, void *ref);
static void* rinq_shift (struct rinq **head);

/* Always defined (no-ops without FEERSUM_HAS_H2): XS CODE blocks cannot #ifdef */
static int h2_try_write_chunk (pTHX_ struct feer_conn *c, SV *body);
static int h2_is_stream (struct feer_conn *c);

#ifdef FEERSUM_HAS_H2
static void h2_tunnel_auto_accept(pTHX_ struct feer_conn *c, struct feer_h2_stream *stream);
static int  pump_h2_io_step(pTHX_ struct feer_conn *c);
static void feersum_h2_close_write(pTHX_ struct feer_conn *c);
static void feersum_h2_write_chunk(pTHX_ struct feer_conn *c, SV *body);
static void h2_check_stream_poll_cbs(pTHX_ struct feer_conn *c);
static inline int h2_stream_send_pending(const struct feer_h2_stream *stream);
static inline void h2_submit_rst(nghttp2_session *session, int32_t stream_id, uint32_t error_code);
static size_t feersum_h2_write_whole_body(pTHX_ struct feer_conn *c, SV *body_sv);
static void feer_h2_setup_tunnel(pTHX_ struct feer_h2_stream *stream);
static void feer_h2_init_session(struct feer_conn *c);
static void feer_h2_free_session(struct feer_conn *c);
static void feer_h2_session_recv(struct feer_conn *c, const uint8_t *data, size_t len);
static void feer_h2_session_send(struct feer_conn *c);
static inline void h2_session_send_and_poll(pTHX_ struct feer_conn *parent);
static void feersum_h2_start_response(pTHX_ struct feer_conn *c, SV *message, AV *headers, int streaming);
static void feersum_h2_respond_error(struct feer_conn *c, int err_code,
                                     const char *msg);
static void h2_try_stream_write(pTHX_ struct feer_conn *c);
#endif

static void feersum_set_conn_remote_info(pTHX_ struct feer_conn *c);
static SV* feersum_env_method(pTHX_ struct feer_req *r);
#ifdef FEERSUM_HAS_H2
static SV* feersum_env_method_h2(pTHX_ struct feer_conn *c, struct feer_req *r);
#endif
static SV* feersum_env_uri(pTHX_ struct feer_req *r);
static SV* feersum_env_protocol(pTHX_ struct feer_req *r);
static void feersum_set_path_and_query(pTHX_ struct feer_req *r);
static HV* feersum_env(pTHX_ struct feer_conn *c);
static SV* feersum_env_path(pTHX_ struct feer_req *r);
static SV* feersum_env_query(pTHX_ struct feer_req *r);
static HV* feersum_env_headers(pTHX_ struct feer_req *r, int norm);
static SV* feersum_env_header(pTHX_ struct feer_req *r, SV* name);
static SV* feersum_env_addr(pTHX_ struct feer_conn *c);
static SV* feersum_env_port(pTHX_ struct feer_conn *c);
static SV* feersum_env_io(pTHX_ struct feer_conn *c);
static SSize_t feersum_return_from_io(pTHX_ struct feer_conn *c, SV *io_sv, const char *func_name);
static void feersum_start_response(pTHX_ struct feer_conn *c, SV *message, AV *headers, int streaming, bool pre_validated);
static size_t feersum_write_whole_body (pTHX_ struct feer_conn *c, SV *body);
static void feersum_handle_psgi_response(pTHX_ struct feer_conn *c, SV *ret, bool can_recurse);
static int feersum_close_handle(pTHX_ struct feer_conn *c, bool is_writer);
static SV* feersum_conn_guard(pTHX_ struct feer_conn *c, SV *guard);

static void start_read_watcher(struct feer_conn *c);
static void stop_read_watcher(struct feer_conn *c);
static void restart_read_timer(struct feer_conn *c);
static void stop_read_timer(struct feer_conn *c);
static void start_write_watcher(struct feer_conn *c);
static void stop_write_watcher(struct feer_conn *c);
static void stop_all_watchers(struct feer_conn *c);
static void feer_conn_set_idle(struct feer_conn *c);
static void feer_conn_set_busy(struct feer_conn *c);
static int feer_server_recycle_idle_conn(struct feer_server *srvr);

static void try_conn_write(EV_P_ struct ev_io *w, int revents);
static void try_conn_read(EV_P_ struct ev_io *w, int revents);
static void conn_read_timeout(EV_P_ struct ev_timer *w, int revents);
static void conn_header_timeout(EV_P_ struct ev_timer *w, int revents);
static void conn_write_timeout(EV_P_ struct ev_timer *w, int revents);
#ifdef FEERSUM_HAS_OUTQ
static int feer_sock_outq(int fd);
#endif
static void restart_write_timer(struct feer_conn *c);
static void stop_write_timer(struct feer_conn *c);
static void stop_header_timer(struct feer_conn *c);
static void restart_header_timer(struct feer_conn *c);
static void begin_request_headers(struct feer_conn *c);
static bool process_request_headers(struct feer_conn *c, int body_offset);
static int try_parse_chunked(struct feer_conn *c);
static void sched_request_callback(struct feer_conn *c);
static void invoke_shutdown_cb(pTHX_ struct feer_server *server);
static void feer_begin_graceful_shutdown(pTHX_ struct feer_server *server, SV *cb);
static void call_died (pTHX_ struct feer_conn *c, const char *cb_type);
static void feersum_writer_unpin (pTHX_ struct feer_conn *c, bool errored);
static void feersum_poll_retry_park (struct feer_conn *c);
static void call_request_callback(struct feer_conn *c);
static void call_poll_callback (struct feer_conn *c, bool is_write);
static void pump_io_handle (struct feer_conn *c);

static int parse_proxy_v1(struct feer_conn *c);
static int parse_proxy_v2(struct feer_conn *c);
static int try_parse_proxy_header(struct feer_conn *c);
static int try_parse_http(struct feer_conn *c, size_t last_read);
static void finish_receiving(struct feer_conn *c);

#ifdef FEERSUM_HAS_TLS
static void feer_tls_init_conn(struct feer_conn *c, struct feer_tls_ctx_ref *ref);
static void feer_tls_free_conn(struct feer_conn *c);
static int feer_tls_flush_wbuf(struct feer_conn *c);
static int feer_tls_send(struct feer_conn *c, const void *data, size_t len);
static void feer_tls_setup_tunnel(struct feer_conn *c);
static void try_tls_conn_read(EV_P_ ev_io *w, int revents);
static void try_tls_conn_write(EV_P_ ev_io *w, int revents);
static ptls_context_t * feer_tls_create_context(pTHX_ const char *cert_file, const char *key_file, int h2);
static void feer_tls_free_context(ptls_context_t *ctx);
static struct feer_tls_ctx_ref *feer_tls_ctx_ref_new(ptls_context_t *ctx);
static void feer_tls_ctx_ref_dec(struct feer_tls_ctx_ref *ref);
static void feer_tls_cleanup_listener(struct feer_listen *lsnr);
#ifdef FEERSUM_HAS_H2
static void drain_h2_tls_records(struct feer_conn *c);
#endif
static void tls_tunnel_sv0_read_cb(EV_P_ struct ev_io *w, int revents);
static void tls_tunnel_sv0_write_cb(EV_P_ struct ev_io *w, int revents);
static int tls_tunnel_write_or_buffer(struct feer_conn *c, const char *data, size_t len);
static void feer_tls_tunnel_shutdown(struct feer_conn *c);
#endif

static void conn_write_ready (struct feer_conn *c);
static void respond_with_server_error(struct feer_conn *c, const char *msg, int code);
static void send_100_continue(struct feer_conn *c);
static void free_feer_req(struct feer_req *req);
static void free_request(struct feer_conn *c);

static void update_wbuf_placeholder(struct feer_conn *c, SV *sv, struct iovec *iov);
static SV* feer_bytes_mortal (const char *p, STRLEN len);
static STRLEN add_sv_to_wbuf (struct feer_conn *c, SV *sv);
static STRLEN add_const_to_wbuf (struct feer_conn *c, const char *str, size_t str_len);
#define add_crlf_to_wbuf(c) add_const_to_wbuf(c,CRLF,2)
static void finish_wbuf (struct feer_conn *c);
static void add_chunk_sv_to_wbuf (struct feer_conn *c, SV *sv);
static void add_placeholder_to_wbuf (struct feer_conn *c, SV **sv, struct iovec **iov_ref);

static void uri_decode_sv (SV *sv);
static bool str_case_eq_both(const char *a, const char *b, size_t len);
static bool str_case_eq_fixed(const char *a, const char *b, size_t len);
static const char* feer_memfind(const char *hay, size_t hay_len, const char *needle, size_t n_len);

static void date_timer_cb(EV_P_ ev_timer *w, int revents);
// Buffer must be at least 40 bytes. Returns length written.
static int format_content_length(char *buf, size_t len);
static struct iomatrix * next_iomatrix (struct feer_conn *c);
static SV* new_feer_conn_handle (pTHX_ struct feer_conn *c, bool is_writer);
static struct feer_conn * new_feer_conn (EV_P_ int conn_fd, struct sockaddr *sa, socklen_t sa_len, struct feer_server *srvr, struct feer_listen *lsnr);
static struct feer_server * new_feer_server (pTHX);
static void prepare_cb (EV_P_ ev_prepare *w, int revents);
static void check_cb (EV_P_ ev_check *w, int revents);
static void idle_cb (EV_P_ ev_idle *w, int revents);
static int psgix_io_svt_get (pTHX_ SV *sv, MAGIC *mg);
static struct feer_server * sv_2feer_server (SV *rv);
static struct feer_conn * sv_2feer_conn (SV *rv);
static SV* feer_conn_2sv (struct feer_conn *c);
static SV* feer_server_2sv (struct feer_server *s);
static feer_conn_handle * sv_2feer_conn_handle (SV *rv, bool can_croak);

static void handle_keepalive_or_close(struct feer_conn *c, conn_read_cb_t read_cb);
static void feer_emit_access_log(pTHX_ struct feer_conn *c);
static void safe_close_conn(struct feer_conn *c, const char *where);
static void feer_linger_close(struct feer_conn *c, const char *where);
static int  feer_arm_linger(struct feer_conn *c, const char *where);
static int prep_socket(int fd, int is_tcp);
static void set_cork(struct feer_conn *c, int cork);
static void feersum_init_psgi_env_constants(pTHX);
static HV* feersum_build_psgi_env(pTHX);
static SV* feer_determine_url_scheme(pTHX_ struct feer_conn *c);
static const char* find_header_value(struct feer_req *r, const char *name, size_t name_len, size_t *value_len);
static SV* extract_forwarded_addr(pTHX_ struct feer_req *r);
static SV* extract_forwarded_proto(pTHX_ struct feer_req *r);
static void feersum_start_psgi_streaming(pTHX_ struct feer_conn *c, SV *streamer);
static int feer_socketpair_nb(int sv[2]);
static SV* newSV_buf(STRLEN size);
static const char *http_code_to_msg (int code);
static void setup_accept_watcher(struct feer_listen *lsnr, int listen_fd);
static void init_feer_server (struct feer_server *s);
static void process_request_ready_rinq (struct feer_server *server);
static int setup_accepted_conn(EV_P_ int fd, struct sockaddr *sa, socklen_t sa_len, struct feer_server *srvr, struct feer_listen *lsnr);
static int try_accept_one(EV_P_ struct feer_listen *lsnr, struct feer_server *srvr);
static SV* fetch_av_normal (pTHX_ AV *av, I32 i);

#define FEER_REQ_ALLOC(r_) do { \
    extern struct feer_req *feer_req_freelist; \
    extern int feer_req_freelist_count; \
    if (feer_req_freelist != NULL) { \
        r_ = feer_req_freelist; \
        feer_req_freelist = *(struct feer_req **)feer_req_freelist; \
        feer_req_freelist_count--; \
    } else { \
        Newx(r_, 1, struct feer_req); \
    } \
    Zero(r_, offsetof(struct feer_req, headers), char); \
} while(0)

#define FEER_REQ_FREE(r_) do { \
    extern struct feer_req *feer_req_freelist; \
    extern int feer_req_freelist_count; \
    extern int FEERSUM_FREELIST_MAX; \
    if (feer_req_freelist_count < FEERSUM_FREELIST_MAX) { \
        *(struct feer_req **)(r_) = feer_req_freelist; \
        feer_req_freelist = (r_); \
        feer_req_freelist_count++; \
    } else { \
        Safefree(r_); \
    } \
} while(0)

#define IOMATRIX_ALLOC(m_) do { \
    extern struct iomatrix *iomatrix_freelist; \
    extern int iomatrix_freelist_count; \
    if (iomatrix_freelist != NULL) { \
        m_ = iomatrix_freelist; \
        iomatrix_freelist = *(struct iomatrix **)iomatrix_freelist; \
        iomatrix_freelist_count--; \
        Zero(m_->sv, FEERSUM_IOMATRIX_SIZE, SV*); \
        /* iov too: a croak between a slot's count++ and its fill would \
         * otherwise writev() the previous connection's stale pointer. */ \
        Zero(m_->iov, FEERSUM_IOMATRIX_SIZE, struct iovec); \
    } else { \
        Newxz(m_, 1, struct iomatrix); \
    } \
} while(0)

#define IOMATRIX_FREE(m_) do { \
    extern struct iomatrix *iomatrix_freelist; \
    extern int iomatrix_freelist_count; \
    extern int FEERSUM_FREELIST_MAX; \
    if (iomatrix_freelist_count < FEERSUM_FREELIST_MAX) { \
        *(struct iomatrix **)(m_) = iomatrix_freelist; \
        iomatrix_freelist = (m_); \
        iomatrix_freelist_count++; \
    } else { \
        Safefree(m_); \
    } \
} while(0)

#endif /* FEERSUM_CORE_H */
