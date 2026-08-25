/* feersum_h2.c.inc - HTTP/2 via nghttp2.  Each stream gets a pseudo feer_conn
 * sharing the parent's fd; its io watchers never start (I/O goes through the
 * parent's session) and its write_ev_timer is the per-stream write deadline. */

#ifdef FEERSUM_HAS_H2

#ifdef H2_DIAG
# define h2_diag(f_, ...) trace3("H2DIAG " f_, ##__VA_ARGS__)
#else
# define h2_diag(...)
#endif

static inline void
h2_submit_rst(nghttp2_session *session, int32_t stream_id, uint32_t error_code)
{
    struct feer_h2_stream *s = nghttp2_session_get_stream_user_data(session, stream_id);
    if (s) s->rst_by_us = 1;
    int rv = nghttp2_submit_rst_stream(session, NGHTTP2_FLAG_NONE,
                                       stream_id, error_code);
    if (rv != 0)
        trouble("nghttp2_submit_rst_stream stream=%d: %s\n",
                stream_id, nghttp2_strerror(rv));
}

static void h2_submit_error_response(pTHX_ nghttp2_session *session,
                                     struct feer_h2_stream *stream,
                                     int32_t stream_id, int err_code,
                                     const char *msg, bool no_body);

static void h2_tunnel_sv0_read_cb(EV_P_ struct ev_io *w, int revents);
static void h2_tunnel_sv0_write_cb(EV_P_ struct ev_io *w, int revents);
static int  h2_tunnel_write_or_buffer(struct feer_h2_stream *stream, const char *data, size_t len);
static void h2_tunnel_recv_data(pTHX_ struct feer_h2_stream *stream, const uint8_t *data, size_t len);

static inline STRLEN
h2_resp_wbuf_avail(const struct feer_h2_stream *stream)
{
    return stream->resp_wbuf
        ? (SvCUR(stream->resp_wbuf) - stream->resp_wbuf_pos) : 0;
}

/* Distinguishes a peer that stopped reading from an idle SSE/long-poll stream */
static inline int
h2_stream_send_pending(const struct feer_h2_stream *stream)
{
    if (h2_resp_wbuf_avail(stream) > 0)
        return 1;
    return stream->resp_body
        && stream->resp_body_pos < SvCUR(stream->resp_body);
}

static inline UV
h2_status_code_from_sv(pTHX_ SV *message)
{
    if (SvIOK(message)) return SvUV(message);
    UV code = 0;
    STRLEN ml;
    const char *mp = SvPV(message, ml);
    grok_number(mp, ml > 3 ? 3 : ml, &code);
    return code;
}

/* Holds parent->self: session_send callbacks may close streams or free the parent */
static inline void
h2_session_send_and_poll(pTHX_ struct feer_conn *parent)
{
    SvREFCNT_inc_void_NN(parent->self);
    feer_h2_session_send(parent);
    h2_check_stream_poll_cbs(aTHX_ parent);
    SvREFCNT_dec(parent->self);
}

static void
h2_stream_write_timeout(EV_P_ ev_timer *w, int revents)
{
    dTHX;
    struct feer_conn *c = (struct feer_conn *)w->data;
    SvREFCNT_inc_void_NN(c->self);

    /* No RESPOND_SHUTDOWN early-out: the whole-body writer enters it at submit,
     * with DATA possibly still behind the peer's window; a finished stream has
     * been freed (which stops this timer), so a live stream here is stalled. */
    if (unlikely(!(revents & EV_TIMER))) {
        stop_write_timer(c);
        goto h2_wt_cleanup;
    }

    /* Paced poll_cb retry (see conn_write_timeout); the pump re-parks on another decline */
    if (unlikely(c->poll_retry_pending)) {
        c->poll_retry_pending = 0;
        if (likely(ev_is_active(w))) {
            ev_timer_stop(feersum_ev_loop, w);
            SvREFCNT_dec(c->self);
        }
        trace("H2 poll retry pc=%p\n", c);
        conn_write_ready(c);   /* pseudo-conn: dispatches h2_try_stream_write */
        goto h2_wt_cleanup;
    }

    struct feer_h2_stream *stream = H2_STREAM_FROM_PC(c);
    stop_write_timer(c);

    if (stream && stream->parent && stream->parent->h2_session) {
        struct feer_conn *parent = stream->parent;
        trace("H2 stream write timeout stream=%d fd=%d\n",
              stream->stream_id, parent->fd);
        h2_submit_rst(parent->h2_session, stream->stream_id,
                      NGHTTP2_CANCEL);
        h2_session_send_and_poll(aTHX_ parent);
    }
    change_responding_state(c, RESPOND_SHUTDOWN);

h2_wt_cleanup:
    SvREFCNT_dec(c->self);
}

static struct feer_h2_stream *
feer_h2_stream_new(struct feer_conn *parent, int32_t stream_id)
{
    struct feer_h2_stream *stream;
    Newxz(stream, 1, struct feer_h2_stream);
    stream->parent = parent;
    stream->stream_id = stream_id;
    stream->tunnel_sv0 = -1;
    stream->tunnel_sv1 = -1;

    /* busy: feer_server_recycle_idle_conn must not reap a parent with live streams */
    stream->next = parent->h2_streams;
    parent->h2_streams = stream;
    feer_conn_set_busy(parent);

    return stream;
}

static void
feer_h2_stream_free(pTHX_ struct feer_h2_stream *stream)
{
    if (!stream) return;

    free_feer_req(stream->req);
    SvREFCNT_dec(stream->body_buf);
    SvREFCNT_dec((SV*)stream->trailers);
    SvREFCNT_dec(stream->h2_method);
    SvREFCNT_dec(stream->h2_path);
    SvREFCNT_dec(stream->h2_scheme);
    SvREFCNT_dec(stream->h2_authority);
    SvREFCNT_dec(stream->h2_protocol);
    SvREFCNT_dec(stream->resp_body);
    SvREFCNT_dec(stream->resp_wbuf);
    SvREFCNT_dec(stream->resp_message);
    SvREFCNT_dec(stream->resp_headers);

    if (stream->tunnel_established) {
        ev_io_stop(feersum_ev_loop, &stream->tunnel_read_w);
        ev_io_stop(feersum_ev_loop, &stream->tunnel_write_w);
    }
    if (stream->tunnel_sv0 >= 0) close(stream->tunnel_sv0);
    if (stream->tunnel_sv1 >= 0) close(stream->tunnel_sv1);
    SvREFCNT_dec(stream->tunnel_wbuf);

    /* Clearing the back-reference makes every H2 response path on the pseudo-conn a no-op */
    if (stream->pseudo_conn) {
        struct feer_conn *pc = stream->pseudo_conn;
        stream->pseudo_conn = NULL; /* before the decs: they may re-enter */
        pc->fd = -1; /* shared with the parent; DESTROY must not close it */
        pc->read_ev_timer.data = NULL;
        SvREFCNT_inc_void_NN(pc->self); /* stop_write_timer may drop the last ref */
        stop_write_timer(pc);
        SvREFCNT_dec(pc->self); /* guard */
        SvREFCNT_dec(pc->self); /* creation-time ref */
    }

    Safefree(stream);
}

static void
feer_h2_unlink_stream(struct feer_conn *c, struct feer_h2_stream *stream)
{
    struct feer_h2_stream **pp = &c->h2_streams;
    while (*pp) {
        if (*pp == stream) {
            *pp = stream->next;
            stream->next = NULL;
            return;
        }
        pp = &(*pp)->next;
    }
}

static struct feer_conn *
feer_h2_create_pseudo_conn(pTHX_ struct feer_h2_stream *stream)
{
    struct feer_conn *parent = stream->parent;
    struct feer_server *srvr = parent->server;

    /* No max_connections check: the parent was admitted against it and streams
     * are bounded by max_h2_concurrent_streams */

    SV *self = newSV(0);
    SvUPGRADE(self, SVt_PVMG);
    SvGROW(self, sizeof(struct feer_conn));
    SvPOK_only(self);
    SvIOK_on(self);
    SvIV_set(self, parent->fd); /* share parent's fd for fileno() */

    struct feer_conn *pc = (struct feer_conn *)SvPVX(self);
    Zero(pc, 1, struct feer_conn);

    pc->self = self;
    pc->server = parent->server;
    pc->listener = parent->listener;
    SvREFCNT_inc_void_NN(parent->server->self);

    /* Only what H2 paths read through the pseudo-conn; timeouts and size limits
     * are read from the parent, so do not copy them here */
    pc->cached_use_reverse_proxy = parent->cached_use_reverse_proxy;
    pc->cached_write_timeout = parent->cached_write_timeout;
    pc->cached_wbuf_low_water = parent->cached_wbuf_low_water;

    pc->fd = parent->fd;
    memcpy(&pc->sa, &parent->sa, sizeof(struct sockaddr_storage));
    if (parent->proxy_tlvs) {
        pc->proxy_tlvs = parent->proxy_tlvs;
        SvREFCNT_inc_simple_void_NN(pc->proxy_tlvs);
    }
    pc->receiving = RECEIVE_HEADERS;
    pc->is_http11 = 1; /* header generation assumes HTTP/1.1 */
    pc->sendfile_fd = -1;

    /* h2_session/h2_streams stay NULL: the pseudo-conn does not own the session */
    pc->is_h2_stream = 1;

    pc->read_ev_timer.data = (void *)stream;

    ev_init(&pc->write_ev_timer, h2_stream_write_timeout);
    pc->write_ev_timer.data = (void *)pc;

    SV *rv = newRV_inc(pc->self);
    sv_bless(rv, feer_conn_stash);
    SvREFCNT_dec(rv);
    SvREADONLY_on(self);

    srvr->active_conns++;
    srvr->active_h2_streams++;
    stream->pseudo_conn = pc;
    return pc;
}

