#include "feersum_core.h"
#include "picohttpparser-git/picohttpparser.c"

#include "rinq.c"

#include "feersum_core.c.inc"
#include "feersum_utils.c.inc"
#include "feersum_h1.c.inc"
#include "feersum_psgi.c.inc"

#ifdef FEERSUM_HAS_TLS
#include "feersum_tls.c.inc"
#endif
#ifdef FEERSUM_HAS_H2
#include "feersum_h2.c.inc"
#endif

MODULE = Feersum                PACKAGE = Feersum

PROTOTYPES: ENABLE

SV *
_xs_new_server(SV *classname)
    CODE:
{
    PERL_UNUSED_VAR(classname);
    struct feer_server *s = new_feer_server(aTHX);
    RETVAL = feer_server_2sv(s);
}
    OUTPUT:
        RETVAL

SV *
_xs_default_server(SV *classname)
    CODE:
{
    PERL_UNUSED_VAR(classname);
    RETVAL = feer_server_2sv(default_server);
}
    OUTPUT:
        RETVAL

void
set_server_name_and_port(struct feer_server *server, SV *name, SV *port)
    PPCODE:
{
    struct feer_listen *lsnr = &server->listeners[server->n_listeners > 0 ? server->n_listeners - 1 : 0];
    SvREFCNT_dec(lsnr->server_name);
    lsnr->server_name = newSVsv(name);
    SvREADONLY_on(lsnr->server_name);

    SvREFCNT_dec(lsnr->server_port);
    lsnr->server_port = newSVsv(port);
    SvREADONLY_on(lsnr->server_port);
}

void
accept_on_fd(struct feer_server *server, int fd)
    PPCODE:
{
    struct sockaddr_storage addr;
    socklen_t addr_len = sizeof(addr);
    struct feer_listen *lsnr;

    /* shutting_down is terminal: prepare_cb skips accept watchers while it is set */
    if (unlikely(server->shutting_down))
        croak("cannot listen after graceful_shutdown; it is terminal");

    if (server->n_listeners == 0) {
        lsnr = &server->listeners[0];
        server->n_listeners = 1;
    } else {
        lsnr = NULL;
        /* an fd already in the table takes its own slot back, or shutdown
         * would close it twice */
        for (int j = 0; j < server->n_listeners; j++) {
            if (server->listeners[j].fd == fd) {
                lsnr = &server->listeners[j];
                /* re-init below would otherwise leave the old watcher armed */
                if (ev_is_active(&lsnr->accept_w))
                    ev_io_stop(feersum_ev_loop, &lsnr->accept_w);
                break;
            }
        }
        for (int j = 0; !lsnr && j < server->n_listeners; j++) {
            if (server->listeners[j].fd == -1) {
                lsnr = &server->listeners[j];
                break;
            }
        }
#ifdef FEERSUM_HAS_TLS
        if (lsnr)
            feer_tls_cleanup_listener(lsnr);
#endif
        if (!lsnr) {
            if (server->n_listeners < FEER_MAX_LISTENERS) {
                lsnr = &server->listeners[server->n_listeners];
                Zero(lsnr, 1, struct feer_listen);
                lsnr->server = server;
                lsnr->fd = -1;
                lsnr->is_tcp = 1;
                server->n_listeners++;
            } else {
                croak("Too many listeners (max %d)", FEER_MAX_LISTENERS);
            }
        }
    }

    Zero(&addr, 1, struct sockaddr_storage);
    if (getsockname(fd, (struct sockaddr*)&addr, &addr_len) == -1) {
        warn("getsockname failed: %s (assuming TCP socket)", strerror(errno));
        addr.ss_family = AF_INET;
    }
    switch (addr.ss_family) {
        case AF_INET:
        case AF_INET6:
            lsnr->is_tcp = 1;
#ifdef TCP_DEFER_ACCEPT
            /* not with drain_accept_queue: a deferred connection is invisible
             * to accept(), so the shutdown drain would close the listener on it */
            if (!server->drain_accept_queue) {
                trace("going to defer accept on %d\n",fd);
                if (setsockopt(fd, IPPROTO_TCP, TCP_DEFER_ACCEPT, &(int){1}, sizeof(int)) < 0)
                    trouble("setsockopt TCP_DEFER_ACCEPT fd=%d: %s\n", fd, strerror(errno));
            }
#endif
            break;
#ifdef AF_UNIX
        case AF_UNIX:
            lsnr->is_tcp = 0;
            break;
#endif
    }

    trace("going to accept on %d\n",fd);
    feersum_ev_loop = EV_DEFAULT;
    lsnr->fd = fd;

    if (!server->watchers_initialized) {
        server->watchers_initialized = true;

        ev_prepare_init(&server->ep, prepare_cb);
        server->ep.data = (void *)server;
        ev_prepare_start(feersum_ev_loop, &server->ep);

        ev_check_init(&server->ec, check_cb);
        server->ec.data = (void *)server;
        /* below the io watchers: at equal priority check_cb runs first and
         * dispatch slips an iteration */
        ev_set_priority(&server->ec, EV_MINPRI);
        ev_check_start(feersum_ev_loop, &server->ec);

        ev_idle_init(&server->ei, idle_cb);
        server->ei.data = (void *)server;

        date_timer_refs++;
    } else if (!ev_is_active(&server->ep)) {
        ev_prepare_start(feersum_ev_loop, &server->ep);
    }

    if (!ev_is_active(&date_timer)) {
        date_timer_cb(feersum_ev_loop, &date_timer, 0);
        ev_timer_init(&date_timer, date_timer_cb, 1.0, 1.0);
        ev_timer_start(feersum_ev_loop, &date_timer);
    }

    /* a blocking listener wedges the loop (accept() past the last pending
     * connection blocks); prep_socket only covers accepted fds */
    {
        int fl = fcntl(fd, F_GETFL);
        if (fl >= 0 && !(fl & O_NONBLOCK))
            (void)fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    }

    setup_accept_watcher(lsnr, fd);
}

