static int
try_parse_http(struct feer_conn *c, size_t last_read)
{
    struct feer_req *req = c->req;
    if (likely(!req)) {
        FEER_REQ_ALLOC(req);
        c->req = req;
    }

    // phr_parse_request resets num_headers on each call; must restore to max
    req->num_headers = MAX_HEADERS;

    return phr_parse_request(SvPVX(c->rbuf), SvCUR(c->rbuf),
        &req->method, &req->method_len,
        &req->uri, &req->uri_len, &req->minor_version,
        req->headers, &req->num_headers,
        (SvCUR(c->rbuf)-last_read));
}

INLINE_UNLESS_DEBUG static void
finish_receiving(struct feer_conn *c) {
    change_receiving_state(c, RECEIVE_SHUTDOWN);
    stop_read_watcher(c);
    stop_read_timer(c);
    stop_header_timer(c);
}

static void
try_conn_read(EV_P_ ev_io *w, int revents)
{
    dCONN;
    SvREFCNT_inc_void_NN(c->self);
    feer_conn_set_busy(c);
    ssize_t got_n = 0;

    if (unlikely(c->pipelined)) goto pipelined;

    if (unlikely(revents & EV_ERROR && !(revents & EV_READ))) {
        trace("EV error on read, fd=%d revents=0x%08x\n", w->fd, revents);
        goto try_read_error;
    }

    if (unlikely(c->receiving == RECEIVE_SHUTDOWN))
        goto dont_read_again;

    trace("try read %d\n",w->fd);

    if (unlikely(!c->rbuf)) {
        trace("init rbuf for %d\n",w->fd);
        c->rbuf = newSV(READ_BUFSZ + 1);
        SvPOK_on(c->rbuf);
    }

    ssize_t space_free = SvLEN(c->rbuf) - SvCUR(c->rbuf);
    // a Content-Length body is bounded by expected_cl, not max_read_buf
    if (unlikely(space_free < READ_BUFSZ) && c->receiving == RECEIVE_BODY) {
        size_t cur_len = SvLEN(c->rbuf);
        size_t need = (size_t)c->expected_cl + 1;
        if (cur_len < need) {
            size_t new_len = cur_len + READ_GROW_FACTOR*READ_BUFSZ;
            if (new_len > need) new_len = need;
            SvGROW(c->rbuf, new_len);
            space_free = (ssize_t)(SvLEN(c->rbuf) - SvCUR(c->rbuf));
        }
    }
    else if (unlikely(space_free < READ_BUFSZ)) {
        size_t cur_len = SvLEN(c->rbuf);
        // bound what is buffered, not where the next grow step would land
        if (unlikely(SvCUR(c->rbuf) > c->cached_max_read_buf)) {
            trace("buffer too large %d: %"Sz_uf" > %"Sz_uf"\n",
                w->fd, (Sz)SvCUR(c->rbuf), (Sz)c->cached_max_read_buf);
            // read side only: stop_all_watchers would drop the queued response
            if (c->receiving == RECEIVE_HEADERS)
                respond_with_server_error(c, "Request header fields too large\n", 431);
            else
                respond_with_server_error(c, "Request too large\n", 413);
            goto dont_read_again;
        }
        size_t new_len = cur_len + READ_GROW_FACTOR*READ_BUFSZ;
        trace("moar memory %d: %"Sz_uf" to %"Sz_uf"\n",
            w->fd, (Sz)SvLEN(c->rbuf), (Sz)new_len);
        SvGROW(c->rbuf, new_len);
        space_free = (ssize_t)(SvLEN(c->rbuf) - SvCUR(c->rbuf));
    }

    char *cur = SvPVX(c->rbuf) + SvCUR(c->rbuf);
    got_n = read(w->fd, cur, space_free);

    if (unlikely(got_n <= 0)) {
        if (unlikely(got_n == 0)) {
            trace("EOF before complete request: fd=%d buf=%"Sz_uf"\n", w->fd, (Sz)SvCUR(c->rbuf));
            goto try_read_error;
        }
        if (likely(errno == EAGAIN || errno == EINTR))
            goto try_read_again;
        if (errno == ECONNRESET || errno == EPIPE)
            trace("try_conn_read fd=%d: %s\n", w->fd, strerror(errno));
        else
            trouble("try_conn_read fd=%d: %s\n", w->fd, strerror(errno));
        goto try_read_error;
    }

    trace("read %d %"Ssz_df"\n", w->fd, (Ssz)got_n);
    SvCUR(c->rbuf) += got_n;
    begin_request_headers(c);
    goto try_parse;

pipelined:
    got_n = c->pipelined;
    c->pipelined = 0;
    /* no socket event for these bytes: without the WAIT->HEADERS transition
     * a half-written pipelined request gets no header deadline */
    begin_request_headers(c);

try_parse:
    if (unlikely(c->receiving == RECEIVE_PROXY_HEADER)) {
        int ret = try_parse_proxy_header(c);
        if (ret == -1) {
            respond_with_server_error(c, "Invalid PROXY protocol header\n", 400);
            goto dont_read_again;
        }
        if (ret == -2) goto try_read_again_reset_timer;

        STRLEN remaining = SvCUR(c->rbuf) - ret;
        if (remaining > 0)
            memmove(SvPVX(c->rbuf), SvPVX(c->rbuf) + ret, remaining);
        SvCUR_set(c->rbuf, remaining);

        feer_clear_remote_cache(c);

        change_receiving_state(c, RECEIVE_HEADERS);
        if (remaining > 0) {
            got_n = remaining;
            goto try_parse;
        }
        goto try_read_again_reset_timer;
    }

    if (likely(c->receiving <= RECEIVE_HEADERS)) {
        int ret = try_parse_http(c, (size_t)got_n);
        if (ret == -1) goto try_read_bad;
        if (ret == -2) {
            /* the growth check only fires when space runs out; cap here too */
            if (unlikely(SvCUR(c->rbuf) > c->cached_max_read_buf)) {
                trace("header buffer too large %d: %"Sz_uf" > %"Sz_uf"\n",
                    w->fd, (Sz)SvCUR(c->rbuf), (Sz)c->cached_max_read_buf);
                respond_with_server_error(c,
                    "Request header fields too large\n", 431);
                goto dont_read_again;
            }
#ifdef TCP_DEFER_ACCEPT
            goto try_read_again_reset_timer;
#else
            if (c->cached_is_tcp) goto try_read_again;
            else goto try_read_again_reset_timer;
#endif
        }

        /* ret is the body offset, i.e. the header block size */
        if (unlikely((STRLEN)ret > c->cached_max_read_buf)) {
            trace("header block too large %d: %"Sz_uf" > %"Sz_uf"\n",
                w->fd, (Sz)ret, (Sz)c->cached_max_read_buf);
            respond_with_server_error(c, "Request header fields too large\n", 431);
            goto dont_read_again;
        }
        if (process_request_headers(c, ret))
            goto try_read_again_reset_timer;
        else
            goto dont_read_again;
    }
    else if (likely(c->receiving == RECEIVE_BODY)) {
        c->received_cl += got_n;
        if (c->received_cl < c->expected_cl)
            goto try_read_again_reset_timer;
        sched_request_callback(c);
        goto dont_read_again;
    }
    else if (c->receiving == RECEIVE_CHUNKED) {
        int ret = try_parse_chunked(c);
        if (ret == 1) {
            if (unlikely(SvCUR(c->rbuf) > c->cached_max_read_buf)) {
                trace("chunked buffer too large %d: %"Sz_uf" > %"Sz_uf"\n",
                    w->fd, (Sz)SvCUR(c->rbuf), (Sz)c->cached_max_read_buf);
                respond_with_server_error(c, "Request too large\n", 413);
                goto dont_read_again;
            }
            goto try_read_again_reset_timer;
        }
        if (ret == -2) {
            respond_with_server_error(c, "Request body too large\n", 413);
            goto dont_read_again;
        }
        if (ret == -1) {
            respond_with_server_error(c, "Malformed chunked encoding\n", 400);
            goto dont_read_again;
        }
        sched_request_callback(c);
        goto dont_read_again;
    }
    else if (c->receiving == RECEIVE_STREAMING) {
        c->received_cl += got_n;
        if (c->poll_read_cb) {
            call_poll_callback(c, 0);  // 0 = read callback
        }
        // the callback may have closed the connection
        if (c->receiving >= RECEIVE_SHUTDOWN)
            goto dont_read_again;
        if (c->expected_cl > 0 && c->received_cl >= c->expected_cl) {
            goto dont_read_again;
        }
        goto try_read_again_reset_timer;
    }
    else {
        trouble("unknown read state fd=%d state=%d\n", w->fd, c->receiving);
    }

try_read_error:
    trace("READ ERROR %d, refcnt=%d\n", w->fd, SvREFCNT(c->self));
    change_receiving_state(c, RECEIVE_SHUTDOWN);
    change_responding_state(c, RESPOND_SHUTDOWN);
    stop_all_watchers(c);
    goto try_read_cleanup;

try_read_bad:
    trace("bad request %d\n", w->fd);
    /* picohttpparser returns -1 for malformed and for too many headers alike;
     * only the cap leaves num_headers at MAX_HEADERS */
    if (unlikely(c->req && c->req->num_headers >= MAX_HEADERS))
        respond_with_server_error(c, "Too many header fields\n", 431);
    else
        respond_with_server_error(c, "Malformed request\n", 400);
dont_read_again:
    trace("done reading %d\n", w->fd);
    finish_receiving(c);
    goto try_read_cleanup;

try_read_again_reset_timer:
    trace("(reset read timer) %d\n", w->fd);
    restart_read_timer(c);
try_read_again:
    trace("read again %d\n", w->fd);
    start_read_watcher(c);

try_read_cleanup:
    SvREFCNT_dec(c->self);
}