static ssize_t
h2_send_cb(nghttp2_session *session, const uint8_t *data,
           size_t length, int flags, void *user_data)
{
    struct feer_conn *c = (struct feer_conn *)user_data;
    PERL_UNUSED_VAR(session);
    PERL_UNUSED_VAR(flags);

    /* an earlier callback in this same session_send may have closed the fd */
    if (c->fd < 0)
        return NGHTTP2_ERR_CALLBACK_FAILURE;
    if (unlikely(c->tls_wbuf.off >= FEER_H2_MAX_WBUF))
        return NGHTTP2_ERR_WOULDBLOCK;
    if (feer_tls_send(c, data, length) != 0)
        return NGHTTP2_ERR_CALLBACK_FAILURE;
    return (ssize_t)length;
}

static int
h2_on_begin_headers_cb(nghttp2_session *session,
                       const nghttp2_frame *frame, void *user_data)
{
    struct feer_conn *c = (struct feer_conn *)user_data;

    /* HCAT_HEADERS (trailers) arrives on an existing stream */
    if (frame->hd.type != NGHTTP2_HEADERS ||
        frame->headers.cat != NGHTTP2_HCAT_REQUEST) {
        return 0;
    }

    int32_t stream_id = frame->hd.stream_id;
    trace("H2 begin_headers stream_id=%d fd=%d\n", stream_id, c->fd);

    struct feer_h2_stream *stream = feer_h2_stream_new(c, stream_id);

    FEER_REQ_ALLOC(stream->req);

    nghttp2_session_set_stream_user_data(session, stream_id, stream);

    return 0;
}

static int
h2_on_header_cb(nghttp2_session *session, const nghttp2_frame *frame,
                const uint8_t *name, size_t namelen,
                const uint8_t *value, size_t valuelen,
                uint8_t flags, void *user_data)
{
    dTHX;
    PERL_UNUSED_VAR(flags);
    PERL_UNUSED_VAR(user_data);

    if (frame->hd.type != NGHTTP2_HEADERS ||
        (frame->headers.cat != NGHTTP2_HCAT_REQUEST &&
         frame->headers.cat != NGHTTP2_HCAT_HEADERS)) {
        return 0;
    }

    struct feer_h2_stream *stream = nghttp2_session_get_stream_user_data(
        session, frame->hd.stream_id);
    if (!stream) return 0;

    trace("H2 header stream=%d cat=%d: %.*s: %.*s\n",
        frame->hd.stream_id, frame->headers.cat, (int)namelen, name, (int)valuelen, value);

    if (frame->headers.cat == NGHTTP2_HCAT_HEADERS) {
        /* pseudo-headers in trailers are malformed (RFC 9113 8.1) */
        if (namelen > 0 && name[0] == ':')
            return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
        if (!stream->trailers) {
            stream->trailers = newAV();
        }
        if (av_len(stream->trailers) + 1 >= MAX_TRAILER_HEADERS * 2) {
            return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
        }
        av_push(stream->trailers, newSVpvn((const char *)name, namelen));
        av_push(stream->trailers, newSVpvn((const char *)value, valuelen));
        return 0;
    }

    /* duplicate pseudo-headers are malformed (RFC 9113 8.3.1) */
    if (namelen > 0 && name[0] == ':') {
        if (namelen == 7 && memcmp(name, ":method", 7) == 0) {
            if (stream->h2_method)
                return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
            stream->h2_method = newSVpvn((const char *)value, valuelen);
            stream->req->method = SvPVX(stream->h2_method);
            stream->req->method_len = valuelen;
        } else if (namelen == 5 && memcmp(name, ":path", 5) == 0) {
            if (stream->h2_path)
                return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
            /* an administrative limit, not a protocol error: answer 414 like
             * HTTP/1 instead of resetting */
            if (valuelen > stream->parent->cached_max_uri_len) {
                stream->limit_status = 414;
                return 0;
            }
            stream->h2_path = newSVpvn((const char *)value, valuelen);
            stream->req->uri = SvPVX(stream->h2_path);
            stream->req->uri_len = valuelen;
        } else if (namelen == 7 && memcmp(name, ":scheme", 7) == 0) {
            if (stream->h2_scheme)
                return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
            stream->h2_scheme = newSVpvn((const char *)value, valuelen);
        } else if (namelen == 10 && memcmp(name, ":authority", 10) == 0) {
            if (stream->h2_authority)
                return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
            stream->h2_authority = newSVpvn((const char *)value, valuelen);
        } else if (namelen == 9 && memcmp(name, ":protocol", 9) == 0) {
            if (stream->h2_protocol)
                return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
            stream->h2_protocol = newSVpvn((const char *)value, valuelen);
        } else {
            /* unknown pseudo-header is malformed (RFC 9113 8.3) */
            return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
        }
        return 0;
    }

    /* connection-specific headers are a stream error (RFC 9113 8.2.2) */
    if ((namelen == 10 && memcmp(name, "connection", 10) == 0) ||
        (namelen == 17 && memcmp(name, "transfer-encoding", 17) == 0) ||
        (namelen == 7  && memcmp(name, "upgrade", 7) == 0) ||
        (namelen == 10 && memcmp(name, "keep-alive", 10) == 0) ||
        (namelen == 16 && memcmp(name, "proxy-connection", 16) == 0)) {
        return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
    }

    if (namelen == 14 && memcmp(name, "content-length", 14) == 0) {
        UV cl;
        /* Content-Length is 1*DIGIT (RFC 9110 8.6); grok_number alone also
         * takes a sign and whitespace */
        if (valuelen > 0 && value[0] >= '0' && value[0] <= '9'
            && grok_number((const char *)value, valuelen, &cl) == IS_NUMBER_IN_UV) {
            if (cl > (UV)stream->parent->cached_max_body_len) {
                trace("H2 content-length %"UVuf" exceeds max_body_len\n", cl);
                stream->limit_status = 413;
                return 0;
            }
        } else {
            return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
        }
    }

    /* te other than "trailers" is malformed (RFC 9113 8.2.2) */
    if (namelen == 2 && memcmp(name, "te", 2) == 0) {
        if (valuelen != 8 || memcmp(value, "trailers", 8) != 0)
            return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
    }

    /* administrative limits: answer 431 like HTTP/1 rather than resetting */
    struct feer_req *r = stream->req;
    if (r->num_headers >= MAX_HEADERS) {
        stream->limit_status = 431;
        return 0;
    }

    if (namelen > MAX_HEADER_NAME_LEN) {
        trace("H2 header name too long: %zu\n", namelen);
        stream->limit_status = 431;
        return 0;
    }

    /* nghttp2's name/value pointers die with this callback */
    if (!r->buf) {
        r->buf = newSV_buf(512);
    }

    STRLEN buf_start = SvCUR(r->buf);
    sv_catpvn(r->buf, (const char *)name, namelen);
    sv_catpvn(r->buf, (const char *)value, valuelen);

    /* offsets, not pointers: r->buf may realloc; h2_fixup_header_ptrs resolves them */
    struct phr_header *hdr = &r->headers[r->num_headers];
    hdr->name = (const char *)(uintptr_t)buf_start;
    hdr->name_len = namelen;
    hdr->value = (const char *)(uintptr_t)(buf_start + namelen);
    hdr->value_len = valuelen;
    r->num_headers++;

    return 0;
}

static void
h2_fixup_header_ptrs(struct feer_req *r)
{
    if (!r->buf) return;
    const char *base = SvPVX(r->buf);
    for (size_t i = 0; i < r->num_headers; i++) {
        struct phr_header *hdr = &r->headers[i];
        hdr->name = base + (uintptr_t)hdr->name;
        hdr->value = base + (uintptr_t)hdr->value;
    }
}

static struct feer_conn *
h2_dispatch_stream(pTHX_ struct feer_h2_stream *stream)
{
    h2_fixup_header_ptrs(stream->req);
    stream->req->minor_version = 1;

    struct feer_conn *pc = feer_h2_create_pseudo_conn(aTHX_ stream);
    if (!pc) return NULL;

    pc->req = stream->req;
    stream->req = NULL;
    pc->req->h2_method_sv = stream->h2_method;
    stream->h2_method = NULL;
    pc->req->h2_uri_sv = stream->h2_path;
    stream->h2_path = NULL;
    pc->trailers = stream->trailers;
    stream->trailers = NULL;
    pc->responding = RESPOND_NOT_STARTED;
    /* not RECEIVE_BODY: the body is complete, and psgi.input must return 0 at EOF */
    pc->receiving = RECEIVE_SHUTDOWN;
    return pc;
}