void
unlisten (struct feer_server *server)
    PPCODE:
{
    trace("stopping accept\n");
    ev_prepare_stop(feersum_ev_loop, &server->ep);
    ev_check_stop(feersum_ev_loop, &server->ec);
    ev_idle_stop(feersum_ev_loop, &server->ei);
    for (int i = 0; i < server->n_listeners; i++) {
        struct feer_listen *lsnr = &server->listeners[i];
        ev_io_stop(feersum_ev_loop, &lsnr->accept_w);
        ev_timer_stop(feersum_ev_loop, &lsnr->emfile_w);
        lsnr->fd = -1;
        lsnr->pause_flags = 0;
#ifdef FEERSUM_HAS_TLS
        feer_tls_cleanup_listener(lsnr);
#endif
        SvREFCNT_dec(lsnr->server_name);
        lsnr->server_name = NULL;
        SvREFCNT_dec(lsnr->server_port);
        lsnr->server_port = NULL;
    }
    server->n_listeners = 0;
    if (server->watchers_initialized) {
        server->watchers_initialized = false;
        if (--date_timer_refs <= 0) {
            ev_timer_stop(feersum_ev_loop, &date_timer);
            date_timer_refs = 0;
        }
    }
}

void
pause_accept (struct feer_server *server)
    PPCODE:
{
    if (server->shutting_down) {
        trace("cannot pause during shutdown\n");
        XSRETURN_NO;
    }
    int paused_any = 0;
    for (int i = 0; i < server->n_listeners; i++) {
        struct feer_listen *lsnr = &server->listeners[i];
        if (!(lsnr->pause_flags & FEER_PAUSE_USER)) {
            trace("pausing accept on listener %d\n", i);
            if (ev_is_active(&lsnr->accept_w))
                ev_io_stop(feersum_ev_loop, &lsnr->accept_w);
            lsnr->pause_flags |= FEER_PAUSE_USER;
            paused_any = 1;
        }
    }
    if (paused_any)
        XSRETURN_YES;
    else
        XSRETURN_NO;
}

void
resume_accept (struct feer_server *server)
    PPCODE:
{
    if (server->shutting_down) {
        trace("cannot resume during shutdown\n");
        XSRETURN_NO;
    }
    int resumed_any = 0;
    for (int i = 0; i < server->n_listeners; i++) {
        struct feer_listen *lsnr = &server->listeners[i];
        if (lsnr->pause_flags & FEER_PAUSE_USER) {
            trace("resuming accept on listener %d\n", i);
            lsnr->pause_flags &= ~FEER_PAUSE_USER;
            if (!lsnr->pause_flags && lsnr->fd >= 0)
                ev_io_start(feersum_ev_loop, &lsnr->accept_w);
            resumed_any = 1;
        }
    }
    if (resumed_any)
        XSRETURN_YES;
    else
        XSRETURN_NO;
}

