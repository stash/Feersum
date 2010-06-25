#include "EVAPI.h"
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <errno.h>
#include <ctype.h>
#include <netinet/ip.h>
#include <netinet/tcp.h>

#include "ppport.h"

#include "picohttpparser-git/picohttpparser.c"

#include "rinq.c"

#ifndef CRLF
#define CRLF "\015\012"
#endif
#define CRLFx2 CRLF CRLF

// if you change these, also edit the LIMITS section in the POD
#define MAX_HEADERS 64
#define MAX_HEADER_NAME_LEN 128
#define MAX_BODY_LENGTH 2147483647
#define READ_CHUNK 4096

// Setting this to true will wait for writability before calling write() (will
// try to immediately write otherwise)
#define AUTOCORK_WRITES 1

#define WARN_PREFIX "Feersum: "

#ifndef DEBUG
 #ifndef __inline
  #define __inline
 #endif
 #define INLINE_UNLESS_DEBUG __inline
#else
 #define INLINE_UNLESS_DEBUG
#endif

#define trouble(f_, ...) warn(WARN_PREFIX f_, ##__VA_ARGS__);

#ifdef DEBUG
#define trace(f_, ...) warn("%s:%d: " f_, __FILE__, __LINE__, ##__VA_ARGS__)
#else
#define trace(...)
#endif

#include <sys/uio.h>
#define IOMATRIX_SIZE 64
struct iomatrix {
    uint16_t offset;
    uint16_t count;
    struct iovec iov[IOMATRIX_SIZE];
    SV *sv[IOMATRIX_SIZE];
};

struct feer_req {
    SV *buf;
    const char* method;
    size_t method_len;
    const char* path; 
    size_t path_len;
    int minor_version;
    size_t num_headers;
    struct phr_header headers[MAX_HEADERS];
};

// enough to hold a 64-bit signed integer (which is 20+1 chars) plus nul
#define CONN_LABEL_LENGTH 24
#define RESPOND_NOT_STARTED 0
#define RESPOND_NORMAL 1
#define RESPOND_STREAMING 2
#define RESPOND_SHUTDOWN 3
#define RECEIVE_HEADERS 0
#define RECEIVE_BODY 1
#define RECEIVE_STREAMING 2
#define RECEIVE_SHUTDOWN 3

struct feer_conn {
    char label[CONN_LABEL_LENGTH];
    SV *self;

    int fd;
    struct ev_io read_ev_io;
    struct ev_io write_ev_io;
    struct ev_timer read_ev_timer;
    struct ev_loop *loop;

    SV *rbuf;
    struct rinq *wbuf_rinq;

    struct feer_req *req;
    size_t expected_cl;
    size_t received_cl;

    int16_t in_callback;
    int16_t responding;
    int16_t receiving;
};

typedef struct feer_conn feer_conn_handle; // for typemap

#define dCONN struct feer_conn *c = (struct feer_conn *)w->data

static void try_conn_write(EV_P_ struct ev_io *w, int revents);
static void try_conn_read(EV_P_ struct ev_io *w, int revents);
static void conn_read_timeout(EV_P_ struct ev_timer *w, int revents);
static bool process_request_headers(struct feer_conn *c, int body_offset);
static void sched_request_callback(struct feer_conn *c);
static void call_request_callback(struct feer_conn *c);

static void conn_write_ready (struct feer_conn *c);
static void respond_with_server_error(struct feer_conn *c, const char *msg, STRLEN msg_len, int code);

static STRLEN add_sv_to_wbuf (struct feer_conn *c, SV *sv);
static STRLEN add_const_to_wbuf (struct feer_conn *c, const char const *str, size_t str_len);
static void add_chunk_sv_to_wbuf (struct feer_conn *c, SV *sv);
static void add_placeholder_to_wbuf (struct feer_conn *c, SV **sv, struct iovec **iov_ref);

static void uri_decode_sv (SV *sv);
static bool str_eq(const char *a, int a_len, const char *b, int b_len);
static bool str_case_eq(const char *a, int a_len, const char *b, int b_len);

static const char const *http_code_to_msg (int code);
static int prep_socket (int fd);

static HV *feer_stash, *feer_conn_stash;
static HV *feer_conn_reader_stash = NULL, *feer_conn_writer_stash = NULL;

static SV *request_cb_cv = NULL;
static SV *shutdown_cb_cv = NULL;
static bool shutting_down = 0;
static int active_conns = 0;
static double read_timeout = 5.0;

static ev_io accept_w;
static ev_prepare ep;
static ev_check   ec;
struct ev_idle    ei;

static struct rinq *request_ready_rinq = NULL;

static AV *psgi_ver;
static SV *psgi_serv10, *psgi_serv11, *crlf_sv;

INLINE_UNLESS_DEBUG
static struct iomatrix *
next_iomatrix (struct feer_conn *c)
{
    bool add_iomatrix = 0;
    struct iomatrix *m;

    if (!c->wbuf_rinq) {
        add_iomatrix = 1;
    }
    else {
        // get the tail-end struct
        m = (struct iomatrix *)c->wbuf_rinq->prev->ref;
        if (m->count >= IOMATRIX_SIZE) {
            add_iomatrix = 1;
        }
    }

    if (add_iomatrix) {
        New(0,m,1,struct iomatrix);
        Poison(m,1,struct iomatrix);
        m->offset = m->count = 0;
        rinq_push(&c->wbuf_rinq, m);
    }

    return m;
}

INLINE_UNLESS_DEBUG
static STRLEN
add_sv_to_wbuf(struct feer_conn *c, SV *sv)
{
    struct iomatrix *m = next_iomatrix(c);
    int idx = m->count++;
    STRLEN cur;
    if (SvPADTMP(sv) || SvTEMP(sv)) {
        // PADTMPs have their PVs re-used, so we can't simply keep a
        // reference.  TEMPs maybe behave in a similar way and are potentially
        // stealable.
#ifdef FEERSUM_STEAL
        if (SvFLAGS(sv) == SVs_PADTMP|SVf_POK|SVp_POK) {
            // XXX: EGREGIOUS HACK THAT MAKES THINGS A LOT FASTER
            // steal the PV from a PADTMP PV
            SV *theif = newSV(0);
            sv_upgrade(theif, SVt_PV);

            SvPV_set(theif, SvPVX(sv));
            SvLEN_set(theif, SvLEN(sv));
            SvCUR_set(theif, SvCUR(sv));

            // make the temp null
            (void)SvOK_off(sv);
            SvPV_set(sv, NULL);
            SvLEN_set(sv, 0);
            SvCUR_set(sv, 0);

            SvFLAGS(theif) |= SVf_READONLY|SVf_POK|SVp_POK;

            sv = theif;
        }
        else {
            // be safe an just make a simple copy
            sv = newSVsv(sv);
        }
#else
        // Make a simple copy (which duplicates the PV almost all of the time)
        sv = newSVsv(sv);
#endif
    }
    else {
        sv = SvREFCNT_inc(sv);
    }
    m->iov[idx].iov_base = SvPV(sv, cur);
    m->iov[idx].iov_len = cur;
    m->sv[idx] = sv;

    return cur;
}

