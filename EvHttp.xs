#include "EVAPI.h"
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <errno.h>
#include <ctype.h>

#include "ppport.h"

#include "picohttpparser/picohttpparser.c"

#include "rinq.c"

#ifndef CRLF
#define CRLF "\015\012"
#endif
#define CRLFx2 CRLF CRLF

#define MAX_HEADERS 64
#define MAX_HEADER_NAME_LEN 128
#define MAX_BODY_LENGTH IV_MAX - 1

#define WARN_PREFIX "Socialtext::EvHttp: "

#ifndef __inline
#define __inline
#endif

#define trouble(f_, ...) warn(WARN_PREFIX f_, ##__VA_ARGS__);

#ifdef DEBUG
#define trace(f_, ...) trouble(f_, ##__VA_ARGS__)
#else
#define trace(...)
#endif

struct http_client_req {
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
#define CLIENT_LABEL_LENGTH 24
#define RESPOND_NORMAL 1
#define RESPOND_STREAMING 2
#define RESPOND_SHUTDOWN 3
#define RECEIVE_HEADERS 0
#define RECEIVE_BODY 1
#define RECEIVE_STREAMING 2
#define RECEIVE_SHUTDOWN 3

struct http_client {
    char label[CLIENT_LABEL_LENGTH];
    SV *self;

    int fd;
    struct ev_io read_ev_io;
    struct ev_io write_ev_io;
    struct ev_loop *loop;

    SV *rbuf, *wbuf;

    struct http_client_req *req;
    size_t expected_cl;
    size_t received_cl;

    // SV *drain_cb; // async "done writing" callback
    // SV *read_cb;  // async "data available" callback