bool
accept_is_paused (struct feer_server *server)
    CODE:
    {
        RETVAL = (server->n_listeners > 0);
        for (int i = 0; i < server->n_listeners; i++) {
            if (!(server->listeners[i].pause_flags & FEER_PAUSE_USER)) {
                RETVAL = 0; break;
            }
        }
    }
    OUTPUT:
        RETVAL

void
request_handler(struct feer_server *server, SV *cb)
    PROTOTYPE: $&
    ALIAS:
        psgi_request_handler = 1
    PPCODE:
{
    if (unlikely(!SvOK(cb) || !SvROK(cb)))
        croak("can't supply an undef handler");
    SvREFCNT_dec(server->request_cb_cv);
    server->request_cb_cv = newSVsv(cb);
    server->request_cb_is_psgi = ix;
    trace("assigned %s request handler %p\n",
        ix ? "PSGI" : "Feersum", server->request_cb_cv);
}

void
graceful_shutdown (struct feer_server *server, SV *cb)
    PROTOTYPE: $&
    PPCODE:
{
    if (!IsCodeRef(cb))
        croak("must supply a code reference");
    if (unlikely(server->shutting_down))
        croak("already shutting down");
    feer_begin_graceful_shutdown(aTHX_ server, cb);
}

void
access_log (struct feer_server *server, ...)
    PROTOTYPE: $;$
    PPCODE:
{
    if (items > 1) {
        SV *cb = ST(1);
        if (SvOK(cb) && !IsCodeRef(cb))
            croak("access_log must be a code reference or undef");
        SvREFCNT_dec(server->access_log_cb_cv);
        server->access_log_cb_cv = SvOK(cb) ? newSVsv(cb) : NULL;
    }
    if (server->access_log_cb_cv)
        XPUSHs(sv_2mortal(newSVsv(server->access_log_cb_cv)));
    else
        XPUSHs(&PL_sv_undef);
    XSRETURN(1);
}

void
max_requests_per_worker (struct feer_server *server, ...)
    PROTOTYPE: $;$$$
    PPCODE:
{
    if (items > 1) {
        /* range-check the NV, as every limit here does: SvIV saturates at
         * 2**63 and past UV range; !(>=) also catches NaN */
        NV want = SvNV(ST(1));
        if (!(want >= 0.0))
            croak("max_requests_per_worker must be non-negative");
        UV limit = want >= (NV)UV_MAX ? UV_MAX : (UV)want;
        if (limit && (items < 3 || !IsCodeRef(ST(2))))
            croak("must supply a code reference to run once the worker has drained");
        bool has_begin = limit && items > 3 && SvOK(ST(3));
        if (has_begin && !IsCodeRef(ST(3)))
            croak("the retirement callback must be a code reference");
        SvREFCNT_dec(server->max_requests_cb_cv);
        SvREFCNT_dec(server->retire_begin_cb_cv);
        server->max_requests_cb_cv = limit ? newSVsv(ST(2)) : NULL;
        server->retire_begin_cb_cv = has_begin ? newSVsv(ST(3)) : NULL;
        server->max_requests = (UV)limit;
    }
    XSRETURN_UV(server->max_requests);
}

double
read_timeout (struct feer_server *server, ...)
    PROTOTYPE: $;$
    CODE:
{
    if (items > 1) {
        double val = SvNV(ST(1));
        if (!(val > 0.0))
            croak("read_timeout must be a positive (non-zero) value");
        trace("set read_timeout %f\n", val);
        server->read_timeout = val;
    }
    RETVAL = server->read_timeout;
}
    OUTPUT:
        RETVAL

double
header_timeout (struct feer_server *server, ...)
    PROTOTYPE: $;$
    CODE:
{
    if (items > 1) {
        double val = SvNV(ST(1));
        if (val < 0.0)
            croak("header_timeout must be non-negative (0 to disable)");
        trace("set header_timeout %f\n", val);
        server->header_timeout = val;
    }
    RETVAL = server->header_timeout;
}
    OUTPUT:
        RETVAL

double
write_timeout (struct feer_server *server, ...)
    PROTOTYPE: $;$
    CODE:
{
    if (items > 1) {
        double val = SvNV(ST(1));
        if (val < 0.0)
            croak("write_timeout must be non-negative (0 to disable)");
        trace("set write_timeout %f\n", val);
        server->write_timeout = val;
    }
    RETVAL = server->write_timeout;
}
    OUTPUT:
        RETVAL