INLINE_UNLESS_DEBUG
static STRLEN
add_const_to_wbuf(struct feer_conn *c, const char const *str, size_t str_len)
{
    struct iomatrix *m = next_iomatrix(c);
    int idx = m->count++;
    m->iov[idx].iov_base = (void*)str;
    m->iov[idx].iov_len = str_len;
    m->sv[idx] = NULL;
    return str_len;
}

INLINE_UNLESS_DEBUG
static void
add_placeholder_to_wbuf(struct feer_conn *c, SV **sv, struct iovec **iov_ref)
{
    struct iomatrix *m = next_iomatrix(c);
    int idx = m->count++;
    *sv = newSV(31);
    m->sv[idx] = *sv;
    *iov_ref = &m->iov[idx];
}

#define update_wbuf_placeholder(c,sv,iov) iov->iov_base = SvPV(sv, iov->iov_len)

static void
add_chunk_sv_to_wbuf(struct feer_conn *c, SV *sv)
{
    if (!sv) {
        add_const_to_wbuf(c, "0\r\n\r\n", 5);
        return;
    }
    SV *chunk;
    struct iovec *chunk_iov;
    add_placeholder_to_wbuf(c, &chunk, &chunk_iov);
    STRLEN cur = add_sv_to_wbuf(c, sv);
    add_const_to_wbuf(c, CRLF, 2);

    sv_setpvf(chunk, "%x" CRLF, cur);
    update_wbuf_placeholder(c, chunk, chunk_iov);
}

static const char const *
http_code_to_msg (int code) {
    // http://en.wikipedia.org/wiki/List_of_HTTP_status_codes
    switch (code) {
        case 100: return "Continue";
        case 101: return "Switching Protocols";
        case 102: return "Processing"; // RFC 2518
        case 200: return "OK";
        case 201: return "Created";
        case 202: return "Accepted";
        case 203: return "Non Authoritative Information";
        case 204: return "No Content";
        case 205: return "Reset Content";
        case 206: return "Partial Content";
        case 207: return "Multi-Status"; // RFC 4918 (WebDav)
        case 300: return "Multiple Choices";
        case 301: return "Moved Permanently";
        case 302: return "Found";
        case 303: return "See Other";
        case 304: return "Not Modified";
        case 305: return "Use Proxy";
        case 307: return "Temporary Redirect";
        case 400: return "Bad Request";
        case 401: return "Unauthorized";
        case 402: return "Payment Required";
        case 403: return "Forbidden";
        case 404: return "Not Found";
        case 405: return "Method Not Allowed";
        case 406: return "Not Acceptable";
        case 407: return "Proxy Authentication Required";
        case 408: return "Request Timeout";
        case 409: return "Conflict";
        case 410: return "Gone";
        case 411: return "Length Required";
        case 412: return "Precondition Failed";
        case 413: return "Request Entity Too Large";
        case 414: return "Request URI Too Long";
        case 415: return "Unsupported Media Type";
        case 416: return "Requested Range Not Satisfiable";
        case 417: return "Expectation Failed";
        case 418: return "I'm a teapot";
        case 421: return "Too Many Connections"; // Microsoft?
        case 422: return "Unprocessable Entity"; // RFC 4918
        case 423: return "Locked"; // RFC 4918
        case 424: return "Failed Dependency"; // RFC 4918
        case 425: return "Unordered Collection"; // RFC 3648
        case 426: return "Upgrade Required"; // RFC 2817
        case 449: return "Retry With"; // Microsoft
        case 450: return "Blocked by Parental Controls"; // Microsoft
        case 500: return "Internal Server Error";
        case 501: return "Not Implemented";
        case 502: return "Bad Gateway";
        case 503: return "Service Unavailable";
        case 504: return "Gateway Timeout";
        case 505: return "HTTP Version Not Supported";
        case 506: return "Variant Also Negotiates"; // RFC 2295
        case 507: return "Insufficient Storage"; // RFC 4918
        case 509: return "Bandwidth Limit Exceeded"; // Apache mod
        case 510: return "Not Extended"; // RFC 2774
        case 530: return "User access denied"; // ??
        default: break;
    }

    // default to the Nxx group names in RFC 2616
    if (100 <= code && code <= 199) {
        return "Informational";
    }
    else if (200 <= code && code <= 299) {
        return "Success";
    }
    else if (300 <= code && code <= 399) {
        return "Redirection";
    }
    else if (400 <= code && code <= 499) {
        return "Client Error";
    }
    else {
        return "Error";
    }
}

static int
prep_socket(int fd)
{
    int flags;
    struct linger linger = { .l_onoff = 0, .l_linger = 0 };

    // make it non-blocking
    flags = O_NONBLOCK;
    if (fcntl(fd, F_SETFL, flags) < 0)
        return -1;

    // flush writes immediately
    flags = 1;
#if PERL_DARWIN
    if (setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &flags, sizeof(int)))
#else
    if (setsockopt(fd, SOL_TCP, TCP_NODELAY, &flags, sizeof(int)))
#endif
        return -1;

    // handle URG data inline
    flags = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_OOBINLINE, &flags, sizeof(int)))
        return -1;

    // disable lingering
    if (setsockopt(fd, SOL_SOCKET, SO_LINGER, &linger, sizeof(linger)))
        return -1;

    return 0;
}