    int16_t in_callback;
    int16_t responding;
    int16_t receiving;
};


static void try_client_write(EV_P_ struct ev_io *w, int revents);
static void try_client_read(EV_P_ struct ev_io *w, int revents);
static bool process_request_headers(struct http_client *c, int body_offset);
static void sched_request_callback(struct http_client *c);
static void call_request_callback(struct http_client *c);

static void client_write_ready (struct http_client *c);
static void respond_with_server_error(struct http_client *c, const char *msg, STRLEN msg_len, int code);

static void add_sv_to_wbuf (struct http_client *c, SV *sv, bool chunked);
static void uri_decode_sv (SV *sv);
static void offset_sv(SV *sv, int how_much);

static bool str_eq(const char *a, int a_len, const char *b, int b_len);
static bool str_case_eq(const char *a, int a_len, const char *b, int b_len);

static const char const *http_code_to_msg (int code);
static int setnonblock (int fd);


static HV *stash, *http_client_stash;

static SV *request_cb_cv = NULL;

static ev_io accept_w;
static ev_prepare ep;
static ev_check   ec;
struct ev_idle    ei;

static struct rinq *request_ready_rinq = NULL;

static AV *psgi_ver;
static SV *psgi_serv10, *psgi_serv11;
static HV *psgi_env_template;

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
setnonblock(int fd)
{
    int flags;

    flags = fcntl(fd, F_GETFL);
    if (flags < 0)
            return flags;
    flags |= O_NONBLOCK;
    if (fcntl(fd, F_SETFL, flags) < 0)
            return -1;

    return 0;
}

static struct http_client *
new_http_client (EV_P_ int client_fd)
{
    // allocate an SV that can hold the http_client PLUS a string for the fd
    // so that dumping the SV from interpreter-land 
    SV *self = newSV(0);
    SvUPGRADE(self, SVt_PVMG); // ensures sv_bless doesn't reallocate
    SvGROW(self, sizeof(struct http_client));
    SvPOK_only(self);
    SvIOK_on(self);
    SvIV_set(self,client_fd);

    struct http_client *c = (struct http_client *)SvPVX(self);
    Zero(c, 1, struct http_client);

    STRLEN label_len = snprintf(
        c->label, CLIENT_LABEL_LENGTH, "%"IVdf, client_fd);

    // make the var readonly and make the visible portion just the fd number
    SvCUR_set(self, label_len);
    SvREADONLY_on(self); // turn off later for blessing

    c->self = self;
    c->fd = client_fd;
    setnonblock(c->fd);

    c->loop = loop; // from EV_P_

    // TODO: these initializations should be Lazy
    ev_io_init(&c->read_ev_io, try_client_read, client_fd, EV_READ);
    c->read_ev_io.data = (void *)c;

    ev_io_init(&c->write_ev_io, try_client_write, client_fd, EV_WRITE);
    c->write_ev_io.data = (void *)c;

#ifdef DEBUG
    sv_dump(self);
#endif
    trace("made client self=%p, c=%p, cur=%d, len=%d, structlen=%d, refcnt=%d\n",
        self, c, SvCUR(self), SvLEN(self), sizeof(struct http_client), SvREFCNT(self));

    return c;
}

// for use in the typemap:
static struct http_client *
sv_2http_client (SV *rv)
{
    if (!sv_isa(rv,"Socialtext::EvHttp::Client"))
       croak("object is not of type Socialtext::EvHttp::Client");
    return (struct http_client *)SvPVX(SvRV(rv));
}

static SV*
http_client_2sv (struct http_client *c)
{
    SV *rv = newRV_inc(c->self);
    if (!SvOBJECT(c->self)) {
        trace("c->self not yet an object, SvCUR:%d\n",SvCUR(c->self));
        SvREADONLY_off(c->self);
        // XXX: should this block use newRV_noinc instead?
        sv_bless(rv, http_client_stash);
        SvREADONLY_on(c->self);
    }
    return rv;
}

static void
process_request_ready_rinq (void)
{
    while (request_ready_rinq) {
        struct http_client *c =
            (struct http_client *)rinq_shift(&request_ready_rinq);
        trace("rinq shifted c=%p, head=%p\n", c, request_ready_rinq);

        call_request_callback(c);

        if (c->wbuf && SvCUR(c->wbuf) > 0) {
            // this was deferred until after the perl callback
            client_write_ready(c);
        }
        SvREFCNT_dec(c->self); // for the rinq
    }
}

static void
prepare_cb (EV_P_ ev_prepare *w, int revents)
{
    trace("prepare!\n");
    if (!ev_is_active(&accept_w)) {
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

#define dCLIENT struct http_client *c = (struct http_client *)w->data

static void
try_client_write(EV_P_ struct ev_io *w, int revents)
{
    dCLIENT;

    if (!c->wbuf || SvCUR(c->wbuf) == 0) {
        trace("tried to write with an empty buffer %d\n",w->fd);
        ev_io_stop(EV_A, w);
        return;
    }

    // TODO: handle errors in revents?

    trace("going to write %d %ld %p\n",w->fd, SvCUR(c->wbuf), SvPVX(c->wbuf));
    STRLEN buflen;
    const char *bufptr = SvPV(c->wbuf, buflen);
    ssize_t wrote = write(w->fd, bufptr, buflen);
    trace("wrote %d bytes to %d\n", wrote, w->fd);
    if (wrote == -1) {
        if (errno == EAGAIN)
            goto try_write_again;
        perror("try_client_write");
        goto try_write_finished;
    }

    // check for more work
    if (SvCUR(c->wbuf) == wrote) {
        trace("All done with %d\n",w->fd);
        SvREFCNT_dec(c->wbuf); c->wbuf = NULL;
        goto try_write_finished;
    }
    trace("More work to do %d: cur=%d len=%d ivx=%d\n",w->fd, SvCUR(c->wbuf), SvLEN(c->wbuf), SvIVX(c->wbuf));

    // remove written bytes from the front of the string (using the OOK hack)
    offset_sv(c->wbuf, wrote);

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
        trace("ref dec after write %d\n", c->fd);
        // TODO: call a completion callback instead of just GCing
        SvREFCNT_dec(c->self);
    }
    return;
}

static int
try_parse_http(struct http_client *c, size_t last_read)
{
    struct http_client_req *req = c->req;
    if (!req) {
        req = (struct http_client_req *)
            calloc(1,sizeof(struct http_client_req));
        req->num_headers = MAX_HEADERS;
        c->req = req;
    }
    return phr_parse_request(SvPVX(c->rbuf), SvCUR(c->rbuf),
        &req->method, &req->method_len,
        &req->path, &req->path_len, &req->minor_version,
        req->headers, &req->num_headers, 
        (SvCUR(c->rbuf)-last_read));
}

#define READ_CHUNK 4096

static void
try_client_read(EV_P_ ev_io *w, int revents)
{
    dCLIENT;

    // TODO: handle errors in revents?

    if (c->receiving == RECEIVE_SHUTDOWN) {
        ev_io_stop(EV_A, w);
        return;
    }

    trace("try read %d\n",w->fd);

    if (!c->rbuf) {
        trace("init rbuf for %d\n",w->fd);
        c->rbuf = newSV(2*READ_CHUNK + 1);
#ifdef DEBUG
        sv_dump(c->rbuf);
#endif
    }

    if (SvLEN(c->rbuf) - SvCUR(c->rbuf) < READ_CHUNK) {
        size_t new_len = SvLEN(c->rbuf) + READ_CHUNK;
        trace("moar memory %d: %d to %d\n",w->fd, SvLEN(c->rbuf),new_len);
        SvGROW(c->rbuf, new_len);
    }

    char *cur = SvPVX(c->rbuf) + SvCUR(c->rbuf);
    ssize_t got_n = read(w->fd, cur, READ_CHUNK);

    if (got_n == -1) {
        int errno_copy = errno;
        if (errno_copy == EAGAIN) goto try_read_again;
        perror("try_client_read");
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
            goto try_read_again;
        else
            goto dont_read_again;
    }
    else if (c->receiving == RECEIVE_BODY) {
        c->received_cl += got_n;
        if (c->received_cl < c->expected_cl)
            goto try_read_again;
        // body is complete
        c->receiving = RECEIVE_SHUTDOWN;
        sched_request_callback(c);
        goto dont_read_again;
    }
    else {
        warn("unknown read state %d %d", w->fd, c->receiving);
    }

try_read_error:
    trace("try read error %d\n", w->fd);
    ev_io_stop(EV_A, w);
    c->receiving = RECEIVE_SHUTDOWN;
    c->responding = RESPOND_SHUTDOWN;
    close(w->fd);
    SvREFCNT_dec(c->self);
    return;

dont_read_again:
    c->receiving = RECEIVE_SHUTDOWN;
    ev_io_stop(EV_A, w);
    return;

try_read_again:
    trace("read again %d\n", w->fd);
    if (!ev_is_active(w)) {
        ev_io_start(EV_A,w);
    }
    return;
}

static void
accept_cb (EV_P_ ev_io *w, int revents)
{
    int client_fd;
    struct sockaddr_in client_sockaddr;
    socklen_t client_socklen = sizeof(struct sockaddr_in);

    trace("accept! %08x %d\n", revents, revents & EV_READ);
    // TODO: accept as many as possible
    client_fd = accept(w->fd,
                       (struct sockaddr *)&client_sockaddr, &client_socklen);

    struct http_client *c = new_http_client(EV_A, client_fd);
    // XXX: good idea to read right away?
    // try_client_read(EV_A, &c->read_ev_io, EV_READ);
    ev_io_start(EV_A, &c->read_ev_io);
}

static void
sched_request_callback (struct http_client *c)
{
    trace("rinq push: c=%p, head=%p\n", c, request_ready_rinq);
    sv_dump(c->self);
    rinq_push(&request_ready_rinq, c);
    SvREFCNT_inc(c->self); // for the rinq
    if (!ev_is_active(&ei)) {
        ev_idle_start(c->loop, &ei);
    }
}

static bool
process_request_headers (struct http_client *c, int body_offset)
{
    int err_code;
    const char *err;
    struct http_client_req *req = c->req;

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
    
    // a body potentially follows the headers. Let http_client_req retain its
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
    size_t expected = 0;
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
    sched_request_callback(c);
    return 0;
}

static void
client_write_ready (struct http_client *c)
{
    if (c->in_callback) return; // defer until out of callback

    if (!ev_is_active(&c->write_ev_io)) {
        // attempt a non-blocking write immediately if we're not already
        // waiting for writability
        try_client_write(c->loop, &c->write_ev_io, EV_WRITE);
    }
}

static void
offset_sv(SV *sv, int how_much)
{
    if (!SvOOK(sv)) {
        if (SvTYPE(sv) < SVt_PVIV)
            SvUPGRADE(sv, SVt_PVIV);
        SvOOK_on(sv);
        SvIVX(sv) = 0;
    }
    SvIVX(sv) += how_much;
    SvPVX(sv) += how_much;
    SvCUR(sv) -= how_much;
    SvLEN(sv) -= how_much;
}

static void
add_sv_to_wbuf (struct http_client *c, SV *sv, bool chunked)
{
    if (sv == NULL || !SvOK(sv)) {
        if (chunked) {
            // last-chunk = 1*"0" CRLF CRLF
            if (!c->wbuf)
                c->wbuf =  newSVpv("0" CRLFx2, 5);
            else
                sv_catpvn(c->wbuf, "0" CRLFx2, 5);
        }
        return;
    }

    if (SvUTF8(sv)) {
        sv_utf8_encode(sv);
    }

    if (chunked) {
        STRLEN len;
        const char *ptr = SvPV(sv, len); // invoke magic if any
        if (!c->wbuf) {
            // make a buffer that can fit the data plus chunk envelope
            STRLEN need = (len > READ_CHUNK) ? len+32 : READ_CHUNK-1;
            c->wbuf = newSV(need);
            SvPOK_on(c->wbuf);
        }
        /*
            From http://www.w3.org/Protocols/rfc2616/rfc2616-sec3.html#sec3.6.1

            chunk-size = [0-9a-f]+
            chunk = chunk-size CRLF chunk-data CRLF
        */
        sv_catpvf(c->wbuf, "%x" CRLF, len);
        sv_catpvn(c->wbuf, ptr, len);
        sv_catpvn(c->wbuf, CRLF, 2);
    }
    else {
        if (c->wbuf)
            sv_catsv(c->wbuf, sv);
        else {
            // use newSV+sv_setsv instead of newSVsv so that we can steal the
            // buffer if possible
            c->wbuf = newSV(0);
            sv_setsv(c->wbuf, sv);
        }
    }
}

static void
respond_with_server_error (struct http_client *c, const char *msg, STRLEN msg_len, int err_code)
{
    SV *tmp;

    if (c->responding) {
        trouble("Tried to send server error but already responding!");
        return;
    }

    if (!msg_len) msg_len = strlen(msg);
    tmp = newSV(255);
    sv_catpvf(tmp, "HTTP/1.1 %d %s" CRLF
                   "Content-Type: text/plain" CRLF
                   "Connection: close" CRLF
                   "Content-Length: %d" CRLFx2,
              err_code, http_code_to_msg(err_code), msg_len);
    sv_catpvn(tmp, msg, msg_len);

    SvTEMP_on(tmp); // so add_sv_to_wbuf can optimize
    add_sv_to_wbuf(c,tmp,0);
    SvREFCNT_dec(tmp);

    client_write_ready(c);
    c->responding = RESPOND_SHUTDOWN;
    c->receiving = RECEIVE_SHUTDOWN;
}

__inline bool
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
__inline bool
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

__inline int
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
call_request_callback (struct http_client *c)
{
    dSP;
    SV *sv_self;

    c->in_callback++;

    sv_self = http_client_2sv(c);

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
        call_pv("Socialtext::EvHttp::DIED", G_DISCARD|G_EVAL|G_VOID|G_KEEPERR);
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

MODULE = Socialtext::EvHttp		PACKAGE = Socialtext::EvHttp		

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
    PPCODE:
{
    if (!SvROK(cb) || SvTYPE(SvRV(cb)) != SVt_PVCV) {
        croak("must supply a code reference");
    }
    if (request_cb_cv)
        SvREFCNT_dec(request_cb_cv);
    request_cb_cv = SvRV(cb);
    SvREFCNT_inc(request_cb_cv);
    trace("assigned request handler %p\n", SvRV(cb));
}

void
DESTROY (SV *self)
    PPCODE:
{
    if (request_cb_cv)
        SvREFCNT_dec(request_cb_cv);
}

MODULE = Socialtext::EvHttp	PACKAGE = Socialtext::EvHttp::Client

PROTOTYPES: ENABLE

SV*
read (struct http_client *c, SV *buf, size_t len, ...)
    PROTOTYPE: $$$;$
    CODE:
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

    if (SvUTF8(buf)) 
        croak("buffer must have unicode flag turned off");

    buf_ptr = SvPV(buf, buf_len);
    if (c->rbuf)
        src_ptr = SvPV(c->rbuf, src_len);

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
        SvTEMP_on(c->rbuf);
        if (buf_len == 0) {
            sv_setsv(buf, c->rbuf);
        }
        else {
            sv_catsv(buf, c->rbuf);
        }
        SvREFCNT_dec(c->rbuf);
        c->rbuf = NULL;
        XSRETURN_IV(src_len);
    }
    else {
        trace("appending partial rbuf %d\n", c->fd);
        // partial append
        SvGROW(buf, SvCUR(buf) + len);
        sv_catpvn(buf, src_ptr, len);
        offset_sv(c->rbuf, len);
        XSRETURN_IV(len);
    }

    XSRETURN_UNDEF;
}

void
start_response (struct http_client *c, SV *message, AV *headers, int streaming)
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