double
linger_timeout (struct feer_server *server, ...)
    PROTOTYPE: $;$
    CODE:
{
    if (items > 1) {
        double val = SvNV(ST(1));
        if (val < 0.0)
            croak("linger_timeout must be non-negative (0 to disable)");
        trace("set linger_timeout %f\n", val);
        server->linger_timeout = val;
    }
    RETVAL = server->linger_timeout;
}
    OUTPUT:
        RETVAL

void
set_keepalive (struct feer_server *server, SV *set)
    PPCODE:
{
    trace("set keepalive %d\n", SvTRUE(set));
    server->is_keepalive = SvTRUE(set);
}

int
get_keepalive (struct feer_server *server)
    CODE:
        RETVAL = server->is_keepalive ? 1 : 0;
    OUTPUT:
        RETVAL

void
set_drain_accept_queue (struct feer_server *server, SV *set)
    PPCODE:
{
    trace("set drain_accept_queue %d\n", SvTRUE(set));
    server->drain_accept_queue = SvTRUE(set);
#ifdef TCP_DEFER_ACCEPT
    /* Keep TCP_DEFER_ACCEPT in sync on listeners registered before this
     * call, so the order against use_socket() does not matter.  A deferred
     * connection is invisible to accept() until its data arrives, and the
     * shutdown drain would close the listener on top of it. */
    for (int i = 0; i < server->n_listeners; i++) {
        struct feer_listen *lsnr = &server->listeners[i];
        if (lsnr->is_tcp && lsnr->fd >= 0
            && setsockopt(lsnr->fd, IPPROTO_TCP, TCP_DEFER_ACCEPT,
                          &(int){ server->drain_accept_queue ? 0 : 1 },
                          sizeof(int)) < 0)
            trouble("setsockopt TCP_DEFER_ACCEPT fd=%d: %s\n",
                    lsnr->fd, strerror(errno));
    }
#endif
}

int
get_drain_accept_queue (struct feer_server *server)
    CODE:
        RETVAL = server->drain_accept_queue ? 1 : 0;
    OUTPUT:
        RETVAL

void
set_reverse_proxy (struct feer_server *server, SV *set)
    PPCODE:
{
    trace("set reverse_proxy %d\n", SvTRUE(set));
    server->use_reverse_proxy = SvTRUE(set);
}

int
get_reverse_proxy (struct feer_server *server)
    CODE:
{
    RETVAL = server->use_reverse_proxy;
}
    OUTPUT:
        RETVAL

void
set_psgix_io (struct feer_server *server, SV *set)
    PPCODE:
{
    server->psgix_io = SvTRUE(set);
    trace("set psgix_io %d\n", server->psgix_io);
}

int
get_psgix_io (struct feer_server *server)
    CODE:
{
    RETVAL = server->psgix_io;
}
    OUTPUT:
        RETVAL

void
set_proxy_protocol (struct feer_server *server, SV *set)
    PPCODE:
{
    trace("set proxy_protocol %d\n", SvTRUE(set));
    server->use_proxy_protocol = SvTRUE(set);
}

int
get_proxy_protocol (struct feer_server *server)
    CODE:
{
    RETVAL = server->use_proxy_protocol;
}
    OUTPUT:
        RETVAL

int
read_priority (struct feer_server *server, ...)
    ALIAS:
        write_priority = 1
        accept_priority = 2
    PROTOTYPE: $;$
    CODE:
{
    static const char *names[] = {"read", "write", "accept"};
    PERL_UNUSED_VAR(names); /* only consumed by trace() */
    int *field = ix == 2 ? &server->accept_priority
               : ix == 1 ? &server->write_priority
               :           &server->read_priority;
    if (items > 1) {
        /* narrowing SvIV to int wraps; !(>) sends NaN to EV_MINPRI */
        NV want = SvNV(ST(1));
        int new_priority = !(want > (NV)EV_MINPRI) ? EV_MINPRI
                         : want >= (NV)EV_MAXPRI   ? EV_MAXPRI
                         :                           (int)want;
        trace("set %s_priority %d\n", names[ix], new_priority);
        *field = new_priority;
    }
    RETVAL = *field;
}
    OUTPUT:
        RETVAL

int
max_accept_per_loop (struct feer_server *server, ...)
    PROTOTYPE: $;$
    CODE:
{
    if (items > 1) {
        NV want = SvNV(ST(1));
        int new_max = !(want >= 1)        ? 1        /* also catches NaN */
                    : want >= (NV)INT_MAX ? INT_MAX
                    :                       (int)want;
        trace("set max_accept_per_loop %d\n", new_max);
        server->max_accept_per_loop = new_max;
    }
    RETVAL = server->max_accept_per_loop;
}
    OUTPUT:
        RETVAL