static void
conn_read_timeout (EV_P_ ev_timer *w, int revents)
{
    dCONN;
    SvREFCNT_inc_void_NN(c->self);

    if (unlikely(!(revents & EV_TIMER) || c->receiving == RECEIVE_SHUTDOWN)) {
        if (revents & EV_ERROR)
            trouble("EV error on read timer, fd=%d revents=0x%08x\n",
                c->fd,revents);
        goto read_timeout_cleanup;
    }

    trace("read timeout %d\n", c->fd);

#ifdef FEERSUM_HAS_H2
    if (c->h2_session) {
        /* H2 cannot stop these timers at tunnel takeover (sibling streams still
         * need the idle bound), so re-arm.  A dispatched stream is not idle, but
         * one owing bytes the peer will not take is stalled: strike it. */
        int stalled = 0;
        for (struct feer_h2_stream *s = c->h2_streams; s; s = s->next) {
            if (!s->tunnel_established && !s->pseudo_conn)
                continue;
            if (s->tunnel_established || !h2_stream_send_pending(s)) {
                trace("H2 idle timeout deferred, stream live fd=%d\n", c->fd);
                c->h2_stall_strikes = 0;
                restart_read_timer(c);
                goto read_timeout_cleanup;
            }
            stalled = 1;
        }
        if (stalled && ++c->h2_stall_strikes < FEER_H2_STALL_STRIKES) {
            trace("H2 stall strike %d fd=%d\n", c->h2_stall_strikes, c->fd);
            restart_read_timer(c);
            goto read_timeout_cleanup;
        }
        /* respond_with_server_error writes HTTP/1.1; H2 gets a GOAWAY */
        trace("H2 idle timeout fd=%d\n", c->fd);
        if (!c->h2_goaway_sent) {
            nghttp2_submit_goaway(c->h2_session, NGHTTP2_FLAG_NONE,
                                  nghttp2_session_get_last_proc_stream_id(c->h2_session),
                                  NGHTTP2_NO_ERROR, NULL, 0);
            c->h2_goaway_sent = 1;
            feer_h2_session_send(c);
        }
        feer_shutdown_conn(c, "H2 idle timeout");
        goto read_timeout_cleanup;
    }
#endif

    if (likely(c->responding == RESPOND_NOT_STARTED) && c->receiving >= RECEIVE_HEADERS) {
#ifdef FEERSUM_HAS_TLS
        if (c->tls && !c->tls_handshake_done) {
            feer_shutdown_conn(c, "TLS handshake timeout (read)");
            goto read_timeout_cleanup;
        }
#endif
        const char *msg;
        if (c->receiving == RECEIVE_PROXY_HEADER) {
            msg = "PROXY protocol header timeout.";
        }
        else if (c->receiving == RECEIVE_HEADERS) {
            msg = "Headers took too long.";
        }
        else {
            msg = "Timeout reading body.";
        }
        respond_with_server_error(c, msg, 408);
    } else if (feer_conn_still_delivering(c)) {
        /* this clock doubles as the keepalive idle clock; delivering is not idle */
        trace("read deadline deferred, still delivering fd=%d\n", c->fd);
        restart_read_timer(c);
    } else {
        trace("read timeout in keepalive conn: %d\n", c->fd);
        /* linger so a late pipelined request is absorbed instead of RST-ing
         * away the tail of the previous response */
        feer_linger_close(c, "close at read timeout");
        change_receiving_state(c, RECEIVE_SHUTDOWN);
    }

read_timeout_cleanup:
    SvREFCNT_dec(c->self);
}