static struct feer_conn *
new_feer_conn (EV_P_ int conn_fd)
{
    // allocate an SV that can hold the feer_conn PLUS a string for the fd
    // so that dumping the SV from interpreter-land 
    SV *self = newSV(0);
    SvUPGRADE(self, SVt_PVMG); // ensures sv_bless doesn't reallocate
    SvGROW(self, sizeof(struct feer_conn));
    SvPOK_only(self);
    SvIOK_on(self);
    SvIV_set(self,conn_fd);

    struct feer_conn *c = (struct feer_conn *)SvPVX(self);
    Zero(c, 1, struct feer_conn);

    STRLEN label_len = snprintf(
        c->label, CONN_LABEL_LENGTH, "%"IVdf, conn_fd);

    // make the var readonly and make the visible portion just the fd number
    SvCUR_set(self, label_len);
    SvREADONLY_on(self); // turn off later for blessing

    c->self = self;
    c->fd = conn_fd;
    if (prep_socket(c->fd)) {
        perror("prep_socket");
        trace("prep_socket failed for %d", c->fd);
    }

    c->loop = loop; // from EV_P_

    // TODO: these initializations should be Lazy
    ev_io_init(&c->read_ev_io, try_conn_read, conn_fd, EV_READ);
    c->read_ev_io.data = (void *)c;

    ev_io_init(&c->write_ev_io, try_conn_write, conn_fd, EV_WRITE);
    c->write_ev_io.data = (void *)c;

    ev_init(&c->read_ev_timer, conn_read_timeout);
    c->read_ev_timer.repeat = read_timeout;
    c->read_ev_timer.data = (void *)c;
    ev_timer_again(EV_A, &c->read_ev_timer);

    trace("made conn fd=%d self=%p, c=%p, cur=%d, len=%d\n",
        c->fd, self, c, SvCUR(self), SvLEN(self));

    active_conns++;
    return c;
}

// for use in the typemap:
static struct feer_conn *
sv_2feer_conn (SV *rv)
{
    if (!sv_isa(rv,"Feersum::Connection"))
       croak("object is not of type Feersum::Connection");
    return (struct feer_conn *)SvPVX(SvRV(rv));
}

static SV*
feer_conn_2sv (struct feer_conn *c)
{
    SV *rv = newRV_inc(c->self);
    if (!SvOBJECT(c->self)) {
        trace("c->self not yet an object, SvCUR:%d\n",SvCUR(c->self));
        SvREADONLY_off(c->self);
        // XXX: should this block use newRV_noinc instead?
        sv_bless(rv, feer_conn_stash);
        SvREADONLY_on(c->self);
    }
    return rv;
}

static feer_conn_handle *
sv_2feer_conn_handle (SV *rv, bool can_croak)
{
    trace("sv 2 conn_handle\n");
    if (!SvROK(rv))
        croak("Expected a reference");
    // do not allow subclassing
    SV *sv = SvRV(rv);
    if (sv_isobject(rv) &&
        (SvSTASH(sv) == feer_conn_writer_stash ||
         SvSTASH(sv) == feer_conn_reader_stash))
    {
        UV uv = SvUV(sv);
        if (uv == 0) {
            if (can_croak) croak("Operation not allowed: Handle is closed.");
            return NULL;
        }
        return INT2PTR(feer_conn_handle*,uv);
    }

    if (can_croak)
        croak("Expected a Feersum::Connection::Writer or ::Reader object");
    return NULL;
}

static SV *
new_feer_conn_handle (struct feer_conn *c, bool is_writer)
{
    SV *sv;
    SvREFCNT_inc(c->self);
    sv = newRV_noinc(newSVuv(PTR2UV(c)));
    sv_bless(sv, is_writer ? feer_conn_writer_stash : feer_conn_reader_stash);
    return sv;
}

static void
process_request_ready_rinq (void)
{
    while (request_ready_rinq) {
        struct feer_conn *c =
            (struct feer_conn *)rinq_shift(&request_ready_rinq);
        trace("rinq shifted c=%p, head=%p\n", c, request_ready_rinq);

        call_request_callback(c);

        if (c->wbuf_rinq) {
            // this was deferred until after the perl callback
            conn_write_ready(c);
        }
        SvREFCNT_dec(c->self); // for the rinq
    }
}

static void
prepare_cb (EV_P_ ev_prepare *w, int revents)
{
    trace("prepare!\n");
    if (!ev_is_active(&accept_w) && !shutting_down) {
        ev_io_start(EV_A, &accept_w);
        //ev_prepare_stop(EV_A, w);
    }
}

static void
check_cb (EV_P_ ev_check *w, int revents)
{
    trace("check! head=%p\n", request_ready_rinq);
    process_request_ready_rinq();
}

static void
idle_cb (EV_P_ ev_idle *w, int revents)
{
    trace("idle! head=%p\n", request_ready_rinq);
    process_request_ready_rinq();
    ev_idle_stop(EV_A, w);
}

static void
try_conn_write(EV_P_ struct ev_io *w, int revents)
{
    dCONN;
    int i;

    if (!c->wbuf_rinq) {
        trace("tried to write with an empty buffer %d\n",w->fd);
        ev_io_stop(EV_A, w);
        return;
    }
    
    struct iomatrix *m = (struct iomatrix *)c->wbuf_rinq->ref;
#if DEBUG >= 2
    for (i=0; i < m->count; i++) {
        fprintf(stderr,"%.*s",m->iov[i].iov_len, m->iov[i].iov_base);
    }
#endif

    // TODO: handle errors in revents?

    trace("going to write %d off=%d count=%d\n", w->fd, m->offset, m->count);
    ssize_t wrote = writev(w->fd, &m->iov[m->offset], m->count - m->offset);
    trace("wrote %d bytes to %d\n", wrote, w->fd);
    if (wrote == -1) {
        if (errno == EAGAIN || errno == EINTR)
            goto try_write_again;
        perror("try_conn_write");
        goto try_write_finished;
    }
    if (wrote == 0) goto try_write_again;
    
    for (i = 0; i < m->count; i++) {
        struct iovec *v = &m->iov[i];
        if (v->iov_len > wrote) {
            // offset within vector
#if DEBUG >= 2
            trace("offset vector %d  base=%p len=%lu\n", w->fd, v->iov_base, v->iov_len);
#endif
            v->iov_base += wrote;
            v->iov_len  -= wrote;
        }
        else {
            // done with vector
#if DEBUG >= 2
            trace("consume vector %d base=%p len=%lu sv=%p\n", w->fd, v->iov_base, v->iov_len, m->sv[i]);
#endif
            wrote -= v->iov_len;
            m->offset++;
            if (m->sv[i]) {
                SvREFCNT_dec(m->sv[i]);
                m->sv[i] = NULL;
            }
        }
    }

    if (m->offset >= m->count) {
        trace("all done with iomatrix %d\n",w->fd);
        rinq_shift(&c->wbuf_rinq);
        Safefree(m);
        goto try_write_finished;
    }

try_write_again:
    trace("write again %d\n",w->fd);
    if (!ev_is_active(w)) {
        ev_io_start(EV_A, w);
    }
    return;

try_write_finished:
    // TODO: call a drain callback with success/error
    ev_io_stop(EV_A, w);
    // should always be responding, but just in case
    if (!c->responding || c->responding == RESPOND_SHUTDOWN) {
        shutdown(c->fd, SHUT_WR);
        // sleep(1);
        trace("ref dec after write %d\n", c->fd);
        // TODO: call a completion callback instead of just GCing
        SvREFCNT_dec(c->self);
    }
    return;
}