int
active_conns (struct feer_server *server)
    CODE:
        RETVAL = server->active_conns;
    OUTPUT:
        RETVAL

int
max_connections (struct feer_server *server, ...)
    PROTOTYPE: $;$
    CODE:
{
    if (items > 1) {
        NV want = SvNV(ST(1));
        int new_max = !(want > 0)         ? 0        /* <= 0, or NaN: unlimited */
                    : want >= (NV)INT_MAX ? INT_MAX
                    :                       (int)want;
        trace("set max_connections %d\n", new_max);
        server->max_connections = new_max;
    }
    RETVAL = server->max_connections;
}
    OUTPUT:
        RETVAL

size_t
max_read_buf (struct feer_server *server, ...)
    PROTOTYPE: $;$
    CODE:
{
    if (items > 1) {
        /* clamp on the NV: a UV into size_t truncates where they differ */
        NV want = SvNV(ST(1));
        if (want < 0.0)
            croak("max_read_buf must be non-negative");
        size_t new_max = !(want > 0.0)        ? 0   /* 0, or NaN: default */
                       : want >= (NV)SIZE_MAX ? SIZE_MAX
                       :                        (size_t)want;
        if (new_max == 0) new_max = MAX_READ_BUF;
        server->max_read_buf = new_max;
    }
    RETVAL = server->max_read_buf;
}
    OUTPUT:
        RETVAL

size_t
max_body_len (struct feer_server *server, ...)
    PROTOTYPE: $;$
    CODE:
{
    if (items > 1) {
        NV want = SvNV(ST(1));
        if (want < 0.0)
            croak("max_body_len must be non-negative");
        size_t new_max = !(want > 0.0)        ? 0   /* 0, or NaN: default */
                       : want >= (NV)SIZE_MAX ? SIZE_MAX
                       :                        (size_t)want;
        if (new_max == 0) new_max = MAX_BODY_LEN;
        server->max_body_len = new_max;
    }
    RETVAL = server->max_body_len;
}
    OUTPUT:
        RETVAL

size_t
max_uri_len (struct feer_server *server, ...)
    PROTOTYPE: $;$
    CODE:
{
    if (items > 1) {
        NV want = SvNV(ST(1));
        if (want < 0.0)
            croak("max_uri_len must be non-negative");
        size_t new_max = !(want > 0.0)        ? 0   /* 0, or NaN: default */
                       : want >= (NV)SIZE_MAX ? SIZE_MAX
                       :                        (size_t)want;
        if (new_max == 0) new_max = MAX_URI_LEN;
        server->max_uri_len = new_max;
    }
    RETVAL = server->max_uri_len;
}
    OUTPUT:
        RETVAL

size_t
wbuf_low_water (struct feer_server *server, ...)
    PROTOTYPE: $;$
    CODE:
{
    if (items > 1) {
        NV want = SvNV(ST(1));
        if (want < 0.0)
            croak("wbuf_low_water must be non-negative");
        server->wbuf_low_water = !(want > 0.0)        ? 0
                               : want >= (NV)SIZE_MAX ? SIZE_MAX
                               :                        (size_t)want;
    }
    RETVAL = server->wbuf_low_water;
}
    OUTPUT:
        RETVAL

void
set_multiprocess (struct feer_server *server, SV *set)
    PPCODE:
{
    server->multiprocess = SvTRUE(set);
}

int
get_multiprocess (struct feer_server *server)
    CODE:
        RETVAL = server->multiprocess ? 1 : 0;
    OUTPUT:
        RETVAL

int
max_h2_concurrent_streams (struct feer_server *server, ...)
    PROTOTYPE: $;$
    CODE:
{
#ifdef FEERSUM_HAS_H2
    if (items > 1) {
        /* capped because h2_check_stream_poll_cbs uses a fixed-size stack array */
        NV want = SvNV(ST(1));
        int n = !(want >= 1) ? 1        /* also catches NaN */
              : want >= (NV)FEER_H2_MAX_CONCURRENT_STREAMS
                    ? FEER_H2_MAX_CONCURRENT_STREAMS
              : (int)want;
        server->max_h2_concurrent_streams = n;
    }
    RETVAL = server->max_h2_concurrent_streams;
#else
    PERL_UNUSED_VAR(server);
    if (items > 1)
        warn("H2 not compiled in, max_h2_concurrent_streams ignored");
    RETVAL = 0;
#endif
}
    OUTPUT:
        RETVAL