static int
h2_on_frame_recv_cb(nghttp2_session *session,
                    const nghttp2_frame *frame, void *user_data)
{
    struct feer_conn *c = (struct feer_conn *)user_data;
    dTHX;
    PERL_UNUSED_VAR(c); /* only read by trace() */

    switch (frame->hd.type) {
    case NGHTTP2_HEADERS:
    {
        if (frame->headers.cat == NGHTTP2_HCAT_HEADERS) {
            if (frame->hd.flags & NGHTTP2_FLAG_END_STREAM) {
                goto end_stream_dispatch;
            }
            break;
        }

        if (frame->headers.cat != NGHTTP2_HCAT_REQUEST)
            break;

        /* A header-block limit is answered here, before the Extended CONNECT
         * branch can dispatch: a refused request must never reach the app */
        {
            struct feer_h2_stream *lim_stream =
                nghttp2_session_get_stream_user_data(session, frame->hd.stream_id);
            if (unlikely(lim_stream && lim_stream->limit_status)) {
                lim_stream->rst_by_us = 1;   /* our refusal, not a client flood */
                bool lim_head = lim_stream->h2_method
                             && SvCUR(lim_stream->h2_method) == 4
                             && memcmp(SvPVX(lim_stream->h2_method), "HEAD", 4) == 0;
                const char *lim_msg =
                      lim_stream->limit_status == 414 ? "URI Too Long\n"
                    : lim_stream->limit_status == 431 ? "Request header fields too large\n"
                    :                                   "Request body too large\n";
                h2_submit_error_response(aTHX_ session, lim_stream,
                    frame->hd.stream_id, lim_stream->limit_status,
                    lim_msg, lim_head);
                break;
            }
        }

        /* Extended CONNECT (RFC 8441) never carries END_STREAM: dispatch on HEADERS */
        struct feer_h2_stream *hdr_stream = nghttp2_session_get_stream_user_data(
            session, frame->hd.stream_id);
        if (hdr_stream && hdr_stream->h2_method &&
            SvCUR(hdr_stream->h2_method) == 7 &&
            memcmp(SvPVX(hdr_stream->h2_method), "CONNECT", 7) == 0)
        {
            if (hdr_stream->h2_protocol) {
                if (hdr_stream->req && hdr_stream->h2_path && hdr_stream->h2_scheme
                    && hdr_stream->h2_authority) {
                    hdr_stream->is_tunnel = 1;
                    struct feer_conn *pc = h2_dispatch_stream(aTHX_ hdr_stream);
                    if (unlikely(!pc)) {
                        h2_submit_rst(session, frame->hd.stream_id,
                                      NGHTTP2_REFUSED_STREAM);
                        break;
                    }
                    trace("H2 Extended CONNECT stream=%d fd=%d\n",
                          frame->hd.stream_id, c->fd);
                    sched_request_callback(pc);
                } else {
                    /* :path and :scheme are required with :protocol (RFC 8441 4) */
                    h2_submit_rst(session, frame->hd.stream_id,
                                  NGHTTP2_PROTOCOL_ERROR);
                }
            } else {
                /* plain CONNECT (RFC 9113 8.5 forward proxy) is not supported */
                h2_submit_error_response(aTHX_ session, hdr_stream,
                                         frame->hd.stream_id, 501,
                                         "CONNECT not supported\n", FALSE);
            }
            break;
        }

        if (!(frame->hd.flags & NGHTTP2_FLAG_END_STREAM))
            break;

        goto end_stream_dispatch;
    }
    case NGHTTP2_DATA:
    {
        /* tunnel: DATA+END_STREAM is the client's half-close */
        if (frame->hd.flags & NGHTTP2_FLAG_END_STREAM) {
            struct feer_h2_stream *data_stream = nghttp2_session_get_stream_user_data(
                session, frame->hd.stream_id);
            if (data_stream && data_stream->is_tunnel) {
                if (data_stream->tunnel_established) {
                    if (data_stream->tunnel_sv0 >= 0) {
                        shutdown(data_stream->tunnel_sv0, SHUT_WR);
                        data_stream->tunnel_eof_sent = 1;
                    }
                } else {
                    data_stream->tunnel_pending_shutdown = 1;
                }
                break;
            }
        }

        if (!(frame->hd.flags & NGHTTP2_FLAG_END_STREAM))
            break;

    end_stream_dispatch: ;
        struct feer_h2_stream *stream = nghttp2_session_get_stream_user_data(
            session, frame->hd.stream_id);
        if (!stream || !stream->req) break;

        if (unlikely(stream->body_overflow)) break;

        if (unlikely(stream->limit_status)) break;

        /* :method, :path and :scheme are mandatory (RFC 9113 8.3.1) */
        if (unlikely(!stream->h2_method || !stream->h2_path || !stream->h2_scheme)) {
            h2_submit_rst(session, frame->hd.stream_id,
                          NGHTTP2_PROTOCOL_ERROR);
            break;
        }

        struct feer_conn *pc = h2_dispatch_stream(aTHX_ stream);
        if (unlikely(!pc)) {
            h2_submit_rst(session, frame->hd.stream_id,
                          NGHTTP2_REFUSED_STREAM);
            break;
        }

        if (stream->body_buf && SvCUR(stream->body_buf) > 0) {
            pc->rbuf = stream->body_buf;
            stream->body_buf = NULL;
            pc->expected_cl = SvCUR(pc->rbuf);
            pc->received_cl = pc->expected_cl;
        }

        trace("H2 request ready stream=%d method=%.*s path=%.*s fd=%d\n",
              frame->hd.stream_id,
              (int)pc->req->method_len, pc->req->method,
              (int)pc->req->uri_len, pc->req->uri,
              c->fd);

        sched_request_callback(pc);
    }
        break;

    case NGHTTP2_SETTINGS:
        if (frame->hd.flags & NGHTTP2_FLAG_ACK) {
            trace("H2 SETTINGS ACK received fd=%d\n", c->fd);
        }
        break;

    case NGHTTP2_GOAWAY:
        trace("H2 GOAWAY received fd=%d last_stream=%d error=%d\n",
              c->fd, frame->goaway.last_stream_id, frame->goaway.error_code);
        break;

    default:
        break;
    }

    return 0;
}

static int
h2_on_data_chunk_recv_cb(nghttp2_session *session, uint8_t flags,
                         int32_t stream_id, const uint8_t *data,
                         size_t len, void *user_data)
{
    dTHX;
    struct feer_conn *c = (struct feer_conn *)user_data;
    PERL_UNUSED_VAR(flags);

    struct feer_h2_stream *stream = nghttp2_session_get_stream_user_data(
        session, stream_id);
    if (!stream) return 0;

    if (stream->is_tunnel && stream->tunnel_established) {
        h2_tunnel_recv_data(aTHX_ stream, data, len);
        return 0;
    }

    /* already answered from the header block: drop the payload before the
     * overflow path below can RST over the status */
    if (unlikely(stream->limit_status)) return 0;

    if (!stream->body_buf) {
        stream->body_buf = newSV_buf(len + 256);
    }

    /* An error return here does not reject the request (nghttp2 honours only
     * PAUSE and fatal codes): flag it, RST once, skip dispatch */
    if (SvCUR(stream->body_buf) + len > (STRLEN)c->cached_max_body_len) {
        if (!stream->body_overflow) {
            stream->body_overflow = 1;
            trouble("H2 body too large stream=%d (%" UVuf " + %" UVuf " > %" UVuf ")\n",
                    stream_id, (UV)SvCUR(stream->body_buf), (UV)len,
                    (UV)c->cached_max_body_len);
            h2_submit_rst(session, stream_id, NGHTTP2_ENHANCE_YOUR_CALM);
        }
        return 0;
    }

    /* opt-in cap on the sum across the connection's streams */
    if (unlikely(c->server->max_h2_conn_body)) {
        size_t total = len;
        for (struct feer_h2_stream *t = c->h2_streams; t; t = t->next)
            if (t->body_buf) total += SvCUR(t->body_buf);
        if (total > c->server->max_h2_conn_body) {
            if (!stream->body_overflow) {
                stream->body_overflow = 1;
                trouble("H2 connection body over cap stream=%d (%" UVuf " > %" UVuf ")\n",
                        stream_id, (UV)total, (UV)c->server->max_h2_conn_body);
                h2_submit_rst(session, stream_id, NGHTTP2_ENHANCE_YOUR_CALM);
            }
            return 0;
        }
    }

    sv_catpvn(stream->body_buf, (const char *)data, len);

    return 0;
}

static int
h2_on_stream_close_cb(nghttp2_session *session, int32_t stream_id,
                      uint32_t error_code, void *user_data)
{
    struct feer_conn *c = (struct feer_conn *)user_data;
    dTHX;
    trace("H2 stream close stream=%d error=%u fd=%d\n",
          stream_id, error_code, c->fd);
    h2_diag("STREAM-CLOSE stream=%d error=%u fd=%d\n",
            stream_id, error_code, c->fd);

    struct feer_h2_stream *stream = nghttp2_session_get_stream_user_data(
        session, stream_id);

    /* rapid-reset guard; our own RSTs must not trip it */
    if (error_code != 0 && (!stream || !stream->rst_by_us)) {
        ev_tstamp now = ev_now(feersum_ev_loop);
        if (now - c->h2_rst_window_start > FEER_H2_RST_FLOOD_WINDOW) {
            c->h2_rst_window_start = now;
            c->h2_rst_count = 0;
        }
        if (c->h2_rst_count < UINT32_MAX) c->h2_rst_count++;
        if (c->h2_rst_count > FEER_H2_RST_FLOOD_THRESHOLD) {
            trouble("H2 rapid reset flood fd=%d, closing\n", c->fd);
            return NGHTTP2_ERR_CALLBACK_FAILURE;
        }
    }
    if (!stream) return 0;

    /* the app sees EOF on sv[1] */
    if (stream->tunnel_established && stream->tunnel_sv0 >= 0
        && !stream->tunnel_eof_sent) {
        shutdown(stream->tunnel_sv0, SHUT_WR);
    }

    nghttp2_session_set_stream_user_data(session, stream_id, NULL);
    feer_h2_unlink_stream(c, stream);
    feer_h2_stream_free(aTHX_ stream);

    if (c->h2_streams == NULL) {
        if (unlikely(c->server->shutting_down)) {
            /* Not here: this runs inside session_send with the last frames
             * still in tls_wbuf, and closing (fd = -1) would drop them.
             * Whoever empties the buffer closes. */
            c->h2_close_pending = 1;
        } else {
            feer_conn_set_idle(c);
        }
    }

    return 0;
}

