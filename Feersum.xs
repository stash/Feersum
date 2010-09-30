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

#if DEBUG >= 2
#define trace2(f_, ...) trace(f_, ##__VA_ARGS__)
#else
#define trace2(...)
#endif

#if DEBUG >= 3
#define trace3(f_, ...) trace(f_, ##__VA_ARGS__)
#else
#define trace3(...)
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

#define RESPOND_NOT_STARTED 0
#define RESPOND_NORMAL 1
#define RESPOND_STREAMING 2
#define RESPOND_SHUTDOWN 3
#define RECEIVE_HEADERS 0
#define RECEIVE_BODY 1
#define RECEIVE_STREAMING 2
#define RECEIVE_SHUTDOWN 3

struct feer_conn {
    SV *self;
    int fd;
    struct sockaddr *sa;

    struct ev_io read_ev_io;
    struct ev_io write_ev_io;
    struct ev_timer read_ev_timer;

    SV *rbuf;
    struct rinq *wbuf_rinq;

    SV *poll_write_cb;

    struct feer_req *req;
    ssize_t expected_cl;
    ssize_t received_cl;

    U16 in_callback;
    U16 responding;
    U16 receiving;
    U16 _reservedflags:14;
    U16 is_http11:1;
    U16 poll_write_cb_is_io_handle:1;
};

typedef struct feer_conn feer_conn_handle; // for typemap

#define dCONN struct feer_conn *c = (struct feer_conn *)w->data
#define IsArrayRef(_x) (SvROK(_x) && SvTYPE(SvRV(_x)) == SVt_PVAV)
#define IsCodeRef(_x) (SvROK(_x) && SvTYPE(SvRV(_x)) == SVt_PVCV)

static HV* feersum_env(pTHX_ struct feer_conn *c);
static void feersum_start_response
    (pTHX_ struct feer_conn *c, SV *message, AV *headers, int streaming);
static int feersum_write_whole_body (pTHX_ struct feer_conn *c, SV *body);
static void feersum_handle_psgi_response(pTHX_ struct feer_conn *c, SV *ret);

static void try_conn_write(EV_P_ struct ev_io *w, int revents);
static void try_conn_read(EV_P_ struct ev_io *w, int revents);
static void conn_read_timeout(EV_P_ struct ev_timer *w, int revents);
static bool process_request_headers(struct feer_conn *c, int body_offset);
static void sched_request_callback(struct feer_conn *c);
static void call_died (pTHX_ struct feer_conn *c, const char *cb_type);
static void call_request_callback(struct feer_conn *c);
static void call_poll_callback (struct feer_conn *c, bool is_write);
static void pump_io_handle (struct feer_conn *c, SV *io);

static void conn_write_ready (struct feer_conn *c);
static void respond_with_server_error(struct feer_conn *c, const char *msg, STRLEN msg_len, int code);

static STRLEN add_sv_to_wbuf (struct feer_conn *c, SV *sv);
static STRLEN add_const_to_wbuf (struct feer_conn *c, const char const *str, size_t str_len);
static void finish_wbuf (struct feer_conn *c);
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
static bool request_cb_is_psgi = 0;
static SV *shutdown_cb_cv = NULL;
static bool shutting_down = 0;
static int active_conns = 0;
static double read_timeout = 5.0;

static SV *feer_server_name = NULL;
static SV *feer_server_port = NULL;

static ev_io accept_w;
static ev_prepare ep;
static ev_check   ec;
struct ev_idle    ei;

static struct rinq *request_ready_rinq = NULL;

static AV *psgi_ver;
static SV *psgi_serv10, *psgi_serv11, *crlf_sv;

