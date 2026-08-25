
INLINE_UNLESS_DEBUG
static SV*
fetch_av_normal (pTHX_ AV *av, I32 i)
{
    SV **elt = av_fetch(av, i, 0);
    if (elt == NULL) return NULL;
    SV *sv = *elt;
    if (unlikely(SvMAGICAL(sv))) sv = sv_2mortal(newSVsv(sv));
    if (unlikely(!SvOK(sv))) return NULL;
    if (unlikely(SvROK(sv))) sv = SvRV(sv);
    return sv;
}

INLINE_UNLESS_DEBUG
static struct iomatrix *
next_iomatrix (struct feer_conn *c)
{
    bool add_iomatrix = 0;
    struct iomatrix *m;

    if (!c->wbuf_rinq) {
        trace3("next_iomatrix(%d): head\n", c->fd);
        add_iomatrix = 1;
    }
    else {
        m = (struct iomatrix *)c->wbuf_rinq->prev->ref;
        trace3("next_iomatrix(%d): tail, count=%d, offset=%d\n",
            c->fd, m->count, m->offset);
        if (m->count >= FEERSUM_IOMATRIX_SIZE) {
            add_iomatrix = 1;
        }
    }

    if (add_iomatrix) {
        trace3("next_iomatrix(%d): alloc\n", c->fd);
        IOMATRIX_ALLOC(m);
        m->offset = m->count = 0;
        rinq_push(&c->wbuf_rinq, m);
    }

    trace3("next_iomatrix(%d): end, count=%d, offset=%d\n",
        c->fd, m->count, m->offset);
    return m;
}

// PSGI strings are bytes: ship a UTF8-flagged value downgraded; wide chars
// (> 255) fail the downgrade and keep their UTF-8 bytes.
INLINE_UNLESS_DEBUG
static SV *
feer_bytes_mortal(const char *p, STRLEN len)
{
    SV *sv = sv_2mortal(newSVpvn_utf8(p, len, 1));
    (void)sv_utf8_downgrade(sv, TRUE);
    return sv;
}

INLINE_UNLESS_DEBUG
static STRLEN
add_sv_to_wbuf(struct feer_conn *c, SV *sv)
{
    struct iomatrix *m = next_iomatrix(c);
    unsigned idx = m->count++;
    STRLEN cur;
    // newSVsv() below can croak on a magical SV, leaving the slot counted but unfilled
    m->iov[idx].iov_base = NULL;
    m->iov[idx].iov_len = 0;
    if (unlikely(SvMAGICAL(sv) || SvUTF8(sv))) {
        sv = newSVsv(sv);
        if (unlikely(SvUTF8(sv)))
            (void)sv_utf8_downgrade(sv, TRUE);
    }
    else if (unlikely(SvPADTMP(sv))) {
        // a PADTMP's PV is reused, so it must be copied or stolen
#ifdef FEERSUM_STEAL
        if (SvFLAGS(sv) == (SVs_PADTMP|SVf_POK|SVp_POK)) {
            trace3("STEALING\n");
            SV *thief = newSV(0);
            sv_upgrade(thief, SVt_PV);

            SvPV_set(thief, SvPVX(sv));
            SvLEN_set(thief, SvLEN(sv));
            SvCUR_set(thief, SvCUR(sv));

            (void)SvOK_off(sv);
            SvPV_set(sv, NULL);
            SvLEN_set(sv, 0);
            SvCUR_set(sv, 0);

            SvFLAGS(thief) |= SVf_READONLY|SVf_POK|SVp_POK;

            sv = thief;
        }
        else {
            sv = newSVsv(sv);
        }
#else
        sv = newSVsv(sv);
#endif
    }
    else {
        sv = SvREFCNT_inc(sv);
    }

    m->iov[idx].iov_base = SvPV(sv, cur);
    m->iov[idx].iov_len = cur;
    m->sv[idx] = sv;

    c->wbuf_len += cur;
    return cur;
}

/* A raw streaming body stops at the app's Content-Length: a surplus would run
 * into the next response on a reused connection. */
static void
add_raw_body_to_wbuf(struct feer_conn *c, SV *sv)
{
    dTHX;
    if (likely(!c->resp_cl_enforced)) {
        add_sv_to_wbuf(c, sv);
        return;
    }
    STRLEN len;
    const char *p = SvPV(sv, len);
    // count what reaches the wire, which add_sv_to_wbuf downgrades
    if (unlikely(SvUTF8(sv))) {
        sv = feer_bytes_mortal(p, len);
        p = SvPV(sv, len);
    }
    if (len <= c->resp_cl_owed) {
        c->resp_cl_owed -= len;
        add_sv_to_wbuf(c, sv);
        return;
    }
    trace("body over its Content-Length by %"Sz_uf", truncated fd=%d\n",
        (Sz)(len - c->resp_cl_owed), c->fd);
    if (c->resp_cl_owed) {
        SV *head = newSVpvn(p, c->resp_cl_owed);
        add_sv_to_wbuf(c, head);
        SvREFCNT_dec(head);
        c->resp_cl_owed = 0;
    }
}

INLINE_UNLESS_DEBUG
static STRLEN
add_const_to_wbuf(struct feer_conn *c, const char *str, size_t str_len)
{
    struct iomatrix *m = next_iomatrix(c);
    unsigned idx = m->count++;
    m->iov[idx].iov_base = (void*)str;
    m->iov[idx].iov_len = str_len;
    m->sv[idx] = NULL;
    c->wbuf_len += str_len;
    return str_len;
}

INLINE_UNLESS_DEBUG
static void
add_placeholder_to_wbuf(struct feer_conn *c, SV **sv, struct iovec **iov_ref)
{
    struct iomatrix *m = next_iomatrix(c);
    unsigned idx = m->count++;
    // Counted now, filled later by update_wbuf_placeholder: a croak in between
    // must leave an empty iovec, not stale memory.
    m->iov[idx].iov_base = NULL;
    m->iov[idx].iov_len = 0;
    *sv = newSV(31);
    SvPOK_on(*sv);
    m->sv[idx] = *sv;
    *iov_ref = &m->iov[idx];
}

INLINE_UNLESS_DEBUG
static void
finish_wbuf(struct feer_conn *c)
{
    // a raw body short of its Content-Length cannot end cleanly: close after it
    if (unlikely(c->resp_cl_enforced && c->resp_cl_owed))
        c->is_keepalive = 0;
    if (!c->use_chunked) return;
    // HEAD: not even the terminating chunk, which a client that reads no body
    // would parse as the start of the next response.
    if (unlikely(c->no_resp_body)) return;
    add_const_to_wbuf(c, "0\r\n\r\n", 5);
}

INLINE_UNLESS_DEBUG
static void
update_wbuf_placeholder(struct feer_conn *c, SV *sv, struct iovec *iov)
{
    STRLEN cur;
    // iov_len cannot be passed as cur: incompatible pointer type on some systems
    iov->iov_base = SvPV(sv,cur);
    iov->iov_len = cur;
    c->wbuf_len += cur;
}

static void
add_chunk_sv_to_wbuf(struct feer_conn *c, SV *sv)
{
    STRLEN len;
    (void)SvPV(sv, len);
    if (unlikely(len == 0)) return;  /* an empty chunk would read as the terminator */

    SV *chunk;
    struct iovec *chunk_iov;
    add_placeholder_to_wbuf(c, &chunk, &chunk_iov);
    STRLEN cur = add_sv_to_wbuf(c, sv);
    add_crlf_to_wbuf(c);
    sv_setpvf(chunk, "%"Sz_xf CRLF, (Sz)cur);
    update_wbuf_placeholder(c, chunk, chunk_iov);
}

static const char *
http_code_to_msg (int code) {
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
        case 421: return "Misdirected Request"; // RFC 9110
        case 422: return "Unprocessable Entity"; // RFC 4918
        case 423: return "Locked"; // RFC 4918
        case 424: return "Failed Dependency"; // RFC 4918
        case 425: return "Too Early"; // RFC 8470
        case 426: return "Upgrade Required"; // RFC 2817
        case 429: return "Too Many Requests"; // RFC 6585
        case 431: return "Request Header Fields Too Large"; // RFC 6585
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
        case 530: return "User access denied";
        default: break;
    }

    switch (code / 100) {
        case 1: return "Informational";
        case 2: return "Success";
        case 3: return "Redirection";
        case 4: return "Client Error";
        default: return "Error";
    }
}