static int
h2_on_invalid_frame_recv_cb(nghttp2_session *session,
                            const nghttp2_frame *frame,
                            int lib_error_code, void *user_data)
{
    struct feer_conn *c = (struct feer_conn *)user_data;
    PERL_UNUSED_VAR(session);
    if (c->h2_invalid_frames < 5) {
        c->h2_invalid_frames++;
        trouble("H2 invalid frame type=%d stream=%d fd=%d: %s\n",
                frame->hd.type, frame->hd.stream_id, c->fd,
                nghttp2_strerror(lib_error_code));
    }
    return 0;
}

static void
feer_h2_init_session(struct feer_conn *c)
{
    nghttp2_session_callbacks *callbacks;
    int rv = nghttp2_session_callbacks_new(&callbacks);
    if (rv != 0) {
        trouble("nghttp2_session_callbacks_new failed fd=%d: %s\n",
                c->fd, nghttp2_strerror(rv));
        stop_all_watchers(c);
        safe_close_conn(c, "H2 callbacks alloc failed");
        return;
    }
    nghttp2_session_callbacks_set_send_callback(callbacks, h2_send_cb);
    nghttp2_session_callbacks_set_on_begin_headers_callback(callbacks, h2_on_begin_headers_cb);
    nghttp2_session_callbacks_set_on_header_callback(callbacks, h2_on_header_cb);
    nghttp2_session_callbacks_set_on_frame_recv_callback(callbacks, h2_on_frame_recv_cb);
    nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks, h2_on_data_chunk_recv_cb);
    nghttp2_session_callbacks_set_on_stream_close_callback(callbacks, h2_on_stream_close_cb);
    nghttp2_session_callbacks_set_on_invalid_frame_recv_callback(callbacks, h2_on_invalid_frame_recv_cb);

    rv = nghttp2_session_server_new(&c->h2_session, callbacks, c);
    nghttp2_session_callbacks_del(callbacks);
    if (rv != 0) {
        trouble("nghttp2_session_server_new failed fd=%d: %s\n",
                c->fd, nghttp2_strerror(rv));
        stop_all_watchers(c);
        safe_close_conn(c, "H2 session alloc failed");
        return;
    }

    nghttp2_settings_entry settings[] = {
        { NGHTTP2_SETTINGS_HEADER_TABLE_SIZE, 4096 },
        { NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS, c->server->max_h2_concurrent_streams },
        { NGHTTP2_SETTINGS_MAX_HEADER_LIST_SIZE, FEER_H2_MAX_HEADER_LIST_SIZE },
        { NGHTTP2_SETTINGS_ENABLE_PUSH, 0 },
        { NGHTTP2_SETTINGS_ENABLE_CONNECT_PROTOCOL, 1 },
    };
    rv = nghttp2_submit_settings(c->h2_session, NGHTTP2_FLAG_NONE,
                                 settings, sizeof(settings) / sizeof(settings[0]));
    if (rv != 0) {
        trouble("nghttp2_submit_settings failed fd=%d: %s\n",
                c->fd, nghttp2_strerror(rv));
        nghttp2_session_del(c->h2_session);
        c->h2_session = NULL;
        stop_all_watchers(c);
        safe_close_conn(c, "H2 settings submit failed");
        return;
    }

    /* RECEIVE_BODY keeps the H1 header timeout off this conn */
    change_receiving_state(c, RECEIVE_BODY);
    stop_header_timer(c);

    feer_conn_set_idle(c);

    trace("H2 session initialized fd=%d\n", c->fd);
}

static void
feer_h2_free_session(struct feer_conn *c)
{
    dTHX;

    if (c->h2_session) {
        nghttp2_session_del(c->h2_session);
        c->h2_session = NULL;
    }

    struct feer_h2_stream *stream = c->h2_streams;
    while (stream) {
        struct feer_h2_stream *next = stream->next;
        feer_h2_stream_free(aTHX_ stream);
        stream = next;
    }
    c->h2_streams = NULL;
}

static void
feer_h2_session_recv(struct feer_conn *c, const uint8_t *data, size_t len)
{
    /* Any frame at all, WINDOW_UPDATE included, ends a run of peer silence. */
    c->h2_stall_strikes = 0;

    /* graceful shutdown: GOAWAY before parsing more frames */
    if (unlikely(c->server->shutting_down)) {
        if (!c->h2_goaway_sent) {
            int ga_rv = nghttp2_submit_goaway(c->h2_session, NGHTTP2_FLAG_NONE,
                                  nghttp2_session_get_last_proc_stream_id(c->h2_session),
                                  NGHTTP2_NO_ERROR, NULL, 0);
            if (ga_rv != 0)
                trouble("nghttp2_submit_goaway(graceful) fd=%d: %s\n",
                        c->fd, nghttp2_strerror(ga_rv));
            c->h2_goaway_sent = 1;
        }
    }

    ssize_t rv = nghttp2_session_mem_recv(c->h2_session, data, len);
    if (rv < 0) {
        trouble("nghttp2_session_mem_recv error fd=%d: %s\n",
                c->fd, nghttp2_strerror((int)rv));
        int ga_rv = nghttp2_submit_goaway(c->h2_session, NGHTTP2_FLAG_NONE,
                              nghttp2_session_get_last_proc_stream_id(c->h2_session),
                              NGHTTP2_PROTOCOL_ERROR, NULL, 0);
        if (ga_rv != 0)
            trouble("nghttp2_submit_goaway(error) fd=%d: %s\n",
                    c->fd, nghttp2_strerror(ga_rv));
        feer_h2_session_send(c);
        stop_all_watchers(c);
        safe_close_conn(c, "H2 protocol error");
        return;
    }
    trace("H2 session_recv consumed %zd of %zu bytes fd=%d\n", rv, len, c->fd);
}

static void
feer_h2_session_send(struct feer_conn *c)
{
    if (!c->h2_session || c->fd < 0) return;

    /* session_send callbacks may drop the last ref through stop_all_watchers */
    SvREFCNT_inc_void_NN(c->self);

    h2_diag("ENTER fd=%d want_w=%d want_r=%d\n",
            c->fd, nghttp2_session_want_write(c->h2_session),
            nghttp2_session_want_read(c->h2_session));

    int rv = nghttp2_session_send(c->h2_session);
    if (rv != 0) {
        trouble("nghttp2_session_send error fd=%d: %s\n",
                c->fd, nghttp2_strerror(rv));
        stop_all_watchers(c);
        safe_close_conn(c, "H2 send error");
        goto send_done;
    }

    h2_diag("POST-SEND fd=%d rv=%d want_w=%d want_r=%d\n",
            c->fd, rv, nghttp2_session_want_write(c->h2_session),
            nghttp2_session_want_read(c->h2_session));

#ifdef FEERSUM_HAS_TLS
    if (c->tls_wbuf.off > 0) {
        int flush_ret = feer_tls_flush_wbuf(c);
        h2_diag("FLUSH fd=%d ret=%d remaining=%zu\n",
                c->fd, flush_ret, c->tls_wbuf.off);
        if (flush_ret == -2) {
            trouble("TLS flush error in H2 session_send fd=%d\n", c->fd);
            stop_all_watchers(c);
            safe_close_conn(c, "TLS flush error");
            goto send_done;
        }
        if (c->tls_wbuf.off > 0) {
            h2_diag("START-WRITE-WATCHER fd=%d remaining=%zu\n",
                    c->fd, c->tls_wbuf.off);
            start_write_watcher(c);
            /* the watcher alone bounds nothing while the peer is not reading */
            ensure_write_timer(c);
        }
    }
#endif

    /* deferred close from h2_on_stream_close_cb; try_tls_conn_write does it otherwise */
    if (unlikely(c->h2_close_pending) && c->tls_wbuf.off == 0) {
        c->h2_close_pending = 0;
        /* linger: the response is only in the kernel, the client's WINDOW_UPDATE still unread */
        c->want_linger_close = 1;
        feer_shutdown_conn(c, "last H2 stream closed during shutdown");
    }

send_done:
    SvREFCNT_dec(c->self);
}

static ssize_t
h2_body_read_cb(nghttp2_session *session, int32_t stream_id,
                uint8_t *buf, size_t length, uint32_t *data_flags,
                nghttp2_data_source *source, void *user_data)
{
    PERL_UNUSED_VAR(session);
    PERL_UNUSED_VAR(stream_id);
    PERL_UNUSED_VAR(user_data);

    struct feer_h2_stream *stream = (struct feer_h2_stream *)source->ptr;
    if (!stream || !stream->resp_body)
        return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;

    STRLEN body_len;
    const char *body = SvPV_nomg(stream->resp_body, body_len);
    size_t remaining = body_len - stream->resp_body_pos;
    size_t to_copy = remaining < length ? remaining : length;

    if (to_copy > 0) {
        memcpy(buf, body + stream->resp_body_pos, to_copy);
        /* progress refreshes the deadline; the ev_is_active guard matters, as
         * restart_write_timer would also arm one on an exempt tunnel stream */
        if (stream->pseudo_conn
            && ev_is_active(&stream->pseudo_conn->write_ev_timer))
            restart_write_timer(stream->pseudo_conn);
    }
    stream->resp_body_pos += to_copy;

    if (stream->resp_body_pos >= body_len)
        *data_flags |= NGHTTP2_DATA_FLAG_EOF;

    return (ssize_t)to_copy;
}