size_t
max_h2_conn_body (struct feer_server *server, ...)
    PROTOTYPE: $;$
    CODE:
{
#ifdef FEERSUM_HAS_H2
    if (items > 1) {
        NV want = SvNV(ST(1));
        if (want < 0.0)
            croak("max_h2_conn_body must be non-negative");
        server->max_h2_conn_body = !(want > 0.0)        ? 0   /* 0/NaN: off */
                                 : want >= (NV)SIZE_MAX ? SIZE_MAX
                                 :                        (size_t)want;
    }
    RETVAL = server->max_h2_conn_body;
#else
    PERL_UNUSED_VAR(server);
    if (items > 1)
        warn("H2 not compiled in, max_h2_conn_body ignored");
    RETVAL = 0;
#endif
}
    OUTPUT:
        RETVAL

UV
total_requests (struct feer_server *server)
    CODE:
        RETVAL = server->total_requests;
    OUTPUT:
        RETVAL

unsigned int
max_connection_reqs (struct feer_server *server, ...)
    PROTOTYPE: $;$
    CODE:
{
    if (items > 1) {
        NV want = SvNV(ST(1));
        if (!(want >= 0.0))
            croak("max_connection_reqs must be non-negative (0 for unlimited)");
        unsigned int reqs = want >= (NV)UINT_MAX ? UINT_MAX : (unsigned int)want;
        trace("set max requests per connection %u\n", reqs);
        server->max_connection_reqs = reqs;
    }
    RETVAL = server->max_connection_reqs;
}
    OUTPUT:
        RETVAL

void
_xs_destroy (struct feer_server *server)
    PPCODE:
{
    trace3("DESTROY server\n");
    /* the server may be freed without unlisten(): stop everything that points at it */
    ev_prepare_stop(feersum_ev_loop, &server->ep);
    ev_check_stop(feersum_ev_loop, &server->ec);
    ev_idle_stop(feersum_ev_loop, &server->ei);
    SvREFCNT_dec(server->request_cb_cv);
    SvREFCNT_dec(server->shutdown_cb_cv);
    SvREFCNT_dec(server->max_requests_cb_cv);
    SvREFCNT_dec(server->retire_begin_cb_cv);
    SvREFCNT_dec(server->access_log_cb_cv);
    for (int i = 0; i < server->n_listeners; i++) {
        struct feer_listen *lsnr = &server->listeners[i];
        ev_io_stop(feersum_ev_loop, &lsnr->accept_w);
        ev_timer_stop(feersum_ev_loop, &lsnr->emfile_w);
        SvREFCNT_dec(lsnr->server_name);
        SvREFCNT_dec(lsnr->server_port);
#ifdef FEERSUM_HAS_TLS
        feer_tls_cleanup_listener(lsnr);
#endif
    }
    if (server->watchers_initialized && --date_timer_refs <= 0) {
        ev_timer_stop(feersum_ev_loop, &date_timer);
        date_timer_refs = 0;
    }
}