static int
prep_socket(int fd, int is_tcp)
{
#ifdef HAS_ACCEPT4
    int flags = 1;
#else
    int flags;

    flags = fcntl(fd, F_GETFL);
    if (unlikely(flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0))
        return -1;
    if (unlikely(fcntl(fd, F_SETFD, FD_CLOEXEC) < 0))
        return -1;

    flags = 1;
#endif
    if (likely(is_tcp)) {
        if (unlikely(setsockopt(fd, SOL_TCP, TCP_NODELAY, &flags, sizeof(int))))
            return -1;
    }

    return 0;
}

#if defined(TCP_CORK)
# define FEERSUM_TCP_CORK TCP_CORK
#elif defined(TCP_NOPUSH)
# define FEERSUM_TCP_CORK TCP_NOPUSH
#endif

#ifdef FEERSUM_TCP_CORK
INLINE_UNLESS_DEBUG static void
set_cork(struct feer_conn *c, int cork)
{
    if (likely(c->cached_is_tcp)) {
        setsockopt(c->fd, SOL_TCP, FEERSUM_TCP_CORK, &cork, sizeof(cork));
    }
}
#else
# define set_cork(c, cork) ((void)0)
#endif

static void
invoke_shutdown_cb(pTHX_ struct feer_server *server)
{
    dSP;
    SV *cb = server->shutdown_cb_cv;
    server->shutdown_cb_cv = NULL;

    /* Release the loop hold, as unlisten does, or ev_run never runs dry. */
    ev_idle_stop(feersum_ev_loop, &server->ei);
    ev_prepare_stop(feersum_ev_loop, &server->ep);
    ev_check_stop(feersum_ev_loop, &server->ec);
    if (server->watchers_initialized) {
        server->watchers_initialized = false;
        if (--date_timer_refs <= 0) {
            ev_timer_stop(feersum_ev_loop, &date_timer);
            date_timer_refs = 0;
        }
    }

    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    PUTBACK;
    call_sv(cb, G_EVAL|G_VOID|G_DISCARD|G_NOARGS);
    SPAGAIN;
    trace3("called shutdown handler\n");
    if (SvTRUE(ERRSV)) {
        trouble("shutdown callback died: %-p\n", ERRSV);
        sv_setsv(ERRSV, &PL_sv_undef);
    }
    SvREFCNT_dec(cb);
    FREETMPS;
    LEAVE;
}

/* Caller must have rejected the already-shutting-down case. */
static void
feer_begin_graceful_shutdown(pTHX_ struct feer_server *server, SV *cb)
{
    SvREFCNT_dec(server->shutdown_cb_cv);
    server->shutdown_cb_cv = newSVsv(cb);
    trace("shutting down, active=%d\n", server->active_conns);

    server->shutting_down = 1;
    for (int i = 0; i < server->n_listeners; i++) {
        struct feer_listen *lsnr = &server->listeners[i];
        ev_io_stop(feersum_ev_loop, &lsnr->accept_w);
        /* A reuseport TCP listener's accept queue dies with its fd; UNIX
         * listeners stay shared across workers, so theirs is left alone. */
        if (unlikely(server->drain_accept_queue)
            && lsnr->is_tcp && lsnr->fd >= 0) {
            while (try_accept_one(feersum_ev_loop, lsnr, server))
                ;
        }
        ev_timer_stop(feersum_ev_loop, &lsnr->emfile_w);
        if (lsnr->fd >= 0) {
            if (unlikely(close(lsnr->fd) < 0))
                trouble("close(listen fd) fd=%d: %s\n", lsnr->fd, strerror(errno));
            ev_io_set(&lsnr->accept_w, -1, EV_READ);
            lsnr->fd = -1;
        }
#ifdef FEERSUM_HAS_TLS
        feer_tls_cleanup_listener(lsnr);
#endif
        lsnr->pause_flags = 0;
    }

    while (feer_server_recycle_idle_conn(server))
        ;

    if (server->active_conns <= 0 && server->shutdown_cb_cv) {
        trace("shutdown is immediate\n");
        invoke_shutdown_cb(aTHX_ server);
    }
}

static void
safe_close_conn(struct feer_conn *c, const char *where)
{
    if (unlikely(c->fd < 0))
        return;

    /* The app's IO handle owns this fd; a second close would hit a recycled
     * number and kill an unrelated connection. */
    if (unlikely(c->fd_given_away)) {
        c->fd = -1;
        return;
    }

#ifdef FEERSUM_HAS_H2
    if (c->is_h2_stream) {
        /* the parent owns the shared fd */
        c->fd = -1;
        return;
    }
#endif

    CLOSE_SENDFILE_FD(c);

#ifdef FEERSUM_HAS_TLS
    if (c->tls_tunnel)
        feer_tls_tunnel_shutdown(c);

    // An alert encrypted now sequences after whatever is still queued in
    // tls_wbuf, so flush first; if that fails send none.
    if (c->tls && c->tls_handshake_done && c->tls_wbuf.off > 0)
        (void)feer_tls_flush_wbuf(c);
    if (c->tls && c->tls_handshake_done && c->tls_wbuf.off == 0
        && !c->tls_alert_sent) {
        ptls_buffer_t closebuf;
        c->tls_alert_sent = 1;
        ptls_buffer_init(&closebuf, "", 0);
        if (unlikely(c->tls_fatal_alert))
            ptls_send_alert(c->tls, &closebuf, PTLS_ALERT_LEVEL_FATAL,
                            c->tls_fatal_alert);
        else
            ptls_send_alert(c->tls, &closebuf, PTLS_ALERT_LEVEL_WARNING,
                            PTLS_ALERT_CLOSE_NOTIFY);
        if (closebuf.off > 0) {
            ssize_t wr PERL_UNUSED_DECL;
            wr = write(c->fd, closebuf.base, closebuf.off);
        }
        ptls_buffer_dispose(&closebuf);
    }
#endif

    // FIN before close: the peer sees a clean EOF, not RST
    shutdown(c->fd, SHUT_WR);

    /* close() on an unread client frame would RST the queued response away */
    if (unlikely(c->want_linger_close) && feer_arm_linger(c, where))
        return;

    if (unlikely(close(c->fd) < 0))
        trouble("close(%s) fd=%d: %s\n", where, c->fd, strerror(errno));

    c->fd = -1;
}

static struct feer_conn *
new_feer_conn (EV_P_ int conn_fd, struct sockaddr *sa, socklen_t sa_len,
               struct feer_server *srvr, struct feer_listen *lsnr)
{
    SV *self = newSV(0);
    SvUPGRADE(self, SVt_PVMG); // ensures sv_bless doesn't reallocate
    SvGROW(self, sizeof(struct feer_conn));
    SvPOK_only(self);
    SvIOK_on(self);
    SvIV_set(self,conn_fd);

    struct feer_conn *c = (struct feer_conn *)SvPVX(self);
    Zero(c, 1, struct feer_conn);

    c->self = self;
    c->server = srvr;
    c->listener = lsnr;
    SvREFCNT_inc_void_NN(srvr->self); // prevent server GC while conn alive

    c->cached_read_timeout      = srvr->read_timeout;
    c->cached_write_timeout     = srvr->write_timeout;
    c->cached_max_conn_reqs     = srvr->max_connection_reqs;
    c->cached_is_tcp            = lsnr->is_tcp;
    c->cached_keepalive_default = srvr->is_keepalive;
    c->cached_use_reverse_proxy = srvr->use_reverse_proxy;
    c->cached_max_read_buf      = srvr->max_read_buf;
    c->cached_max_body_len      = srvr->max_body_len;
    c->cached_max_uri_len       = srvr->max_uri_len;
    c->cached_wbuf_low_water    = srvr->wbuf_low_water;
    c->fd = conn_fd;
    memcpy(&c->sa, sa, sa_len);
    c->receiving = srvr->use_proxy_protocol ? RECEIVE_PROXY_HEADER : RECEIVE_HEADERS;
    c->sendfile_fd = -1;

#ifdef FEERSUM_HAS_TLS
    if (lsnr->tls_ctx_ref) {
        ev_io_init(&c->read_ev_io, try_tls_conn_read, conn_fd, EV_READ);
        ev_io_init(&c->write_ev_io, try_tls_conn_write, conn_fd, EV_WRITE);
        feer_tls_init_conn(c, lsnr->tls_ctx_ref);
    } else
#endif
    {
        ev_io_init(&c->read_ev_io, try_conn_read, conn_fd, EV_READ);
        ev_io_init(&c->write_ev_io, try_conn_write, conn_fd, EV_WRITE);
    }
    ev_set_priority(&c->read_ev_io, srvr->read_priority);
    c->read_ev_io.data = (void *)c;