/* Same shape as respond_with_server_error gives HTTP/1 */
static void
h2_submit_error_response(pTHX_ nghttp2_session *session,
                         struct feer_h2_stream *stream, int32_t stream_id,
                         int err_code, const char *msg, bool no_body)
{
    char status_buf[12];
    char cl_buf[24];
    nghttp2_nv nva[5];
    int n = 0;

    /* no stream, nowhere to park the body: advertise zero, not a length we will not send */
    size_t body_len = (stream && msg) ? strlen(msg) : 0;

    int slen = my_snprintf(status_buf, sizeof(status_buf), "%d", err_code);
    nva[n].name  = (uint8_t *)":status";  nva[n].namelen  = 7;
    nva[n].value = (uint8_t *)status_buf; nva[n].valuelen = slen;
    nva[n].flags = NGHTTP2_NV_FLAG_NONE;  n++;

    nva[n].name  = (uint8_t *)"content-type"; nva[n].namelen  = 12;
    nva[n].value = (uint8_t *)"text/plain";   nva[n].valuelen = 10;
    nva[n].flags = NGHTTP2_NV_FLAG_NONE;      n++;

    nva[n].name  = (uint8_t *)"cache-control";      nva[n].namelen  = 13;
    nva[n].value = (uint8_t *)"no-cache, no-store"; nva[n].valuelen = 18;
    nva[n].flags = NGHTTP2_NV_FLAG_NONE;            n++;

    nva[n].name  = (uint8_t *)"date";           nva[n].namelen  = 4;
    nva[n].value = (uint8_t *)(DATE_BUF + 6);   nva[n].valuelen = DATE_VALUE_LENGTH;
    nva[n].flags = NGHTTP2_NV_FLAG_NONE;        n++;

    int cl_len = my_snprintf(cl_buf, sizeof(cl_buf), "%"UVuf, (UV)body_len);
    nva[n].name  = (uint8_t *)"content-length"; nva[n].namelen  = 14;
    nva[n].value = (uint8_t *)cl_buf;           nva[n].valuelen = cl_len;
    nva[n].flags = NGHTTP2_NV_FLAG_NONE;        n++;

    /* HEAD keeps the length a GET would send, carries no body (RFC 9110 9.3.2) */
    nghttp2_data_provider data_prd;
    nghttp2_data_provider *prd = NULL;
    if (body_len && !no_body) {
        SvREFCNT_dec(stream->resp_body);
        stream->resp_body = newSVpvn(msg, body_len);
        stream->resp_body_pos = 0;
        data_prd.source.ptr = stream;
        data_prd.read_callback = h2_body_read_cb;
        prd = &data_prd;
    }

    int rv = nghttp2_submit_response(session, stream_id, nva, n, prd);
    if (rv != 0) {
        trouble("H2 error response submit failed stream=%d: %s\n",
                stream_id, nghttp2_strerror(rv));
        h2_submit_rst(session, stream_id, NGHTTP2_INTERNAL_ERROR);
    }
}

static ssize_t
h2_streaming_read_cb(nghttp2_session *session, int32_t stream_id,
                     uint8_t *buf, size_t length, uint32_t *data_flags,
                     nghttp2_data_source *source, void *user_data)
{
    PERL_UNUSED_VAR(session);
    PERL_UNUSED_VAR(stream_id);
    PERL_UNUSED_VAR(user_data);

    struct feer_h2_stream *stream = (struct feer_h2_stream *)source->ptr;
    if (!stream)
        return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;

    STRLEN total = stream->resp_wbuf ? SvCUR(stream->resp_wbuf) : 0;
    STRLEN avail = total - stream->resp_wbuf_pos;

    if (avail == 0) {
        if (stream->resp_eof) {
            *data_flags |= NGHTTP2_DATA_FLAG_EOF;
            return 0;
        }
        return NGHTTP2_ERR_DEFERRED; /* until nghttp2_session_resume_data */
    }

    const char *ptr = SvPVX(stream->resp_wbuf) + stream->resp_wbuf_pos;
    size_t to_copy = avail < length ? avail : length;

    memcpy(buf, ptr, to_copy);
    stream->resp_wbuf_pos += to_copy;
    /* refresh only, as in h2_body_read_cb: a tunnel stream must not acquire a deadline */
    if (to_copy > 0 && stream->pseudo_conn
        && ev_is_active(&stream->pseudo_conn->write_ev_timer))
        restart_write_timer(stream->pseudo_conn);

    if (stream->resp_wbuf_pos >= total) {
        SvCUR_set(stream->resp_wbuf, 0);
        stream->resp_wbuf_pos = 0;
        if (stream->resp_eof)
            *data_flags |= NGHTTP2_DATA_FLAG_EOF;
    }

    return (ssize_t)to_copy;
}

/* connection-specific headers (RFC 9113 8.2.2) */
static inline bool
h2_skip_header(const char *hp, STRLEN hlen)
{
    switch (hlen) {
    case 2:  return str_case_eq_fixed("te", hp, 2);
    case 7:  return str_case_eq_fixed("upgrade", hp, 7);
    case 10: return str_case_eq_fixed("connection", hp, 10) ||
                    str_case_eq_fixed("keep-alive", hp, 10);
    case 16: return str_case_eq_fixed("proxy-connection", hp, 16);
    case 17: return str_case_eq_fixed("transfer-encoding", hp, 17);
    default: return false;
    }
}

#define h2_is_content_length(hp, hlen) \
    ((hlen) == 14 && str_case_eq_fixed("content-length", (hp), 14))

/* body_len -1 keeps the app's Content-Length (streaming, or a 304 carrying the
 * would-be length); otherwise it replaces it.  status_buf is char[12], cl_buf
 * char[24]; caller Safefrees nva and *out_lc_buf after the submit. */
static nghttp2_nv *
h2_build_nva(pTHX_ SV *message, AV *headers, char *status_buf, int *out_len,
             char **out_lc_buf, IV body_len, char *cl_buf)
{
    UV code = 0;
    if (SvIOK(message))
        code = SvUV(message);
    else {
        STRLEN mlen;
        const char *mp = SvPV(message, mlen);
        const int numtype = grok_number(mp, mlen > 3 ? 3 : mlen, &code);
        if (numtype != IS_NUMBER_IN_UV) {
            trouble("h2_build_nva: invalid status '%.*s', using 500\n",
                    (int)mlen, mp);
            code = 500;
        }
    }
    if (code < 100 || code > 599) {
        trouble("h2_build_nva: status %"UVuf" out of range, using 500\n", code);
        code = 500;
    }

    /* 1xx/204 must not carry Content-Length (RFC 9110 8.6) and 205 sends no DATA */
    const bool drop_app_cl = (code < 200 || code == 204 || code == 205);
    const bool emit_own_cl = (!drop_app_cl && body_len >= 0);
    const bool skip_app_cl = (drop_app_cl || emit_own_cl);

    I32 avl = av_len(headers);
    /* :status + headers + date + our own content-length */
    int nva_max = 1 + (avl + 1) / 2 + 2;
    SV **ary = AvARRAY(headers);

    /* size lc_buf exactly: nva points into it, so it must never Renew */
    STRLEN lc_needed = 0;
    for (I32 i = 0; i + 1 <= avl; i += 2) {
        SV *hdr = ary[i];
        SV *val = ary[i + 1];
        if (!hdr || !SvOK(hdr) || !val || !SvOK(val)) continue;

        STRLEN hlen;
        const char *hp = SvPV_nomg(hdr, hlen);

        if (h2_skip_header(hp, hlen))
            continue;
        if (skip_app_cl && h2_is_content_length(hp, hlen))
            continue;

        lc_needed += hlen;
    }

    nghttp2_nv *nva;
    Newx(nva, nva_max, nghttp2_nv);

    char *lc_buf;
    Newx(lc_buf, lc_needed ? lc_needed : 1, char);

    int slen = my_snprintf(status_buf, 12, "%d", (int)code);
    nva[0].name = (uint8_t *)":status";
    nva[0].namelen = 7;
    nva[0].value = (uint8_t *)status_buf;
    nva[0].valuelen = slen;
    nva[0].flags = NGHTTP2_NV_FLAG_NONE;

    int nva_idx = 1;
    STRLEN lc_used = 0;
    for (I32 i = 0; i + 1 <= avl; i += 2) {
        SV *hdr = ary[i];
        SV *val = ary[i + 1];
        if (!hdr || !SvOK(hdr) || !val || !SvOK(val)) continue;

        STRLEN hlen, vlen;
        const char *hp = SvPV_nomg(hdr, hlen);
        const char *vp = SvPV_nomg(val, vlen);

        if (h2_skip_header(hp, hlen))
            continue;
        if (skip_app_cl && h2_is_content_length(hp, hlen))
            continue;

        /* downgrade as on H1; it never lengthens, so the pre-scan bound holds */
        if (unlikely(SvUTF8(hdr))) {
            SV *t = feer_bytes_mortal(hp, hlen);
            hp = SvPVX(t); hlen = SvCUR(t);
        }
        if (unlikely(SvUTF8(val))) {
            SV *t = feer_bytes_mortal(vp, vlen);
            vp = SvPVX(t); vlen = SvCUR(t);
        }

        char *dst = lc_buf + lc_used;
        for (STRLEN j = 0; j < hlen; j++)
            dst[j] = ascii_lower[(unsigned char)hp[j]];

        nva[nva_idx].name = (uint8_t *)dst;
        nva[nva_idx].namelen = hlen;
        nva[nva_idx].value = (uint8_t *)vp;
        nva[nva_idx].valuelen = vlen;
        nva[nva_idx].flags = NGHTTP2_NV_FLAG_NONE;
        nva_idx++;
        lc_used += hlen;
    }

    if (emit_own_cl) {
        int cl_len = my_snprintf(cl_buf, 24, "%"IVdf, body_len);
        nva[nva_idx].name = (uint8_t *)"content-length";
        nva[nva_idx].namelen = 14;
        nva[nva_idx].value = (uint8_t *)cl_buf;
        nva[nva_idx].valuelen = cl_len;
        nva[nva_idx].flags = NGHTTP2_NV_FLAG_NONE;
        nva_idx++;
    }

    nva[nva_idx].name = (uint8_t *)"date";
    nva[nva_idx].namelen = 4;
    nva[nva_idx].value = (uint8_t *)(DATE_BUF + 6);  /* skip "Date: " prefix */
    nva[nva_idx].valuelen = DATE_VALUE_LENGTH;
    nva[nva_idx].flags = NGHTTP2_NV_FLAG_NONE;
    nva_idx++;

    *out_lc_buf = lc_buf;
    *out_len = nva_idx;
    return nva;
}