void
set_tls (struct feer_server *server, ...)
    PPCODE:
{
#ifdef FEERSUM_HAS_TLS
    const char *cert_file = NULL;
    const char *key_file = NULL;
    const char *sni_name = NULL;
    int listener_idx = -1; /* -1 means last-added listener (default) */
    int h2 = 0;
    int i;

    if (items < 3 || (items - 1) % 2 != 0)
        croak("set_tls requires key => value pairs (cert_file => $path, key_file => $path)");

    for (i = 1; i < items; i += 2) {
        const char *key = SvPV_nolen(ST(i));
        SV *val = ST(i + 1);
        if (strcmp(key, "cert_file") == 0)
            cert_file = SvPV_nolen(val);
        else if (strcmp(key, "key_file") == 0)
            key_file = SvPV_nolen(val);
        else if (strcmp(key, "listener") == 0) {
            /* check the NV: SvIV wraps; !( ) also refuses NaN */
            NV want = SvNV(val);
            if (!(want >= -1.0 && want <= (NV)INT_MAX))
                croak("set_tls: listener index %" NVgf " out of range (0..%d or -1)",
                      want, server->n_listeners - 1);
            listener_idx = (int)want;
        }
        else if (strcmp(key, "h2") == 0)
            h2 = SvTRUE(val) ? 1 : 0;
        else if (strcmp(key, "sni") == 0)
            sni_name = SvPV_nolen(val);
        else
            croak("set_tls: unknown option '%s'", key);
    }

    if (!cert_file) croak("set_tls: cert_file is required");
    if (!key_file)  croak("set_tls: key_file is required");

    if (server->n_listeners == 0)
        croak("set_tls: no listeners configured (call use_socket/accept_on_fd first)");

    if (listener_idx < -1)
        croak("set_tls: listener index %d out of range (0..%d or -1)",
              listener_idx, server->n_listeners - 1);
    if (listener_idx < 0)
        listener_idx = server->n_listeners - 1;
    if (listener_idx >= server->n_listeners)
        croak("set_tls: listener index %d out of range (0..%d)",
              listener_idx, server->n_listeners - 1);

    struct feer_listen *lsnr = &server->listeners[listener_idx];

    /* validate before creating the context: a croak after would leak it */
    STRLEN sni_name_len = 0;
    char sni_lower[256];
    int sni_existing = -1;
    if (sni_name) {
        sni_name_len = strlen(sni_name);
        if (sni_name_len == 0)
            croak("set_tls: SNI hostname must not be empty");
        if (sni_name_len >= 256)
            croak("set_tls: SNI hostname too long");
        if (!lsnr->tls_ctx_ref)
            croak("set_tls: set a default TLS context before adding SNI entries");
        for (i = 0; (size_t)i < sni_name_len; i++)
            sni_lower[i] = ascii_lower[(unsigned char)sni_name[i]];
        sni_lower[sni_name_len] = '\0';
        /* a re-registered name is a cert rotation and must work on a full table */
        for (i = 0; i < lsnr->n_sni_entries; i++) {
            if (strcmp(lsnr->sni_entries[i].hostname, sni_lower) == 0) {
                sni_existing = i;
                break;
            }
        }
        if (sni_existing < 0 && lsnr->n_sni_entries >= FEER_MAX_SNI_ENTRIES)
            croak("set_tls: too many SNI entries (max %d)", FEER_MAX_SNI_ENTRIES);
        /* ALPN is negotiated by the default context, so a per-SNI h2 flag would be a no-op */
        if (h2)
            croak("set_tls: 'h2' option is listener-wide; set it on the "
                  "default certificate, not per-SNI entry");
    }

    ptls_context_t *new_ctx = feer_tls_create_context(aTHX_ cert_file, key_file, h2);
    if (!new_ctx)
        croak("set_tls: failed to create TLS context");

    if (sni_name) {
        struct feer_sni_entry *e;
        if (sni_existing >= 0) {
            e = &lsnr->sni_entries[sni_existing];
            feer_tls_ctx_ref_dec(e->ctx_ref);
        }
        else {
            e = &lsnr->sni_entries[lsnr->n_sni_entries++];
            Newx(e->hostname, sni_name_len + 1, char);
            memcpy(e->hostname, sni_lower, sni_name_len + 1);
        }
        e->ctx_ref = feer_tls_ctx_ref_new(new_ctx);

        trace("SNI entry '%s' set on listener %d (h2=%d)\n",
              e->hostname, listener_idx, h2);
    } else {
        if (lsnr->tls_ctx_ref)
            feer_tls_ctx_ref_dec(lsnr->tls_ctx_ref);
        lsnr->tls_ctx_ref = feer_tls_ctx_ref_new(new_ctx);

        trace("TLS enabled on listener %d (h2=%d)\n", listener_idx, h2);
    }
#else
    PERL_UNUSED_VAR(server);
    croak("set_tls: Feersum was not compiled with TLS support (need picotls submodule + OpenSSL; see Alien::OpenSSL)");
#endif
}

int
has_tls (struct feer_server *server)
    CODE:
{
    PERL_UNUSED_VAR(server);
#ifdef FEERSUM_HAS_TLS
    RETVAL = 1;
#else
    RETVAL = 0;
#endif
}
    OUTPUT:
        RETVAL

int
has_h2 (struct feer_server *server)
    CODE:
{
    PERL_UNUSED_VAR(server);
#ifdef FEERSUM_HAS_H2
    RETVAL = 1;
#else
    RETVAL = 0;
#endif
}
    OUTPUT:
        RETVAL