static int
try_parse_http(struct feer_conn *c, size_t last_read)
{
    struct feer_req *req = c->req;
    if (!req) {
        req = (struct feer_req *)
            calloc(1,sizeof(struct feer_req));
        req->num_headers = MAX_HEADERS;
        c->req = req;
    }
    return phr_parse_request(SvPVX(c->rbuf), SvCUR(c->rbuf),
        &req->method, &req->method_len,
        &req->path, &req->path_len, &req->minor_version,
        req->headers, &req->num_headers, 
        (SvCUR(c->rbuf)-last_read));
}

static void
try_conn_read(EV_P_ ev_io *w, int revents)
{
    dCONN;

    // TODO: handle errors in revents?

    if (c->receiving == RECEIVE_SHUTDOWN) {
        ev_io_stop(EV_A, w);
        ev_timer_stop(EV_A, &c->read_ev_timer);
        return;
    }

    trace("try read %d\n",w->fd);

    if (!c->rbuf) {
        trace("init rbuf for %d\n",w->fd);
        c->rbuf = newSV(2*READ_CHUNK + 1);
    }

    if (SvLEN(c->rbuf) - SvCUR(c->rbuf) < READ_CHUNK) {
        size_t new_len = SvLEN(c->rbuf) + READ_CHUNK;
        trace("moar memory %d: %d to %d\n",w->fd, SvLEN(c->rbuf),new_len);
        SvGROW(c->rbuf, new_len);
    }

    char *cur = SvPVX(c->rbuf) + SvCUR(c->rbuf);
    ssize_t got_n = read(w->fd, cur, READ_CHUNK);

    if (got_n == -1) {
        if (errno == EAGAIN || errno == EINTR)
            goto try_read_again;
        perror("try_conn_read");
        goto try_read_error;
    }
    else if (got_n == 0) {
        trace("EOF before complete request: %d\n",w->fd,SvCUR(c->rbuf));
        goto try_read_error;
    }

    trace("read %d %d\n", w->fd, got_n);
    SvCUR(c->rbuf) += got_n;
    if (c->receiving == RECEIVE_HEADERS) {
        int ret = try_parse_http(c, (size_t)got_n);
        if (ret == -1) goto try_read_error;
        if (ret == -2) goto try_read_again;

        if (process_request_headers(c, ret))
            goto try_read_again_reset_timer;
        else
            goto dont_read_again;
    }
    else if (c->receiving == RECEIVE_BODY) {
        c->received_cl += got_n;
        if (c->received_cl < c->expected_cl)
            goto try_read_again_reset_timer;
        // body is complete
        sched_request_callback(c);
        goto dont_read_again;
    }
    else {
        warn("unknown read state %d %d", w->fd, c->receiving);
    }

try_read_error:
    trace("try read error %d\n", w->fd);
    c->receiving = RECEIVE_SHUTDOWN;
    c->responding = RESPOND_SHUTDOWN;
    ev_io_stop(EV_A, w);
    ev_timer_stop(EV_A, &c->read_ev_timer);
    shutdown(c->fd, SHUT_RDWR);
    SvREFCNT_dec(c->self);
    return;

dont_read_again:
    trace("done reading %d\n", w->fd);
    c->receiving = RECEIVE_SHUTDOWN;
    ev_io_stop(EV_A, w);
    ev_timer_stop(EV_A, &c->read_ev_timer);
    shutdown(c->fd, SHUT_RD); // TODO: respect keep-alive
    return;

try_read_again_reset_timer:
    trace("(reset read timer) %d\n", w->fd);
    ev_timer_again(EV_A, &c->read_ev_timer);
try_read_again:
    trace("read again %d\n", w->fd);
    if (!ev_is_active(w)) {
        ev_io_start(EV_A,w);
    }
    return;
}

static void
conn_read_timeout (EV_P_ ev_timer *w, int revents)
{
    dCONN;

    trace("read timeout %d\n", c->fd);
    if (revents != EV_TIMER || c->receiving == RECEIVE_SHUTDOWN) {
        return;
    }

    c->receiving = RECEIVE_SHUTDOWN;
    ev_io_stop(EV_A, &c->read_ev_io);

    // always stop since, for efficiency, we set this up as a recurring timer.
    ev_timer_stop(EV_A, w);


    if (c->responding == RESPOND_NOT_STARTED) {
        shutdown(c->fd, SHUT_RD);
        const char *msg;
        if (c->receiving == RECEIVE_HEADERS) {
            msg = "Headers took too long.";
        }
        else {
            msg = "Timeout reading body.";
        }
        respond_with_server_error(c, msg, 0, 408);
        return;
    }
    else {
        shutdown(c->fd, SHUT_RDWR);
        c->responding = RESPOND_SHUTDOWN;
    }

    // TODO: trigger the Reader poll callback with an error, if present

    SvREFCNT_dec(c->self);
}

static void
accept_cb (EV_P_ ev_io *w, int revents)
{
    struct sockaddr_in sa;
    socklen_t sl = sizeof(struct sockaddr_in);

    trace("accept! revents=0x%08x\n", revents);
    if (!(revents & EV_READ))
        return;

    if (shutting_down) {
        // shouldn't get called, but be defensive
        close(w->fd);
        ev_io_stop(EV_A, w);
        return;
    }

    while (1) {
        sl = sizeof(struct sockaddr_in);
        int fd = accept(w->fd, (struct sockaddr *)&sa, &sl);
        if (fd == -1) break;

        // TODO: put the sockaddr in with the conn
        struct feer_conn *c = new_feer_conn(EV_A, fd);
        // XXX: good idea to read right away?
        // try_conn_read(EV_A, &c->read_ev_io, EV_READ);
        ev_io_start(EV_A, &c->read_ev_io);
    }
}

static void
sched_request_callback (struct feer_conn *c)
{
    trace("rinq push: c=%p, head=%p\n", c, request_ready_rinq);
    rinq_push(&request_ready_rinq, c);
    SvREFCNT_inc(c->self); // for the rinq
    if (!ev_is_active(&ei)) {
        ev_idle_start(c->loop, &ei);
    }
}