// non-resetting header deadline (Slowloris)
static void
conn_header_timeout (EV_P_ ev_timer *w, int revents)
{
    dCONN;
    SvREFCNT_inc_void_NN(c->self);

    if (unlikely(!(revents & EV_TIMER) || c->receiving == RECEIVE_SHUTDOWN)) {
        if (revents & EV_ERROR)
            trouble("EV error on header timer, fd=%d revents=0x%08x\n",
                c->fd, revents);
        goto header_timeout_cleanup;
    }

    if ((c->receiving == RECEIVE_HEADERS || c->receiving == RECEIVE_PROXY_HEADER)
        && c->responding == RESPOND_NOT_STARTED) {
        trace("header deadline timeout %d (Slowloris protection)\n", c->fd);
#ifdef FEERSUM_HAS_TLS
        if (c->tls && !c->tls_handshake_done) {
            feer_shutdown_conn(c, "TLS handshake timeout");
        } else
#endif
        {
            respond_with_server_error(c, "Header timeout (possible Slowloris attack)\n", 408);
        }
    }

header_timeout_cleanup:
    SvREFCNT_dec(c->self);  // the timer's ref: one-shot, libev already stopped it
    SvREFCNT_dec(c->self);  // the callback guard
}

static void
conn_write_timeout (EV_P_ ev_timer *w, int revents)
{
    dCONN;
    SvREFCNT_inc_void_NN(c->self);

    // no RESPOND_SHUTDOWN guard: a complete response enters it when queued,
    // before the drain
    if (unlikely(!(revents & EV_TIMER))) {
        if (revents & EV_ERROR)
            trouble("EV error on write timer, fd=%d revents=0x%08x\n",
                c->fd, revents);
        goto write_timeout_cleanup;
    }

    /* poll_cb re-invitation, not a deadline; stop the timer first since
     * ev_timer_again made it periodic */
    if (unlikely(c->poll_retry_pending)) {
        c->poll_retry_pending = 0;
        if (likely(ev_is_active(w))) {
            ev_timer_stop(feersum_ev_loop, w);
            SvREFCNT_dec(c->self);
        }
        trace("poll retry %d\n", c->fd);
        conn_write_ready(c);
        goto write_timeout_cleanup;
    }

    /* no writev progress is not a stalled peer: EPOLLOUT needs half the sndbuf
     * free.  A shrinking kernel queue means the peer is draining; ACKs arrive
     * in clumps, so reap after three drain-free intervals, not one. */
#ifdef FEERSUM_HAS_OUTQ
    {
        int outq = feer_sock_outq(c->fd);
        if (outq > 0) {
            int stalls = (c->prev_outq > 0 && outq < c->prev_outq)
                         ? 0 : c->outq_stalls + 1;
            if (stalls < 3) {
                trace("write deadline deferred fd=%d outq=%d prev=%d stalls=%d\n",
                    c->fd, outq, c->prev_outq, stalls);
                restart_write_timer(c);   /* resets both trackers; re-store */
                c->prev_outq = outq;
                c->outq_stalls = stalls;
                goto write_timeout_cleanup;
            }
        }
    }
#endif

    trace("write timeout %d\n", c->fd);
#ifdef FEERSUM_HAS_H2
    /* a live tunnel is exempt; the deadline exists for H2 only to bound
     * tls_wbuf, so bound that by size instead */
    if (c->h2_session && c->tls && c->tls_wbuf.off < FEER_TUNNEL_MAX_WBUF) {
        for (struct feer_h2_stream *s = c->h2_streams; s; s = s->next) {
            if (!s->tunnel_established) continue;
            trace("H2 write deadline deferred, tunnel live fd=%d\n", c->fd);
            restart_write_timer(c);
            goto write_timeout_cleanup;
        }
    }
    /* GOAWAY(last_stream_id) tells the client which in-flight requests it may retry */
    if (c->h2_session && !c->h2_goaway_sent) {
        nghttp2_submit_goaway(c->h2_session, NGHTTP2_FLAG_NONE,
                              nghttp2_session_get_last_proc_stream_id(c->h2_session),
                              NGHTTP2_NO_ERROR, NULL, 0);
        c->h2_goaway_sent = 1;
        feer_h2_session_send(c);
    }
#endif
    feer_shutdown_conn(c, "write timeout");
    change_receiving_state(c, RECEIVE_SHUTDOWN);

write_timeout_cleanup:
    SvREFCNT_dec(c->self);
}

// returns -1 with fd already closed
static int
setup_accepted_conn(EV_P_ int fd, struct sockaddr *sa, socklen_t sa_len,
                    struct feer_server *srvr, struct feer_listen *lsnr)
{
    if (unlikely(prep_socket(fd, lsnr->is_tcp))) {
        trouble("prep_socket failed for fd=%d: %s\n", fd, strerror(errno));
        if (unlikely(close(fd) < 0))
            trouble("close(prep_socket error) fd=%d: %s\n", fd, strerror(errno));
        return -1;
    }