int
has_outq_probe (struct feer_server *server)
    CODE:
{
    PERL_UNUSED_VAR(server);
#ifdef FEERSUM_HAS_OUTQ
    RETVAL = 1;
#else
    RETVAL = 0;
#endif
}
    OUTPUT:
        RETVAL

BOOT:
    {
        feer_stash = gv_stashpv("Feersum", 1);
        feer_conn_stash = gv_stashpv("Feersum::Connection", 1);
        feer_conn_writer_stash = gv_stashpv("Feersum::Connection::Writer",1);
        feer_conn_reader_stash = gv_stashpv("Feersum::Connection::Reader",1);
        /* writes to closed sockets must return EPIPE, not kill the process */
        signal(SIGPIPE, SIG_IGN);
        I_EV_API("Feersum");

        const char *env_fl_max = getenv("FEERSUM_FREELIST_MAX");
        if (env_fl_max) {
            int n = atoi(env_fl_max);
            FEERSUM_FREELIST_MAX = n < 0 ? 0 : n;  /* clamp; 0 disables */
        }

        default_server = new_feer_server(aTHX);
        SvREFCNT_inc_void_NN(default_server->self); // never freed

        psgi_ver = newAV();
        av_extend(psgi_ver, 1);
        av_push(psgi_ver, newSViv(1));
        av_push(psgi_ver, newSViv(1));
        SvREADONLY_on((SV*)psgi_ver);

        psgi_serv10 = newSVpvs("HTTP/1.0");
        SvREADONLY_on(psgi_serv10);
        psgi_serv11 = newSVpvs("HTTP/1.1");
        SvREADONLY_on(psgi_serv11);

        method_GET = newSVpvs("GET");
        SvREADONLY_on(method_GET);
        method_POST = newSVpvs("POST");
        SvREADONLY_on(method_POST);
        method_HEAD = newSVpvs("HEAD");
        SvREADONLY_on(method_HEAD);
        method_PUT = newSVpvs("PUT");
        SvREADONLY_on(method_PUT);
        method_PATCH = newSVpvs("PATCH");
        SvREADONLY_on(method_PATCH);
        method_DELETE = newSVpvs("DELETE");
        SvREADONLY_on(method_DELETE);
        method_OPTIONS = newSVpvs("OPTIONS");
        SvREADONLY_on(method_OPTIONS);

        status_200 = newSVpvs("200 OK");
        SvREADONLY_on(status_200);
        status_201 = newSVpvs("201 Created");
        SvREADONLY_on(status_201);
        status_204 = newSVpvs("204 No Content");
        SvREADONLY_on(status_204);
        status_301 = newSVpvs("301 Moved Permanently");
        SvREADONLY_on(status_301);
        status_302 = newSVpvs("302 Found");
        SvREADONLY_on(status_302);
        status_304 = newSVpvs("304 Not Modified");
        SvREADONLY_on(status_304);
        status_400 = newSVpvs("400 Bad Request");
        SvREADONLY_on(status_400);
        status_404 = newSVpvs("404 Not Found");
        SvREADONLY_on(status_404);
        status_500 = newSVpvs("500 Internal Server Error");
        SvREADONLY_on(status_500);

        empty_query_sv = newSVpvs("");
        SvREADONLY_on(empty_query_sv);

        Zero(&psgix_io_vtbl, 1, MGVTBL);
        psgix_io_vtbl.svt_get = psgix_io_svt_get;
        newCONSTSUB(feer_stash, "HEADER_NORM_SKIP", newSViv(HEADER_NORM_SKIP));
        newCONSTSUB(feer_stash, "HEADER_NORM_UPCASE", newSViv(HEADER_NORM_UPCASE));
        newCONSTSUB(feer_stash, "HEADER_NORM_LOCASE", newSViv(HEADER_NORM_LOCASE));
        newCONSTSUB(feer_stash, "HEADER_NORM_UPCASE_DASH", newSViv(HEADER_NORM_UPCASE_DASH));
        newCONSTSUB(feer_stash, "HEADER_NORM_LOCASE_DASH", newSViv(HEADER_NORM_LOCASE_DASH));

        trace3("Feersum booted, iomatrix %lu, FEERSUM_IOMATRIX_SIZE=%u, "
            "feer_req %lu, feer_conn %lu\n",
            (long unsigned int)sizeof(struct iomatrix),
            (unsigned int)FEERSUM_IOMATRIX_SIZE,
            (long unsigned int)sizeof(struct feer_req),
            (long unsigned int)sizeof(struct feer_conn)
        );
    }

INCLUDE: feersum_conn.xs
