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
    const char* method;
    size_t method_len;
    const char* path; 
    size_t path_len;
    int minor_version;
    ssize_t expected_cl;
    size_t num_headers;
    struct phr_header headers[MAX_HEADERS];
};

// enough to hold a 64-bit signed integer (which is 20+1 chars) plus nul
#define CLIENT_LABEL_LENGTH 24
#define RESPOND_NORMAL 1
#define RESPOND_STREAMING 2
#define RESPOND_SHUTDOWN 3

struct http_client {
    char label[CLIENT_LABEL_LENGTH];
    SV *self;
    SV *drain_cb;

    int fd;
    struct ev_io read_ev_io;
    struct ev_io write_ev_io;
    struct ev_loop *loop;

    SV *rbuf, *wbuf;

    size_t body_offset;

    struct http_client_req *req;

    int in_callback;
    int responding;
};


static void try_client_write(EV_P_ struct ev_io *w, int revents);
static void try_client_read(EV_P_ struct ev_io *w, int revents);
static void call_http_request_callback(EV_P_ struct http_client *c);

static void client_write_ready (struct http_client *c);
static void respond_with_server_error(EV_P_ struct http_client *c, const char *msg, STRLEN msg_len);

static void add_sv_to_wbuf (struct http_client *c, SV *sv, bool chunked);
static void uri_decode_sv (SV *sv);

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
process_request_ready_rinq (EV_P)
{
    while (request_ready_rinq) {
        struct http_client *c =
            (struct http_client *)rinq_shift(&request_ready_rinq);
        trace("rinq shifted c=%p, head=%p\n", c, request_ready_rinq);

        call_http_request_callback(EV_A, c);

        if (c->wbuf && SvCUR(c->wbuf) > 0) {
            // this was deferred until after the perl callback
            client_write_ready(c);
        }
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
    process_request_ready_rinq(EV_A);
}

static void
idle_cb (EV_P_ ev_idle *w, int revents)
{
    trace("idle! head=%p\n", request_ready_rinq);
    process_request_ready_rinq(EV_A);
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
    if (!SvOOK(c->wbuf)) {
        // can't use the OOK hack without a PVIV
        if (SvTYPE(c->wbuf) < SVt_PVIV)
            SvUPGRADE(c->wbuf, SVt_PVIV);
        SvOOK_on(c->wbuf);
    }
    SvIVX(c->wbuf) += wrote;
    SvPVX(c->wbuf) += wrote;
    SvCUR(c->wbuf) -= wrote;
    SvLEN(c->wbuf) -= wrote;

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

    trace("try read %d\n",w->fd);

    if (!c->rbuf) {
        trace("init rbuf for %d\n",w->fd);
        c->rbuf = newSV((2*READ_CHUNK) - 1);
        SvPOK_on(c->rbuf);
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
    else {
        trace("read %d %d\n", w->fd, got_n);
        SvCUR(c->rbuf) += got_n;
        int ret = try_parse_http(c, (size_t)got_n);
        if (ret == -1) goto try_read_error;
        if (ret == -2) goto try_read_again;
        c->body_offset = (size_t)ret;
        ev_io_stop(EV_A, w);

        // XXX: here's where we'd check the content length or chunked
        // input stuff, read the body if it's not too big.
        c->req->expected_cl = 0;

        if (strncmp(c->req->method, "GET", 3) == 0) {
            trace("rinq push: c=%p, head=%p\n", c, request_ready_rinq);
            rinq_push(&request_ready_rinq, c);
            if (!ev_is_active(&ei)) {
                ev_idle_start(EV_A, &ei);
            }
        }
        else {
            respond_with_server_error(EV_A, c, "TODO: support POST/PUT\n", 0);
        }
    }

    return;

try_read_again:
    trace("read again %d\n", w->fd);
    if (!ev_is_active(w)) {
        ev_io_start(EV_A,w);
    }
    return;

try_read_error:
    ev_io_stop(EV_A, w);
    close(w->fd);
    SvREFCNT_dec(c->self);
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
respond_with_server_error (EV_P_ struct http_client *c, const char *msg, STRLEN msg_len)
{
    SV *tmp;

    if (c->responding) {
        trouble("Tried to send server error but already responding!");
        return;
    }

    static char *base_error = NULL;
    static STRLEN base_error_len = 0;
    if (!base_error) {
        base_error =
            "HTTP/1.0 500 Server Error" CRLF
            "Content-Type: text/plain" CRLF
            "Connection: close" CRLF
            "Content-Length: ";
        base_error_len = strlen(base_error);
    }
    
    if (!msg_len) msg_len = strlen(msg);
    tmp = newSV(base_error_len + msg_len + 16);
    SvPOK_on(tmp);
    SvTEMP_on(tmp); // so add_sv_to_wbuf can optimize
    sv_catpvn(tmp, base_error, base_error_len);
    sv_catpvf(tmp, "%d" CRLFx2, msg_len);
    sv_catpvn(tmp, msg, msg_len);
    add_sv_to_wbuf(c,tmp,0);
    SvREFCNT_dec(tmp);
    client_write_ready(c);
    c->responding = RESPOND_SHUTDOWN;

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
call_http_request_callback (EV_P_ struct http_client *c)
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

        respond_with_server_error(EV_A,c,"Request handler threw an exception.\n",0);
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

void
on_drain (struct http_client *c, SV *cb)
    PPCODE:
{
    if (!(SvOK(cb) && SvROK(cb) && SvTYPE(SvRV(cb)) == SVt_PVCV)) {
        croak("expected code reference");
    }
    if (c->drain_cb) {
        SvREFCNT_dec(c->drain_cb);
    }
    c->drain_cb = newRV_inc(SvRV(cb));
}

void
start_response (struct http_client *c, SV *message, AV *headers, int streaming)
    PPCODE:
{
    char *ptr;
    STRLEN len;
    I32 i;

    trace("start_response fd=%d streaming=%d\n", c->fd, streaming);

    if (c->responding)
        croak("already responding!");
    c->responding = streaming ? RESPOND_STREAMING : RESPOND_NORMAL;

    I32 avl = av_len(headers);
    if (avl < 0 || (avl % 2 != 1)) {
        croak("expected even-length array");
    }

    SV *tmp = newSV((2*READ_CHUNK)-1);
    SvPOK_on(tmp);
    SvTEMP_on(tmp);
#ifdef DEBUG
    sv_dump(tmp);
#endif

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

        if (strncasecmp(hp,"content-length",hlen) == 0) {
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

SV*
get_headers (struct http_client *c)
    CODE:
{
    AV *hdrs = newAV();
    int i;
    SV *lastval = NULL;

    for (i=0; i<c->req->num_headers; i++) {
        struct phr_header *hdr = &(c->req->headers[i]);
        if (hdr->name == NULL && lastval != NULL) {
            trace("... extending %.*s\n", hdr->value_len, hdr->value);
            sv_catpvn(lastval, hdr->value, hdr->value_len);
        }
        else {
            trace("adding %.*s:%.*s\n", hdr->name_len, hdr->name, hdr->value_len, hdr->value);
            SV *key = newSVpvn(hdr->name, hdr->name_len);
            SV *val = newSVpvn(hdr->value, hdr->value_len);
            lastval = val;
            av_push(hdrs, key);
            av_push(hdrs, val);
        }
    }
    RETVAL = newRV_noinc((SV*)hdrs);
}
    OUTPUT:
        RETVAL

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
    hv_store(e, "psgi.errors", 11, &PL_sv_undef, 0); // TODO errors object
    hv_store(e, "psgi.input", 10, &PL_sv_undef, 0); // TODO input object
    hv_store(e, "REQUEST_URI", 11, newSVpvn(r->path,r->path_len),0);
    hv_store(e, "REQUEST_METHOD", 14, newSVpvn(r->method,r->method_len),0);
    hv_store(e, "SCRIPT_NAME", 11, newSVpvn("",0),0);
    hv_store(e, "CONTENT_LENGTH", 14, newSViv(r->expected_cl), 0);
    hv_store(e, "SERVER_PROTOCOL", 15, (r->minor_version == 1) ? newSVsv(psgi_serv11) : newSVsv(psgi_serv10), 0);

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
        else if (tolower(hdr->name[0]) == 'c' &&
                 strncasecmp(hdr->name, "content-length", (14 > hdr->name_len) ? hdr->name_len : 14) == 0)
        {
            // content length shouldn't show up as HTTP_CONTENT_LENGTH but
            // as CONTENT_LENGTH in the env-hash.  This is assigned from
            // r->expected_cl.
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
    if (c->drain_cb) SvREFCNT_dec(c->drain_cb);
    if (c->rbuf) SvREFCNT_dec(c->rbuf);
    if (c->wbuf) SvREFCNT_dec(c->wbuf);
    if (c->req) free(c->req);
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