    SV *tmp = newSV((2*READ_CHUNK)-1);
    SvPOK_on(tmp);
    SvTEMP_on(tmp);

    // int or 3 chars? use a stock message
    if (SvIOK(message) || (SvPOK(message) && SvCUR(message) == 3)) {
        int code = SvIV(message);
        ptr = http_code_to_msg(code);
        len = strlen(ptr);
        message = sv_2mortal(newSVpvf("%d %.*s",code,len,ptr));
    }

    ptr = SvPV(message, len);
    sv_catpvf(tmp, "HTTP/1.%d %.*s" CRLF, streaming ? 1 : 0, len, ptr);

    for (i=0; i<avl; i+= 2) {
        const char *hp, *vp;
        STRLEN hlen, vlen;
        SV **hdr = av_fetch(headers, i, 0);
        SV **val = av_fetch(headers, i+1, 0);

        if (!hdr || !SvOK(*hdr)) {
            trouble("skipping undef header");
            continue;
        }
        if (!val || !SvOK(*val)) {
            trouble("skipping undef header value");
            continue;
        }

        hp = SvPV(*hdr, hlen);
        vp = SvPV(*val, vlen);

        if (str_case_eq("content-length",15,hp,hlen)) {
            trouble("ignoring content-length header in the response");
            continue; 
        }

        sv_catpvf(tmp, "%.*s: %.*s" CRLF, hlen, hp, vlen, vp);
    }