static bool
process_request_headers (struct feer_conn *c, int body_offset)
{
    int err_code;
    const char *err;
    struct feer_req *req = c->req;

    trace("body follows headers, making new rbuf\n");
    bool body_is_required;

    c->receiving = RECEIVE_BODY;

    if (str_eq("GET", 3, req->method, req->method_len) ||
        str_eq("HEAD", 4, req->method, req->method_len) ||
        str_eq("DELETE", 6, req->method, req->method_len))
    {
        // Not supposed to have a body.  Additional bytes are either a mistake
        // or pipelined requests under HTTP/1.1

        // XXX ignore them for now
        goto got_it_all;
    }
    else if (str_eq("PUT", 3, req->method, req->method_len) ||
             str_eq("POST", 4, req->method, req->method_len))
    {
        // MUST have a body
        body_is_required = 1;
    }
    else {
        err = "Feersum doesn't support that method yet\n";
        err_code = 405;
        goto got_bad_request;
    }
    
    // a body potentially follows the headers. Let feer_req retain its
    // pointers into rbuf and make a new scalar for more body data.
    int need = SvCUR(c->rbuf) - body_offset;
    char *from  = SvPVX(c->rbuf) + body_offset;
    SV *new_rbuf = newSV((need > 2*READ_CHUNK) ? need-1 : 2*READ_CHUNK-1);
    if (need)
        sv_setpvn(new_rbuf, from, need);
    req->buf = c->rbuf;
    c->rbuf = new_rbuf;

    // determine how much we need to read
    int i;
    UV expected = 0;
    for (i=0; i < req->num_headers; i++) {
        struct phr_header *hdr = &req->headers[i];
        if (!hdr->name) continue;
        // XXX: ignore multiple C-L headers?
        if (str_case_eq("content-length", 14, hdr->name, hdr->name_len)) {
            int g = grok_number(hdr->value, hdr->value_len, &expected);
            if (g == IS_NUMBER_IN_UV) {
                if (expected > MAX_BODY_LENGTH) {
                    err_code = 413;
                    err = "Content length exceeds maximum\n";
                    goto got_bad_request;
                }
                else
                    goto got_cl;
            }
            else {
                err_code = 400;
                err = "invalid content-length\n";
                goto got_bad_request;
            }
        }
        // TODO: support "Connection: close" bodies
        // TODO: support "Transfer-Encoding: chunked" bodies
    }

    if (body_is_required) {
        // Go the nginx route...
        err_code = 411;
        err = "Content-Length required\n";
    }
    else {
        // XXX TODO support requests that don't require a body
        err_code = 418;
        err = "Feersum doesn't know how to handle optional-body requests yet\n";
    }

got_bad_request:
    respond_with_server_error(c, err, 0, err_code);
    return 0;

got_cl:
    c->expected_cl = expected;
    c->received_cl = SvCUR(c->rbuf);

    // don't have enough bytes to schedule immediately?
    if (c->expected_cl && c->received_cl < c->expected_cl) {
        // TODO: schedule the callback immediately and support a non-blocking
        // ->read method.
        // sched_request_callback(c);
        // c->receiving = RECEIVE_STREAM;
        return 1;
    }
    // fallthrough: have enough bytes
got_it_all:
    c->receiving = RECEIVE_SHUTDOWN;
    shutdown(c->fd, SHUT_RD);
    sched_request_callback(c);
    return 0;
}

static void
conn_write_ready (struct feer_conn *c)
{
    if (c->in_callback) return; // defer until out of callback

    if (!ev_is_active(&c->write_ev_io)) {
#if AUTOCORK_WRITES
        ev_io_start(c->loop, &c->write_ev_io);
#else
        // attempt a non-blocking write immediately if we're not already
        // waiting for writability
        try_conn_write(c->loop, &c->write_ev_io, EV_WRITE);
#endif
    }
}

static void
respond_with_server_error (struct feer_conn *c, const char *msg, STRLEN msg_len, int err_code)
{
    SV *tmp;

    if (c->responding != RESPOND_NOT_STARTED) {
        trouble("Tried to send server error but already responding!");
        return;
    }

    if (!msg_len) msg_len = strlen(msg);

    tmp = newSVpvf("HTTP/1.1 %d %s" CRLF
                   "Content-Type: text/plain" CRLF
                   "Connection: close" CRLF
                   "Content-Length: %d" CRLFx2
                   "%.*s",
              err_code, http_code_to_msg(err_code), msg_len, msg_len, msg);
    add_sv_to_wbuf(c, sv_2mortal(tmp));

    shutdown(c->fd, SHUT_RD);
    c->responding = RESPOND_SHUTDOWN;
    c->receiving = RECEIVE_SHUTDOWN;
    conn_write_ready(c);
}

INLINE_UNLESS_DEBUG bool
str_eq(const char *a, int a_len, const char *b, int b_len)
{
    if (a_len != b_len) return 0;
    if (a == b) return 1;
    int i;
    for (i=0; i<a_len && i<b_len; i++) {
        if (a[i] != b[i]) return 0;
    }
    return 1;
}

/*
 * Compares two strings, assumes that the first string is already lower-cased
 */
INLINE_UNLESS_DEBUG bool
str_case_eq(const char *a, int a_len, const char *b, int b_len)
{
    if (a_len != b_len) return 0;
    if (a == b) return 1;
    int i;
    for (i=0; i<a_len && i<b_len; i++) {
        if (a[i] != tolower(b[i])) return 0;
    }
    return 1;
}

INLINE_UNLESS_DEBUG int
hex_decode(const char ch)
{
    if ('0' <= ch && ch <= '9')
        return ch - '0';
    else if ('A' <= ch && ch <= 'F')
        return ch - 'A' + 10;
    else if ('a' <= ch && ch <= 'f')
        return ch - 'a' + 10;
    return -1;
}

static void
uri_decode_sv (SV *sv)
{
    STRLEN len;
    char *ptr, *end, *decoded;

    ptr = SvPV(sv, len);
    end = SvEND(sv);
    while (ptr < end) {
        if (*ptr == '%') goto needs_decode;
        ptr++;
    }
    return;

needs_decode:

    // Up until ptr have been "decoded" already by virtue of those chars not
    // being encoded.
    decoded = ptr;

    for (; ptr < end; ptr++) {
        if (*ptr == '%' && end-ptr >= 2) {
            int c1 = hex_decode(ptr[1]);
            int c2 = hex_decode(ptr[2]);
            if (c1 != -1 && c2 != -1) {
                *decoded++ = (c1 << 4) + c2;
                ptr += 2;
                continue;
            }
        }
        *decoded++ = *ptr;
    }

    *decoded = '\0'; // play nice with C

    ptr = SvPV_nolen(sv);
    SvCUR_set(sv, decoded-ptr);
}