static void
feersum_h2_start_response(pTHX_ struct feer_conn *c, SV *message, AV *headers, int streaming)
{
    if (unlikely(c->responding != RESPOND_NOT_STARTED))
        croak("already responding?!");

    struct feer_h2_stream *stream = H2_STREAM_FROM_PC(c);
    if (!stream || !stream->parent || !stream->parent->h2_session) {
        /* orphaned by a client RST; SHUTDOWN lets DESTROY release the active_conns slot */
        trace("H2 start_response: orphaned pseudo_conn fd=%d\n", c->fd);
        change_responding_state(c, RESPOND_SHUTDOWN);
        return;
    }
    struct feer_conn *parent = stream->parent;

    if (streaming) {
        char status_buf[12];
        char cl_buf[24];
        char *lc_buf = NULL;
        int nva_len;
        nghttp2_nv *nva = h2_build_nva(aTHX_ message, headers, status_buf,
                                       &nva_len, &lc_buf, -1, cl_buf);

        bool no_body = c->no_resp_body
                    || http_status_no_body(h2_status_code_from_sv(aTHX_ message));

        nghttp2_data_provider data_prd;
        nghttp2_data_provider *data_prd_ptr = NULL;
        if (!no_body) {
            change_responding_state(c, RESPOND_STREAMING);
            data_prd.source.ptr = stream;
            data_prd.read_callback = h2_streaming_read_cb;
            data_prd_ptr = &data_prd;
        } else {
            change_responding_state(c, RESPOND_SHUTDOWN);
            /* a late $w->write must return 0 silently, as on H1, not croak */
            c->no_resp_body = 1;
        }

        int rv = nghttp2_submit_response(parent->h2_session, stream->stream_id,
                                         nva, nva_len, data_prd_ptr);
        Safefree(nva);
        Safefree(lc_buf);
        if (rv != 0) {
            trouble("nghttp2_submit_response error stream=%d: %s\n",
                    stream->stream_id, nghttp2_strerror(rv));
            h2_submit_rst(parent->h2_session, stream->stream_id,
                          NGHTTP2_INTERNAL_ERROR);
            change_responding_state(c, RESPOND_SHUTDOWN);
        }

        h2_session_send_and_poll(aTHX_ parent);
    } else {
        /* submitted from write_whole_body, once the body is known */
        change_responding_state(c, RESPOND_NORMAL);
        stream->resp_message = newSVsv(message);
        stream->resp_headers = newRV_inc((SV *)headers);
    }
}

static size_t
feersum_h2_write_whole_body(pTHX_ struct feer_conn *c, SV *body_sv)
{
    struct feer_h2_stream *stream = H2_STREAM_FROM_PC(c);
    if (!stream || !stream->parent || !stream->parent->h2_session) {
        if (c->responding != RESPOND_SHUTDOWN)
            change_responding_state(c, RESPOND_SHUTDOWN);
        return 0;
    }

    struct feer_conn *parent = stream->parent;

    SV *msg = stream->resp_message;
    AV *hdrs = NULL;
    if (stream->resp_headers && SvROK(stream->resp_headers))
        hdrs = (AV *)SvRV(stream->resp_headers);

    if (!msg || !hdrs) {
        trouble("H2 write_whole_body: no saved message/headers fd=%d\n", c->fd);
        h2_submit_rst(parent->h2_session, stream->stream_id,
                      NGHTTP2_INTERNAL_ERROR);
        SvREFCNT_inc_void_NN(parent->self);
        feer_h2_session_send(parent);
        SvREFCNT_dec(parent->self);
        change_responding_state(c, RESPOND_SHUTDOWN);
        return 0;
    }

    STRLEN body_len;
    bool status_no_body = http_status_no_body(h2_status_code_from_sv(aTHX_ msg));
    /* HEAD advertises the GET length (RFC 9113 8.1.1) but sends no DATA */
    bool head_only = c->no_resp_body && !status_no_body;
    bool no_body = status_no_body || head_only;
    if (unlikely(head_only)) {
        const char *bp = SvPV(body_sv, body_len);
        /* the length the downgraded GET body would have */
        if (unlikely(SvUTF8(body_sv)))
            body_len = SvCUR(feer_bytes_mortal(bp, body_len));
    } else if (unlikely(status_no_body)) {
        body_len = 0;
    } else {
        stream->resp_body = newSVsv(body_sv);
        /* private copy: downgrade in place, as H1's add_sv_to_wbuf does */
        if (unlikely(SvUTF8(stream->resp_body)))
            (void)sv_utf8_downgrade(stream->resp_body, TRUE);
        (void)SvPV(stream->resp_body, body_len);
    }
    stream->resp_body_pos = 0;

    char status_buf[12];
    char cl_buf[24];
    char *lc_buf = NULL;
    int nva_len;
    nghttp2_nv *nva = h2_build_nva(aTHX_ msg, hdrs, status_buf, &nva_len,
                                   &lc_buf, status_no_body ? -1 : (IV)body_len,
                                   cl_buf);

    nghttp2_data_provider data_prd;
    data_prd.source.ptr = stream;
    data_prd.read_callback = h2_body_read_cb;

    h2_diag("SUBMIT stream=%d body=%zu fd=%d\n",
            stream->stream_id, body_len, parent->fd);

    /* resp_body is unset in both no_body cases */
    int submit_rv = nghttp2_submit_response(parent->h2_session, stream->stream_id,
                                             nva, nva_len,
                                             (!no_body && body_len > 0) ? &data_prd : NULL);
    Safefree(nva);
    Safefree(lc_buf);
    if (submit_rv != 0) {
        trouble("nghttp2_submit_response error stream=%d: %s\n",
                stream->stream_id, nghttp2_strerror(submit_rv));
        h2_submit_rst(parent->h2_session, stream->stream_id,
                      NGHTTP2_INTERNAL_ERROR);
    }

    h2_diag("SUBMIT-RV stream=%d rv=%d\n", stream->stream_id, submit_rv);

    SvREFCNT_dec(stream->resp_message);
    stream->resp_message = NULL;
    SvREFCNT_dec(stream->resp_headers);
    stream->resp_headers = NULL;

    {
        int32_t sid = stream->stream_id;
        PERL_UNUSED_VAR(sid); /* only consumed by h2_diag() */
        h2_session_send_and_poll(aTHX_ parent);
        h2_diag("DONE stream=%d\n", sid);
    }
    change_responding_state(c, RESPOND_SHUTDOWN);
    /* Still live after the send: the tail sits behind the peer's window and
     * needs a deadline.  Re-fetch: a completed send has freed `stream`. */
    if (unlikely(H2_STREAM_FROM_PC(c) != NULL))
        ensure_write_timer(c);
    return body_len;
}

static void
h2_resp_wbuf_append(struct feer_h2_stream *stream, const char *ptr, STRLEN len)
{
    dTHX;
    if (!stream->resp_wbuf) {
        stream->resp_wbuf = newSV_buf(len + 256);
    } else if (stream->resp_wbuf_pos > 0) {
        STRLEN remain = SvCUR(stream->resp_wbuf) - stream->resp_wbuf_pos;
        if (remain > 0)
            memmove(SvPVX(stream->resp_wbuf),
                    SvPVX(stream->resp_wbuf) + stream->resp_wbuf_pos, remain);
        SvCUR_set(stream->resp_wbuf, remain);
        stream->resp_wbuf_pos = 0;
    }
    sv_catpvn(stream->resp_wbuf, ptr, len);
}

static void
feersum_h2_write_chunk(pTHX_ struct feer_conn *c, SV *body)
{
    struct feer_h2_stream *stream = H2_STREAM_FROM_PC(c);
    if (!stream || !stream->parent || !stream->parent->h2_session) {
        /* orphaned: SHUTDOWN makes the next write() croak as on H1, so the app
         * drops the writer and the active_conns slot is released */
        trace("H2 write_chunk: orphaned pseudo_conn fd=%d\n", c->fd);
        change_responding_state(c, RESPOND_SHUTDOWN);
        return;
    }

    STRLEN len;
    const char *ptr = SvPV(body, len);
    stream->writes_seen++;   /* before the empty return, on purpose */
    if (len == 0) return;

    /* downgrade as H1's add_sv_to_wbuf does */
    if (unlikely(SvUTF8(body))) {
        SV *t = feer_bytes_mortal(ptr, len);
        ptr = SvPVX(t); len = SvCUR(t);
    }
    h2_resp_wbuf_append(stream, ptr, len);

    nghttp2_session_resume_data(stream->parent->h2_session, stream->stream_id);

    /* in_callback: defer, or session_send drains resp_wbuf before the pump sees progress */
    if (!c->in_callback)
        h2_session_send_and_poll(aTHX_ stream->parent);
    restart_write_timer(c);
}