    if (streaming) {
        sv_catpvn(tmp, "Transfer-Encoding: chunked" CRLFx2, 30);
    }

    add_sv_to_wbuf(c,tmp,0);
    SvREFCNT_dec(tmp);
    client_write_ready(c);
}

void
write_whole_body (struct http_client *c, SV *body)
    PPCODE:
{
    int i;
    const char *ptr;
    STRLEN len;
    bool body_is_string = 0;

    if (c->responding != RESPOND_NORMAL)
        croak("can't use write_whole_body when in streaming mode");

    if (!SvOK(body)) {
        sv_catpvn(c->wbuf, "Content-Length: 0" CRLFx2, 21);
        client_write_ready(c);
        PUTBACK;
        return;
    }

    if (SvROK(body)) {
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

    assert(c->wbuf);

    if (body_is_string) {
        sv_catpvf(c->wbuf, "Content-Length: %d" CRLFx2, SvCUR(body));
        add_sv_to_wbuf(c,body,0);
    }
    else {
        AV *abody = (AV*)SvRV(body);
        I32 amax = av_len(abody);
        SV **svs;
        New(0,svs,amax+1,SV*);
        unsigned int cl = 0;
        int actual = 0;
        for (i=0; i<=amax; i++) {
            SV **elt = av_fetch(abody, i, 0);
            if (!elt || !SvOK(*elt))
                continue;

            SV *sv = *elt;
            trace("body part i=%d cur=%d utf=%d\n", i, SvCUR(sv), 0+SvUTF8(sv));
            if (SvUTF8(sv)) {
                sv_utf8_encode(sv); // convert to utf-8 bytes
                trace("... encoded utf8, cur=%d\n", SvCUR(sv));
            }
            cl += SvCUR(sv);
            svs[actual++] = sv;
        }

        if (!c->wbuf) {
            c->wbuf = newSV(cl + 32);
        }
        else {
            SvGROW(c->wbuf, SvCUR(c->wbuf) + cl + 32);
        }
        sv_catpvf(c->wbuf, "Content-Length: %u" CRLFx2, cl);

        for (i=0; i<actual; i++) {
            add_sv_to_wbuf(c, svs[i], 0);
        }
        Safefree(svs);
    }

    c->responding = RESPOND_SHUTDOWN;
    client_write_ready(c);
}

void
write (struct http_client *c, SV *body)
    PPCODE:
{
    if (c->responding != RESPOND_STREAMING)
        croak("can only call write in streaming mode");

    if (!SvOK(body)) {
        trace("write fd=%d c=%p, body=undef\n", c->fd, c);
        add_sv_to_wbuf(c, NULL, 1);   
        c->responding = RESPOND_SHUTDOWN;
    }
    else {
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
        add_sv_to_wbuf(c, body, 1);
    }

    client_write_ready(c);
}

void
env (struct http_client *c, HV *e)
    PROTOTYPE: $\%
    PPCODE:
{
    SV **hsv;
    int i,j;
    struct http_client_req *r = c->req;

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
        hv_store(e, "psgi.input", 10, http_client_2sv(c), 0);
    }
    else {
        hv_store(e, "CONTENT_LENGTH", 14, newSViv(0), 0);
        hv_store(e, "psgi.input", 10, &PL_sv_undef, 0);
    }

    {
        const char *qpos = r->path;
        SV *pinfo;
        while (*qpos != '?' && qpos < r->path + r->path_len) {
            qpos++;
        }
        if (*qpos == '?') {
            pinfo = newSVpvn(r->path, (qpos - r->path));
            qpos++;
            hv_store(e, "QUERY_STRING", 12, newSVpvn(qpos, r->path_len - (qpos - r->path)), 0);
        }
        else {
            pinfo = newSVpvn(r->path, r->path_len);
        }
        uri_decode_sv(pinfo);
        hv_store(e, "PATH_INFO", 9, pinfo, 0);
    }

    SV *val = NULL;
    SV *keybuf = newSV(48 - 1);
    SvPOK_on(keybuf);
    char *key = SvPVX(keybuf);
    key[0] = 'H'; key[1] = 'T'; key[2] = 'T'; key[3] = 'P'; key[4] = '_';

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
            SvGROW(keybuf,5+hdr->name_len);
            SvLEN_set(keybuf,5+hdr->name_len);
            key = SvPVX(keybuf) + 5;
            for (j=0; j<hdr->name_len; j++) {
                char n = hdr->name[j];
                *key++ = (n == '-') ? '_' : toupper(n);
            }

            SV **val = hv_fetch(e, SvPVX(keybuf), hdr->name_len + 5, 1);
            trace("adding %.*s:%.*s\n",
                SvLEN(keybuf), SvPVX(keybuf), hdr->value_len, hdr->value);

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
}