    struct feer_conn *c = new_feer_conn(EV_A, fd, sa, sa_len, srvr, lsnr);

    // arm at accept: the lazy arming needs parsed bytes first and
    // header_timeout may be 0
    restart_read_timer(c);

    if (srvr->header_timeout > 0.0) {
        ev_timer_set(&c->header_ev_timer, srvr->header_timeout, 0.0);
        ev_timer_start(feersum_ev_loop, &c->header_ev_timer);
        SvREFCNT_inc_void_NN(c->self);
        trace("started header deadline timer %d (%.1fs)\n", c->fd, srvr->header_timeout);
    }

#ifdef TCP_DEFER_ACCEPT
    // drain_accept_queue turns TCP_DEFER_ACCEPT off, so data may not be there
#ifdef FEERSUM_HAS_TLS
    if (lsnr->tls_ctx_ref) {
        // the TLS handshake needs event-driven I/O
        start_read_watcher(c);
    } else
#endif
    {
        try_conn_read(EV_A, &c->read_ev_io, EV_READ);
    }
    assert(SvREFCNT(c->self) <= (srvr->header_timeout > 0.0 ? 5 : 4));
#else
    if (lsnr->is_tcp) {
        start_read_watcher(c);
        assert(SvREFCNT(c->self) == (srvr->header_timeout > 0.0 ? 4 : 3));
    } else {
#ifdef FEERSUM_HAS_TLS
        // try_tls_conn_read never arms a watcher itself
        if (lsnr->tls_ctx_ref)
            start_read_watcher(c);
        else
#endif
            try_conn_read(EV_A, &c->read_ev_io, EV_READ);
        assert(SvREFCNT(c->self) <= (srvr->header_timeout > 0.0 ? 5 : 4));
    }
#endif
    SvREFCNT_dec(c->self);
    return 0;
}

static void
emfile_retry_cb (EV_P_ ev_timer *w, int revents)
{
    PERL_UNUSED_VAR(revents);
    struct feer_listen *lsnr = (struct feer_listen *)w->data;
    if (lsnr->server->shutting_down) return;
    trace("EMFILE retry: clearing emfile pause on fd=%d\n", lsnr->fd);
    lsnr->pause_flags &= ~FEER_PAUSE_EMFILE;
    if (!lsnr->pause_flags && lsnr->fd >= 0)
        ev_io_start(EV_A, &lsnr->accept_w);
}

/* returns 1 to keep accepting, 0 to stop */
static int
try_accept_one(EV_P_ struct feer_listen *lsnr, struct feer_server *srvr)
{
    struct sockaddr_storage sa_buf;
    socklen_t sa_len = sizeof(struct sockaddr_storage);
    errno = 0;
#ifdef HAS_ACCEPT4
    int fd = accept4(lsnr->fd, (struct sockaddr *)&sa_buf, &sa_len, SOCK_CLOEXEC|SOCK_NONBLOCK);
#else
    int fd = accept(lsnr->fd, (struct sockaddr *)&sa_buf, &sa_len);
#endif
    trace("accepted fd=%d, errno=%d\n", fd, errno);
    if (fd == -1) {
        if (errno == EINTR) return 1;
        /* the pending connection stays queued, so a level-triggered watcher
         * would spin on the failing accept() */
        if (errno == EMFILE || errno == ENFILE
            || errno == ENOBUFS || errno == ENOMEM) {
            trouble("accept: %s - pausing accept for 1s on fd=%d\n",
                    strerror(errno), lsnr->fd);
            ev_io_stop(EV_A, &lsnr->accept_w);
            lsnr->pause_flags |= FEER_PAUSE_EMFILE;
            ev_timer_set(&lsnr->emfile_w, 1.0, 0.0);
            ev_timer_start(EV_A, &lsnr->emfile_w);
        }
        return 0;
    }

    /* admit against sockets: active_conns also counts H2 pseudo-conns, which
     * max_h2_concurrent_streams already bounds */
    int socket_conns = srvr->active_conns;
#ifdef FEERSUM_HAS_H2
    socket_conns -= srvr->active_h2_streams;
#endif
    if (srvr->max_connections > 0 && socket_conns >= srvr->max_connections) {
        if (!feer_server_recycle_idle_conn(srvr)) {
            /* pause rather than spin accepting-and-closing; DESTROY clears it */
            trace("max_connections limit reached (%d), pausing accept on fd=%d\n",
                  srvr->max_connections, lsnr->fd);
            close(fd);
            ev_io_stop(EV_A, &lsnr->accept_w);
            lsnr->pause_flags |= FEER_PAUSE_CAP;
            return 0;
        }
    }

    setup_accepted_conn(EV_A, fd, (struct sockaddr *)&sa_buf, sa_len, srvr, lsnr);
    return 1;
}

static void
accept_cb (EV_P_ ev_io *w, int revents)
{
    struct feer_listen *lsnr = (struct feer_listen *)w->data;
    struct feer_server *srvr = lsnr->server;

    if (unlikely(srvr->shutting_down)) {
        ev_io_stop(EV_A, w);
        return;
    }

    if (unlikely(revents & EV_ERROR)) {
        trouble("EV error in accept_cb, fd=%d, revents=0x%08x\n",w->fd,revents);
        ev_break(EV_A, EVBREAK_ALL);
        return;
    }

    trace2("accept! revents=0x%08x\n", revents);

    int accept_count = 0;
    while (accept_count++ < srvr->max_accept_per_loop) {
        if (!try_accept_one(EV_A, lsnr, srvr)) break;
    }
}

static void
setup_accept_watcher(struct feer_listen *lsnr, int listen_fd)
{
    struct feer_server *srvr = lsnr->server;
    ev_io_init(&lsnr->accept_w, accept_cb, listen_fd, EV_READ);
    lsnr->accept_w.data = (void *)lsnr;
    ev_set_priority(&lsnr->accept_w, srvr->accept_priority);
    ev_init(&lsnr->emfile_w, emfile_retry_cb);
    lsnr->emfile_w.data = (void *)lsnr;
}