/* Streaming write pump: the H2 twin of try_conn_write */
static void
h2_try_stream_write(pTHX_ struct feer_conn *c)
{
    struct feer_h2_stream *stream = H2_STREAM_FROM_PC(c);
    if (!stream || !stream->parent) {
        /* orphaned, as in feersum_h2_write_chunk */
        change_responding_state(c, RESPOND_SHUTDOWN);
        return;
    }
    if (c->responding != RESPOND_STREAMING || !c->poll_write_cb) return;

    SvREFCNT_inc_void_NN(c->self);  /* poll_cb may close and drop the last ref */

    int iters = 0;
    int budget_spent = 0;
    int declined = 0;
    while (c->responding == RESPOND_STREAMING && c->poll_write_cb) {
        if (iters++ >= 64) { budget_spent = 1; break; }
        STRLEN avail = h2_resp_wbuf_avail(stream);
        if (avail > c->cached_wbuf_low_water) break;

        STRLEN before = avail;
        unsigned int writes_before = stream->writes_seen;
        /* IO-handle bodies: one getline per iteration, paced like a poll_cb */
        if (c->poll_write_cb_is_io_handle) {
            if (!pump_h2_io_step(aTHX_ c)) break;
        }
        else
            call_poll_callback(c, 1);

        /* the callback may have closed it */
        stream = H2_STREAM_FROM_PC(c);
        if (!stream || !stream->parent) break;

        STRLEN after = h2_resp_wbuf_avail(stream);
        /* an empty write() is not a decline; only a silent app is */
        if (after == before && stream->writes_seen == writes_before) {
            declined = 1;
            break;
        }
        /* Empty writes can spin this pump forever, so deadline them here, not
         * at start_response: a stream that has not written yet may be an
         * SSE/long-poll app waiting for its event, and must not be reaped */
        if (unlikely(after == before && !stream->is_tunnel))
            ensure_write_timer(c);

        /* flush the deferred writes; with no write watcher to yield to, the
         * loop runs until low_water, flow control, or the app stops */
        struct feer_conn *parent = stream->parent;
        SvREFCNT_inc_void_NN(parent->self);
        feer_h2_session_send(parent);
        SvREFCNT_dec(parent->self);

        /* session_send may have freed it */
        stream = H2_STREAM_FROM_PC(c);
        if (!stream || !stream->parent) break;
    }

    /* After a budget yield nothing re-invites the poll_cb (a pseudo-conn has no
     * watcher and the peer may send nothing), so re-arm the parent's write
     * watcher, whose callback runs the refill */
    if (unlikely(budget_spent)) {
        struct feer_h2_stream *st = H2_STREAM_FROM_PC(c);
        if (st && st->parent && c->responding == RESPOND_STREAMING
            && c->poll_write_cb) {
            st->parent->h2_pump_pending = 1;
            start_write_watcher(st->parent);
        }
    }
    /* Declined: paced re-invitation through h2_stream_write_timeout, but only
     * with an empty buffer; a sub-low-water tail keeps its write deadline and
     * the peer's WINDOW_UPDATEs re-invite it */
    else if (unlikely(declined) && c->responding == RESPOND_STREAMING
             && c->poll_write_cb) {
        struct feer_h2_stream *st = H2_STREAM_FROM_PC(c);
        if (st && st->parent && h2_resp_wbuf_avail(st) == 0)
            feersum_poll_retry_park(c);
    }

    SvREFCNT_dec(c->self);
}

/* Refill starved poll_cbs; runs after every session_send, since a WINDOW_UPDATE
 * can drain resp_wbuf below low_water */
static void
h2_check_stream_poll_cbs(pTHX_ struct feer_conn *c)
{
    /* ids, not pointers: h2_try_stream_write can free any sibling stream */
    int32_t candidates[FEER_H2_MAX_CONCURRENT_STREAMS];
    int n = 0;
    struct feer_h2_stream *stream;

    for (stream = c->h2_streams; stream && n < FEER_H2_MAX_CONCURRENT_STREAMS;
         stream = stream->next) {
        /* Resume a tunnel relay paused at the resp_wbuf cap.  Never once
         * resp_eof is set: sv[0] is at EOF then, and a level-triggered watcher
         * re-armed on it busy-spins (read 0 -> stop -> send -> here -> re-arm) */
        if (unlikely(stream->tunnel_established) && stream->tunnel_sv0 >= 0
            && !stream->resp_eof
            && !ev_is_active(&stream->tunnel_read_w)
            && h2_resp_wbuf_avail(stream) <= FEER_TUNNEL_MAX_WBUF)
            ev_io_start(feersum_ev_loop, &stream->tunnel_read_w);

        struct feer_conn *pc = stream->pseudo_conn;
        if (!pc || pc->responding != RESPOND_STREAMING || !pc->poll_write_cb)
            continue;

        STRLEN buffered = h2_resp_wbuf_avail(stream);
        if (buffered == 0 || (pc->cached_wbuf_low_water > 0
                              && buffered <= pc->cached_wbuf_low_water)) {
            candidates[n++] = stream->stream_id;
        }
    }

    for (int i = 0; i < n; i++) {
        /* by id: stream_user_data is cleared before a stream is freed */
        stream = c->h2_session
            ? nghttp2_session_get_stream_user_data(c->h2_session, candidates[i])
            : NULL;
        if (!stream) continue;

        struct feer_conn *pc = stream->pseudo_conn;
        if (!pc || pc->responding != RESPOND_STREAMING || !pc->poll_write_cb)
            continue;

        h2_try_stream_write(aTHX_ pc);
    }
}

static void
h2_tunnel_sv0_read_cb(EV_P_ struct ev_io *w, int revents)
{
    dTHX;
    PERL_UNUSED_VAR(revents);
    struct feer_h2_stream *stream = (struct feer_h2_stream *)w->data;
    if (!stream || !stream->parent || !stream->parent->h2_session) return;

    char buf[FEER_TUNNEL_BUFSZ];
    ssize_t nread = read(stream->tunnel_sv0, buf, sizeof(buf));

    if (nread < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
            return;
        /* sv[1] closed with unread bytes reads ECONNRESET, not 0: EOF, not an error */
        if (errno != ECONNRESET && errno != EPIPE) {
            ev_io_stop(EV_A, &stream->tunnel_read_w);
            ev_io_stop(EV_A, &stream->tunnel_write_w);
            h2_submit_rst(stream->parent->h2_session, stream->stream_id,
                          NGHTTP2_CONNECT_ERROR);
            h2_session_send_and_poll(aTHX_ stream->parent);
            return;
        }
        nread = 0;
    }

    if (nread == 0) {
        ev_io_stop(EV_A, &stream->tunnel_read_w);
        if (!stream->tunnel_wbuf ||
            SvCUR(stream->tunnel_wbuf) <= stream->tunnel_wbuf_pos)
            ev_io_stop(EV_A, &stream->tunnel_write_w);
        stream->resp_eof = 1;
        nghttp2_session_resume_data(stream->parent->h2_session, stream->stream_id);
        h2_session_send_and_poll(aTHX_ stream->parent);
        return;
    }
    /* psgix.io apps write an HTTP/1.1 101 response first; it must not reach the H2 wire */
    if (unlikely(stream->tunnel_swallow_response)) {
        if (!stream->resp_wbuf) {
            stream->resp_wbuf = newSV_buf(nread + 256);
        }
        sv_catpvn(stream->resp_wbuf, buf, nread);

        const char *p = SvPVX(stream->resp_wbuf);
        STRLEN len = SvCUR(stream->resp_wbuf);

        /* Relay on the first byte diverging from "HTTP/1.x NNN": waiting for a
         * minimum length held a 2-byte websocket PING forever */
        STRLEN n = len < 12 ? len : 12;
        int diverged = 0;
        for (STRLEN k = 0; k < n; k++) {
            char ch = p[k];
            if (k < 7)       diverged = (ch != "HTTP/1."[k]);
            else if (k == 8) diverged = (ch != ' ');
            else             diverged = !(ch >= '0' && ch <= '9');
            if (diverged) break;
        }
        if (diverged) {
            stream->tunnel_swallow_response = 0;
            stream->resp_wbuf_pos = 0;
            /* this read is already appended above */
            goto relay;
        }

        if (len >= 4) {
            STRLEN i;
            for (i = 0; i <= len - 4; i++) {
                if (p[i] == '\r' && p[i+1] == '\n' &&
                    p[i+2] == '\r' && p[i+3] == '\n') {
                    STRLEN after = len - (i + 4);
                    stream->tunnel_swallow_response = 0;
                    if (after > 0) {
                        memmove(SvPVX(stream->resp_wbuf),
                                p + i + 4, after);
                        SvCUR_set(stream->resp_wbuf, after);
                        stream->resp_wbuf_pos = 0;
                        goto relay;
                    }
                    SvCUR_set(stream->resp_wbuf, 0);
                    stream->resp_wbuf_pos = 0;
                    return;
                }
            }
        }

        /* 8KB without a header terminator: relay rather than swallow the app's bytes */
        if (SvCUR(stream->resp_wbuf) > 8192) {
            stream->tunnel_swallow_response = 0;
            stream->resp_wbuf_pos = 0;
            goto relay;
        }
        return;
    }

    h2_resp_wbuf_append(stream, buf, nread);

    /* backpressure: an established tunnel is exempt from timeouts, so cap
     * resp_wbuf by pausing the reader; h2_check_stream_poll_cbs re-arms it */
    if (unlikely(h2_resp_wbuf_avail(stream) > FEER_TUNNEL_MAX_WBUF))
        ev_io_stop(EV_A, &stream->tunnel_read_w);

relay:
    nghttp2_session_resume_data(stream->parent->h2_session, stream->stream_id);
    h2_session_send_and_poll(aTHX_ stream->parent);
}