void
call_request_callback (struct feer_conn *c)
{
    dSP;
    SV *sv_self;

    c->in_callback++;

    sv_self = feer_conn_2sv(c);

    trace("request callback c=%p self=%p\n", c, sv_self);

    ENTER;
    SAVETMPS;

    PUSHMARK(SP);
    XPUSHs(sv_2mortal(sv_self));

    trace("calling request callback, errsv? %d\n", SvTRUE(ERRSV) ? 1 : 0);

    PUTBACK;
    call_sv(request_cb_cv, G_DISCARD|G_EVAL|G_VOID);
    SPAGAIN;

    trace("called request callback, errsv? %d\n", SvTRUE(ERRSV) ? 1 : 0);

    if (SvTRUE(ERRSV)) {
        STRLEN err_len;
        char *err = SvPV(ERRSV,err_len);
        trace("an error was thrown in the request callback: %.*s\n",err_len,err);
        PUSHMARK(SP);
        XPUSHs(sv_2mortal(newSVsv(ERRSV)));
        PUTBACK;
        call_pv("Feersum::DIED", G_DISCARD|G_EVAL|G_VOID|G_KEEPERR);
        SPAGAIN;

        respond_with_server_error(c,"Request handler exception.\n",0,500);
        sv_setsv(ERRSV, &PL_sv_undef);
    }

    trace("leaving request callback\n");
    PUTBACK;
    FREETMPS;
    LEAVE;

    c->in_callback--;
}

MODULE = Feersum		PACKAGE = Feersum		

PROTOTYPES: ENABLE

void
accept_on_fd(SV *self, int fd)
    PPCODE:
{
    trace("going to accept on %d\n",fd);

    ev_prepare_init(&ep, prepare_cb);
    ev_prepare_start(EV_DEFAULT, &ep);

    ev_check_init(&ec, check_cb);
    ev_check_start(EV_DEFAULT, &ec);

    ev_idle_init(&ei, idle_cb);

    ev_io_init(&accept_w, accept_cb, fd, EV_READ);
}

void
request_handler(SV *self, SV *cb)
    PROTOTYPE: $&
    PPCODE:
{
    if (!SvROK(cb) || SvTYPE(SvRV(cb)) != SVt_PVCV)
        croak("must supply a code reference");
    if (request_cb_cv)
        SvREFCNT_dec(request_cb_cv);
    request_cb_cv = SvRV(cb);
    SvREFCNT_inc(request_cb_cv);
    trace("assigned request handler %p\n", SvRV(cb));
}

void
graceful_shutdown (SV *self, SV *cb)
    PROTOTYPE: $&
    PPCODE:
{
    if (!SvROK(cb) || SvTYPE(SvRV(cb)) != SVt_PVCV)
        croak("must supply a code reference");
    if (shutting_down)
        croak("already shutting down");
    shutdown_cb_cv = SvRV(cb);
    SvREFCNT_inc(shutdown_cb_cv);
    trace("assigned shutdown handler %p\n", SvRV(cb));

    shutting_down = 1;
    ev_io_stop(EV_DEFAULT, &accept_w);
    close(accept_w.fd);
}

double
read_timeout (SV *self, ...)
    PROTOTYPE: $;$
    CODE:
{
    if (items <= 1) {
        RETVAL = read_timeout;
    }
    else if (items == 2) {
        SV *duration = ST(1);
        NV new_read_timeout = SvNV(duration);
        if (!(new_read_timeout > 0.0)) {
            croak("must set a positive (non-zero) value for the timeout");
        }
        read_timeout = (double) new_read_timeout;
    }
}
    OUTPUT:
        RETVAL

void
DESTROY (SV *self)
    PPCODE:
{
    trace("DESTROY server\n");
    if (request_cb_cv)
        SvREFCNT_dec(request_cb_cv);
}

MODULE = Feersum	PACKAGE = Feersum::Connection::Handle

PROTOTYPES: ENABLE

int
fileno (feer_conn_handle *hdl)
    CODE:
        RETVAL = c->fd;
    OUTPUT:
        RETVAL

void
DESTROY (SV *self)
    PPCODE:
{
    feer_conn_handle *hdl = sv_2feer_conn_handle(self, 0);
    if (hdl == NULL) {
        trace("DESTROY handle (closed) class=%s\n", HvNAME(SvSTASH(SvRV(ST(0)))));
    }
    else {
        struct feer_conn *c = (struct feer_conn *)hdl;
        trace("DESTROY handle fd=%d, class=%s\n", c->fd, HvNAME(SvSTASH(SvRV(ST(0)))));
        SvREFCNT_dec(c->self);
    }
}

SV*
read (feer_conn_handle *hdl, SV *buf, size_t len, ...)
    PROTOTYPE: $$$;$
    PPCODE:
{
    STRLEN buf_len, src_len;
    char *buf_ptr, *src_ptr;
    bool src_ookd;
    
    //  if (items > 3 && SvOK(ST(3)) && SvIOK(ST(3)))
    //      off = SvUV(ST(3));
    if (items > 3)
        croak("reading with an offset is not yet supported");

    if (c->receiving <= RECEIVE_HEADERS)
        croak("can't call read() until the body begins to arrive");

    if (!SvOK(buf) || !SvPOK(buf)) {
        SvUPGRADE(buf, SVt_PV);
    }

    if (SvREADONLY(buf))
        croak("buffer must not be read-only");

    buf_ptr = SvPV(buf, buf_len);
    if (c->rbuf) {
        trace("getting rbuf src_ptr\n");
        src_ptr = SvPV(c->rbuf, src_len);
    }

    if (!c->rbuf || src_len == 0) {
        trace("rbuf empty during read %d\n", c->fd);
        if (c->receiving == RECEIVE_SHUTDOWN) {
            XSRETURN_IV(0); // all done
        }
        else {
            errno = EAGAIN; // need to wait for more
            XSRETURN_UNDEF;
        }
    }

    if (len == -1) len = src_len;

    if (len >= src_len) {
        trace("appending entire rbuf %d\n", c->fd);
        sv_2mortal(c->rbuf); // allow pv to be stolen
        if (buf_len == 0) {
            sv_setsv(buf, c->rbuf);
        }
        else {
            sv_catsv(buf, c->rbuf);
        }
        c->rbuf = NULL;
        XSRETURN_IV(src_len);
    }
    else {
        trace("appending partial rbuf %d len=%d ptr=%p\n", c->fd, len, SvPVX(c->rbuf));
        // partial append
        SvGROW(buf, SvCUR(buf) + len);
        sv_catpvn(buf, src_ptr, len);
        sv_chop(c->rbuf, SvPVX(c->rbuf) + len);
        XSRETURN_IV(len);
    }

    XSRETURN_UNDEF;
}