// TODO: make this thread-local if and when there are multiple C threads:
struct ev_loop *feersum_ev_loop = NULL;
static HV *feersum_tmpl_env = NULL;

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
        Newx(m,1,struct iomatrix);
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
    if (SvMAGICAL(sv)) {
        sv = newSVsv(sv); // copy to force it to be normal.
    }
    else if (SvPADTMP(sv) || SvTEMP(sv)) {
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

static void
finish_wbuf(struct feer_conn *c)
{
    if (!c->is_http11) return; // nothing required
    add_const_to_wbuf(c, "0\r\n\r\n", 5); // terminating chunk
}

#define update_wbuf_placeholder(c,sv,iov) iov->iov_base = SvPV(sv, iov->iov_len)

static void
add_chunk_sv_to_wbuf(struct feer_conn *c, SV *sv)
{
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
new_feer_conn (EV_P_ int conn_fd, struct sockaddr *sa)
{
    SV *self = newSV(0);
    SvUPGRADE(self, SVt_PVMG); // ensures sv_bless doesn't reallocate
    SvGROW(self, sizeof(struct feer_conn));
    SvPOK_only(self);
    SvIOK_on(self);
    SvIV_set(self,conn_fd);

    struct feer_conn *c = (struct feer_conn *)SvPVX(self);
    Zero(c, 1, struct feer_conn);

    SvREADONLY_on(self); // turn off later for blessing

    c->self = self;
    c->fd = conn_fd;
    c->sa = sa;
    if (prep_socket(c->fd)) {
        perror("prep_socket");
        trace("prep_socket failed for %d\n", c->fd);
    }

    ev_io_init(&c->read_ev_io, try_conn_read, conn_fd, EV_READ);
    c->read_ev_io.data = (void *)c;

    ev_init(&c->read_ev_timer, conn_read_timeout);
    c->read_ev_timer.repeat = read_timeout;
    c->read_ev_timer.data = (void *)c;
    ev_timer_again(EV_A, &c->read_ev_timer);

    trace3("made conn fd=%d self=%p, c=%p, cur=%d, len=%d\n",
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
        trace3("c->self not yet an object\n");
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
    trace3("sv 2 conn_handle\n");
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
        //trace("rinq shifted c=%p, head=%p\n", c, request_ready_rinq);

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
    if (revents & EV_ERROR) {
        trouble("EV error in prepare, revents=0x%08x\n", revents);
        ev_unloop(EV_A, EVUNLOOP_ALL);
        return;
    }

    if (!ev_is_active(&accept_w) && !shutting_down) {
        ev_io_start(EV_A, &accept_w);
    }
    ev_prepare_stop(EV_A, w);
}

static void
check_cb (EV_P_ ev_check *w, int revents)
{
    if (revents & EV_ERROR) {
        trouble("EV error in check, revents=0x%08x\n", revents);
        ev_unloop(EV_A, EVUNLOOP_ALL);
        return;
    }
    trace3("check! head=%p\n", request_ready_rinq);
    process_request_ready_rinq();
}

static void
idle_cb (EV_P_ ev_idle *w, int revents)
{
    if (revents & EV_ERROR) {
        trouble("EV error in idle, revents=0x%08x\n", revents);
        ev_unloop(EV_A, EVUNLOOP_ALL);
        return;
    }
    trace3("idle! head=%p\n", request_ready_rinq);
    process_request_ready_rinq();
    ev_idle_stop(EV_A, w);
}

static void
try_conn_write(EV_P_ struct ev_io *w, int revents)
{
    dCONN;
    int i;

    // if it's marked readable EV suggests we simply try write to it.
    // Otherwise it is stopped and we should ditch this connection.
    if (revents & EV_ERROR && !(revents & EV_WRITE)) {
        trace("EV error on write, fd=%d revents=0x%08x\n", w->fd, revents);
        c->responding = RESPOND_SHUTDOWN;
        goto try_write_finished;
    }

    if (!c->wbuf_rinq) {
        if (c->responding == RESPOND_SHUTDOWN)
            goto try_write_finished;

        if (!c->poll_write_cb) {
            trace("tried to write with an empty buffer %d resp=%d\n",w->fd,c->responding);
            ev_io_stop(EV_A, w);
            return;
        }

        if (c->poll_write_cb_is_io_handle)
            pump_io_handle(c, c->poll_write_cb);
        else
            call_poll_callback(c, 1);

        // callback didn't write anything:
        if (!c->wbuf_rinq) goto try_write_again;
    }
    
    struct iomatrix *m = (struct iomatrix *)c->wbuf_rinq->ref;
#if DEBUG >= 2
    for (i=0; i < m->count; i++) {
        fprintf(stderr,"%.*s",m->iov[i].iov_len, m->iov[i].iov_base);
    }
#endif

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
            trace3("offset vector %d  base=%p len=%lu\n", w->fd, v->iov_base, v->iov_len);
            v->iov_base += wrote;
            v->iov_len  -= wrote;
        }
        else {
            trace3("consume vector %d base=%p len=%lu sv=%p\n", w->fd, v->iov_base, v->iov_len, m->sv[i]);
            wrote -= v->iov_len;
            m->offset++;
            if (m->sv[i]) {
                SvREFCNT_dec(m->sv[i]);
                m->sv[i] = NULL;
            }
        }
    }

    if (m->offset >= m->count) {
        trace2("all done with iomatrix %d\n",w->fd);
        rinq_shift(&c->wbuf_rinq);
        Safefree(m);
        goto try_write_finished;
    }
    // else, fallthrough:

try_write_again:
    trace("write again %d\n",w->fd);
    if (!ev_is_active(w)) {
        ev_io_start(EV_A, w);
    }
    return;

try_write_finished:
    // should always be responding, but just in case
    if (!c->responding || c->responding == RESPOND_SHUTDOWN) {
        ev_io_stop(EV_A, w);
        shutdown(c->fd, SHUT_WR);
        trace3("ref dec after write %d\n", c->fd);
        // TODO: call a completion callback instead of just GCing
        SvREFCNT_dec(c->self);
    }
    else if (c->poll_write_cb) {
        goto try_write_again;
    }
    else {
        ev_io_stop(EV_A, w);
    }
    return;
}

static int
try_parse_http(struct feer_conn *c, size_t last_read)
{
    struct feer_req *req = c->req;
    if (!req) {
        Newxz(req,1,struct feer_req);
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

    // if it's marked readable EV suggests we simply try read it. Otherwise it
    // is stopped and we should ditch this connection.
    if (revents & EV_ERROR && !(revents & EV_READ)) {
        trace("EV error on read, fd=%d revents=0x%08x\n", w->fd, revents);
        goto try_read_error;
    }

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
        perror("try_conn_read error");
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
        if (ret == -1) goto try_read_bad;
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

    // fallthrough:
try_read_error:
    trace("READ ERROR %d\n", w->fd);
    c->receiving = RECEIVE_SHUTDOWN;
    c->responding = RESPOND_SHUTDOWN;
    ev_io_stop(EV_A, w);
    ev_timer_stop(EV_A, &c->read_ev_timer);
    shutdown(c->fd, SHUT_RDWR);
    SvREFCNT_dec(c->self);
    return;

try_read_bad:
    trace("bad request %d\n", w->fd);
    respond_with_server_error(c, "Malformed request.\n", 0, 400);
    // TODO: when keep-alive, close conn instead of fallthrough here.
    // fallthrough:
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
    // fallthrough:
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

    if (!(revents & EV_TIMER) || c->receiving == RECEIVE_SHUTDOWN) {
        // if there's no EV_TIMER then EV has stopped it on an error
        if (revents & EV_ERROR)
            trouble("EV error on read timer, fd=%d revents=0x%08x\n",
                c->fd,revents);
        return;
    }

    trace("read timeout %d\n", c->fd);

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
    if (shutting_down) {
        // shouldn't get called, but be defensive
        ev_io_stop(EV_A, w);
        close(w->fd);
        return;
    }

    if (revents & EV_ERROR) {
        trouble("EV error in accept_cb, fd=%d, revents=0x%08x\n",w->fd,revents);
        ev_unloop(EV_A, EVUNLOOP_ALL);
        return;
    }

    trace2("accept! revents=0x%08x\n", revents);

    while (1) {
        struct sockaddr_storage *sa;
        Newx(sa,1,struct sockaddr_storage);
        socklen_t sl = sizeof(struct sockaddr_storage);
        int fd = accept(w->fd, (struct sockaddr *)sa, &sl);
        if (fd == -1) break;

        struct feer_conn *c = new_feer_conn(EV_A,fd,(struct sockaddr *)sa);
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
        ev_idle_start(feersum_ev_loop, &ei);
    }
}

static bool
process_request_headers (struct feer_conn *c, int body_offset)
{
    int err_code;
    const char *err;
    struct feer_req *req = c->req;

    trace("processing headers %d minor_version=%d\n",c->fd,req->minor_version);
    bool body_is_required;

    c->is_http11 = (req->minor_version == 1);

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
    c->expected_cl = (ssize_t)expected;
    c->received_cl = SvCUR(c->rbuf);
    trace("expecting body %d size=%d have=%d\n",c->fd, c->expected_cl,c->received_cl);

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

    if (c->write_ev_io.data == NULL) {
        ev_io_init(&c->write_ev_io, try_conn_write, c->fd, EV_WRITE);
        c->write_ev_io.data = (void *)c;
    }

    if (!ev_is_active(&c->write_ev_io)) {
#if AUTOCORK_WRITES
        ev_io_start(feersum_ev_loop, &c->write_ev_io);
#else
        // attempt a non-blocking write immediately if we're not already
        // waiting for writability
        try_conn_write(feersum_ev_loop, &c->write_ev_io, EV_WRITE);
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
                   "Cache-Control: no-cache, no-store" CRLF
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

static void
feersum_init_tmpl_env(pTHX)
{
    HV *e;
    e = newHV();

    // constants
    hv_stores(e, "psgi.version", newRV((SV*)psgi_ver));
    hv_stores(e, "psgi.url_scheme", newSVpvs("http"));
    hv_stores(e, "psgi.nonblocking", &PL_sv_yes);
    hv_stores(e, "psgi.multithread", &PL_sv_no);
    hv_stores(e, "psgi.multiprocess", &PL_sv_no);
    hv_stores(e, "psgi.streaming", &PL_sv_yes);
    hv_stores(e, "psgi.errors", newRV((SV*)PL_stderrgv));
    hv_stores(e, "psgix.input.buffered", &PL_sv_yes);
    hv_stores(e, "psgix.output.buffered", &PL_sv_yes);
    hv_stores(e, "psgix.body.scalar_refs", &PL_sv_yes);
    hv_stores(e, "SCRIPT_NAME", newSVpvs(""));

    // placeholders that get defined for every request
    hv_stores(e, "SERVER_PROTOCOL", &PL_sv_undef);
    hv_stores(e, "SERVER_NAME", &PL_sv_undef);
    hv_stores(e, "SERVER_PORT", &PL_sv_undef);
    hv_stores(e, "REQUEST_URI", &PL_sv_undef);
    hv_stores(e, "REQUEST_METHOD", &PL_sv_undef);
    hv_stores(e, "PATH_INFO", &PL_sv_undef);
    hv_stores(e, "REMOTE_ADDR", &PL_sv_placeholder);
    hv_stores(e, "REMOTE_PORT", &PL_sv_placeholder);

    // defaults that get changed for some requests
    hv_stores(e, "psgi.input", &PL_sv_undef);
    hv_stores(e, "CONTENT_LENGTH", newSViv(0));
    hv_stores(e, "QUERY_STRING", newSVpvs(""));

    // anticipated headers
    hv_stores(e, "HTTP_HOST", &PL_sv_placeholder);
    hv_stores(e, "HTTP_USER_AGENT", &PL_sv_placeholder);
    hv_stores(e, "HTTP_ACCEPT", &PL_sv_placeholder);
    hv_stores(e, "HTTP_ACCEPT_LANGUAGE", &PL_sv_placeholder);
    hv_stores(e, "HTTP_ACCEPT_CHARSET", &PL_sv_placeholder);
    hv_stores(e, "HTTP_KEEP_ALIVE", &PL_sv_placeholder);
    hv_stores(e, "HTTP_CONNECTION", &PL_sv_placeholder);
    hv_stores(e, "HTTP_REFERER", &PL_sv_placeholder);
    hv_stores(e, "HTTP_COOKIE", &PL_sv_placeholder);
    hv_stores(e, "HTTP_IF_MODIFIED_SINCE", &PL_sv_placeholder);
    hv_stores(e, "HTTP_IF_NONE_MATCH", &PL_sv_placeholder);
    hv_stores(e, "HTTP_CACHE_CONTROL", &PL_sv_placeholder);
    
    feersum_tmpl_env = e;
}

static HV*
feersum_env(pTHX_ struct feer_conn *c)
{
    HV *e;
    SV **hsv;
    int i,j;
    struct feer_req *r = c->req;

    if (!feersum_tmpl_env)
        feersum_init_tmpl_env(aTHX);
    e = newHVhv(feersum_tmpl_env);

    trace("generating header (fd %d) %.*s\n",
        c->fd, r->path_len, r->path);

    SV *path = newSVpvn(r->path, r->path_len);
    hv_stores(e, "SERVER_NAME", newSVsv(feer_server_name));
    hv_stores(e, "SERVER_PORT", newSVsv(feer_server_port));
    hv_stores(e, "REQUEST_URI", path);
    hv_stores(e, "REQUEST_METHOD", newSVpvn(r->method,r->method_len));
    hv_stores(e, "SERVER_PROTOCOL", (r->minor_version == 1) ?
        newSVsv(psgi_serv11) : newSVsv(psgi_serv10));

    SV *addr = &PL_sv_undef;
    SV *port = &PL_sv_undef;
    const char *str_addr;
    unsigned short s_port;

    if (c->sa->sa_family == AF_INET) {
        struct sockaddr_in *in = (struct sockaddr_in *)c->sa;
        addr = newSV(INET_ADDRSTRLEN);
        str_addr = inet_ntop(AF_INET,&in->sin_addr,SvPVX(addr),INET_ADDRSTRLEN);
        s_port = ntohs(in->sin_port);
    }
#ifdef AF_INET6
    else if (c->sa->sa_family == AF_INET6) {
        struct sockaddr_in6 *in6 = (struct sockaddr_in6 *)c->sa;
        addr = newSV(INET6_ADDRSTRLEN);
        str_addr = inet_ntop(AF_INET6,&in6->sin6_addr,SvPVX(addr),INET6_ADDRSTRLEN);
        s_port = ntohs(in6->sin6_port);
    }
#endif

    if (str_addr) {
        SvCUR(addr) = strlen(SvPVX(addr));
        SvPOK_on(addr);
        port = newSViv(s_port);
    }
    hv_stores(e, "REMOTE_ADDR", addr);
    hv_stores(e, "REMOTE_PORT", port);

    if (c->expected_cl > 0) {
        hv_stores(e, "CONTENT_LENGTH", newSViv(c->expected_cl));
        hv_stores(e, "psgi.input", new_feer_conn_handle(c,0));
    }
    else if (request_cb_is_psgi) {
        // TODO: make psgi.input a valid, but always empty stream for PSGI mode?
    }

    {
        const char *qpos = r->path;
        SV *pinfo, *qstr;
        
        // rather than memchr, for speed:
        while (*qpos != '?' && qpos < r->path + r->path_len)
            qpos++;

        if (*qpos == '?') {
            pinfo = newSVpvn(r->path, (qpos - r->path));
            qpos++;
            qstr = newSVpvn(qpos, r->path_len - (qpos - r->path));
        }
        else {
            pinfo = newSVsv(path);
            qstr = NULL; // use template default
        }
        uri_decode_sv(pinfo);
        hv_stores(e, "PATH_INFO", pinfo);
        if (qstr != NULL) // hv template defaults QUERY_STRING to empty
            hv_stores(e, "QUERY_STRING", qstr);
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
            trace("adding header to env (fd %d) %.*s: %.*s\n",
                c->fd, klen, kbuf, hdr->value_len, hdr->value);

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

    return e;
}

static void
feersum_start_response (pTHX_ struct feer_conn *c, SV *message, AV *headers,
                        int streaming)
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

    add_const_to_wbuf(c, c->is_http11 ? "HTTP/1.1 " : "HTTP/1.0 ", 9);
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
        if (c->is_http11)
            add_const_to_wbuf(c, "Transfer-Encoding: chunked" CRLFx2, 30);
        else
            add_const_to_wbuf(c, "Connection: close" CRLFx2, 21);
    }

    conn_write_ready(c);
}

static int
feersum_write_whole_body (pTHX_ struct feer_conn *c, SV *body)
{
    int RETVAL;
    int i;
    bool body_is_string = 0;
    STRLEN cur;

    if (c->responding != RESPOND_NORMAL)
        croak("can't use write_whole_body when in streaming mode");

    if (!SvOK(body)) {
        body = sv_2mortal(newSVpvs(""));
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
            if (elt == NULL) continue;
            SV *sv = *elt;
            // copy to remove magic
            if (SvMAGICAL(sv)) sv = sv_2mortal(newSVsv(sv));
            if (!SvOK(sv)) continue;
            if (SvROK(sv)) sv = SvRV(sv);
            cur = add_sv_to_wbuf(c,sv);
            trace("body part i=%d sv=%p cur=%d\n", i, sv, cur);
            RETVAL += cur;
        }
    }

    sv_setpvf(cl_sv, "Content-Length: %d" CRLFx2, RETVAL);
    update_wbuf_placeholder(c, cl_sv, cl_iov);

    c->responding = RESPOND_SHUTDOWN;
    conn_write_ready(c);
    return RETVAL;
}

static void
feersum_start_psgi_streaming(pTHX_ struct feer_conn *c, SV *streamer)
{
    dSP;
    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    SV *conn_sv = sv_2mortal(feer_conn_2sv(c));
    XPUSHs(conn_sv);
    XPUSHs(streamer);
    PUTBACK;
    call_method("_initiate_streaming_psgi", G_DISCARD|G_EVAL|G_VOID);
    SPAGAIN;
    if (SvTRUE(ERRSV)) {
        call_died(aTHX_ c, "PSGI stream initiator");
    }
    PUTBACK;
    FREETMPS;
    LEAVE;
}

static void
feersum_handle_psgi_response(pTHX_ struct feer_conn *c, SV *ret)
{
    if (IsCodeRef(ret)) {
        trace("PSGI response code-ref, c=%p cv=%p\n", c, ret);
        feersum_start_psgi_streaming(aTHX_ c, ret);
        return;
    }
    else if (!IsArrayRef(ret)) {
        sv_setpvs(ERRSV, "Invalid PSGI response (expected array or code ref)");
        call_died(aTHX_ c, "PSGI request");
        return;
    }

    AV *psgi_triplet = (AV*)SvRV(ret);
    if (av_len(psgi_triplet)+1 != 3) {
        sv_setpvs(ERRSV, "Invalid PSGI array response (expected triplet)");
        call_died(aTHX_ c, "PSGI request");
        return;
    }

    trace("PSGI response triplet, c=%p av=%p\n", c, psgi_triplet);
    SV *msg = av_shift(psgi_triplet);
    SV *hdrs = av_shift(psgi_triplet);
    SV *body = av_shift(psgi_triplet);

    AV *headers;
    if (IsArrayRef(hdrs))
        headers = (AV*)SvRV(hdrs);
    else {
        sv_setpvs(ERRSV, "PSGI Headers must be an array-ref");
        call_died(aTHX_ c, "PSGI request");
        return;
    }

    if (IsArrayRef(body)) {
        feersum_start_response(aTHX_ c, msg, headers, 0);
        feersum_write_whole_body(aTHX_ c, body);
    }
    else if (SvROK(body)) { // probaby an IO::Handle-like object
        feersum_start_response(aTHX_ c, msg, headers, 1);
        c->poll_write_cb = newSVsv(body);
        c->poll_write_cb_is_io_handle = 1;
        conn_write_ready(c);
    }
    else {
        sv_setpvs(ERRSV, "Expected PSGI array-ref or IO::Handle-like body");
        call_died(aTHX_ c, "PSGI request");
    }
}

static void
call_died (pTHX_ struct feer_conn *c, const char *cb_type)
{
    dSP;
    STRLEN err_len;
    char *err = SvPV(ERRSV,err_len);
    trace("An error was thrown in the %s callback: %.*s\n",cb_type,err_len,err);
    PUSHMARK(SP);
    XPUSHs(sv_2mortal(newSVsv(ERRSV)));
    PUTBACK;
    call_pv("Feersum::DIED", G_DISCARD|G_EVAL|G_VOID|G_KEEPERR);
    SPAGAIN;

    respond_with_server_error(c,"Request handler exception.\n",0,500);
    sv_setsv(ERRSV, &PL_sv_undef);
}

static void
call_request_callback (struct feer_conn *c)
{
    dTHX;
    dSP;
    int flags;
    c->in_callback++;

    trace("request callback c=%p\n", c);

    ENTER;
    SAVETMPS;
    PUSHMARK(SP);

    if (request_cb_is_psgi) {
        HV *env = feersum_env(aTHX_ c);
//         SV *conn_sv = feer_conn_2sv(c);
//         hv_stores((HV*)env, "psgix.feersum", conn_sv);
        XPUSHs(sv_2mortal(newRV_noinc((SV*)env)));
        flags = G_EVAL|G_SCALAR;
    }
    else {
        SV *conn_sv = feer_conn_2sv(c);
        XPUSHs(sv_2mortal(conn_sv));
        flags = G_DISCARD|G_EVAL|G_VOID;
    }

    PUTBACK;
    call_sv(request_cb_cv, flags);
    SPAGAIN;

    trace("called request callback, errsv? %d\n", SvTRUE(ERRSV) ? 1 : 0);

    if (SvTRUE(ERRSV)) {
        call_died(aTHX_ c, "request");
    }

    SV *psgi_response;
    if (request_cb_is_psgi) {
        psgi_response = *sp;
        SvREFCNT_inc(psgi_response);
    }

    trace("leaving request callback\n");
    PUTBACK;
    FREETMPS;
    LEAVE;

    if (request_cb_is_psgi) {
        feersum_handle_psgi_response(aTHX_ c, psgi_response);
        SvREFCNT_dec(psgi_response);
    }

    c->in_callback--;
}

static void
call_poll_callback (struct feer_conn *c, bool is_write)
{
    dTHX;
    dSP;
    
    SV *cb = (is_write) ? c->poll_write_cb : NULL;

    if (!cb) return;

    c->in_callback++;

    trace("%s poll callback c=%p cbrv=%p\n",
        is_write ? "write" : "read", c, cb);

    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    XPUSHs(sv_2mortal(new_feer_conn_handle(c, is_write)));
    PUTBACK;
    call_sv(cb, G_DISCARD|G_EVAL|G_VOID);
    SPAGAIN;

    trace("called %s poll callback, errsv? %d\n",
        is_write ? "write" : "read", SvTRUE(ERRSV) ? 1 : 0);

    if (SvTRUE(ERRSV)) {
        call_died(aTHX_ c, is_write ? "write poll" : "read poll");
    }

    trace("leaving %s poll callback\n", is_write ? "write" : "read");
    PUTBACK;
    FREETMPS;
    LEAVE;

    c->in_callback--;
}

static void
pump_io_handle (struct feer_conn *c, SV *io)
{
    dTHX;
    dSP;
    SV *ret = NULL;

    if (!io) return;

    c->in_callback++;

    trace("pump io handle %d\n", c->fd);

    ENTER;
    SAVETMPS;

    // Emulate `local $/ = \4096;`
    SV *old_rs = PL_rs;
    PL_rs = sv_2mortal(newRV_noinc(newSViv(4096)));
    sv_setsv(get_sv("/", GV_ADD), PL_rs);

    PUSHMARK(SP);
    XPUSHs(c->poll_write_cb);
    PUTBACK;
    call_method("getline", G_SCALAR|G_EVAL);
    SPAGAIN;

    trace("called getline on io handle, errsv? %d %d\n",
        SvTRUE(ERRSV) ? 1 : 0, c->fd);

    if (SvTRUE(ERRSV)) {
        call_died(aTHX_ c, "getline on io handle");
        goto done_pump_io;
    }

    ret = POPs;
    if (SvMAGICAL(ret))
        ret = sv_2mortal(newSVsv(ret));

    if (!SvOK(ret)) {
        // returned undef, so call the close method out of niceity
        PUSHMARK(SP);
        XPUSHs(c->poll_write_cb);
        PUTBACK;
        call_method("close", G_VOID|G_DISCARD|G_EVAL);
        SPAGAIN;

        if (SvTRUE(ERRSV)) {
            STRLEN len;
            const char *err = SvPV(ERRSV,len);
            trouble("Couldn't close body IO handle: %.*s",len,err);
        }

        SvREFCNT_dec(c->poll_write_cb);
        c->poll_write_cb = NULL;
        finish_wbuf(c);
        c->responding = RESPOND_SHUTDOWN;

        goto done_pump_io;
    }

    if (c->is_http11)
        add_chunk_sv_to_wbuf(c, ret);
    else
        add_sv_to_wbuf(c, ret);

done_pump_io:
    trace("leaving pump io handle %d\n", c->fd);

    PUTBACK;
    FREETMPS;
    LEAVE;

    PL_rs = old_rs;
    sv_setsv(get_sv("/", GV_ADD), old_rs);

    c->in_callback--;
}

MODULE = Feersum		PACKAGE = Feersum		

PROTOTYPES: ENABLE

void
set_server_name_and_port(SV *self, SV *name, SV *port)
    PPCODE:
{
    if (feer_server_name)
        SvREFCNT_DEC(feer_server_name);
    feer_server_name = newSVsv(name);
    SvREADONLY_on(feer_server_name);

    if (feer_server_port)
        SvREFCNT_DEC(feer_server_port);
    feer_server_port = newSVsv(port);
    SvREADONLY_on(feer_server_port);
}

void
accept_on_fd(SV *self, int fd)
    PPCODE:
{
    trace("going to accept on %d\n",fd);
    feersum_ev_loop = EV_DEFAULT;

    ev_prepare_init(&ep, prepare_cb);
    ev_prepare_start(feersum_ev_loop, &ep);

    ev_check_init(&ec, check_cb);
    ev_check_start(feersum_ev_loop, &ec);

    ev_idle_init(&ei, idle_cb);

    ev_io_init(&accept_w, accept_cb, fd, EV_READ);
}

void
request_handler(SV *self, SV *cb)
    PROTOTYPE: $&
    ALIAS:
        psgi_request_handler = 1
    PPCODE:
{
    if (!IsCodeRef(cb))
        croak("must supply a code reference");
    if (request_cb_cv)
        SvREFCNT_dec(request_cb_cv);
    request_cb_cv = SvRV(cb);
    SvREFCNT_inc(request_cb_cv);
    request_cb_is_psgi = ix;
    trace("assigned %s request handler %p\n",
        request_cb_is_psgi?"PSGI":"Feersum", request_cb_cv);
}

void
graceful_shutdown (SV *self, SV *cb)
    PROTOTYPE: $&
    PPCODE:
{
    if (!IsCodeRef(cb))
        croak("must supply a code reference");
    if (shutting_down)
        croak("already shutting down");
    shutdown_cb_cv = SvRV(cb);
    SvREFCNT_inc(shutdown_cb_cv);
    trace("assigned shutdown handler %p\n", SvRV(cb));

    shutting_down = 1;
    ev_io_stop(feersum_ev_loop, &accept_w);
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
    trace3("DESTROY server\n");
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
        trace3("DESTROY handle (closed) class=%s\n", HvNAME(SvSTASH(SvRV(ST(0)))));
    }
    else {
        struct feer_conn *c = (struct feer_conn *)hdl;
        trace3("DESTROY handle fd=%d, class=%s\n", c->fd, HvNAME(SvSTASH(SvRV(ST(0)))));
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

    if (!body || !SvOK(body)) {
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

    if (c->is_http11)
        add_chunk_sv_to_wbuf(c, body);
    else
        add_sv_to_wbuf(c, body);

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
    switch (ix) {
    case 1:
        trace("close reader fd=%d, c=%p\n", c->fd, c);
        // TODO: ref-dec poll_read_cb
        RETVAL = shutdown(c->fd, SHUT_RD); // TODO: respect keep-alive
        c->receiving = RECEIVE_SHUTDOWN;
        break;
    case 2:
        trace("close writer fd=%d, c=%p\n", c->fd, c);
        if (c->poll_write_cb) {
            SvREFCNT_dec(c->poll_write_cb);
            c->poll_write_cb = NULL;
        }
        finish_wbuf(c);
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
_poll_cb (feer_conn_handle *hdl, SV *cb)
    PROTOTYPE: $$
    ALIAS:
        Feersum::Connection::Reader::poll_cb = 1
        Feersum::Connection::Writer::poll_cb = 2
    PPCODE:
{
    if (ix < 1 || ix > 2)
        croak("can't call _poll_cb directly");
    else if (ix == 1)
        croak("poll_cb for reading not yet supported"); // TODO poll_read_cb

    if (c->poll_write_cb != NULL) {
        SvREFCNT_dec(c->poll_write_cb);
        c->poll_write_cb = NULL;
    }

    if (!SvOK(cb)) {
        trace("unset poll_cb ix=%d\n", ix);
        return;
    }
    else if (!IsCodeRef(cb))
        croak("must supply a code reference to poll_cb");

    c->poll_write_cb = newSVsv(cb);

    // start the write-watcher unless it's already activated.
    if (!ev_is_active(&c->write_ev_io))
        ev_io_start(feersum_ev_loop, &c->write_ev_io);
}

MODULE = Feersum	PACKAGE = Feersum::Connection

PROTOTYPES: ENABLE

void
start_response (struct feer_conn *c, SV *message, AV *headers, int streaming)
    PROTOTYPE: $$\@$
    PPCODE:
        feersum_start_response(aTHX_ c, message, headers, streaming);

int
write_whole_body (struct feer_conn *c, SV *body)
    PROTOTYPE: $$
    CODE:
        RETVAL = feersum_write_whole_body(aTHX_ c, body);
    OUTPUT:
        RETVAL

void
send_response (struct feer_conn *c, SV* msg, SV *hdrs, SV *body)
    PROTOTYPE: $$$$
    PPCODE:
{
    AV *headers;
    if (IsArrayRef(hdrs))
        headers = (AV*)SvRV(hdrs);
    else
        croak("Must supply headers as an array-ref");

    feersum_start_response(aTHX_ c, msg, headers, 0);
    feersum_write_whole_body(aTHX_ c, body);
}

void
force_http10 (struct feer_conn *c)
    PROTOTYPE: $
    ALIAS:
        force_http11 = 1
    PPCODE:
        c->is_http11 = ix;

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

SV *
env (struct feer_conn *c)
    PROTOTYPE: $
    CODE:
        RETVAL = newRV_noinc((SV*)feersum_env(aTHX_ c));
    OUTPUT:
        RETVAL

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
    trace3("DESTROY conn %d %p\n", c->fd, c);

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
        Safefree(c->req);
    }

    if (c->sa) Safefree(c->sa);

    if (c->fd) close(c->fd);

    if (c->poll_write_cb) SvREFCNT_dec(c->poll_write_cb);

    active_conns--;

    if (shutting_down && active_conns <= 0) {
        ev_idle_stop(feersum_ev_loop, &ei);
        ev_prepare_stop(feersum_ev_loop, &ep);
        ev_check_stop(feersum_ev_loop, &ec);

        trace3("... was last conn, going to try shutdown\n");
        if (shutdown_cb_cv) {
            PUSHMARK(SP);
            call_sv(shutdown_cb_cv, G_EVAL|G_VOID|G_DISCARD|G_NOARGS|G_KEEPERR);
            PUTBACK;
            trace3("... ok, called that handler\n");
            SvREFCNT_dec(shutdown_cb_cv);
            shutdown_cb_cv = NULL;
        }
    }
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

        psgi_serv10 = newSVpvs("HTTP/1.0");
        SvREADONLY_on(psgi_serv10);
        psgi_serv11 = newSVpvs("HTTP/1.1");
        SvREADONLY_on(psgi_serv11);
    }