    ev_set_priority(&c->write_ev_io, srvr->write_priority);
    c->write_ev_io.data = (void *)c;

    ev_init(&c->read_ev_timer, conn_read_timeout);
    ev_set_priority(&c->read_ev_timer, srvr->read_priority);
    c->read_ev_timer.data = (void *)c;

    ev_init(&c->header_ev_timer, conn_header_timeout);
    ev_set_priority(&c->header_ev_timer, srvr->read_priority);
    c->header_ev_timer.data = (void *)c;

    ev_init(&c->write_ev_timer, conn_write_timeout);
    ev_set_priority(&c->write_ev_timer, srvr->write_priority);
    c->write_ev_timer.data = (void *)c;

    trace3("made conn fd=%d self=%p, c=%p, cur=%"Sz_uf", len=%"Sz_uf"\n",
        c->fd, self, c, (Sz)SvCUR(self), (Sz)SvLEN(self));

    SV *rv = newRV_inc(c->self);
    sv_bless(rv, feer_conn_stash); // so DESTROY can get called on read errors
    SvREFCNT_dec(rv);

    SvREADONLY_on(self);
    srvr->active_conns++;
    return c;
}

INLINE_UNLESS_DEBUG
static struct feer_conn *
sv_2feer_conn (SV *rv)
{
    if (unlikely(!sv_isa(rv,"Feersum::Connection")))
       croak("object is not of type Feersum::Connection");
    return (struct feer_conn *)SvPVX(SvRV(rv));
}

INLINE_UNLESS_DEBUG
static SV*
feer_conn_2sv (struct feer_conn *c)
{
    return newRV_inc(c->self);
}