STRLEN
write (feer_conn_handle *hdl, SV *body, ...)
    CODE:
{
    if (c->responding != RESPOND_STREAMING)
        croak("can only call write in streaming mode");

    if (!SvOK(body)) {
        XSRETURN_IV(0);
    }

    trace("write fd=%d c=%p, body=%p\n", c->fd, c, body);
    if (SvROK(body)) {
        SV *refd = SvRV(body);
        if (SvOK(refd) && SvPOK(refd)) {
            body = refd;
        }
        else {
            croak("body must be a scalar, scalar ref or undef");
        }
    }
    (void)SvPV(body, RETVAL);
    add_chunk_sv_to_wbuf(c, body);
    conn_write_ready(c);
}
    OUTPUT:
        RETVAL

int
_close (feer_conn_handle *hdl)
    PROTOTYPE: $
    ALIAS:
        Feersum::Connection::Reader::close = 1
        Feersum::Connection::Writer::close = 2
    CODE:
{
    SV *hdl_sv = SvRV(ST(0));

    switch (ix) {
    case 1:
        trace("close reader fd=%d, c=%p\n", c->fd, c);
        RETVAL = shutdown(c->fd, SHUT_RD); // TODO: respect keep-alive
        c->receiving = RECEIVE_SHUTDOWN;
        break;
    case 2:
        trace("close writer fd=%d, c=%p\n", c->fd, c);
        add_chunk_sv_to_wbuf(c, NULL);
        conn_write_ready(c);
        c->responding = RESPOND_SHUTDOWN;
        RETVAL = 1;
        break;
    default:
        croak("cannot call _close directly");
    }

    // disassociate the handle from the conn
    SvUVX(hdl_sv) = 0;
    SvREFCNT_dec(c->self);
}
    OUTPUT:
        RETVAL

void
_poll_cb (feer_conn_handle *hdl, CV *cb)
    PROTOTYPE: $&
    ALIAS:
        Feersum::Connection::Reader::poll_cb = 1
        Feersum::Connection::Writer::poll_cb = 2
    PPCODE:
{
    croak("poll_cb is not yet supported (ix=%d)", ix);
}

MODULE = Feersum	PACKAGE = Feersum::Connection

PROTOTYPES: ENABLE

void
start_response (struct feer_conn *c, SV *message, AV *headers, int streaming)
    PROTOTYPE: $$\@$
    PPCODE:
{
    const char *ptr;
    STRLEN len;
    I32 i;

    trace("start_response fd=%d streaming=%d\n", c->fd, streaming);

    if (c->responding)
        croak("already responding!");
    c->responding = streaming ? RESPOND_STREAMING : RESPOND_NORMAL;

    if (!SvOK(message) || !(SvIOK(message) || SvPOK(message))) {
        croak("Must define an HTTP status code or message");
    }

    I32 avl = av_len(headers);
    if (avl < 0 || (avl % 2 != 1)) {
        croak("expected even-length array");
    }

    // int or 3 chars? use a stock message
    if (SvIOK(message) || (SvPOK(message) && SvCUR(message) == 3)) {
        int code = SvIV(message);
        ptr = http_code_to_msg(code);
        len = strlen(ptr);
        message = sv_2mortal(newSVpvf("%d %.*s",code,len,ptr));
    }

    add_const_to_wbuf(c, streaming ? "HTTP/1.1 " : "HTTP/1.0 ", 9);
    add_sv_to_wbuf(c, message);
    add_const_to_wbuf(c, CRLF, 2);

    for (i=0; i<avl; i+= 2) {
        SV **hdr = av_fetch(headers, i, 0);
        if (!hdr || !SvOK(*hdr)) {
            trouble("skipping undef header key");
            continue;
        }

        SV **val = av_fetch(headers, i+1, 0);
        if (!val || !SvOK(*val)) {
            trouble("skipping undef header value");
            continue;
        }

        STRLEN hlen;
        const char *hp = SvPV(*hdr, hlen);
        if (str_case_eq("content-length",14,hp,hlen)) {
            trouble("ignoring content-length header in the response");
            continue; 
        }

        add_sv_to_wbuf(c, *hdr);
        add_const_to_wbuf(c, ": ", 2);
        add_sv_to_wbuf(c, *val);
        add_const_to_wbuf(c, CRLF, 2);
    }

    if (streaming) {
        add_const_to_wbuf(c, "Transfer-Encoding: chunked" CRLFx2, 30);
    }

    conn_write_ready(c);
}

int
write_whole_body (struct feer_conn *c, SV *body)
    PROTOTYPE: $$
    CODE:
{
    int i;
    bool body_is_string = 0;
    STRLEN cur;

    if (c->responding != RESPOND_NORMAL)
        croak("can't use write_whole_body when in streaming mode");

    if (!SvOK(body)) {
        body = sv_2mortal(newSVpvn("",0));
        body_is_string = 1;
    }
    else if (SvROK(body)) {
        SV *refd = SvRV(body);
        if (SvOK(refd) && !SvROK(refd)) {
            body = refd;
            body_is_string = 1;
        }
        else if (SvTYPE(refd) != SVt_PVAV) {
            croak("body must be a scalar, scalar reference or array reference");
        }
    }
    else {
        body_is_string = 1;
    }

    SV *cl_sv; // content-length future
    struct iovec *cl_iov;
    add_placeholder_to_wbuf(c, &cl_sv, &cl_iov);

    if (body_is_string) {
        cur = add_sv_to_wbuf(c,body);
        RETVAL = cur;
    }
    else {
        AV *abody = (AV*)SvRV(body);
        I32 amax = av_len(abody);
        RETVAL = 0;
        for (i=0; i<=amax; i++) {
            SV **elt = av_fetch(abody, i, 0);
            if (elt == NULL || !SvOK(*elt)) continue;
            SV *sv = SvROK(*elt) ? SvRV(*elt) : *elt;
            cur = add_sv_to_wbuf(c,sv);
            trace("body part i=%d sv=%p cur=%d\n", i, sv, cur);
            RETVAL += cur;
        }
    }

    sv_setpvf(cl_sv, "Content-Length: %d" CRLFx2, RETVAL);
    update_wbuf_placeholder(c, cl_sv, cl_iov);

    c->responding = RESPOND_SHUTDOWN;
    conn_write_ready(c);
}
    OUTPUT:
        RETVAL

SV *
_handle (struct feer_conn *c)
    PROTOTYPE: $
    ALIAS:
        read_handle = 1
        write_handle = 2
    CODE:
        if(!ix) croak("cannot call _handle directly");
        RETVAL = new_feer_conn_handle(c, ix-1);
    OUTPUT:
        RETVAL