static void
sched_request_callback (struct feer_conn *c)
{
    struct feer_server *server = c->server;
    trace("sched req callback: %d c=%p, head=%p\n", c->fd, c, server->request_ready_rinq);
    rinq_push(&server->request_ready_rinq, c);
    SvREFCNT_inc_void_NN(c->self); // for the rinq
    if (!ev_is_active(&server->ei)) {
        trace("starting idle watcher\n");
        ev_idle_start(feersum_ev_loop, &server->ei);
    }
}

// Decodes in place, rbuf = [decoded body][unparsed]: received_cl is the decoded
// length, chunk_remaining the state (CHUNK_STATE_*).  Returns 1 need more,
// 0 complete, -1 malformed, -2 over the size limit
static int
try_parse_chunked (struct feer_conn *c)
{
    if (!c->rbuf) return 1;

    char *buf = SvPVX(c->rbuf);
    STRLEN buf_len = SvCUR(c->rbuf);
    STRLEN read_pos = (c->received_cl >= 0) ? (STRLEN)c->received_cl : 0;
    STRLEN write_pos = read_pos;

    trace("try_parse_chunked fd=%d buf_len=%"Sz_uf" read_pos=%"Sz_uf" chunk_remaining=%"Ssz_df"\n",
        c->fd, (Sz)buf_len, (Sz)read_pos, (Ssz)c->chunk_remaining);

    while (read_pos < buf_len) {
        if (c->chunk_remaining == CHUNK_STATE_NEED_CRLF) {
            STRLEN remaining = buf_len - read_pos;
            if (remaining < 2)
                goto need_more;
            if (buf[read_pos] != '\r' || buf[read_pos+1] != '\n') {
                trace("chunked: missing CRLF after chunk data\n");
                return -1;
            }
            read_pos += 2;
            c->chunk_remaining = CHUNK_STATE_PARSE_SIZE;
            continue;
        }
        else if (c->chunk_remaining == CHUNK_STATE_PARSE_SIZE) {
            char *line_start = buf + read_pos;
            char *line_end = NULL;
            STRLEN remaining = buf_len - read_pos;
            STRLEN i;

            for (i = 0; i + 1 < remaining; i++) {
                if (line_start[i] == '\r' && line_start[i+1] == '\n') {
                    line_end = line_start + i;
                    break;
                }
            }

            if (!line_end) {
                // the scan restarts every read event: an unbounded line is quadratic
                if (unlikely(remaining > MAX_CHUNK_SIZE_LINE)) {
                    trace("chunked: chunk size line too long (%"Sz_uf")\n",
                          (Sz)remaining);
                    return -1;
                }
                trace("chunked: need more data for chunk size line\n");
                goto need_more;
            }

            UV chunk_size = 0;
            int hex_digits = 0;
            char *p = line_start;
            while (p < line_end) {
                unsigned char ch = (unsigned char)*p;
                unsigned char val = hex_decode_table[ch];
                if (val != 0xFF) {
                    hex_digits++;
                    if (chunk_size > (UV_MAX >> 4)) {
                        trace("chunked: chunk size overflow\n");
                        return -1;
                    }
                    chunk_size = (chunk_size << 4) | val;
                }
                else if (ch == ';' || ch == ' ' || ch == '\t') {
                    break;
                }
                else {
                    trace("chunked: invalid hex char '%c'\n", ch);
                    return -1;
                }
                p++;
            }

            if (hex_digits == 0) {
                trace("chunked: no hex digits in chunk size\n");
                return -1;
            }

            trace("chunked: parsed size=%"UVuf" at pos=%"Sz_uf"\n",
                chunk_size, (Sz)(line_start - buf));

            read_pos = (line_end - buf) + 2;

            if (chunk_size == 0) {
                // last chunk: the chunk_remaining == 0 branch scans the trailers
                c->trailer_count = 0;
                c->chunk_remaining = 0;
                continue;
            }

            // two checks: the subtraction wraps when chunk_size is the larger
            if (unlikely(chunk_size > (UV)c->cached_max_body_len)) {
                trace("chunked: chunk too large %"UVuf"\n", chunk_size);
                return -2;
            }
            if (unlikely(write_pos > (STRLEN)(c->cached_max_body_len - chunk_size))) {
                trace("chunked: body too large %"UVuf" + %"Sz_uf"\n",
                    chunk_size, (Sz)write_pos);
                return -2;
            }

            c->chunk_count++;
            if (unlikely(c->chunk_count > MAX_CHUNK_COUNT)) {
                trace("chunked: too many chunks (%u)\n", c->chunk_count);
                return -1;
            }

            if (chunk_size > (UV)SSIZE_MAX) return -1;
            c->chunk_remaining = (ssize_t)chunk_size;
        }
        else if (c->chunk_remaining == 0) {
            // after the last chunk: trailers
            STRLEN remaining = buf_len - read_pos;
            char *trailer_start = buf + read_pos;
            STRLEN i = 0;
            while (i + 1 < remaining) {
                if (trailer_start[i] == '\r' && trailer_start[i+1] == '\n') {
                    if (i == 0) {
                        read_pos += 2;
                        STRLEN pipelined = (read_pos < buf_len) ? buf_len - read_pos : 0;
                        c->expected_cl = write_pos;
                        c->received_cl = write_pos + pipelined;
                        if (pipelined > 0)
                            memmove(buf + write_pos, buf + read_pos, pipelined);
                        SvCUR_set(c->rbuf, write_pos + pipelined);
                        return 0;
                    }
                    if (unlikely(++c->trailer_count > MAX_TRAILER_HEADERS)) {
                        trace("chunked: too many trailer headers\n");
                        return -1;
                    }
                    read_pos += i + 2;
                    remaining = buf_len - read_pos;
                    trailer_start = buf + read_pos;
                    i = 0;
                    continue;
                }
                i++;
            }
            // same rescan shape as the chunk-size line
            if (unlikely(remaining > MAX_TRAILER_LINE)) {
                trace("chunked: trailer line too long (%"Sz_uf")\n", (Sz)remaining);
                return -1;
            }
            goto need_more;
        }
        else {
            // chunk_remaining > 0: chunk data
            STRLEN remaining = buf_len - read_pos;
            STRLEN to_copy = (STRLEN)c->chunk_remaining;
            if (to_copy > remaining)
                to_copy = remaining;

            if (write_pos != read_pos && to_copy > 0) {
                memmove(buf + write_pos, buf + read_pos, to_copy);
            }
            write_pos += to_copy;
            read_pos += to_copy;
            c->chunk_remaining -= to_copy;
            c->received_cl = write_pos;

            if (c->chunk_remaining > 0) {
                goto need_more;
            }

            remaining = buf_len - read_pos;
            if (remaining < 2) {
                c->chunk_remaining = CHUNK_STATE_NEED_CRLF;
                goto need_more;
            }
            if (buf[read_pos] != '\r' || buf[read_pos+1] != '\n') {
                trace("chunked: missing CRLF after chunk data\n");
                return -1;
            }
            read_pos += 2;
            c->chunk_remaining = CHUNK_STATE_PARSE_SIZE;
        }
    }

need_more:
    if (read_pos > write_pos) {
        if (read_pos < buf_len) {
            STRLEN unparsed = buf_len - read_pos;
            memmove(buf + write_pos, buf + read_pos, unparsed);
            SvCUR_set(c->rbuf, write_pos + unparsed);
        } else {
            SvCUR_set(c->rbuf, write_pos);
        }
    }
    c->received_cl = write_pos;
    return 1;
}