static feer_conn_handle *
sv_2feer_conn_handle (SV *rv, bool can_croak)
{
    trace3("sv 2 conn_handle\n");
    if (unlikely(!SvROK(rv))) croak("Expected a reference");
    // do not allow subclassing
    SV *sv = SvRV(rv);
    if (likely(
        sv_isobject(rv) &&
        (SvSTASH(sv) == feer_conn_writer_stash ||
         SvSTASH(sv) == feer_conn_reader_stash)
    )) {
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
new_feer_conn_handle (pTHX_ struct feer_conn *c, bool is_writer)
{
    SV *sv;
    SvREFCNT_inc_void_NN(c->self);
    sv = newRV_noinc(newSVuv(PTR2UV(c)));
    sv_bless(sv, is_writer ? feer_conn_writer_stash : feer_conn_reader_stash);
    /* Pin the referent while the guarded callback runs (see pinned_writer);
     * the !pinned_writer gate keeps a nested poll_cb's handle off the slot. */
    if (is_writer && unlikely(c->pin_writer) && !c->pinned_writer)
        c->pinned_writer = SvREFCNT_inc_NN(SvRV(sv));
    return sv;
}

static void
init_feer_server (struct feer_server *s)
{
    Zero(s, 1, struct feer_server);
    s->read_timeout = READ_TIMEOUT;
    s->header_timeout = HEADER_TIMEOUT;
    s->write_timeout = WRITE_TIMEOUT;
    s->linger_timeout = LINGER_TIMEOUT;
    s->max_accept_per_loop = DEFAULT_MAX_ACCEPT_PER_LOOP;
    s->max_connections = 10000;
    s->max_read_buf = MAX_READ_BUF;
    s->max_body_len = MAX_BODY_LEN;
    s->max_uri_len = MAX_URI_LEN;
    s->psgix_io = true;
#ifdef FEERSUM_HAS_H2
    s->max_h2_concurrent_streams = FEER_H2_MAX_CONCURRENT_STREAMS;
    s->max_h2_conn_body = 0;
#endif
    for (int i = 0; i < FEER_MAX_LISTENERS; i++) {
        s->listeners[i].fd = -1;
        s->listeners[i].server = s;
    }
}

static struct feer_server *
new_feer_server (pTHX)
{
    SV *self = newSV(0);
    SvUPGRADE(self, SVt_PVMG);
    SvGROW(self, sizeof(struct feer_server));
    SvPOK_only(self);
    SvIOK_on(self);

    struct feer_server *s = (struct feer_server *)SvPVX(self);
    init_feer_server(s);
    s->self = self;

    SV *rv = newRV_inc(self);
    sv_bless(rv, feer_stash);
    SvREFCNT_dec(rv);

    SvREADONLY_on(self);
    return s;
}

INLINE_UNLESS_DEBUG
static struct feer_server *
sv_2feer_server (SV *rv)
{
    if (sv_isa(rv, "Feersum")) {
        return (struct feer_server *)SvPVX(SvRV(rv));
    }
    if (SvPOK(rv) && strEQ(SvPV_nolen(rv), "Feersum")) {
        if (unlikely(!default_server))
            croak("Feersum: no server instance (call Feersum->new first)");
        return default_server;
    }
    croak("object is not of type Feersum");
    return NULL; // unreachable
}

INLINE_UNLESS_DEBUG
static SV*
feer_server_2sv (struct feer_server *s)
{
    return newRV_inc(s->self);
}

INLINE_UNLESS_DEBUG static void
start_read_watcher(struct feer_conn *c) {
    ASSERT_EV_LOOP_INITIALIZED();
    if (unlikely(ev_is_active(&c->read_ev_io)))
        return;
    trace("start read watcher %d\n",c->fd);
    ev_io_start(feersum_ev_loop, &c->read_ev_io);
    SvREFCNT_inc_void_NN(c->self);
}

INLINE_UNLESS_DEBUG static void
stop_read_watcher(struct feer_conn *c) {
    if (unlikely(!ev_is_active(&c->read_ev_io)))
        return;
    trace("stop read watcher %d\n",c->fd);
    ev_io_stop(feersum_ev_loop, &c->read_ev_io);
    SvREFCNT_dec(c->self);
}

/* True only while the send queue shrinks: a peer that stopped reading holds
 * it steady and stays reapable. */
INLINE_UNLESS_DEBUG static int
feer_conn_still_delivering(struct feer_conn *c) {
#ifdef FEERSUM_HAS_OUTQ
    int outq = feer_sock_outq(c->fd);
    if (outq > 0 && (c->prev_read_outq <= 0 || outq < c->prev_read_outq)) {
        c->prev_read_outq = outq;
        return 1;
    }
    c->prev_read_outq = 0;
#else
    PERL_UNUSED_ARG(c);
#endif
    return 0;
}

INLINE_UNLESS_DEBUG static void
restart_read_timer(struct feer_conn *c) {
    /* While lingering this timer is the one-shot linger deadline, and
     * ev_timer_again would stop it rather than restart it. */
    if (unlikely(c->closing_linger))
        return;
    if (likely(!ev_is_active(&c->read_ev_timer))) {
        trace("restart read timer %d\n",c->fd);
        c->read_ev_timer.repeat = c->cached_read_timeout;
        SvREFCNT_inc_void_NN(c->self);
    }
    ev_timer_again(feersum_ev_loop, &c->read_ev_timer);
}

INLINE_UNLESS_DEBUG static void
stop_read_timer(struct feer_conn *c) {
    if (unlikely(!ev_is_active(&c->read_ev_timer)))
        return;
    trace("stop read timer %d\n",c->fd);
    ev_timer_stop(feersum_ev_loop, &c->read_ev_timer);
    SvREFCNT_dec(c->self);
}

/* A peek of 0 is EOF; EAGAIN is a quiet live client (normal while streaming). */
INLINE_UNLESS_DEBUG static bool
peer_is_gone(struct feer_conn *c)
{
    char probe;
    ssize_t n;
    if (c->fd < 0) return 1;
    do {
        n = recv(c->fd, &probe, 1, MSG_PEEK | MSG_DONTWAIT);
    } while (n < 0 && errno == EINTR);
    return n == 0;
}

INLINE_UNLESS_DEBUG static void
start_write_watcher(struct feer_conn *c) {
    ASSERT_EV_LOOP_INITIALIZED();
    if (unlikely(ev_is_active(&c->write_ev_io)))
        return;
    trace("start write watcher %d\n",c->fd);
    ev_io_start(feersum_ev_loop, &c->write_ev_io);
    SvREFCNT_inc_void_NN(c->self);
}

INLINE_UNLESS_DEBUG static void
stop_write_watcher(struct feer_conn *c) {
    if (unlikely(!ev_is_active(&c->write_ev_io)))
        return;
    trace("stop write watcher %d\n",c->fd);
    ev_io_stop(feersum_ev_loop, &c->write_ev_io);
    SvREFCNT_dec(c->self);
}

INLINE_UNLESS_DEBUG static void
restart_write_timer(struct feer_conn *c) {
    /* Backoff resets on any progress, deadline or not; poll_retry_pending may
     * only change where the timer is actually stopped or re-armed. */
    c->poll_retry_backoff = 0;
    /* fresh bytes queued: the old outq sample means nothing now */
    c->prev_outq = 0;
    c->outq_stalls = 0;
    if (c->cached_write_timeout <= 0.0) return;
    if (likely(!ev_is_active(&c->write_ev_timer))) {
        trace("restart write timer %d\n",c->fd);
        SvREFCNT_inc_void_NN(c->self);
    }
    /* a poll-retry repeat must not survive as the deadline interval */
    c->poll_retry_pending = 0;
    c->write_ev_timer.repeat = c->cached_write_timeout;
    ev_timer_again(feersum_ev_loop, &c->write_ev_timer);
}

/* Arm the write deadline without resetting a running one: "blocked on
 * writability" recurs many times a second and must not push it back. */
INLINE_UNLESS_DEBUG static void
ensure_write_timer(struct feer_conn *c) {
    if (c->cached_write_timeout <= 0.0) return;
    /* armed as a poll retry: the deadline takes the timer back */
    if (ev_is_active(&c->write_ev_timer) && likely(!c->poll_retry_pending))
        return;
    trace("arm write timer %d\n",c->fd);
    if (likely(!ev_is_active(&c->write_ev_timer)))
        SvREFCNT_inc_void_NN(c->self);
    c->poll_retry_pending = 0;
    c->poll_retry_backoff = 0;
    c->write_ev_timer.repeat = c->cached_write_timeout;
    ev_timer_again(feersum_ev_loop, &c->write_ev_timer);
}

INLINE_UNLESS_DEBUG static void
stop_write_timer(struct feer_conn *c) {
    /* a pending poll retry dies with the timer */
    c->poll_retry_pending = 0;
    c->poll_retry_backoff = 0;
    if (unlikely(!ev_is_active(&c->write_ev_timer)))
        return;
    trace("stop write timer %d\n",c->fd);
    ev_timer_stop(feersum_ev_loop, &c->write_ev_timer);
    SvREFCNT_dec(c->self);
}

/* A write poll_cb that wrote nothing: re-arming the level-triggered watcher
 * would re-deliver it every iteration, so park and pace the retry instead. */
static void
feersum_poll_retry_park(struct feer_conn *c)
{
    double iv;
    stop_write_watcher(c);
    iv = FEER_POLL_RETRY_MIN * (double)(1u << c->poll_retry_backoff);
    if (iv > FEER_POLL_RETRY_MAX) iv = FEER_POLL_RETRY_MAX;
    if (c->poll_retry_backoff < FEER_POLL_RETRY_BACKOFF_CAP)
        c->poll_retry_backoff++;
    c->poll_retry_pending = 1;
    if (likely(!ev_is_active(&c->write_ev_timer)))
        SvREFCNT_inc_void_NN(c->self);
    c->write_ev_timer.repeat = iv;
    ev_timer_again(feersum_ev_loop, &c->write_ev_timer);
    trace("poll_cb declined, parked fd=%d retry in %.3fs\n", c->fd, iv);
}

INLINE_UNLESS_DEBUG static void
stop_header_timer(struct feer_conn *c) {
    if (unlikely(!ev_is_active(&c->header_ev_timer)))
        return;
    trace("stop header timer %d\n", c->fd);
    ev_timer_stop(feersum_ev_loop, &c->header_ev_timer);
    SvREFCNT_dec(c->self);
}

INLINE_UNLESS_DEBUG static void
restart_header_timer(struct feer_conn *c) {
    double timeout = c->server->header_timeout;
    if (timeout <= 0.0) return;
    stop_header_timer(c);
    ev_timer_set(&c->header_ev_timer, timeout, 0.0);
    ev_timer_start(feersum_ev_loop, &c->header_ev_timer);
    SvREFCNT_inc_void_NN(c->self);
}

INLINE_UNLESS_DEBUG static void
stop_all_watchers(struct feer_conn *c) {
    stop_read_watcher(c);
    stop_read_timer(c);
    stop_header_timer(c);
    stop_write_watcher(c);
    stop_write_timer(c);
}

INLINE_UNLESS_DEBUG static void
feer_shutdown_conn(struct feer_conn *c, const char *where) {
    stop_all_watchers(c);
    safe_close_conn(c, where);
    change_responding_state(c, RESPOND_SHUTDOWN);
}

static void
feer_conn_set_busy(struct feer_conn *c)
{
    if (c->idle_rinq_node) {
        rinq_remove(&c->server->idle_keepalive_rinq, c->idle_rinq_node);
        c->idle_rinq_node = NULL;
    }
}

static void
feer_conn_set_idle(struct feer_conn *c)
{
    if (c->idle_rinq_node) return;

    c->idle_rinq_node = rinq_push(&c->server->idle_keepalive_rinq, c);
    trace("conn fd=%d is now idle (added to MRU)\n", c->fd);
}

static int
feer_server_recycle_idle_conn(struct feer_server *srvr)
{
    if (!srvr->idle_keepalive_rinq) return 0;

    struct feer_conn *c = (struct feer_conn *)rinq_shift(&srvr->idle_keepalive_rinq);
    if (unlikely(!c)) return 0;

    c->idle_rinq_node = NULL;

    trace("recycling idle keepalive conn fd=%d to make room for new accept\n", c->fd);

    // Only watcher refs keep the conn alive: stop_all_watchers could DESTROY
    // it before safe_close_conn runs.
    SvREFCNT_inc_void_NN(c->self);
#ifdef FEERSUM_HAS_H2
    /* GOAWAY before the FIN (RFC 9113 6.8) */
    if (c->h2_session && !c->h2_goaway_sent) {
        nghttp2_submit_goaway(c->h2_session, NGHTTP2_FLAG_NONE,
                              nghttp2_session_get_last_proc_stream_id(c->h2_session),
                              NGHTTP2_NO_ERROR, NULL, 0);
        c->h2_goaway_sent = 1;
        feer_h2_session_send(c);
    }
#endif
    feer_shutdown_conn(c, "recycled for new connection");
    SvREFCNT_dec(c->self);
    return 1;
}


/* ------------------------- lingering close ------------------------- */

/* An empty wbuf_rinq means the kernel took the bytes, not that the peer got
 * them, and a byte arriving after close() RSTs the queued response away.
 * So: shutdown(SHUT_WR), then drain until EOF, a byte cap or a deadline. */

static void
linger_read_cb(EV_P_ ev_io *w, int revents)
{
    dCONN;
    char buf[8192];
    ssize_t n;

    SvREFCNT_inc_void_NN(c->self);

    if (unlikely(revents & EV_ERROR && !(revents & EV_READ))) {
        trace("linger read EV error fd=%d revents=0x%08x\n", w->fd, revents);
        feer_shutdown_conn(c, "linger EV error");
        goto linger_out;
    }

    do {
        n = read(w->fd, buf, sizeof(buf));
    } while (n < 0 && errno == EINTR);

    if (likely(n > 0)) {
        c->linger_left = ((size_t)n < c->linger_left)
                       ? c->linger_left - (size_t)n : 0;
        trace("linger drained fd=%d left=%"Sz_uf"\n", w->fd, (Sz)c->linger_left);
        if (likely(c->linger_left > 0))
            goto linger_out;
        feer_shutdown_conn(c, "linger byte cap");
    }
    else if (n == 0) {
        feer_shutdown_conn(c, "linger peer EOF");
    }
    else if (errno != EAGAIN && errno != EWOULDBLOCK) {
        feer_shutdown_conn(c, "linger read error");
    }
linger_out:
    SvREFCNT_dec(c->self);
}

static void
linger_timeout_cb(EV_P_ ev_timer *w, int revents)
{
    dCONN;
    SvREFCNT_inc_void_NN(c->self);

    if (unlikely(revents & EV_ERROR))
        trouble("EV error on linger timer, fd=%d revents=0x%08x\n",
                c->fd, revents);

    trace("linger deadline fd=%d\n", c->fd);
    feer_shutdown_conn(c, "linger deadline");
    /* libev already stopped this one-shot timer, so stop_read_timer released
     * nothing: balance the ev_timer_start reference here */
    SvREFCNT_dec(c->self);

    SvREFCNT_dec(c->self);  /* protection */
}

/* Plain HTTP/1.x only, work complete, server not draining: a linger holds an
 * fd and a max_connections slot, which shutdown and eviction must free. */
static void
feer_linger_close(struct feer_conn *c, const char *where)
{
    if (likely(c->fd >= 0)
        && c->server->linger_timeout > 0.0
        && !c->server->shutting_down
        && !c->closing_linger
        && !c->wbuf_rinq
        && (c->responding == RESPOND_SHUTDOWN
            || c->responding == RESPOND_NOT_STARTED)
#ifdef __linux__
        && c->sendfile_fd < 0
#endif
#ifdef FEERSUM_HAS_TLS
        && !c->tls
#endif
#ifdef FEERSUM_HAS_H2
        && !c->h2_session && !c->is_h2_stream
#endif
    ) {
        trace("linger begin fd=%d (%s)\n", c->fd, where);
        if (unlikely(shutdown(c->fd, SHUT_WR) < 0 && errno != ENOTCONN))
            trace("linger shutdown fd=%d: %s\n", c->fd, strerror(errno));
        stop_all_watchers(c);
        change_responding_state(c, RESPOND_SHUTDOWN);
        change_receiving_state(c, RECEIVE_SHUTDOWN);
        c->closing_linger = 1;
        c->linger_left = LINGER_MAX_BYTES;
        ev_io_init(&c->read_ev_io, linger_read_cb, c->fd, EV_READ);
        ev_set_priority(&c->read_ev_io, c->server->read_priority);
        c->read_ev_io.data = (void *)c;
        start_read_watcher(c);
        ev_timer_init(&c->read_ev_timer, linger_timeout_cb,
                      c->server->linger_timeout, 0.0);
        ev_set_priority(&c->read_ev_timer, c->server->read_priority);
        c->read_ev_timer.data = (void *)c;
        ev_timer_start(feersum_ev_loop, &c->read_ev_timer);
        SvREFCNT_inc_void_NN(c->self);
        /* Fire response_guard now, not after the drain.  NULL before dec: its
         * DESTROY may register a replacement guard. */
        { SV *g = c->ext_guard; c->ext_guard = NULL; SvREFCNT_dec(g); }
        /* idle-listed so eviction and the shutdown sweep can reap it early */
        feer_conn_set_idle(c);
        return;
    }
    feer_shutdown_conn(c, where);
}

/* Shutdown-path linger for TLS/H2 (alert and FIN already queued), with its
 * own short cap.  Returns 1 if the fd is now held. */
static int
feer_arm_linger(struct feer_conn *c, const char *where)
{
    double cap = c->server->linger_timeout;
    if (c->fd < 0 || c->closing_linger)
        return 0;
    if (cap <= 0.0 || cap > FEER_SHUTDOWN_LINGER_MAX)
        cap = FEER_SHUTDOWN_LINGER_MAX;

    trace("shutdown linger begin fd=%d (%s)\n", c->fd, where);
    c->want_linger_close = 0;   /* the drain's own close must not linger again */
    c->closing_linger = 1;
    c->linger_left = LINGER_MAX_BYTES;
    stop_all_watchers(c);
    change_receiving_state(c, RECEIVE_SHUTDOWN);
    ev_io_init(&c->read_ev_io, linger_read_cb, c->fd, EV_READ);
    ev_set_priority(&c->read_ev_io, c->server->read_priority);
    c->read_ev_io.data = (void *)c;
    start_read_watcher(c);
    ev_timer_init(&c->read_ev_timer, linger_timeout_cb, cap, 0.0);
    ev_set_priority(&c->read_ev_timer, c->server->read_priority);
    c->read_ev_timer.data = (void *)c;
    ev_timer_start(feersum_ev_loop, &c->read_ev_timer);
    SvREFCNT_inc_void_NN(c->self);
    return 1;
}

static void
process_request_ready_rinq (struct feer_server *server)
{
    while (server->request_ready_rinq) {
        struct feer_conn *c =
            (struct feer_conn *)rinq_shift(&server->request_ready_rinq);
        if (unlikely(!c)) break;

        /* a response ended twice once left a queued conn with no request */
        if (unlikely(!c->req)) {
            trouble("dispatch without a request fd=%d\n", c->fd);
#ifdef FEERSUM_HAS_H2
            if (!c->is_h2_stream)
#endif
                feer_shutdown_conn(c, "dispatch without a request");
            SvREFCNT_dec(c->self);
            continue;
        }

        call_request_callback(c);

        if (likely(c->wbuf_rinq)) {
            conn_write_ready(c);
        }
#ifdef FEERSUM_HAS_H2
        else if (c->is_h2_stream) {
            dTHX;
            struct feer_h2_stream *stream = H2_STREAM_FROM_PC(c);
            if (stream && stream->parent)
                h2_session_send_and_poll(aTHX_ stream->parent);
        }
#endif
        SvREFCNT_dec(c->self); // for the rinq
    }
}

static void
prepare_cb (EV_P_ ev_prepare *w, int revents)
{
    struct feer_server *srvr = (struct feer_server *)w->data;

    if (unlikely(revents & EV_ERROR)) {
        trouble("EV error in prepare, revents=0x%08x\n", revents);
        ev_break(EV_A, EVBREAK_ALL);
        return;
    }

    if (!srvr->shutting_down) {
        for (int i = 0; i < srvr->n_listeners; i++) {
            struct feer_listen *lsnr = &srvr->listeners[i];
            if (!ev_is_active(&lsnr->accept_w) && !lsnr->pause_flags) {
                ev_io_start(EV_A, &lsnr->accept_w);
            }
        }
    }
    ev_prepare_stop(EV_A, w);
}

static void
check_cb (EV_P_ ev_check *w, int revents)
{
    struct feer_server *server = (struct feer_server *)w->data;

    if (unlikely(revents & EV_ERROR)) {
        trouble("EV error in check, revents=0x%08x\n", revents);
        ev_break(EV_A, EVBREAK_ALL);
        return;
    }

    trace3("check! head=%p\n", server->request_ready_rinq);
    if (server->request_ready_rinq)
        process_request_ready_rinq(server);

    /* Acted on at a loop boundary, not mid-dispatch: draining then would drop
     * responses of sibling requests (H2 streams) still queued. */
    if (unlikely(server->retire_pending) && !server->shutting_down) {
        dTHX;
        SV *cb = server->max_requests_cb_cv;
        SV *begin_cb = server->retire_begin_cb_cv;
        server->retire_pending = 0;
        server->max_requests_cb_cv = NULL;
        server->retire_begin_cb_cv = NULL;
        /* begin_cb first: an empty drain finishes inside the shutdown call */
        if (begin_cb) {
            dSP;
            ENTER;
            SAVETMPS;
            PUSHMARK(SP);
            PUTBACK;
            call_sv(begin_cb, G_DISCARD|G_VOID|G_EVAL|G_NOARGS);
            SPAGAIN;
            if (unlikely(SvTRUE(ERRSV))) {
                trouble("retirement callback died: %-p\n", ERRSV);
                sv_setsv(ERRSV, &PL_sv_undef);
            }
            PUTBACK;
            FREETMPS;
            LEAVE;
            SvREFCNT_dec(begin_cb);
        }
        if (cb) {
            feer_begin_graceful_shutdown(aTHX_ server, cb);
            SvREFCNT_dec(cb);
        }
    }
}

static void
idle_cb (EV_P_ ev_idle *w, int revents)
{
    struct feer_server *server = (struct feer_server *)w->data;

    trace("idle_cb called, revents=0x%08x\n", revents);
    if (unlikely(revents & EV_ERROR)) {
        trouble("EV error in idle, revents=0x%08x\n", revents);
        ev_break(EV_A, EVBREAK_ALL);
        return;
    }
    trace3("idle! head=%p\n", server->request_ready_rinq);
    if (server->request_ready_rinq)
        process_request_ready_rinq(server);
    ev_idle_stop(EV_A, w);
}

/* Leaving RECEIVE_WAIT re-arms the one-shot header deadline: without it the
 * 2nd and later keepalive requests would have none. */
INLINE_UNLESS_DEBUG static void
begin_request_headers(struct feer_conn *c)
{
    if (c->receiving != RECEIVE_WAIT) return;
    change_receiving_state(c, RECEIVE_HEADERS);
    restart_header_timer(c);
}

/* Idempotent: the captured method/uri are released here. */
static void
feer_emit_access_log(pTHX_ struct feer_conn *c)
{
    if (likely(!c->log_method)) return;

    SV *method = c->log_method, *uri = c->log_uri;
    c->log_method = NULL;
    c->log_uri = NULL;

    SV *cb = c->server->access_log_cb_cv;
    if (likely(cb != NULL)) {
        dSP;
        ENTER;
        SAVETMPS;
        PUSHMARK(SP);
        EXTEND(SP, 3);
        PUSHs(sv_2mortal(method));
        PUSHs(sv_2mortal(uri ? uri : newSVpvs("")));
        PUSHs(sv_2mortal(newSVnv(ev_now(feersum_ev_loop) - c->req_start)));
        PUTBACK;
        call_sv(cb, G_DISCARD|G_VOID|G_EVAL);
        SPAGAIN;
        if (unlikely(SvTRUE(ERRSV))) {
            trouble("access_log callback died: %-p\n", ERRSV);
            sv_setsv(ERRSV, &PL_sv_undef);
        }
        PUTBACK;
        FREETMPS;
        LEAVE;
    }
    else {
        SvREFCNT_dec(method);
        SvREFCNT_dec(uri);
    }
}

static void
handle_keepalive_or_close(struct feer_conn *c, conn_read_cb_t read_cb)
{
    stop_write_watcher(c);
    stop_write_timer(c);

    /* fully flushed: what the access log means by "completed" */
    {
        dTHX;
        feer_emit_access_log(aTHX_ c);
    }

    /* Strip body bytes the app never read (expected_cl is the decoded size for
     * chunked too), or they parse as the next request. */
    if (c->is_keepalive && c->rbuf) {
        ssize_t body_total = (c->expected_cl > 0) ? c->expected_cl : 0;
        if (body_total > 0) {
            ssize_t consumed = c->received_cl - (ssize_t)SvCUR(c->rbuf);
            ssize_t remaining = body_total - consumed;
            if (remaining > 0 && remaining <= (ssize_t)SvCUR(c->rbuf)) {
                sv_chop(c->rbuf, SvPVX(c->rbuf) + remaining);
                trace("drained body fd=%d stripped=%"Ssz_df" pipeline=%"Sz_uf"\n",
                    c->fd, (Ssz)remaining, (Sz)SvCUR(c->rbuf));
            }
        }
    }

    /* not back to keepalive-idle during a shutdown: nothing sweeps it again */
    if (c->is_keepalive && !c->server->shutting_down) {
        /* leftover sendfile state would be written into the next response */
        CLOSE_SENDFILE_FD(c);
        change_responding_state(c, RESPOND_NOT_STARTED);
        change_receiving_state(c, RECEIVE_WAIT);
        STRLEN pipelined = 0;
        if (c->rbuf) { pipelined = SvCUR(c->rbuf); }
        if (likely(c->req)) {
            if (likely(pipelined == 0) && c->req->buf && c->rbuf) {
                SV *tmp = c->rbuf;
                c->rbuf = c->req->buf;
                c->req->buf = NULL;
                /* sv_chop may have left it OOK; SvPV_renew reallocs SvPVX directly */
                SvOOK_off(c->rbuf);
                SvCUR_set(c->rbuf, 0);
                if (SvLEN(c->rbuf) > READ_BUFSZ * 4)
                    SvPV_renew(c->rbuf, READ_BUFSZ + 1);
                SvREFCNT_dec(tmp);
            } else if (c->req->buf) {
                SvREFCNT_dec(c->req->buf);
                c->req->buf = NULL;
            }
            free_request(c);
        }
        // No is_http11 gate: a 1.0 keep-alive client pipelines too, and its
        // bytes would otherwise sit unparsed in rbuf.
        if (unlikely(pipelined > 0)) {
            c->pipelined = pipelined;
            if (c->pipeline_depth <= MAX_PIPELINE_DEPTH) {
                c->pipeline_depth++;
                restart_header_timer(c);
                read_cb(feersum_ev_loop, &c->read_ev_io, 0);
                c->pipeline_depth--;
                /* try_tls_conn_read never arms a watcher itself: a partial
                 * pipelined request would otherwise never wake us */
                if (c->fd >= 0 && c->receiving != RECEIVE_SHUTDOWN)
                    start_read_watcher(c);
                return;
            }
            trace("pipeline depth limit reached on %d\n", c->fd);
        } else {
            c->pipelined = 0;
        }
        start_read_watcher(c);
        /* the drain sample belongs to the response just finished */
        c->prev_read_outq = 0;
        restart_read_timer(c);
        restart_header_timer(c);
        feer_conn_set_idle(c);
    } else {
        /* Not a bare safe_close_conn: the read watcher may still be armed (a
         * reader poll_cb starts it) and must be stopped before the fd goes,
         * or it keeps its ref on c->self and the conn is never freed. */
        feer_linger_close(c, "close at write shutdown");
    }
}

static void
try_conn_write(EV_P_ struct ev_io *w, int revents)
{
    dCONN;
    unsigned i;
    struct iomatrix *m;

    SvREFCNT_inc_void_NN(c->self);

    if (unlikely(revents & EV_ERROR && !(revents & EV_WRITE))) {
        trace("EV error on write, fd=%d revents=0x%08x\n", w->fd, revents);
        change_responding_state(c, RESPOND_SHUTDOWN);
        goto try_write_finished;
    }

    if (unlikely(!c->wbuf_rinq)) {
#ifdef __linux__
        // Before the RESPOND_SHUTDOWN early-out: closing the writer sets
        // RESPOND_SHUTDOWN while the sendfile is still in progress.
        if (c->sendfile_fd >= 0)
            goto try_sendfile;
#endif

        if (unlikely(c->responding >= RESPOND_SHUTDOWN))
            goto try_write_finished;

        if (!c->poll_write_cb) {
            if (c->responding == RESPOND_STREAMING)
                goto try_write_paused;

            trace("tried to write with an empty buffer %d resp=%d\n",w->fd,c->responding);
            change_responding_state(c, RESPOND_SHUTDOWN);
            goto try_write_finished;
        }

        unsigned int writes_before = c->poll_writes_seen;
        if (c->poll_write_cb_is_io_handle)
            pump_io_handle(c);
        else
            call_poll_callback(c, 1);

        if (unlikely(!c->wbuf_rinq)) {
            /* nothing else notices a gone peer: the read watcher is stopped
             * and writev never runs on an empty buffer */
            if (unlikely(peer_is_gone(c))) {
                trace("poll_cb produced nothing and the peer is gone %d\n", w->fd);
                c->is_keepalive = 0;
                change_responding_state(c, RESPOND_SHUTDOWN);
                goto try_write_finished;
            }
            /* pure decline (no write call at all): park; an empty write()
             * counts as engagement and stays hot */
            if (c->responding == RESPOND_STREAMING && c->poll_write_cb
                && c->poll_writes_seen == writes_before) {
                feersum_poll_retry_park(c);
                goto try_write_cleanup;
            }
            goto try_write_again;
        }
    }
    else if (c->cached_wbuf_low_water > 0
             && c->wbuf_len <= c->cached_wbuf_low_water
             && c->responding == RESPOND_STREAMING && c->poll_write_cb) {
        if (c->poll_write_cb_is_io_handle)
            pump_io_handle(c);
        else
            call_poll_callback(c, 1);

        // a nested event loop in the callback can re-enter and drain the ring
        if (unlikely(!c->wbuf_rinq)) goto try_write_again;
    }

try_write_again_immediately:
#if defined(__linux__) && defined(FEERSUM_TCP_CORK)
    if (c->sendfile_fd >= 0)
        set_cork(c, 1);
#endif
    m = (struct iomatrix *)c->wbuf_rinq->ref;

    /* Skip zero-length iovecs: alone in a batch they make writev() return 0,
     * which the check below would take for a fatal error. */
    while (m->offset < m->count && m->iov[m->offset].iov_len == 0) {
        if (m->sv[m->offset]) {
            SvREFCNT_dec(m->sv[m->offset]);
            m->sv[m->offset] = NULL;
        }
        m->offset++;
    }
    if (unlikely(m->offset >= m->count)) {
        rinq_shift(&c->wbuf_rinq);
        IOMATRIX_FREE(m);
        if (!c->wbuf_rinq) {
#ifdef __linux__
            if (c->sendfile_fd >= 0)
                goto try_sendfile;
#endif
            goto try_write_finished;
        }
        goto try_write_again_immediately;
    }
#if DEBUG >= 2
    warn("going to write to %d:\n",c->fd);
    for (i=0; i < m->count; i++) {
        fprintf(stderr,"%.*s",
            (int)m->iov[i].iov_len, (char*)m->iov[i].iov_base);
    }
#endif

    trace("going to write %d off=%d count=%d\n", w->fd, m->offset, m->count);
    errno = 0;
    int iov_count = m->count - m->offset;
#ifdef IOV_MAX
    if (iov_count > IOV_MAX) iov_count = IOV_MAX;
#endif
    ssize_t wrote;
    if (iov_count == 1) {
        wrote = write(w->fd, m->iov[m->offset].iov_base, m->iov[m->offset].iov_len);
    } else {
        wrote = writev(w->fd, &m->iov[m->offset], iov_count);
    }
    trace("wrote %"Ssz_df" bytes to %d, errno=%d\n", (Ssz)wrote, w->fd, errno);

    if (unlikely(wrote <= 0)) {
        if (likely(errno == EAGAIN || errno == EINTR))
            goto try_write_again;
        if (errno == ECONNRESET || errno == EPIPE)
            trace("try_conn_write fd=%d: %s\n", w->fd, strerror(errno));
        else
            trouble("try_conn_write fd=%d: %s\n", w->fd, strerror(errno));
        CLOSE_SENDFILE_FD(c);
        set_cork(c, 0);
        stop_write_timer(c);
        c->is_keepalive = 0;
        change_responding_state(c, RESPOND_SHUTDOWN);
        goto try_write_finished;
    }

    c->wbuf_len -= wrote;
    restart_write_timer(c);

    bool consume = 1;
    for (i = m->offset; i < m->count && consume; i++) {
        struct iovec *v = &m->iov[i];
        if (unlikely(v->iov_len > wrote)) {
            trace3("offset vector %d  base=%p len=%"Sz_uf"\n",
                w->fd, v->iov_base, (Sz)v->iov_len);
            v->iov_base = (char*)v->iov_base + wrote;
            v->iov_len  -= wrote;
            consume = 0;
        }
        else {
            trace3("consume vector %d base=%p len=%"Sz_uf" sv=%p\n",
                w->fd, v->iov_base, (Sz)v->iov_len, m->sv[i]);
            wrote -= v->iov_len;
            m->offset++;
            if (m->sv[i]) {
                SvREFCNT_dec(m->sv[i]);
                m->sv[i] = NULL;
            }
        }
    }

    if (likely(m->offset >= m->count)) {
        trace2("all done with iomatrix %d state=%d\n",w->fd,c->responding);
        rinq_shift(&c->wbuf_rinq);
        IOMATRIX_FREE(m);
        if (!c->wbuf_rinq) {
#ifdef __linux__
            if (c->sendfile_fd >= 0)
                goto try_sendfile;
#endif
            goto try_write_finished;
        }
        // low water: yield so poll_cb can refill
        if (c->cached_wbuf_low_water > 0
            && c->wbuf_len <= c->cached_wbuf_low_water
            && c->responding == RESPOND_STREAMING && c->poll_write_cb) {
            goto try_write_again;
        }
        trace2("write again immediately %d state=%d\n",w->fd,c->responding);
        goto try_write_again_immediately;
    }
    trace2("write fallthrough %d state=%d\n",w->fd,c->responding);
    goto try_write_again;

#ifdef __linux__
try_sendfile:
    {
        trace("sendfile %d: fd=%d off=%ld remain=%zu\n",
            w->fd, c->sendfile_fd, (long)c->sendfile_off, c->sendfile_remain);
        ssize_t sent = sendfile(w->fd, c->sendfile_fd,
                                &c->sendfile_off, c->sendfile_remain);
        if (sent > 0) {
            c->sendfile_remain -= sent;
            trace("sendfile sent %zd, remain=%zu\n", sent, c->sendfile_remain);
            if (c->sendfile_remain == 0) {
                CLOSE_SENDFILE_FD(c);
                set_cork(c, 0);
                goto try_write_finished;
            }
            // without this write_timeout reaps a long sendfile mid-file
            restart_write_timer(c);
            goto try_write_again;
        }
        else if (sent == 0) {
            // file shrank mid-transfer: body is now shorter than the committed
            // Content-Length, so the connection cannot be reused
            CLOSE_SENDFILE_FD(c);
            set_cork(c, 0);
            c->is_keepalive = 0;
            if (c->responding == RESPOND_STREAMING) {
                change_responding_state(c, RESPOND_SHUTDOWN);
            }
            goto try_write_finished;
        }
        else {
            if (errno == EAGAIN || errno == EINTR) {
                goto try_write_again;
            }
            trouble("sendfile fd=%d: %s\n", c->fd, strerror(errno));
            CLOSE_SENDFILE_FD(c);
            set_cork(c, 0);
            c->is_keepalive = 0;
            change_responding_state(c, RESPOND_SHUTDOWN);
            goto try_write_finished;
        }
    }
#endif

try_write_again:
    trace("write again %d state=%d\n",w->fd,c->responding);
    start_write_watcher(c);
    /* also when blocked without a prior write: an app-driven response would
     * otherwise have no write_timeout coverage */
    ensure_write_timer(c);
    goto try_write_cleanup;

try_write_finished:
    switch(c->responding) {
    case RESPOND_NOT_STARTED:
        // an interim 100 Continue tail just flushed; the request is still being
        // received, so stop writing and keep the read side going, do not reuse
        goto try_write_paused;
    case RESPOND_NORMAL:
        goto try_write_shutdown;
    case RESPOND_STREAMING:
        if (c->poll_write_cb) goto try_write_again;
        else goto try_write_paused;
    case RESPOND_SHUTDOWN:
        goto try_write_shutdown;
    default:
        goto try_write_cleanup;
    }

try_write_paused:
    trace3("write PAUSED %d, refcnt=%d, state=%d\n", c->fd, SvREFCNT(c->self), c->responding);
    stop_write_watcher(c);
    stop_write_timer(c);
    goto try_write_cleanup;

try_write_shutdown:
    handle_keepalive_or_close(c, try_conn_read);

try_write_cleanup:
    SvREFCNT_dec(c->self);
    return;
}

// "PROXY TCP4|TCP6|UNKNOWN src_addr dst_addr src_port dst_port\r\n"
// Returns bytes consumed, -1 on error, -2 if more data is needed
static int
parse_proxy_v1(struct feer_conn *c)
{
    char *buf = SvPVX(c->rbuf);
    STRLEN len = SvCUR(c->rbuf);

    if (len < 8)   // "PROXY \r\n"
        return -2;

    if (memcmp(buf, PROXY_V1_PREFIX, PROXY_V1_PREFIX_LEN) != 0)
        return -1;

    char *crlf = NULL;
    STRLEN search_len = len > PROXY_V1_MAX_LINE ? PROXY_V1_MAX_LINE : len;
    for (STRLEN i = PROXY_V1_PREFIX_LEN; i < search_len - 1; i++) {
        if (buf[i] == '\r' && buf[i+1] == '\n') {
            crlf = buf + i;
            break;
        }
        // a bare LF is not a terminator; scanning past it would swallow the
        // following request line into the header
        if (buf[i] == '\n')
            return -1;
    }

    if (!crlf) {
        if (len >= PROXY_V1_MAX_LINE)
            return -1;
        return -2;
    }

    size_t header_len = (crlf - buf) + 2;

    char saved = *crlf;
    *crlf = '\0';

    char *p = buf + PROXY_V1_PREFIX_LEN;

    if (strncmp(p, "UNKNOWN", 7) == 0 && (p[7] == '\0' || p[7] == ' ')) {
        // UNKNOWN keeps the original address
        *crlf = saved;
        c->proxy_proto_version = 1;
        trace("PROXY v1 UNKNOWN, keeping original address\n");
        return (int)header_len;
    }

    int is_ipv6 = 0;
    if (strncmp(p, "TCP4 ", 5) == 0) {
        p += 5;
    } else if (strncmp(p, "TCP6 ", 5) == 0) {
        p += 5;
        is_ipv6 = 1;
    } else {
        *crlf = saved;
        return -1;
    }

    char src_addr[46], dst_addr[46];  // max IPv6 length
    long long src_port, dst_port;

    // %18lld bounds the conversion: an out-of-range numeric conversion is UB
    if (sscanf(p, "%45s %45s %18lld %18lld", src_addr, dst_addr, &src_port, &dst_port) != 4) {
        *crlf = saved;
        return -1;
    }

    if (src_port < 0 || src_port > 65535 || dst_port < 0 || dst_port > 65535) {
        *crlf = saved;
        return -1;
    }

    *crlf = saved;

    if (is_ipv6) {
        struct sockaddr_in6 *sa6 = (struct sockaddr_in6 *)&c->sa;
        sa6->sin6_family = AF_INET6;
        if (inet_pton(AF_INET6, src_addr, &sa6->sin6_addr) != 1) {
            return -1;
        }
        sa6->sin6_port = htons((uint16_t)src_port);
    } else {
        struct sockaddr_in *sa4 = (struct sockaddr_in *)&c->sa;
        sa4->sin_family = AF_INET;
        if (inet_pton(AF_INET, src_addr, &sa4->sin_addr) != 1) {
            return -1;
        }
        sa4->sin_port = htons((uint16_t)src_port);
    }

    c->proxy_proto_version = 1;
    c->proxy_dst_port = (uint16_t)dst_port;
    trace("PROXY v1 %s src=%s:%lld dst_port=%lld\n", is_ipv6 ? "TCP6" : "TCP4", src_addr, src_port, dst_port);
    return (int)header_len;
}

// Returns bytes consumed, -1 on error, -2 if more data is needed
static int
parse_proxy_v2(struct feer_conn *c)
{
    unsigned char *buf = (unsigned char *)SvPVX(c->rbuf);
    STRLEN len = SvCUR(c->rbuf);

    if (len < PROXY_V2_HDR_MIN)
        return -2;

    if (memcmp(buf, PROXY_V2_SIG, PROXY_V2_SIG_LEN) != 0)
        return -1;

    unsigned char ver_cmd = buf[12];
    unsigned char version = ver_cmd & 0xF0;
    unsigned char command = ver_cmd & 0x0F;

    if (version != PROXY_V2_VERSION)
        return -1;

    unsigned char fam_proto = buf[13];
    unsigned char family = fam_proto & 0xF0;

    uint16_t addr_len = (buf[14] << 8) | buf[15];
    if (unlikely(addr_len > 4096)) { /* spec allows 65535 */
        /* trace, not trouble: rejections here must not be a log-flood tap */
        trace("PROXY v2 addr_len too large: %u\n", addr_len);
        return -1;
    }

    size_t total_len = PROXY_V2_HDR_MIN + addr_len;
    if (len < total_len)
        return -2;

    if (command == PROXY_V2_CMD_LOCAL) {
        // LOCAL keeps the original address
        c->proxy_proto_version = 2;
        trace("PROXY v2 LOCAL, keeping original address\n");
        return (int)total_len;
    }

    if (command != PROXY_V2_CMD_PROXY) {
        return -1;
    }

    unsigned char *addr_data = buf + PROXY_V2_HDR_MIN;

    if (family == PROXY_V2_FAM_INET) {
        // src_addr(4) dst_addr(4) src_port(2) dst_port(2)
        if (addr_len < PROXY_V2_ADDR_V4_LEN)
            return -1;

        struct sockaddr_in *sa4 = (struct sockaddr_in *)&c->sa;
        sa4->sin_family = AF_INET;
        memcpy(&sa4->sin_addr, addr_data, 4);
        memcpy(&sa4->sin_port, addr_data + 8, 2);  // already network order

        uint16_t dst_port_n;
        memcpy(&dst_port_n, addr_data + 10, 2);
        c->proxy_dst_port = ntohs(dst_port_n);

        trace("PROXY v2 TCP4 src=%d.%d.%d.%d:%d dst_port=%d\n",
              addr_data[0], addr_data[1], addr_data[2], addr_data[3],
              ntohs(sa4->sin_port), c->proxy_dst_port);
    } else if (family == PROXY_V2_FAM_INET6) {
        // src_addr(16) dst_addr(16) src_port(2) dst_port(2)
        if (addr_len < PROXY_V2_ADDR_V6_LEN)
            return -1;

        struct sockaddr_in6 *sa6 = (struct sockaddr_in6 *)&c->sa;
        sa6->sin6_family = AF_INET6;
        memcpy(&sa6->sin6_addr, addr_data, 16);
        memcpy(&sa6->sin6_port, addr_data + 32, 2);  // already network order

        uint16_t dst_port_n;
        memcpy(&dst_port_n, addr_data + 34, 2);
        c->proxy_dst_port = ntohs(dst_port_n);

        trace("PROXY v2 TCP6 port=%d dst_port=%d\n", ntohs(sa6->sin6_port), c->proxy_dst_port);
    } else if (family == PROXY_V2_FAM_UNSPEC) {
        trace("PROXY v2 UNSPEC, keeping original address\n");
    } else if (family == PROXY_V2_FAM_UNIX) {
        // UNIX paths are no use as REMOTE_ADDR: keep the original address
        if (addr_len < PROXY_V2_ADDR_UNIX_LEN)
            return -1;
        trace("PROXY v2 UNIX, keeping original address\n");
    } else {
        return -1;
    }

    size_t addr_size = 0;
    if (family == PROXY_V2_FAM_INET) addr_size = PROXY_V2_ADDR_V4_LEN;
    else if (family == PROXY_V2_FAM_INET6) addr_size = PROXY_V2_ADDR_V6_LEN;
    else if (family == PROXY_V2_FAM_UNIX) addr_size = PROXY_V2_ADDR_UNIX_LEN;

    if (addr_len > addr_size) {
        dTHX;
        unsigned char *tlv_start = addr_data + addr_size;
        size_t tlv_remaining = addr_len - addr_size;

        HV *tlv_hv = newHV();
        unsigned int tlv_count = 0;

        while (tlv_remaining >= 3) {  // type(1) length(2)
            // bounds a payload packed with zero-length TLVs
            if (++tlv_count > 64) {
                trace("PROXY v2 too many TLVs (>64), rejecting\n");
                SvREFCNT_dec((SV *)tlv_hv);
                return -1;
            }
            unsigned char tlv_type = tlv_start[0];
            uint16_t tlv_len = (tlv_start[1] << 8) | tlv_start[2];

            if (tlv_remaining < 3 + (size_t)tlv_len) {
                trace("PROXY v2 malformed TLV: need %u bytes, have %zu\n",
                      tlv_len, tlv_remaining - 3);
                SvREFCNT_dec((SV *)tlv_hv);
                return -1;
            }

            // pp2_tlv_ssl { uint8_t client; uint32_t verify; }
            if (tlv_type == PP2_TYPE_SSL && tlv_len >= 5
                && (tlv_start[3] & PP2_CLIENT_SSL)) {
                c->proxy_ssl = 1;
                trace("PROXY v2 TLV PP2_TYPE_SSL, client bit set\n");
            }

            if (tlv_type != PP2_TYPE_NOOP) {
                SV *val = newSVpvn((char *)(tlv_start + 3), tlv_len);
                char key[8];
                int key_len = snprintf(key, sizeof(key), "%u", tlv_type);
                hv_store(tlv_hv, key, key_len, val, 0);
                trace("PROXY v2 TLV type=%u len=%u\n", tlv_type, tlv_len);
            }

            tlv_start += 3 + (size_t)tlv_len;
            tlv_remaining -= 3 + (size_t)tlv_len;
        }

        /* a 1-2 byte tail is malformed: the spec pads with PP2_TYPE_NOOP */
        if (unlikely(tlv_remaining)) {
            trace("PROXY v2 trailing %zu bytes after TLVs, rejecting\n",
                  tlv_remaining);
            SvREFCNT_dec((SV *)tlv_hv);
            return -1;
        }

        if (HvKEYS(tlv_hv) > 0) {
            c->proxy_tlvs = newRV_noinc((SV *)tlv_hv);
        } else {
            SvREFCNT_dec((SV *)tlv_hv);
        }
    }

    c->proxy_proto_version = 2;
    return (int)total_len;
}

static int
try_parse_proxy_header(struct feer_conn *c)
{
    if (SvCUR(c->rbuf) == 0)
        return -2;

    unsigned char first = ((unsigned char *)SvPVX(c->rbuf))[0];

    if (first == 'P') {
        return parse_proxy_v1(c);
    } else if (first == 0x0D) {
        return parse_proxy_v2(c);
    } else {
        return -1;
    }
}