static void
h2_tunnel_sv0_write_cb(EV_P_ struct ev_io *w, int revents)
{
    dTHX;
    PERL_UNUSED_VAR(revents);
    struct feer_h2_stream *stream = (struct feer_h2_stream *)w->data;
    if (!stream) return;

    if (!stream->tunnel_wbuf || SvCUR(stream->tunnel_wbuf) <= stream->tunnel_wbuf_pos) {
        ev_io_stop(EV_A, &stream->tunnel_write_w);
        if (stream->tunnel_wbuf) {
            SvCUR_set(stream->tunnel_wbuf, 0);
            stream->tunnel_wbuf_pos = 0;
        }
        return;
    }

    STRLEN avail = SvCUR(stream->tunnel_wbuf) - stream->tunnel_wbuf_pos;
    const char *ptr = SvPVX(stream->tunnel_wbuf) + stream->tunnel_wbuf_pos;
    ssize_t nw = write(stream->tunnel_sv0, ptr, avail);

    if (nw < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
            return;
        ev_io_stop(EV_A, &stream->tunnel_write_w);
        ev_io_stop(EV_A, &stream->tunnel_read_w);
        if (stream->parent && stream->parent->h2_session) {
            h2_submit_rst(stream->parent->h2_session, stream->stream_id,
                          NGHTTP2_CONNECT_ERROR);
            h2_session_send_and_poll(aTHX_ stream->parent);
        }
        return;
    }

    stream->tunnel_wbuf_pos += nw;
    if (stream->tunnel_wbuf_pos >= SvCUR(stream->tunnel_wbuf)) {
        ev_io_stop(EV_A, &stream->tunnel_write_w);
        SvCUR_set(stream->tunnel_wbuf, 0);
        stream->tunnel_wbuf_pos = 0;
    }
}

/* 0 when written or buffered, -1 on a hard write error */
static int
h2_tunnel_write_or_buffer(struct feer_h2_stream *stream,
                          const char *data, size_t len)
{
    dTHX;
    if (stream->tunnel_sv0 < 0) return -1;

    /* queued bytes go first, or this write overtakes them and the app reads out of order */
    ssize_t nw = 0;
    if (!(stream->tunnel_wbuf
          && SvCUR(stream->tunnel_wbuf) > stream->tunnel_wbuf_pos)) {
        nw = write(stream->tunnel_sv0, data, len);
        if (nw == (ssize_t)len)
            return 0;

        if (nw < 0) {
            if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
                return -1;
            nw = 0;
        }
    }

    size_t remaining = len - nw;
    if (!stream->tunnel_wbuf) {
        stream->tunnel_wbuf = newSV_buf(remaining + 256);
    }

    if (stream->tunnel_wbuf_pos > 0) {
        STRLEN remain = SvCUR(stream->tunnel_wbuf) - stream->tunnel_wbuf_pos;
        if (remain > 0)
            memmove(SvPVX(stream->tunnel_wbuf),
                    SvPVX(stream->tunnel_wbuf) + stream->tunnel_wbuf_pos,
                    remain);
        SvCUR_set(stream->tunnel_wbuf, remain);
        stream->tunnel_wbuf_pos = 0;
    }

    if (SvCUR(stream->tunnel_wbuf) + remaining > FEER_TUNNEL_MAX_WBUF) {
        trouble("H2 tunnel wbuf overflow stream=%d\n", stream->stream_id);
        return -1;
    }

    sv_catpvn(stream->tunnel_wbuf, data + nw, remaining);
    if (!ev_is_active(&stream->tunnel_write_w))
        ev_io_start(feersum_ev_loop, &stream->tunnel_write_w);
    return 0;
}

static void
h2_tunnel_recv_data(pTHX_ struct feer_h2_stream *stream, const uint8_t *data, size_t len)
{
    if (h2_tunnel_write_or_buffer(stream, (const char *)data, len) < 0) {
        if (stream->tunnel_established) {
            ev_io_stop(feersum_ev_loop, &stream->tunnel_read_w);
            ev_io_stop(feersum_ev_loop, &stream->tunnel_write_w);
        }
        if (stream->parent && stream->parent->h2_session) {
            /* submit only: no session_send inside a recv callback; every
             * feer_h2_session_recv caller flushes right after */
            h2_submit_rst(stream->parent->h2_session, stream->stream_id,
                          NGHTTP2_CONNECT_ERROR);
        }
    }
}

/* Socketpair bridge, created lazily by psgix.io or io() */
static void
feer_h2_setup_tunnel(pTHX_ struct feer_h2_stream *stream)
{
    if (stream->tunnel_established) return;

    int sv[2];
    if (feer_socketpair_nb(sv) < 0) {
        trouble("socketpair/fcntl failed for H2 tunnel stream=%d: %s\n",
                stream->stream_id, strerror(errno));
        return;
    }

    stream->tunnel_sv0 = sv[0];
    stream->tunnel_sv1 = sv[1];

    ev_io_init(&stream->tunnel_read_w, h2_tunnel_sv0_read_cb, sv[0], EV_READ);
    stream->tunnel_read_w.data = (void *)stream;
    ev_io_start(feersum_ev_loop, &stream->tunnel_read_w);

    ev_io_init(&stream->tunnel_write_w, h2_tunnel_sv0_write_cb, sv[0], EV_WRITE);
    stream->tunnel_write_w.data = (void *)stream;

    stream->tunnel_established = 1;

    /* pre-tunnel DATA; an overflow here must reset, not drop bytes and leave a hole */
    {
        int flush_err = 0;
        if (stream->pseudo_conn && stream->pseudo_conn->rbuf) {
            SV *rbuf = stream->pseudo_conn->rbuf;
            if (SvOK(rbuf) && SvCUR(rbuf) > 0) {
                if (h2_tunnel_write_or_buffer(stream, SvPVX(rbuf), SvCUR(rbuf)) < 0)
                    flush_err = 1;
                SvCUR_set(rbuf, 0);
            }
        }
        if (!flush_err && stream->body_buf && SvCUR(stream->body_buf) > 0) {
            if (h2_tunnel_write_or_buffer(stream, SvPVX(stream->body_buf),
                                          SvCUR(stream->body_buf)) < 0)
                flush_err = 1;
            SvCUR_set(stream->body_buf, 0);
        }
        if (unlikely(flush_err)) {
            trouble("H2 tunnel pre-flush overflowed stream=%d\n", stream->stream_id);
            ev_io_stop(feersum_ev_loop, &stream->tunnel_read_w);
            ev_io_stop(feersum_ev_loop, &stream->tunnel_write_w);
            if (stream->parent && stream->parent->h2_session)
                h2_submit_rst(stream->parent->h2_session, stream->stream_id,
                              NGHTTP2_CONNECT_ERROR);
            return;
        }
    }

    if (stream->tunnel_pending_shutdown) {
        shutdown(stream->tunnel_sv0, SHUT_WR);
        stream->tunnel_pending_shutdown = 0;
        stream->tunnel_eof_sent = 1;
    }

    trace("H2 tunnel socketpair established stream=%d sv0=%d sv1=%d\n",
          stream->stream_id, sv[0], sv[1]);
}

static void
feersum_h2_close_write(pTHX_ struct feer_conn *c)
{
    struct feer_h2_stream *stream = H2_STREAM_FROM_PC(c);
    if (!stream || !stream->parent || !stream->parent->h2_session) return;

    /* a tunnel ends when the app closes sv[1], not on writer close */
    if (stream->is_tunnel)
        return;

    stream->resp_eof = 1;

    struct feer_conn *parent = stream->parent;
    nghttp2_session_resume_data(parent->h2_session, stream->stream_id);
    h2_session_send_and_poll(aTHX_ parent);
    /* the tail may still sit behind the peer's window: keep a deadline on it */
    if (unlikely(H2_STREAM_FROM_PC(c) != NULL))
        ensure_write_timer(c);
}

static void
feersum_h2_respond_error(struct feer_conn *c, int err_code, const char *msg)
{
    dTHX;
    struct feer_h2_stream *stream = H2_STREAM_FROM_PC(c);
    if (!stream || !stream->parent || !stream->parent->h2_session) {
        if (c->responding != RESPOND_SHUTDOWN)
            change_responding_state(c, RESPOND_SHUTDOWN);
        return;
    }

    struct feer_conn *parent = stream->parent;

    if (c->responding == RESPOND_NOT_STARTED) {
        /* c->no_resp_body is only set by a started response; none was */
        bool no_body = c->req && c->req->method_len == 4
                    && memcmp(c->req->method, "HEAD", 4) == 0;
        h2_submit_error_response(aTHX_ parent->h2_session, stream,
                                 stream->stream_id, err_code, msg, no_body);
    } else {
        h2_submit_rst(parent->h2_session, stream->stream_id,
                      NGHTTP2_INTERNAL_ERROR);
    }

    stop_write_timer(c);
    change_responding_state(c, RESPOND_SHUTDOWN);
    change_receiving_state(c, RECEIVE_SHUTDOWN);
    h2_session_send_and_poll(aTHX_ parent);
}

#endif /* FEERSUM_HAS_H2 */