static bool
process_request_headers (struct feer_conn *c, int body_offset)
{
    int err_code;
    const char *err;
    struct feer_req *req = c->req;

    stop_header_timer(c);

    trace("processing headers %d minor_version=%d\n",c->fd,req->minor_version);
    bool body_is_required = 0;
    bool next_req_follows = 0;
    bool got_content_length = 0;
    PERL_UNUSED_VAR(body_is_required); /* only read under DEBUG >= 2 */

    c->is_http11 = (req->minor_version == 1);
    c->is_keepalive = c->cached_keepalive_default && c->is_http11;
    c->expect_continue = 0;
    c->receive_chunked = 0;
    c->reqs++;

    change_receiving_state(c, RECEIVE_BODY);
    c->expected_cl = 0;
    c->received_cl = 0;
    c->body_framed = 0;

    switch (req->method_len) {
    case 3:
        if (likely(memcmp(req->method, "GET", 3) == 0)) {
            next_req_follows = 1;
        } else if (memcmp(req->method, "PUT", 3) == 0) {
            body_is_required = 1;
        } else {
            goto unsupported_method;
        }
        break;
    case 4:
        if (likely(memcmp(req->method, "POST", 4) == 0)) {
            body_is_required = 1;
        } else if (memcmp(req->method, "HEAD", 4) == 0) {
            next_req_follows = 1;
        } else {
            goto unsupported_method;
        }
        break;
    case 5:
        if (memcmp(req->method, "PATCH", 5) == 0) {
            body_is_required = 1;
        } else {
            goto unsupported_method;
        }
        break;
    case 6:
        if (memcmp(req->method, "DELETE", 6) == 0) {
            next_req_follows = 1;
        } else {
            goto unsupported_method;
        }
        break;
    case 7:
        if (memcmp(req->method, "OPTIONS", 7) == 0) {
            next_req_follows = 1;
        } else {
            goto unsupported_method;
        }
        break;
    default:
    unsupported_method:
        err = "Feersum doesn't support that method yet\n";
        err_code = 405;
        goto got_bad_request;
    }

    if (unlikely(req->uri_len > c->cached_max_uri_len)) {
        err_code = 414;
        err = "URI Too Long\n";
        goto got_bad_request;
    }

#if DEBUG >= 2
    if (next_req_follows)
        trace2("next req follows fd=%d, boff=%d\n",c->fd,body_offset);
    if (body_is_required)
        trace2("body is required fd=%d, boff=%d\n",c->fd,body_offset);
#endif

    // req keeps the old rbuf (its header pointers point into it); the body
    // moves to a fresh one
    STRLEN from_len;
    char *from = SvPV(c->rbuf,from_len);
    if (unlikely(body_offset < 0 || (STRLEN)body_offset > from_len)) {
        trouble("invalid body_offset %d > from_len %"Sz_uf" fd=%d\n",
                body_offset, (Sz)from_len, c->fd);
        respond_with_server_error(c, "Internal parser error\n", 500);
        return 0;
    }
    from += body_offset;
    STRLEN need = from_len - body_offset;
    trace("new rbuf for body %d need=%"Sz_uf"\n", c->fd, (Sz)need);
    SV *new_rbuf = newSVpvn(need > 0 ? from : "", need);

    req->buf = c->rbuf;
    c->rbuf = new_rbuf;
    SvCUR_set(req->buf, body_offset);

    UV expected = 0;
    bool got_host = 0;
    bool got_transfer_encoding = 0;
    for (size_t i = 0; i < req->num_headers; i++) {
        struct phr_header *hdr = &req->headers[i];
        // picohttpparser reports obs-fold as a NULL name
        if (unlikely(!hdr->name)) {
            err_code = 400;
            err = "Obsolete header line folding not allowed\n";
            goto got_bad_request;
        }
        if (unlikely(hdr->name_len > MAX_HEADER_NAME_LEN)) {
            err_code = 431;
            err = "Header name too long\n";
            goto got_bad_request;
        }
        if (unlikely(hdr->name_len == 14 &&
             str_case_eq_fixed("content-length", hdr->name, 14)))
        {
            if (c->receive_chunked) {
                err_code = 400;
                err = "Content-Length not allowed with Transfer-Encoding\n";
                goto got_bad_request;
            }
            UV new_expected = 0;
            /* grok_number accepts a leading sign; Content-Length is 1*DIGIT and
             * a "+4" an intermediary rejects is a smuggling desync.  OWS is legal */
            const char *cl_p = hdr->value, *cl_end = hdr->value + hdr->value_len;
            while (cl_p < cl_end && (*cl_p == ' ' || *cl_p == '\t')) cl_p++;
            int g = (cl_p < cl_end && *cl_p >= '0' && *cl_p <= '9')
                  ? grok_number(hdr->value, hdr->value_len, &new_expected) : 0;
            if (likely(g == IS_NUMBER_IN_UV)) {
                if (unlikely(new_expected > (UV)c->cached_max_body_len)) {
                    err_code = 413;
                    err = "Content length exceeds maximum\n";
                    goto got_bad_request;
                }
                if (got_content_length && new_expected != expected) {
                    err_code = 400;
                    err = "Multiple conflicting Content-Length headers\n";
                    goto got_bad_request;
                }
                expected = new_expected;
                got_content_length = 1;
            }
            else {
                err_code = 400;
                err = "Invalid Content-Length\n";
                goto got_bad_request;
            }
        }
        else if (unlikely(hdr->name_len == 10 &&
                str_case_eq_fixed("connection", hdr->name, 10)))
        {
            if (c->is_http11 && c->is_keepalive &&
                hdr->value_len == 5 && str_case_eq_fixed("close", hdr->value, 5))
            {
                c->is_keepalive = 0;
                trace("setting conn %d to close after response\n", c->fd);
            }
            else if (!c->is_http11 && c->cached_keepalive_default &&
                hdr->value_len == 10 && str_case_eq_fixed("keep-alive", hdr->value, 10))
            {
                c->is_keepalive = 1;
                trace("setting conn %d to keep after response\n", c->fd);
            }
            if (next_req_follows && c->receive_chunked && (!c->is_http11 || got_host)) break;
        }
        else if (unlikely(c->is_http11 && hdr->name_len == 6 &&
                str_case_eq_fixed("expect", hdr->name, 6)))
        {
            if (hdr->value_len == 12 &&
                str_case_eq_fixed("100-continue", hdr->value, 12))
            {
                c->expect_continue = 1;
                trace("got Expect: 100-continue on fd=%d\n", c->fd);
            }
            else {
                err_code = 417;
                err = "Expectation Failed\n";
                goto got_bad_request;
            }
        }
        else if (unlikely(hdr->name_len == 17 &&
                str_case_eq_fixed("transfer-encoding", hdr->name, 17)))
        {
            // TE is undefined for HTTP/1.0 (RFC 9112 6.1); rejecting keeps
            // receive_chunked unreachable there
            if (unlikely(!c->is_http11)) {
                err_code = 400;
                err = "Transfer-Encoding not allowed in HTTP/1.0\n";
                goto got_bad_request;
            }

            if (got_transfer_encoding) {
                err_code = 400;
                err = "Multiple Transfer-Encoding headers not allowed\n";
                goto got_bad_request;
            }
            got_transfer_encoding = 1;

            bool is_chunked = (hdr->value_len >= 7 &&
                str_case_eq_fixed("chunked", hdr->value, 7) &&
                (hdr->value_len == 7 ||
                 hdr->value[7] == ';' ||
                 hdr->value[7] == ' ' ||
                 hdr->value[7] == '\t'));

            bool is_identity = (hdr->value_len == 8 &&
                str_case_eq_fixed("identity", hdr->value, 8));

            if (is_chunked) {
                if (got_content_length) {
                    err_code = 400;
                    err = "Content-Length not allowed with Transfer-Encoding\n";
                    goto got_bad_request;
                }
                c->receive_chunked = 1;
                trace("got Transfer-Encoding: chunked on fd=%d\n", c->fd);
            }
            else if (is_identity) {
                trace("got Transfer-Encoding: identity on fd=%d (ignored)\n", c->fd);
            }
            else {
                err_code = 501;
                err = "Unsupported Transfer-Encoding\n";
                goto got_bad_request;
            }
        }
        else if (unlikely(hdr->name_len == 4 &&
                str_case_eq_fixed("host", hdr->name, 4)))
        {
            if (unlikely(got_host)) {
                err_code = 400;
                err = "Duplicate Host header\n";
                goto got_bad_request;
            }
            got_host = 1;
        }
    }

    if (unlikely(c->is_http11 && !got_host)) {
        err_code = 400;
        err = "Host header required for HTTP/1.1\n";
        goto got_bad_request;
    }

    if (c->cached_max_conn_reqs > 0 && c->reqs >= c->cached_max_conn_reqs) {
        c->is_keepalive = 0;
        trace("reached max requests per connection (%d), will close after response\n", c->cached_max_conn_reqs);
    }

    // proxies disagree on TE for body-less methods: reject to keep framing unambiguous
    if (unlikely(c->receive_chunked && next_req_follows)) {
        err_code = 400;
        err = "Transfer-Encoding not allowed on this method\n";
        goto got_bad_request;
    }

    if (likely(next_req_follows) && !got_content_length && !c->receive_chunked) goto got_it_all;
    else if (likely(got_content_length)) goto got_cl;
    else if (unlikely(c->receive_chunked)) goto got_chunked;

    err_code = 411;
    err = "Content-Length or Transfer-Encoding required\n";

got_bad_request:
    respond_with_server_error(c, err, err_code);
    return 0;

got_cl:
    c->expected_cl = (ssize_t)expected;
    c->received_cl = SvCUR(c->rbuf);
    c->body_framed = 1;
    trace("expecting body %d size=%"Ssz_df" have=%"Ssz_df"\n",
        c->fd, (Ssz)c->expected_cl, (Ssz)c->received_cl);
    /* never pre-grow to the peer's declared length (a Perl allocation failure
     * is a hard _exit); try_conn_read grows the rest as bytes arrive */
    {
        STRLEN want = (STRLEN)c->expected_cl + 1;
        if (want > BODY_PREGROW_MAX) want = BODY_PREGROW_MAX;
        SvGROW(c->rbuf, want);
    }

    if (unlikely(c->expected_cl && c->received_cl < c->expected_cl)) {
        send_100_continue(c);
        return 1;
    }
    goto got_it_all;

got_chunked:
    c->chunk_remaining = CHUNK_STATE_PARSE_SIZE;
    c->chunk_count = 0;
    c->trailer_count = 0;
    c->expected_cl = 0;
    c->received_cl = 0;
    c->body_framed = 1;
    change_receiving_state(c, RECEIVE_CHUNKED);
    trace("starting chunked receive on fd=%d, have=%"Sz_uf" bytes\n",
        c->fd, (Sz)SvCUR(c->rbuf));

    send_100_continue(c);

    {
        int ret = try_parse_chunked(c);
        if (ret == 1)
            return 1;
        if (ret == -2) {
            // headers and an oversize chunk in one segment land here, not in
            // try_conn_read; falling through would dispatch a truncated body
            err_code = 413;
            err = "Request body too large\n";
            goto got_bad_request;
        }
        if (ret == -1) {
            err_code = 400;
            err = "Malformed chunked encoding\n";
            goto got_bad_request;
        }
    }

got_it_all:
    sched_request_callback(c);
    return 0;
}

