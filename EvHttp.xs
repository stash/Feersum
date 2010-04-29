#include "EVAPI.h"
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <errno.h>

#include "ppport.h"

#include "picohttpparser/picohttpparser.c"

#include "rinq.c"

#define MAX_HEADERS 128

#ifdef DEBUG
#define trace(f_, ...) warn(f_, ##__VA_ARGS__)
#else
#define trace(...)
#endif

struct http_client_req {
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
};

static void try_client_write(EV_P_ struct ev_io *w, int revents);
static void client_write_ready (struct http_client *c);
static void try_client_read(EV_P_ struct ev_io *w, int revents);
static void call_http_request_callback(EV_P_ struct http_client *c);

static HV *stash, *http_client_stash;

static SV *request_cb_cv = NULL;

static ev_io accept_w;
static ev_prepare ep;
static ev_check   ec;
struct ev_idle    ei;

static struct rinq *request_ready_rinq = NULL;

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
    //ssize_t wrote = write(w->fd, SvPVX(c->wbuf), SvCUR(c->wbuf));
    ssize_t wrote = (SvCUR(c->wbuf) > 16) ? 16 : SvCUR(c->wbuf);
    wrote = write(w->fd, SvPVX(c->wbuf), wrote);
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
    // TODO: call the drain callback with success/error
    ev_io_stop(EV_A, w);
    SvREFCNT_dec(c->self);
    return;
}

static int
try_parse_http(struct http_client *c, size_t last_len)
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
        last_len);
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
        //
        // Instead, just assume it's a GET and schedule a callback.
        
        trace("rinq push: c=%p, head=%p\n", c, request_ready_rinq);
        rinq_push(&request_ready_rinq, c);
        if (!ev_is_active(&ei)) {
            ev_idle_start(EV_A, &ei);
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
    if (c->in_callback) return;

    if (ev_is_active(&c->write_ev_io)) {
        // just wait for event to fire
    }
    else {
        // attempt a non-blocking write immediately
        try_client_write(c->loop, &c->write_ev_io, EV_WRITE);
    }
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
    PUTBACK;

    trace("calling request callback...\n");

    call_sv(request_cb_cv, G_DISCARD|G_EVAL|G_VOID);

    trace("called request callback...\n");

    if (SvTRUE(ERRSV)) {
        STRLEN len;
        char *err = SvPV(ERRSV,len);
        trace("an error was thrown: %.*s\n",len,err);
        SPAGAIN;
        PUSHMARK(SP);
        PUTBACK;
        call_sv(get_sv("Socialtext::EvHttp::DIED",1),
                G_DISCARD|G_EVAL|G_VOID|G_KEEPERR);
    }

    trace("leaving request callback\n");
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
send_response (struct http_client *c, SV *message, AV *headers, SV *body)
    PPCODE:
{
    char *ptr;
    STRLEN len;
    I32 i;

    trace("send response c=%p\n",c);

    I32 avl = av_len(headers);
    if (avl < 0 || (avl % 2 != 1)) {
        croak("expected even-length array");
    }
    if (!SvOK(body)) {
        croak("body must be a scalar or scalar reference");
    }
    if (SvROK(body)) {
        SV *refd = SvRV(body);
        if (SvOK(refd) && !SvROK(refd)) {
            body = refd;
        }
        else {
            croak("body must be a scalar or scalar reference");
        }
    }

    SV *tmp = newSV((2*READ_CHUNK)-1);

    ptr = SvPV(message, len);
    sv_catpvf(tmp, "HTTP/1.0 %.*s\r\n", len, ptr);

    for (i=0; i<avl; i+= 2) {
        const char *hp, *vp;
        STRLEN hlen, vlen;
        SV **hdr = av_fetch(headers, i, 0);
        SV **val = av_fetch(headers, i+1, 0);

        if (!hdr || !SvOK(*hdr)) {
            warn("skipping undef header");
            continue;
        }
        if (!val || !SvOK(*val)) {
            warn("skipping undef header value");
            continue;
        }

        hp = SvPV(*hdr, hlen);
        vp = SvPV(*val, vlen);

        if (strncasecmp(hp,"Content-Length",hlen) == 0) {
            warn("Ignoring content-length header in the response");
            continue; 
        }

        sv_catpvf(tmp, "%.*s: %.*s\r\n", hlen, hp, vlen, vp);
    }

    ptr = SvPV(body, len);
    sv_catpvf(tmp, "Content-Length: %d\r\n\r\n", len);
    sv_catpvn(tmp, ptr, len);

    if (!c->wbuf) {
        c->wbuf = tmp;
    }
    else {
        sv_catsv(c->wbuf, tmp);
        SvREFCNT_dec(tmp);
    }

    client_write_ready(c);
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
    }