void
DESTROY (struct http_client *c)
    PPCODE:
{
    trace("DESTROY client %p\n", c);
    if (c->rbuf) SvREFCNT_dec(c->rbuf);
    if (c->wbuf) SvREFCNT_dec(c->wbuf);
    if (c->req) {
        if (c->req->buf) SvREFCNT_dec(c->req->buf);
        free(c->req);
    }
    if (c->fd) close(c->fd);
#ifdef DEBUG
    sv_dump(c->self);
    // overwrite for debugging
    Poison(c, 1, struct http_client);
#endif
}

MODULE = Socialtext::EvHttp	PACKAGE = Socialtext::EvHttp		

BOOT:
    {
        stash = gv_stashpv("Socialtext::EvHttp", 1);
        http_client_stash = gv_stashpv("Socialtext::EvHttp::Client", 1);
        I_EV_API("Socialtext::EvHttp");

        SV *ver_svs[2];
        ver_svs[0] = newSViv(1);
        ver_svs[1] = newSViv(0);
        psgi_ver = av_make(2,ver_svs);
        SvREFCNT_dec(ver_svs[0]);
        SvREFCNT_dec(ver_svs[1]);
        SvREADONLY_on((SV*)psgi_ver);

        psgi_serv10 = newSVpvn("HTTP/1.0",8);
        psgi_serv11 = newSVpvn("HTTP/1.1",8);
    }