static void
conn_write_ready (struct feer_conn *c)
{
#ifdef FEERSUM_HAS_H2
    if (c->is_h2_stream) {
        h2_try_stream_write(aTHX_ c);
        return;
    }
#endif

    if (c->in_callback) {
        start_write_watcher(c);
        return;
    }

#ifdef FEERSUM_HAS_TLS
    if (c->tls) {
        try_tls_conn_write(feersum_ev_loop, &c->write_ev_io, EV_WRITE);
        return;
    }
#endif

    try_conn_write(feersum_ev_loop, &c->write_ev_io, EV_WRITE);
}

/* H2 dispatch shims for XS CODE/PPCODE blocks (which cannot use #ifdef). */
static int
h2_try_write_chunk (pTHX_ struct feer_conn *c, SV *body)
{
#ifdef FEERSUM_HAS_H2
    if (unlikely(c->is_h2_stream)) {
        feersum_h2_write_chunk(aTHX_ c, body);
        return 1;
    }
#endif
    PERL_UNUSED_VAR(c); PERL_UNUSED_VAR(body);
    return 0;
}

static int
h2_is_stream (struct feer_conn *c)
{
#ifdef FEERSUM_HAS_H2
    if (unlikely(c->is_h2_stream))
        return 1;
#endif
    PERL_UNUSED_VAR(c);
    return 0;
}