void
env (struct feer_conn *c, HV *e)
    PROTOTYPE: $\%
    PPCODE:
{
    SV **hsv;
    int i,j;
    struct feer_req *r = c->req;

    //  strlen: 012345678901234567890
    hv_store(e, "psgi.version", 12, newRV((SV*)psgi_ver), 0);
    hv_store(e, "psgi.url_scheme", 15, newSVpvn("http",4), 0);
    hv_store(e, "psgi.nonblocking", 16, &PL_sv_yes, 0);
    hv_store(e, "psgi.multithreaded", 18, &PL_sv_yes, 0);
    hv_store(e, "psgi.streaming", 14, &PL_sv_yes, 0);
    hv_store(e, "psgi.errors", 11, newRV((SV*)PL_stderrgv), 0);
    hv_store(e, "REQUEST_URI", 11, newSVpvn(r->path,r->path_len),0);
    hv_store(e, "REQUEST_METHOD", 14, newSVpvn(r->method,r->method_len),0);
    hv_store(e, "SCRIPT_NAME", 11, newSVpvn("",0),0);
    hv_store(e, "SERVER_PROTOCOL", 15, (r->minor_version == 1) ? newSVsv(psgi_serv11) : newSVsv(psgi_serv10), 0);

    if (c->expected_cl >= 0) {
        hv_store(e, "CONTENT_LENGTH", 14, newSViv(c->expected_cl), 0);
        hv_store(e, "psgi.input", 10, new_feer_conn_handle(c,0), 0);
    }
    else {
        hv_store(e, "CONTENT_LENGTH", 14, newSViv(0), 0);
        hv_store(e, "psgi.input", 10, &PL_sv_undef, 0);
    }

    {
        const char *qpos = r->path;
        SV *pinfo, *qstr;
        while (*qpos != '?' && qpos < r->path + r->path_len) {
            qpos++;
        }
        if (*qpos == '?') {
            pinfo = newSVpvn(r->path, (qpos - r->path));
            qpos++;
            qstr = newSVpvn(qpos, r->path_len - (qpos - r->path));
        }
        else {
            pinfo = newSVpvn(r->path, r->path_len);
            qstr = newSVpvn("",0);
        }
        uri_decode_sv(pinfo);
        hv_store(e, "PATH_INFO", 9, pinfo, 0);
        hv_store(e, "QUERY_STRING", 12, qstr, 0);
    }

    SV *val = NULL;
    char *kbuf;
    size_t kbuflen = 64;
    Newx(kbuf, kbuflen, char);
    kbuf[0]='H'; kbuf[1]='T'; kbuf[2]='T'; kbuf[3]='P'; kbuf[4]='_';

    for (i=0; i<r->num_headers; i++) {
        struct phr_header *hdr = &(r->headers[i]);
        if (hdr->name == NULL && val != NULL) {
            trace("... multiline %.*s\n", hdr->value_len, hdr->value);
            sv_catpvn(val, hdr->value, hdr->value_len);
        }
        else if (str_case_eq("content-length", 14, hdr->name, hdr->name_len)) {
            // content length shouldn't show up as HTTP_CONTENT_LENGTH but
            // as CONTENT_LENGTH in the env-hash.
            continue;
        }
        else {
            size_t klen = 5+hdr->name_len;
            if (kbuflen < klen) {
                kbuflen = klen;
                kbuf = Renew(kbuf, kbuflen, char);
            }
            char *key = kbuf + 5;
            for (j=0; j<hdr->name_len; j++) {
                char n = hdr->name[j];
                *key++ = (n == '-') ? '_' : toupper(n);
            }

            SV **val = hv_fetch(e, kbuf, klen, 1);
            trace("adding header to env %.*s: %.*s\n",
                klen, kbuf, hdr->value_len, hdr->value);

            assert(val != NULL); // "fetch is store" flag should ensure this
            if (SvPOK(*val)) {
                trace("... is multivalue\n");
                // extend header with comma
                sv_catpvf(*val, ", %.*s", hdr->value_len, hdr->value);
            }
            else {
                // change from undef to a real value
                sv_setpvn(*val, hdr->value, hdr->value_len);
            }
        }
    }

    Safefree(kbuf);
}

int
fileno (struct feer_conn *c)
    CODE:
        RETVAL = c->fd;
    OUTPUT:
        RETVAL

void
DESTROY (struct feer_conn *c)
    PPCODE:
{
    int i;
    trace("DESTROY conn %d %p\n", c->fd, c);

    if (c->rbuf) SvREFCNT_dec(c->rbuf);

    if (c->wbuf_rinq) {
        struct iomatrix *m;
        while ((m = (struct iomatrix *)rinq_shift(&c->wbuf_rinq)) != NULL) {
            for (i=0; i < m->count; i++) {
                if (m->sv[i]) SvREFCNT_dec(m->sv[i]);
            }
            Safefree(m);
        }
    }

    if (c->req) {
        if (c->req->buf) SvREFCNT_dec(c->req->buf);
        free(c->req);
    }

    if (c->fd) close(c->fd);

    active_conns--;

    if (shutting_down && active_conns <= 0) {
        ev_idle_stop(EV_DEFAULT, &ei);
        ev_prepare_stop(EV_DEFAULT, &ep);
        ev_check_stop(EV_DEFAULT, &ec);

        trace("... was last conn, going to try shutdown\n");
        if (shutdown_cb_cv) {
            PUSHMARK(SP);
            call_sv(shutdown_cb_cv, G_EVAL|G_VOID|G_DISCARD|G_NOARGS|G_KEEPERR);
            PUTBACK;
            trace("... ok, called that handler\n");
            SvREFCNT_dec(shutdown_cb_cv);
            shutdown_cb_cv = NULL;
        }
    }
#ifdef DEBUG
    sv_dump(c->self);
    // overwrite for debugging
    Poison(c, 1, struct feer_conn);
#endif
}

MODULE = Feersum	PACKAGE = Feersum		

BOOT:
    {
        feer_stash = gv_stashpv("Feersum", 1);
        feer_conn_stash = gv_stashpv("Feersum::Connection", 1);
        feer_conn_writer_stash = gv_stashpv("Feersum::Connection::Writer",0);
        feer_conn_reader_stash = gv_stashpv("Feersum::Connection::Reader",0);
        I_EV_API("Feersum");

        SV *ver_svs[2];
        ver_svs[0] = newSViv(1);
        ver_svs[1] = newSViv(0);
        psgi_ver = av_make(2,ver_svs);
        SvREFCNT_dec(ver_svs[0]);
        SvREFCNT_dec(ver_svs[1]);
        SvREADONLY_on((SV*)psgi_ver);

        psgi_serv10 = newSVpvn("HTTP/1.0",8);
        SvREADONLY_on(psgi_serv10);
        psgi_serv11 = newSVpvn("HTTP/1.1",8);
        SvREADONLY_on(psgi_serv11);
    }