INLINE_UNLESS_DEBUG static void
send_100_continue (struct feer_conn *c)
{
    if (likely(!c->expect_continue))
        return;

    static const char continue_response[] = "HTTP/1.1 100 Continue" CRLF CRLF;
#ifdef FEERSUM_HAS_TLS
    if (c->tls) {
        feer_tls_send(c, continue_response, sizeof(continue_response) - 1);
        feer_tls_flush_wbuf(c);
        if (c->tls_wbuf.off > 0)
            start_write_watcher(c);
        c->expect_continue = 0;
        return;
    }
#endif
    size_t cont_len = sizeof(continue_response) - 1;
    ssize_t wr = write(c->fd, continue_response, cont_len);
    // a wholly failed write is fine: the client sends the body anyway after its wait
    if (likely(wr == (ssize_t)cont_len)) {
        trace("sent 100 Continue to fd=%d\n", c->fd);
    }
    else if (wr > 0) {
        // queue the tail; a truncated status line reads as the start of the response
        add_const_to_wbuf(c, continue_response + wr, cont_len - (size_t)wr);
        start_write_watcher(c);
    }
    else if (wr < 0 && errno != EAGAIN && errno != EINTR) {
        trace("100 Continue write error fd=%d: %s\n", c->fd, strerror(errno));
    }
    c->expect_continue = 0;
}

INLINE_UNLESS_DEBUG static void
free_feer_req (struct feer_req *req)
{
    if (unlikely(!req))
        return;

    SvREFCNT_dec(req->buf);
    SvREFCNT_dec(req->path);
    SvREFCNT_dec(req->query);
#ifdef FEERSUM_HAS_H2
    SvREFCNT_dec(req->h2_method_sv);
    SvREFCNT_dec(req->h2_uri_sv);
#endif
    FEER_REQ_FREE(req);
}

INLINE_UNLESS_DEBUG static void
free_request (struct feer_conn *c)
{
    free_feer_req(c->req);
    c->req = NULL;
}

static void
respond_with_server_error (struct feer_conn *c, const char *msg, int err_code)
{
    SV *tmp;
    STRLEN msg_len;

#ifdef FEERSUM_HAS_H2
    if (unlikely(c->is_h2_stream)) {
        feersum_h2_respond_error(c, err_code, msg);
        return;
    }
#endif

    if (unlikely(c->responding != RESPOND_NOT_STARTED)) {
        trouble("Tried to send server error but already responding!\n");
        return;
    }

    msg_len = strlen(msg);
    assert(msg_len < INT_MAX);

    // HEAD keeps the Content-Length but no content; c->req is absent before
    // the request line parses
    const bool no_body = c->req && c->req->method_len == 4
                      && memcmp(c->req->method, "HEAD", 4) == 0;

    /* a 405 must carry Allow (RFC 9110 15.5.6) */
    const char *allow = (err_code == 405)
        ? "Allow: GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS" CRLF : "";

    /* DATE_BUF already ends in CRLF */
    tmp = newSVpvf("HTTP/1.%d %d %s" CRLF
                   "Content-Type: text/plain" CRLF
                   "Connection: close" CRLF
                   "Cache-Control: no-cache, no-store" CRLF
                   "%s%s"
                   "Content-Length: %"Ssz_df"" CRLFx2
                   "%.*s",
              c->is_http11 ? 1 : 0,
              err_code, http_code_to_msg(err_code),
              DATE_BUF, allow,
              (Ssz)msg_len,
              no_body ? 0 : (int)msg_len, msg);
    /* not a mortal: ev callbacks have no FREETMPS scope, so it would leak */
    add_sv_to_wbuf(c, tmp);
    SvREFCNT_dec(tmp);

    stop_read_watcher(c);
    stop_read_timer(c);
    stop_header_timer(c);
    change_responding_state(c, RESPOND_SHUTDOWN);
    change_receiving_state(c, RECEIVE_SHUTDOWN);
    c->is_keepalive = 0;
    conn_write_ready(c);
}


