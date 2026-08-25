
// leftmost X-Forwarded-For entry is the original client
static SV*
extract_forwarded_addr(pTHX_ struct feer_req *r)
{
    size_t val_len;
    const char *val = find_header_value(r, "x-forwarded-for", 15, &val_len);
    if (!val || val_len == 0) return NULL;

    while (val_len > 0 && (*val == ' ' || *val == '\t')) { val++; val_len--; }
    if (val_len == 0) return NULL;

    size_t ip_len = 0;
    while (ip_len < val_len && val[ip_len] != ',' && val[ip_len] != ' ') ip_len++;

    if (ip_len == 0 || ip_len > 45) return NULL;  // max IPv6 length is 45 chars

    char ip_buf[46];
    memcpy(ip_buf, val, ip_len);
    ip_buf[ip_len] = '\0';

    struct in_addr addr4;
    struct in6_addr addr6;
    if (inet_pton(AF_INET, ip_buf, &addr4) == 1) {
        return newSVpvn(val, ip_len);
    }
    if (inet_pton(AF_INET6, ip_buf, &addr6) == 1) {
        return newSVpvn(val, ip_len);
    }

    trace("X-Forwarded-For contains invalid IP: %s\n", ip_buf);
    return NULL;
}

static SV*
extract_forwarded_proto(pTHX_ struct feer_req *r)
{
    size_t val_len;
    const char *val = find_header_value(r, "x-forwarded-proto", 17, &val_len);
    if (!val || val_len == 0) return NULL;

    while (val_len > 0 && (*val == ' ' || *val == '\t')) { val++; val_len--; }

    if (val_len >= 5 && str_case_eq_fixed("https", val, 5) &&
        (val_len == 5 || val[5] == ' ' || val[5] == '\t' || val[5] == ','))
        return newSVpvs("https");
    if (val_len >= 4 && str_case_eq_fixed("http", val, 4) &&
        (val_len == 4 || val[4] == ' ' || val[4] == '\t' || val[4] == ','))
        return newSVpvs("http");

    return NULL;
}

/* Returns a new SV, or NULL for the default "http". */
static SV *
feer_determine_url_scheme(pTHX_ struct feer_conn *c)
{
#ifdef FEERSUM_HAS_H2
    /* H2 is TLS-only here; :scheme is validated but not consulted. */
    if (c->is_h2_stream) return newSVpvs("https");
#endif
#ifdef FEERSUM_HAS_TLS
    if (c->tls) return newSVpvs("https");
#endif
    if (c->proxy_ssl) return newSVpvs("https");
    if (c->proxy_proto_version > 0 && c->proxy_dst_port == 443)
        return newSVpvs("https");
    if (c->cached_use_reverse_proxy && c->req) {
        SV *fwd = extract_forwarded_proto(aTHX_ c->req);
        if (fwd) return fwd;
    }
    return NULL;
}

static HV *psgi_env_template = NULL;

static void
feersum_init_psgi_env_constants(pTHX)
{
    if (psgi_env_version) return;
    psgi_env_version = newRV((SV*)psgi_ver);
    psgi_env_errors = newRV((SV*)PL_stderrgv);

    /* Values are copies: a shared immortal croaks when an app assigns to the key. */
    HV *t = newHV();
    /* The newHVhv clone inherits the bucket count; 48 covers a typical request. */
    hv_ksplit(t, 48);
    hv_stores(t, "psgi.version", newSVsv(psgi_env_version));
    hv_stores(t, "psgi.errors", newSVsv(psgi_env_errors));
    hv_stores(t, "psgi.run_once", newSVsv(&PL_sv_no));
    hv_stores(t, "psgi.nonblocking", newSVsv(&PL_sv_yes));
    hv_stores(t, "psgi.multithread", newSVsv(&PL_sv_no));
    hv_stores(t, "psgi.streaming", newSVsv(&PL_sv_yes));
    /* No psgix.input.buffered: psgi.input cannot rewind. */
    hv_stores(t, "psgix.output.buffered", newSVsv(&PL_sv_yes));
    hv_stores(t, "psgix.body.scalar_refs", newSVsv(&PL_sv_yes));
    hv_stores(t, "psgix.output.guard", newSVsv(&PL_sv_yes));
    hv_stores(t, "SCRIPT_NAME", newSVpvs(""));
    psgi_env_template = t;
}

/* Plain PV only; magic, taint, refs and dualvars must go through newSVsv. */
INLINE_UNLESS_DEBUG static SV *
feer_copy_pv(pTHX_ SV *src)
{
    STRLEN len;
    const char *pv;
    if (unlikely(!src || !SvPOK(src) || SvIOK(src) || SvNOK(src)
                 || SvGMAGICAL(src) || SvROK(src)))
        return newSVsv(src);
    pv = SvPV_const(src, len);
    return newSVpvn_flags(pv, len, SvUTF8(src) ? SVf_UTF8 : 0);
}

static HV*
feersum_build_psgi_env(pTHX)
{
    return newHVhv(psgi_env_template);
}

static HV*
feersum_env(pTHX_ struct feer_conn *c)
{
    HV *e;
    int i,j;
    struct feer_req *r = c->req;

    if (unlikely(!psgi_env_version))
        feersum_init_psgi_env_constants(aTHX);

    e = feersum_build_psgi_env(aTHX);

    trace("generating header (fd %d) %.*s\n",
        c->fd, (int)r->uri_len, r->uri);

    // Copies: the listener SVs are readonly and middleware assigns to these keys.
    {
        struct feer_listen *conn_lsnr = c->listener;
        hv_stores(e, "SERVER_NAME",
            conn_lsnr->server_name ? feer_copy_pv(aTHX_ conn_lsnr->server_name) : newSVpvs(""));
        hv_stores(e, "SERVER_PORT",
            conn_lsnr->server_port ? feer_copy_pv(aTHX_ conn_lsnr->server_port) : newSVpvs("0"));
    }
    hv_stores(e, "REQUEST_URI", feersum_env_uri(aTHX_ r));
#ifdef FEERSUM_HAS_H2
    /* feersum_env_method* return an owned ref to a shared read-only SV. */
    {
        SV *m = feersum_env_method_h2(aTHX_ c, r);
        hv_stores(e, "REQUEST_METHOD", feer_copy_pv(aTHX_ m));
        SvREFCNT_dec(m);
    }
    if (unlikely(c->is_h2_stream))
        hv_stores(e, "SERVER_PROTOCOL", newSVpvs("HTTP/2"));
    else
        hv_stores(e, "SERVER_PROTOCOL", feer_copy_pv(aTHX_ feersum_env_protocol(aTHX_ r)));
#else
    {
        SV *m = feersum_env_method(aTHX_ r);
        hv_stores(e, "REQUEST_METHOD", feer_copy_pv(aTHX_ m));
        SvREFCNT_dec(m);
    }
    hv_stores(e, "SERVER_PROTOCOL", feer_copy_pv(aTHX_ feersum_env_protocol(aTHX_ r)));
#endif

    feersum_set_conn_remote_info(aTHX_ c);

    if (c->cached_use_reverse_proxy) {
        SV *fwd_addr = extract_forwarded_addr(aTHX_ r);
        hv_stores(e, "REMOTE_ADDR", fwd_addr ? fwd_addr : feer_copy_pv(aTHX_ c->remote_addr));
    } else {
        hv_stores(e, "REMOTE_ADDR", feer_copy_pv(aTHX_ c->remote_addr));
    }
    hv_stores(e, "REMOTE_PORT", feer_copy_pv(aTHX_ c->remote_port));

    {
        SV *scheme = feer_determine_url_scheme(aTHX_ c);
        hv_stores(e, "psgi.url_scheme", scheme ? scheme : newSVpvs("http"));
    }

    hv_stores(e, "CONTENT_LENGTH", newSViv(c->expected_cl));

    hv_stores(e, "psgi.input", new_feer_conn_handle(aTHX_ c, 0));

    /* A copy: a shared immortal croaks on assignment. */
    hv_stores(e, "psgi.multiprocess",
        newSVsv(c->server->multiprocess ? &PL_sv_yes : &PL_sv_no));

    /* Check the server's live flag, not a per-conn cache: reading psgix.io
     * takes the socket, so a native handler must never be handed one. */
    if (c->server->request_cb_is_psgi && c->server->psgix_io) {
        SV *fake_fh = newSViv(c->fd);
        SV *selfref = sv_2mortal(feer_conn_2sv(c));
        sv_magicext(fake_fh, selfref, PERL_MAGIC_ext, &psgix_io_vtbl, NULL, 0);
        hv_stores(e, "psgix.io", fake_fh);
    }

    if (c->trailers) {
        hv_stores(e, "psgix.h2.trailers", newRV_inc((SV*)c->trailers));
    }

    if (c->proxy_tlvs) {
        /* Copy: the TLV hash is shared by every request and stream on the conn. */
        HV *tlvs = (HV *)SvRV(c->proxy_tlvs);
        HV *copy = newHVhv(tlvs);
        hv_stores(e, "psgix.proxy_tlvs", newRV_noinc((SV *)copy));
    }

    if (likely(!r->path)) feersum_set_path_and_query(aTHX_ r);
    hv_stores(e, "PATH_INFO", feer_copy_pv(aTHX_ r->path));
    hv_stores(e, "QUERY_STRING", feer_copy_pv(aTHX_ r->query));

    char *kbuf = header_key_buf; // already holds the "HTTP_" prefix

    for (i=0; i<r->num_headers; i++) {
        struct phr_header *hdr = &(r->headers[i]);
        // hdr->name is never NULL: obs-fold is rejected at parse time
        if (unlikely(hdr->name_len == 14) &&
            str_case_eq_fixed("content-length", hdr->name, 14))
        {
            // CONTENT_LENGTH was set above; PSGI forbids HTTP_CONTENT_LENGTH
            continue;
        }
        else if (unlikely(hdr->name_len == 12) &&
            str_case_eq_fixed("content-type", hdr->name, 12))
        {
            hv_stores(e, "CONTENT_TYPE", newSVpvn(hdr->value, hdr->value_len));
            continue;
        }
        else if (unlikely(hdr->name_len == 17) &&
            str_case_eq_fixed("transfer-encoding", hdr->name, 17))
        {
            // Body already de-chunked; TE next to CONTENT_LENGTH is a CL.TE hazard
            continue;
        }

        // defense in depth: parse already rejects these with 431
        if (unlikely(hdr->name_len > MAX_HEADER_NAME_LEN)) {
            trace("skipping oversized header name (len=%zu) on fd %d\n",
                  hdr->name_len, c->fd);
            continue;
        }

        size_t klen = 5+hdr->name_len;
        char *key = kbuf + 5;
        for (j=0; j<hdr->name_len; j++) {
            *key++ = ascii_upper_dash[(unsigned char)hdr->name[j]];
        }

        /* '_' normalises like '-': a "Content_Length:" header must not inject this. */
        if (unlikely((klen == 19 && memEQ(kbuf, "HTTP_CONTENT_LENGTH", 19))
                  || (klen == 17 && memEQ(kbuf, "HTTP_CONTENT_TYPE", 17))))
            continue;

        SV **fetched = hv_fetch(e, kbuf, klen, 1);
        trace("adding header to env (fd %d) %.*s: %.*s\n",
            c->fd, (int)klen, kbuf, (int)hdr->value_len, hdr->value);

        if (unlikely(fetched == NULL)) {
            trace("hv_fetch returned NULL (OOM?) on fd %d\n", c->fd);
            continue;
        }
        SV *cur_val = *fetched;
        if (unlikely(SvPOK(cur_val))) {
            trace("... is multivalue\n");
            // cookie joins with "; " (RFC 9113 8.2.3)
            const char *sep = (hdr->name_len == 6
                && str_case_eq_fixed("cookie", hdr->name, 6)) ? "; " : ", ";
            sv_catpvn(cur_val, sep, 2);
            sv_catpvn(cur_val, hdr->value, hdr->value_len);
        }
        else {
            sv_setpvn(cur_val, hdr->value, hdr->value_len);
        }
    }

#ifdef FEERSUM_HAS_H2
    /* :authority becomes HTTP_HOST unless a Host header was sent (RFC 9113 8.3.1). */
    if (unlikely(c->is_h2_stream)) {
        struct feer_h2_stream *stream = H2_STREAM_FROM_PC(c);
        if (stream && stream->h2_authority && !hv_exists(e, "HTTP_HOST", 9)) {
            STRLEN alen;
            const char *aval = SvPV(stream->h2_authority, alen);
            hv_stores(e, "HTTP_HOST", newSVpvn(aval, alen));
        }
        /* Extended CONNECT (RFC 8441) is presented as an H1 Upgrade request. */
        if (stream && stream->is_tunnel && stream->h2_protocol) {
            STRLEN plen;
            const char *pval = SvPV(stream->h2_protocol, plen);
            hv_stores(e, "HTTP_UPGRADE", newSVpvn(pval, plen));
            hv_stores(e, "HTTP_CONNECTION", newSVpvs("Upgrade"));
            hv_stores(e, "psgix.h2.protocol", newSVpvn(pval, plen));
            hv_stores(e, "psgix.h2.extended_connect", newSViv(1));
        }
    }
#endif

    return e;
}

#define COPY_NORM_HEADER(_str) \
for (i = 0; i < r->num_headers; i++) {\
    struct phr_header *hdr = &(r->headers[i]);\
    if (unlikely(hdr->name_len > MAX_HEADER_NAME_LEN)) continue;\
    char *k = kbuf;\
    for (j = 0; j < hdr->name_len; j++) { char n = hdr->name[j]; *k++ = _str; }\
    SV** val = hv_fetch(e, kbuf, hdr->name_len, 1);\
    if (unlikely(!val)) continue;\
    if (unlikely(SvPOK(*val))) {\
        const char *sep = (hdr->name_len == 6\
            && str_case_eq_fixed("cookie", hdr->name, 6)) ? "; " : ", ";\
        sv_catpvn(*val, sep, 2);\
        sv_catpvn(*val, hdr->value, hdr->value_len);\
    } else {\
        sv_setpvn(*val, hdr->value, hdr->value_len);\
    }\
}\
break;

static HV*
feersum_env_headers(pTHX_ struct feer_req *r, int norm)
{
    size_t i; size_t j; HV* e;
    e = newHV();
    if (r->num_headers > 0)
        hv_ksplit(e, r->num_headers);
    char *kbuf = header_key_buf + 5; // skip the "HTTP_" prefix
    switch (norm) {
        case HEADER_NORM_SKIP:
            COPY_NORM_HEADER(n)
        case HEADER_NORM_LOCASE:
            COPY_NORM_HEADER(ascii_lower[(unsigned char)n])
        case HEADER_NORM_UPCASE:
            COPY_NORM_HEADER(ascii_upper[(unsigned char)n])
        case HEADER_NORM_LOCASE_DASH:
            COPY_NORM_HEADER(ascii_lower_dash[(unsigned char)n])
        case HEADER_NORM_UPCASE_DASH:
            COPY_NORM_HEADER(ascii_upper_dash[(unsigned char)n])
        default:
            break;
    }
    return e;
}

INLINE_UNLESS_DEBUG static SV*
feersum_env_header(pTHX_ struct feer_req *r, SV *name)
{
    SV *result = NULL;
    STRLEN nlen;
    const char *np = SvPV(name, nlen);
    const bool is_cookie = (nlen == 6 && str_case_eq_fixed("cookie", np, 6));
    for (size_t i = 0; i < r->num_headers; i++) {
        struct phr_header *hdr = &(r->headers[i]);
        if (unlikely(hdr->name_len == nlen
            && str_case_eq_both(np, hdr->name, nlen))) {
            if (likely(!result)) {
                result = newSVpvn(hdr->value, hdr->value_len);
            } else {
                sv_catpvn(result, is_cookie ? "; " : ", ", 2);
                sv_catpvn(result, hdr->value, hdr->value_len);
            }
        }
    }
    return result ? result : &PL_sv_undef;
}

/* Returns an owned RV; the glob's scalar slot holds a back-ref that keeps c
 * alive.  On croak the caller still owns fd. */
static SV *
feer_make_io_handle(pTHX_ struct feer_conn *c, int fd, const char *who)
{
    dSP;
    SV *sv = newSViv(fd);

    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    XPUSHs(sv);
    mXPUSHs(newSViv(fd));
    PUTBACK;

    call_pv("Feersum::Connection::_raw", G_VOID|G_DISCARD|G_EVAL);
    SPAGAIN;

    if (unlikely(SvTRUE(ERRSV))) {
        FREETMPS; LEAVE;
        SvREFCNT_dec(sv);
        croak("Failed to create %s IO handle: %-p", who, ERRSV);
    }
    if (unlikely(!SvROK(sv))) {
        FREETMPS; LEAVE;
        SvREFCNT_dec(sv);
        croak("Failed to create %s IO handle: new_from_fd returned undef", who);
    }

    SV *io_glob = SvRV(sv);
    GvSV(io_glob) = newRV_inc(c->self);

    FREETMPS;
    LEAVE;
    return sv;
}

static void
feer_hand_out_raw_fd(pTHX_ struct feer_conn *c, SV *io_glob, const char *who)
{
    if (likely(c->rbuf && SvOK(c->rbuf) && SvCUR(c->rbuf))) {
        STRLEN rbuf_len;
        const char *rbuf_ptr = SvPV(c->rbuf, rbuf_len);
        IO *io = GvIOp(io_glob);
        if (io) {
            SSize_t pushed = PerlIO_unread(IoIFP(io), (const void *)rbuf_ptr, rbuf_len);
            if (likely(pushed == (SSize_t)rbuf_len)) {
                SvCUR_set(c->rbuf, 0);
                *SvPVX(c->rbuf) = '\0';
            } else if (pushed > 0) {
                sv_chop(c->rbuf, rbuf_ptr + pushed);
                trouble("PerlIO_unread partial in %s: %zd of %"Sz_uf" bytes fd=%d\n",
                    who, pushed, (Sz)rbuf_len, c->fd);
            } else {
                trouble("PerlIO_unread failed in %s fd=%d\n", who, c->fd);
            }
        }
        else {
            trouble("%s: GvIOp returned NULL fd=%d\n", who, c->fd);
        }
    }

    stop_read_watcher(c);
    stop_read_timer(c);
    stop_write_timer(c);
    // write watcher stays armed to flush outstanding data

    c->io_taken = 1;
    c->fd_given_away = 1;   // the handle's destructor closes c->fd now
}

static SV*
feersum_env_io(pTHX_ struct feer_conn *c)
{
    if (unlikely(c->io_taken))
        croak("io() already called on this connection");
    if (unlikely(c->responding != RESPOND_NOT_STARTED))
        croak("io() cannot be called after send_response/start_response");

    trace("feersum_env_io for fd=%d\n", c->fd);

#ifdef FEERSUM_HAS_H2
    if (c->is_h2_stream) {
        struct feer_h2_stream *stream = H2_STREAM_FROM_PC(c);
        if (!stream || !stream->is_tunnel)
            croak("io() is not supported on regular HTTP/2 streams");
        h2_tunnel_auto_accept(aTHX_ c, stream);
        /* Re-fetch stream: auto_accept -> session_send may have freed it */
        stream = H2_STREAM_FROM_PC(c);
        if (!stream)
            croak("io() tunnel: stream freed during auto-accept");
        feer_h2_setup_tunnel(aTHX_ stream);
        if (!stream->tunnel_established)
            croak("Failed to create tunnel socketpair");

        SV *sv = feer_make_io_handle(aTHX_ c, stream->tunnel_sv1, "tunnel");
        /* sv[1] now owned by the IO handle */
        stream->tunnel_sv1 = -1;
        c->io_taken = 1;
        return sv;
    }
#endif

#ifdef FEERSUM_HAS_TLS
    if (c->tls) {
        feer_tls_setup_tunnel(c);
        if (!c->tls_tunnel)
            croak("Failed to create TLS tunnel socketpair");

        SV *sv = feer_make_io_handle(aTHX_ c, c->tls_tunnel_sv1, "TLS tunnel");
        /* sv[1] now owned by the IO handle */
        c->tls_tunnel_sv1 = -1;
        c->io_taken = 1;
        stop_read_timer(c);
        stop_write_timer(c);
        /* Keep read watcher active: TLS reads relay to tunnel */
        return sv;
    }
#endif

    SV *sv = feer_make_io_handle(aTHX_ c, c->fd, "raw socket");
    feer_hand_out_raw_fd(aTHX_ c, SvRV(sv), "io()");
    return sv;
}

static SSize_t
feersum_return_from_io(pTHX_ struct feer_conn *c, SV *io_sv, const char *func_name)
{
    if (unlikely(!c->io_taken))
        croak("%s: called without a preceding io()/psgix.io", func_name);
#ifdef FEERSUM_HAS_H2
    if (unlikely(c->is_h2_stream))
        croak("%s: not supported on HTTP/2 streams", func_name);
#endif
#ifdef FEERSUM_HAS_TLS
    if (c->tls_tunnel)
        croak("%s: not supported on TLS tunnel connections "
              "(io() over TLS uses a socketpair relay that cannot be returned)",
              func_name);
#endif

    if (!SvROK(io_sv) || !isGV_with_GP(SvRV(io_sv)))
        croak("%s requires a filehandle", func_name);

    GV *gv = (GV *)SvRV(io_sv);
    IO *io = GvIO(gv);
    if (!io || !IoIFP(io))
        croak("%s: invalid filehandle", func_name);

    PerlIO *fp = IoIFP(io);

    /* A foreign handle would splice its bytes into rbuf and clear
     * fd_given_away while the real handle still shares c->fd. */
    if (PerlIO_fileno(fp) != c->fd)
        croak("%s: that handle does not wrap this connection's socket",
              func_name);

    SSize_t cnt = PerlIO_get_cnt(fp);
    if (cnt > 0) {
        // ptr is valid only until the next PerlIO op on fp
        STDCHAR *ptr = PerlIO_get_ptr(fp);
        if (ptr) {
            if (!c->rbuf)
                c->rbuf = newSV(READ_BUFSZ);

            sv_catpvn(c->rbuf, (const char *)ptr, cnt);

            PerlIO_set_ptrcnt(fp, ptr + cnt, 0);

            trace("pulled %zd bytes back to feersum fd=%d\n", cnt, c->fd);
        }
    }

    /* dup: the app's handle still owns c->fd and closes it when dropped. */
    {
#ifdef F_DUPFD_CLOEXEC
        int nfd = fcntl(c->fd, F_DUPFD_CLOEXEC, 0);
#else
        int nfd = dup(c->fd);
        if (nfd >= 0) (void)fcntl(nfd, F_SETFD, FD_CLOEXEC);
#endif
        if (unlikely(nfd < 0))
            croak("%s: cannot duplicate the connection descriptor: %s",
                  func_name, strerror(errno));
        /* ev_io_set is undefined on an active watcher */
        int r_active = ev_is_active(&c->read_ev_io);
        int w_active = ev_is_active(&c->write_ev_io);
        if (r_active) ev_io_stop(feersum_ev_loop, &c->read_ev_io);
        if (w_active) ev_io_stop(feersum_ev_loop, &c->write_ev_io);
        ev_io_set(&c->read_ev_io, nfd, EV_READ);
        ev_io_set(&c->write_ev_io, nfd, EV_WRITE);
        if (r_active) ev_io_start(feersum_ev_loop, &c->read_ev_io);
        if (w_active) ev_io_start(feersum_ev_loop, &c->write_ev_io);
        c->fd = nfd;
    }

    change_responding_state(c, RESPOND_NOT_STARTED);
    change_receiving_state(c, RECEIVE_HEADERS);
    c->expected_cl = 0;
    c->received_cl = 0;
    c->io_taken = 0;
    c->fd_given_away = 0;
    free_request(c);

    if (c->rbuf && cnt <= 0)
        SvCUR_set(c->rbuf, 0);

    start_read_watcher(c);
    c->prev_read_outq = 0;
    restart_read_timer(c);
    restart_header_timer(c);

    /* Bytes already in rbuf raise no socket event, so parse them now; this
     * only parses and enqueues, it does not dispatch re-entrantly. */
    if (c->rbuf && SvCUR(c->rbuf) > 0) {
        c->pipelined = SvCUR(c->rbuf);
#ifdef FEERSUM_HAS_TLS
        if (c->tls)
            try_tls_conn_read(feersum_ev_loop, &c->read_ev_io, EV_READ);
        else
#endif
            try_conn_read(feersum_ev_loop, &c->read_ev_io, EV_READ);
    }

    return cnt > 0 ? cnt : 0;
}

/* The header passes walk AvARRAY and SvPV with no eval above them.  Returns
 * the AV itself, a mortal plain copy, or NULL with ERRSV set. */
static AV *
feersum_flatten_headers(pTHX_ AV *headers)
{
    bool needs_copy = SvMAGICAL((SV *)headers) ? 1 : 0;
    if (!needs_copy) {
        SV **arr = AvARRAY(headers);
        I32 top = AvFILLp(headers);
        for (I32 i = 0; i <= top; i++) {
            SV *e = arr[i];
            if (!e) continue;
            if (SvMAGICAL(e) || (SvROK(e) && SvAMAGIC(e))) { needs_copy = 1; break; }
        }
    }
    if (likely(!needs_copy)) return headers;

    dSP;
    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    XPUSHs(sv_2mortal(newRV_inc((SV *)headers)));
    PUTBACK;

    int count = call_pv("Feersum::_flatten_headers", G_SCALAR|G_EVAL);
    SPAGAIN;

    AV *out = NULL;
    if (likely(!SvTRUE(ERRSV)) && count == 1) {
        SV *r = POPs;
        if (IsArrayRef(r)) out = (AV *)SvRV(r);
        if (out) SvREFCNT_inc((SV *)out);
    }
    else if (count > 0) {
        (void)POPs;
    }
    PUTBACK;
    FREETMPS;
    LEAVE;

    if (out) sv_2mortal((SV *)out);
    return out;
}

/* av_len/av_fetch on a tied AV run FETCHSIZE/FETCH, which can die with no eval
 * above.  Returns the AV itself, a mortal plain copy, or NULL with ERRSV set. */
static AV *
feersum_flatten_magical_av(pTHX_ AV *av)
{
    if (likely(!SvMAGICAL((SV *)av))) return av;

    dSP;
    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    XPUSHs(sv_2mortal(newRV_inc((SV *)av)));
    PUTBACK;

    int count = call_pv("Feersum::_flatten_body", G_SCALAR|G_EVAL);
    SPAGAIN;

    AV *out = NULL;
    if (likely(!SvTRUE(ERRSV)) && count == 1) {
        SV *r = POPs;
        if (IsArrayRef(r)) out = (AV *)SvRV(r);
        if (out) SvREFCNT_inc((SV *)out);   /* survive FREETMPS below */
    }
    else if (count > 0) {
        (void)POPs;
    }
    PUTBACK;
    FREETMPS;
    LEAVE;

    if (out) sv_2mortal((SV *)out);
    return out;
}

/* Fire element get-magic under an eval: the body write newSVsv's each element
 * with no eval above it.  Returns the body to use, or NULL with ERRSV set. */
static SV *
feersum_flatten_magical_body(pTHX_ SV *body)
{
    AV *av = (AV *)SvRV(body);
    /* A tied AV dies inside av_len itself, so test the array first. */
    bool magical = SvMAGICAL((SV *)av) ? 1 : 0;
    if (!magical) {
        SV **arr = AvARRAY(av);
        I32 top = AvFILLp(av);
        for (I32 i = 0; i <= top; i++) {
            SV *e = arr[i];
            if (!e) continue;
            if (SvMAGICAL(e)) { magical = 1; break; }
            /* the writer derefs an RV, so \$tied bites one level down too */
            if (SvROK(e) && SvMAGICAL(SvRV(e))) { magical = 1; break; }
        }
    }
    if (likely(!magical)) return body;

    dSP;
    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    XPUSHs(body);
    PUTBACK;
    int count = call_pv("Feersum::_flatten_body", G_SCALAR|G_EVAL);
    SPAGAIN;
    SV *out = NULL;
    if (count > 0) {
        SV *r = POPs;
        if (!SvTRUE(ERRSV) && SvROK(r) && SvTYPE(SvRV(r)) == SVt_PVAV)
            out = newSVsv(r);
    }
    PUTBACK;
    FREETMPS;
    LEAVE;
    if (out) return sv_2mortal(out);
    return NULL;
}

/* The only status parser: feersum_check_psgi_status screens for the croak
 * feersum_start_response raises, and that path has no G_EVAL above it. */
INLINE_UNLESS_DEBUG static UV
feer_status_code(pTHX_ SV *message)
{
    UV code = 0;
    if (SvIOK(message)) return SvIV(message);
    STRLEN mlen = SvCUR(message);
    if (grok_number(SvPVX_const(message), mlen > 3 ? 3 : mlen, &code)
            != IS_NUMBER_IN_UV)
        return 0;
    /* the rest is copied verbatim into the status line, so "200.5" must fail */
    if (unlikely(mlen > 3 && SvPVX_const(message)[3] != ' '))
        return 0;
    return code;
}

/* Same bounds as feersum_start_response; returns NULL or a literal error. */
static const char *
feersum_check_psgi_status(pTHX_ SV *msg)
{
    if (!SvOK(msg) || !(SvIOK(msg) || SvPOK(msg)))
        return "PSGI status must be a number or status string";
    UV code = feer_status_code(aTHX_ msg);
    if (unlikely(!code))
        return "PSGI status must start with a positive number";
    if (unlikely(code > 599 || (code < 200 && code != 101)))
        return "PSGI status must be 200-599, or 101";
    return NULL;
}

/* Framing headers Feersum owns; keep in step with h2_skip_header.  Connection
 * and Upgrade deliberately pass through. */
INLINE_UNLESS_DEBUG static bool
feer_skip_response_header(const char *hp, STRLEN hlen)
{
    switch (hlen) {
    case 2:  return str_case_eq_fixed("te", hp, 2);
    case 10: return str_case_eq_fixed("keep-alive", hp, 10);
    case 16: return str_case_eq_fixed("proxy-connection", hp, 16);
    case 17: return str_case_eq_fixed("transfer-encoding", hp, 17);
    default: return false;
    }
}

static bool
feer_header_has_token(const char *vp, STRLEN vlen, const char *tok, STRLEN tlen)
{
    STRLEN i = 0;
    while (i < vlen) {
        while (i < vlen && (vp[i] == ',' || vp[i] == ' ' || vp[i] == '\t'))
            i++;
        STRLEN start = i;
        while (i < vlen && vp[i] != ',')
            i++;
        STRLEN end = i;
        while (end > start && (vp[end-1] == ' ' || vp[end-1] == '\t'))
            end--;
        if (end - start == tlen && str_case_eq_fixed(tok, vp + start, tlen))
            return true;
    }
    return false;
}

/* close and keep-alive are absorbed (the tail emits the canonical header);
 * anything else, Upgrade included, passes through.  Returns 1 to drop. */
INLINE_UNLESS_DEBUG static int
feer_connection_header_drop(struct feer_conn *c, const char *vp, STRLEN vlen,
                            bool apply)
{
    if (feer_header_has_token(vp, vlen, "close", 5)) {
        if (apply) c->is_keepalive = 0;
        return 1;
    }
    return feer_header_has_token(vp, vlen, "keep-alive", 10) ? 1 : 0;
}

/* Response-splitting screen.  Returns NULL or a literal error string: croak
 * it under a G_EVAL, route it through call_died otherwise. */
static const char *
feersum_check_response_framing(pTHX_ SV *message, AV *headers)
{
    if (SvPOK(message)) {
        STRLEN mlen;
        const char *mp = SvPV(message, mlen);
        for (STRLEN k = 0; k < mlen; k++)
            if (unlikely(mp[k] == '\r' || mp[k] == '\n'))
                return "Status message contains CR or LF";
    }
    I32 avl = av_len(headers);
    SV **ary = AvARRAY(headers);
    for (I32 j = 0; j < avl; j += 2) {
        SV *hdr = ary[j];
        SV *val = ary[j+1];
        if (!hdr || !SvOK(hdr) || !val || !SvOK(val))
            continue;
        STRLEN hlen, vlen;
        const char *hp = SvPV(hdr, hlen);
        const char *vp = SvPV(val, vlen);
        if (unlikely(hlen == 0))
            return "Response header name is empty";
        for (STRLEN k = 0; k < hlen; k++) {
            unsigned char ch = (unsigned char)hp[k];
            if (unlikely(ch <= 0x20 || ch == 0x7F || ch == ':'))
                return (ch == '\r' || ch == '\n' || ch == ':')
                     ? "Response header name contains CR, LF, or colon"
                     : "Response header name contains a space or control character";
        }
        for (STRLEN k = 0; k < vlen; k++) {
            unsigned char ch = (unsigned char)vp[k];
            if (unlikely(ch < 0x20 || ch == 0x7F)) {
                if (ch == '\t') continue;   /* HTAB is legal in a field value */
                return (ch == '\r' || ch == '\n')
                     ? "Response header value contains CR or LF"
                     : "Response header value contains a control character";
            }
        }
    }
    return NULL;
}

static void
feersum_start_response (pTHX_ struct feer_conn *c, SV *message, AV *headers,
                        int streaming, bool pre_validated)
{
    const char *ptr;

    trace("start_response fd=%d streaming=%d\n", c->fd, streaming);

    /* Precondition: headers already flattened (feersum_flatten_headers). */

    if (unlikely(!SvOK(message) || !(SvIOK(message) || SvPOK(message)))) {
        croak("Must define an HTTP status code or message");
    }

    I32 avl = av_len(headers);
    if (unlikely((avl+1) % 2 == 1)) {
        croak("expected even-length array, got %d", avl+1);
    }

    if (!pre_validated) {
        const char *err = feersum_check_response_framing(aTHX_ message, headers);
        if (unlikely(err)) croak("%s", err);
    }

    /* Set before the H2 dispatch so both transports see it. */
    c->no_resp_body = (c->req && c->req->method_len == 4
                       && memcmp(c->req->method, "HEAD", 4) == 0) ? 1 : 0;

#ifdef FEERSUM_HAS_H2
    if (unlikely(c->is_h2_stream)) {
        feersum_h2_start_response(aTHX_ c, message, headers, streaming);
        return;
    }
#endif

    if (unlikely(c->responding != RESPOND_NOT_STARTED)) {
        if (c->fd < 0 || c->responding == RESPOND_SHUTDOWN)
            croak("connection is already closed");
        croak("already responding?!");
    }
    /* Reading psgix.io takes the socket; the app's handle owns the fd now. */
    if (unlikely(c->io_taken))
        croak("can't respond after io()/psgix.io; call return_from_io first");

    UV code = feer_status_code(aTHX_ message);
    trace2("starting response fd=%d code=%"UVuf"\n",c->fd,code);

    // Validate before changing state: call_died cannot send a 500 once responding.
    if (unlikely(!code))
        croak("first parameter is not a number or doesn't start with digits");
    /* A non-101 1xx is interim and desyncs the client.  Bounds must match
     * h2_build_nva and feersum_check_psgi_status. */
    if (unlikely(code > 599 || (code < 200 && code != 101)))
        croak("response status must be 200-599, or 101, got %"UVuf, code);

    change_responding_state(c, streaming ? RESPOND_STREAMING : RESPOND_NORMAL);

    if (likely(!SvPOK(message) || SvCUR(message) == 3)) {
        switch (code) {
            case 200: message = status_200; break;
            case 201: message = status_201; break;
            case 204: message = status_204; break;
            case 301: message = status_301; break;
            case 302: message = status_302; break;
            case 304: message = status_304; break;
            case 400: message = status_400; break;
            case 404: message = status_404; break;
            case 500: message = status_500; break;
            default:
                ptr = http_code_to_msg(code);
                message = sv_2mortal(newSVpvf("%"UVuf" %s",code,ptr));
                break;
        }
    }

    c->auto_cl = http_status_no_body(code) ? 0 : 1;
    c->app_content_length = 0;

    /* 304 deliberately keeps the app's Content-Length (RFC 9110 8.6). */
    const bool drop_app_cl = (code < 200 || code == 204 || code == 205);

    /* Unlike 204, a 205 is not bodiless by framing rule; it needs an explicit CL. */
    const bool emit_zero_cl = (code == 205);

    STRLEN msg_len;
    const char *msg_ptr = SvPV(message, msg_len);
    if (unlikely(SvUTF8(message))) {
        SV *t = feer_bytes_mortal(msg_ptr, msg_len);
        msg_ptr = SvPVX(t); msg_len = SvCUR(t);
    }

    // Pass 1: size the block and find Content-Length
    bool has_content_length = 0;
    bool cl_seen = 0, cl_bad = 0;
    UV cl_val = 0;
    STRLEN hdr_total = 9 + msg_len + 2; // "HTTP/1.x " + message + CRLF
    SV **ary = AvARRAY(headers);
    for (I32 i = 0; i < avl; i += 2) {
        SV *hdr = ary[i];
        SV *val = ary[i+1];
        if (unlikely(!hdr || !SvOK(hdr) || !val || !SvOK(val)))
            continue;
        STRLEN hlen, vlen;
        const char *hp = SvPV(hdr, hlen);
        if (unlikely(feer_skip_response_header(hp, hlen)))
            continue;
        /* is_keepalive must be settled here: the tail is sized from it below. */
        if (unlikely(hlen == 10) && str_case_eq_fixed("connection", hp, 10)) {
            STRLEN cvlen;
            const char *cvp = SvPV(val, cvlen);
            if (feer_connection_header_drop(c, cvp, cvlen, 1))
                continue;
        }
        if (unlikely(hlen == 14) && str_case_eq_fixed("content-length", hp, 14)) {
            /* HEAD keeps the app's Content-Length: a GET's length, not the empty body's. */
            if (unlikely(c->no_resp_body) && !unlikely(drop_app_cl)) {
                c->app_content_length = 1;
                has_content_length = 1;
            }
            else if ((likely(c->auto_cl) && !streaming) || unlikely(drop_app_cl))
                continue;
            else {
                has_content_length = 1;
                /* as for a request: 1*DIGIT, OWS allowed, duplicates must agree */
                STRLEN clen;
                const char *clp = SvPV(val, clen), *q = clp;
                while (q < clp + clen && (*q == ' ' || *q == '\t')) q++;
                UV v = 0;
                if (q < clp + clen && *q >= '0' && *q <= '9'
                    && grok_number(clp, clen, &v) == IS_NUMBER_IN_UV
                    && v <= (UV)(~(size_t)0) && (!cl_seen || v == cl_val))
                    cl_val = v;
                else
                    cl_bad = 1;
                cl_seen = 1;
            }
        }
        (void)SvPV(val, vlen);
        hdr_total += hlen + 2 + vlen + 2; // key + ": " + value + CRLF
    }
    // HTTP/1.0 streaming without Content-Length can only end the body by closing.
    if (streaming && c->is_keepalive && !has_content_length
        && !c->is_http11 && c->auto_cl)
        c->is_keepalive = 0;
    // a malformed app Content-Length goes out as-is, unenforced
    c->resp_cl_enforced = streaming && c->auto_cl && cl_seen && !cl_bad;
    c->resp_cl_owed = c->resp_cl_enforced ? (size_t)cl_val : 0;

    // The tail is sized apart so the re-check after pass 2 can use it.
    STRLEN tail_len = 0;
    if (unlikely(emit_zero_cl))
        tail_len += 19;  // "Content-Length: 0\r\n"
    /* Date goes on HTTP/1.0 too (RFC 9110 6.6.1). */
    tail_len += DATE_HEADER_LENGTH;
    if (likely(c->is_http11))
        tail_len += (!c->is_keepalive ? 19 : 0);
    else if (c->is_keepalive)
        tail_len += 24;  // "Connection: keep-alive\r\n"
    if (streaming) {
        if (c->is_http11 && !has_content_length && c->auto_cl)
            tail_len += 30; // "Transfer-Encoding: chunked\r\n\r\n"
        else
            tail_len += 2;  // terminal CRLF
    }
    hdr_total += tail_len;

    // Pass 2: build the block
    SV *hdr_sv = newSV(hdr_total + 1);
    SvPOK_on(hdr_sv);
    char *p = SvPVX(hdr_sv);
    STRLEN hdr_alloc = hdr_total;

    const char *ver = c->is_http11 ? "HTTP/1.1 " : "HTTP/1.0 ";
    memcpy(p, ver, 9); p += 9;
    memcpy(p, msg_ptr, msg_len); p += msg_len;
    *p++ = '\r'; *p++ = '\n';

    for (I32 i = 0; i < avl; i += 2) {
        SV *hdr = ary[i];
        SV *val = ary[i+1];
        if (unlikely(!hdr || !SvOK(hdr) || !val || !SvOK(val)))
            continue;
        STRLEN hlen, vlen;
        const char *hp = SvPV(hdr, hlen);
        if (unlikely(feer_skip_response_header(hp, hlen)))
            continue;
        /* apply=0: a magical value could differ on this second read. */
        if (unlikely(hlen == 10) && str_case_eq_fixed("connection", hp, 10)) {
            STRLEN cvlen;
            const char *cvp = SvPV(val, cvlen);
            if (feer_connection_header_drop(c, cvp, cvlen, 0))
                continue;
        }
        if (unlikely(hlen == 14) && str_case_eq_fixed("content-length", hp, 14)) {
            /* mirror of pass 1 */
            if (!(unlikely(c->no_resp_body) && !unlikely(drop_app_cl))
                && ((likely(c->auto_cl) && !streaming) || unlikely(drop_app_cl)))
                continue;
        }
        const char *vp = SvPV(val, vlen);
        /* Downgrading cannot exceed pass 1's sizing: the encoded form is never shorter. */
        if (unlikely(SvUTF8(hdr))) {
            SV *t = feer_bytes_mortal(hp, hlen);
            hp = SvPVX(t); hlen = SvCUR(t);
        }
        if (unlikely(SvUTF8(val))) {
            SV *t = feer_bytes_mortal(vp, vlen);
            vp = SvPVX(t); vlen = SvCUR(t);
        }
        STRLEN need = hlen + 2 + vlen + 2;
        // Guard against magical SVs returning longer strings than pass 1
        if (unlikely((p - SvPVX(hdr_sv)) + need > hdr_alloc)) {
            STRLEN pos = p - SvPVX(hdr_sv);
            hdr_alloc = pos + need + 128; // slack covers the tail (<= 105 bytes)
            SvGROW(hdr_sv, hdr_alloc + 1);
            p = SvPVX(hdr_sv) + pos;
        }
        memcpy(p, hp, hlen); p += hlen;
        *p++ = ':'; *p++ = ' ';
        memcpy(p, vp, vlen); p += vlen;
        *p++ = '\r'; *p++ = '\n';
    }

    // The 128-byte slack is not reserved (a later header may consume it) and
    // the tail is written unchecked, so re-verify at the final position.
    {
        STRLEN pos = p - SvPVX(hdr_sv);
        if (unlikely(pos + tail_len > hdr_alloc)) {
            hdr_alloc = pos + tail_len;
            SvGROW(hdr_sv, hdr_alloc + 1);
            p = SvPVX(hdr_sv) + pos;
        }
    }

    if (unlikely(emit_zero_cl)) {
        memcpy(p, "Content-Length: 0\r\n", 19); p += 19;
    }

    memcpy(p, DATE_BUF, DATE_HEADER_LENGTH); p += DATE_HEADER_LENGTH;
    if (likely(c->is_http11)) {
        if (!c->is_keepalive) {
            memcpy(p, "Connection: close\r\n", 19); p += 19;
        }
    } else if (c->is_keepalive) {
        memcpy(p, "Connection: keep-alive\r\n", 24); p += 24;
    }

    if (streaming) {
        if (c->is_http11 && !has_content_length && c->auto_cl) {
            memcpy(p, "Transfer-Encoding: chunked\r\n\r\n", 30); p += 30;
            c->use_chunked = 1;
        }
        else {
            *p++ = '\r'; *p++ = '\n';
            c->use_chunked = 0;
        }
    }

    SvCUR_set(hdr_sv, p - SvPVX(hdr_sv));
    *p = '\0';

    {
        struct iomatrix *m = next_iomatrix(c);
        unsigned idx = m->count++;
        m->iov[idx].iov_base = SvPVX(hdr_sv);
        m->iov[idx].iov_len = SvCUR(hdr_sv);
        m->sv[idx] = hdr_sv;
        c->wbuf_len += SvCUR(hdr_sv);
    }

    // Not for RESPOND_NORMAL: conn_write_ready writes immediately and would
    // finish the response before write_whole_body queues the body.
    if (streaming)
        conn_write_ready(c);
}

static size_t
feersum_write_whole_body (pTHX_ struct feer_conn *c, SV *body)
{
    size_t RETVAL;
    bool body_is_string = 0;
    STRLEN cur;

    if (c->responding != RESPOND_NORMAL)
        croak("can't use write_whole_body when in streaming mode");

#ifdef FEERSUM_HAS_H2
    if (unlikely(c->is_h2_stream)) {
        SV *body_sv;
        if (!SvOK(body)) {
            body_sv = sv_2mortal(newSVpvs(""));
        } else if (SvROK(body)) {
            SV *refd = SvRV(body);
            if (SvOK(refd) && !SvROK(refd)) {
                body_sv = refd;
            } else if (SvTYPE(refd) == SVt_PVAV) {
                AV *ab = (AV*)refd;
                body_sv = sv_2mortal(newSVpvs(""));
                I32 amax = av_len(ab);
                /* Per-element bytes like H1's add_sv_to_wbuf: sv_catsv would
                 * upgrade the accumulator and re-encode earlier elements. */
                for (I32 i = 0; i <= amax; i++) {
                    SV *sv = fetch_av_normal(aTHX_ ab, i);
                    if (sv) {
                        STRLEN el_len;
                        const char *el = SvPV(sv, el_len);
                        if (unlikely(SvUTF8(sv))) {
                            SV *t = feer_bytes_mortal(el, el_len);
                            el = SvPVX(t); el_len = SvCUR(t);
                        }
                        sv_catpvn(body_sv, el, el_len);
                    }
                }
            } else {
                croak("body must be a scalar, scalar reference or array reference");
            }
        } else {
            body_sv = body;
        }
        return feersum_h2_write_whole_body(aTHX_ c, body_sv);
    }
#endif

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

    SV *body_scalar = NULL;
    if (body_is_string) {
        body_scalar = body;
    } else {
        AV *abody = (AV*)SvRV(body);
        if (av_len(abody) == 0) {
            SV *elem = fetch_av_normal(aTHX_ abody, 0);
            if (elem) body_scalar = elem;
        }
    }

    // Fast path: append CL (and a small body) to the header buffer, one iovec.
    if (likely(c->auto_cl) && !unlikely(c->app_content_length)
        && body_scalar && c->wbuf_rinq) {
        struct iomatrix *m = (struct iomatrix *)c->wbuf_rinq->prev->ref;
        unsigned last = m->count - 1;
        SV *hdr_sv = m->sv[last];

        // the tail entry must be start_response's writable header SV
        if (unlikely(!hdr_sv || SvREADONLY(hdr_sv)))
            goto whole_body_slow_path;

        STRLEN body_len;
        const char *body_ptr = SvPV(body_scalar, body_len);
        if (unlikely(SvUTF8(body_scalar))) {
            /* bytes on the wire; Content-Length must count the same form */
            SV *t = feer_bytes_mortal(body_ptr, body_len);
            body_scalar = t;
            body_ptr = SvPVX(t); body_len = SvCUR(t);
        }
        char cl_buf[48];
        int cl_len = format_content_length(cl_buf, body_len);
        STRLEN hdr_cur = SvCUR(hdr_sv);

        if (likely(body_len <= 4096)) {
            // HEAD advertises the body's Content-Length but emits no bytes
            STRLEN emit_len = unlikely(c->no_resp_body) ? 0 : body_len;
            STRLEN total = hdr_cur + cl_len + emit_len;
            SvGROW(hdr_sv, total + 1);
            char *p = SvPVX(hdr_sv) + hdr_cur;
            memcpy(p, cl_buf, cl_len); p += cl_len;
            if (likely(emit_len)) { memcpy(p, body_ptr, emit_len); p += emit_len; }
            *p = '\0';
            SvCUR_set(hdr_sv, total);
            m->iov[last].iov_len = total;
            c->wbuf_len += cl_len + emit_len;
        } else {
            SvGROW(hdr_sv, hdr_cur + cl_len + 1);
            memcpy(SvPVX(hdr_sv) + hdr_cur, cl_buf, cl_len);
            SvCUR_set(hdr_sv, hdr_cur + cl_len);
            SvPVX(hdr_sv)[hdr_cur + cl_len] = '\0';
            m->iov[last].iov_len = hdr_cur + cl_len;
            c->wbuf_len += cl_len;
            if (likely(!c->no_resp_body))
                add_sv_to_wbuf(c, body_scalar);
        }
        m->iov[last].iov_base = SvPVX(hdr_sv);
        RETVAL = body_len;
    }
    else { whole_body_slow_path:;
        SV *cl_sv;
        struct iovec *cl_iov;
        /* app_content_length: HEAD with the app's own Content-Length already in the block */
        if (likely(c->auto_cl) && !unlikely(c->app_content_length))
            add_placeholder_to_wbuf(c, &cl_sv, &cl_iov);
        else
            add_crlf_to_wbuf(c);

        if (unlikely(!c->auto_cl)) {
            RETVAL = 0;
        }
        else if (body_is_string) {
            // HEAD: measure the (downgraded) length, queue nothing
            if (unlikely(c->no_resp_body)) {
                const char *bp = SvPV(body, cur);
                if (unlikely(SvUTF8(body)))
                    cur = SvCUR(feer_bytes_mortal(bp, cur));
            }
            else
                cur = add_sv_to_wbuf(c,body);
            RETVAL = cur;
        }
        else {
            AV *abody = (AV*)SvRV(body);
            I32 amax = av_len(abody);
            RETVAL = 0;
            for (I32 i = 0; i <= amax; i++) {
                SV *sv = fetch_av_normal(aTHX_ abody, i);
                if (unlikely(!sv)) continue;
                if (unlikely(c->no_resp_body)) {
                    const char *bp = SvPV(sv, cur);
                    if (unlikely(SvUTF8(sv)))
                        cur = SvCUR(feer_bytes_mortal(bp, cur));
                }
                else
                    cur = add_sv_to_wbuf(c,sv);
                trace("body part i=%d sv=%p cur=%"Sz_uf"\n", i, sv, (Sz)cur);
                RETVAL += cur;
            }
        }

        if (likely(c->auto_cl) && !unlikely(c->app_content_length)) {
            char cl_buf[48];
            int cl_len = format_content_length(cl_buf, RETVAL);
            sv_setpvn(cl_sv, cl_buf, cl_len);
            update_wbuf_placeholder(c, cl_sv, cl_iov);
        }
    }

    change_responding_state(c, RESPOND_SHUTDOWN);
    conn_write_ready(c);
    return RETVAL;
}

static void
call_died (pTHX_ struct feer_conn *c, const char *cb_type)
{
    dSP;
#if DEBUG >= 1
    trace("An error was thrown in the %s callback: %-p\n",cb_type,ERRSV);
#endif
    PUSHMARK(SP);
    mXPUSHs(newSVsv(ERRSV));
    PUTBACK;
    call_pv("Feersum::DIED", G_DISCARD|G_EVAL|G_VOID);
    SPAGAIN;

    /* A mid-response die may leave an unterminated block on the wire: no reuse. */
    if (unlikely(c->responding > RESPOND_NOT_STARTED
                 && c->responding < RESPOND_SHUTDOWN))
        c->is_keepalive = 0;

    /* No 500 onto an app-owned stream or mid-response on H1; H2 still needs
     * the call, where it becomes RST_STREAM. */
    if (!c->io_taken
        && (likely(c->responding == RESPOND_NOT_STARTED)
#ifdef FEERSUM_HAS_H2
            || c->is_h2_stream
#endif
    ))
        respond_with_server_error(c, "Request handler exception\n", 500);
    sv_setsv(ERRSV, &PL_sv_undef);
}

/* Balance the pin new_feer_conn_handle took.  On a die, a still-streaming
 * writer whose last ref unwound is sealed dirty so the truncation shows. */
static void
feersum_writer_unpin(pTHX_ struct feer_conn *c, bool errored)
{
    SV *pin = c->pinned_writer;
    if (likely(!pin)) return;
    c->pinned_writer = NULL;
    if (unlikely(errored) && SvREFCNT(pin) == 1
        && c->responding == RESPOND_STREAMING) {
        trace("callback died mid-stream, sealing dirty fd=%d c=%p\n", c->fd, c);
        c->is_keepalive = 0;    /* also done in call_died; keep both */
        change_responding_state(c, RESPOND_SHUTDOWN);
        conn_write_ready(c);
    }
    SvREFCNT_dec(pin);
}

static void
feersum_start_psgi_streaming(pTHX_ struct feer_conn *c, SV *streamer)
{
    dSP;
    bool errored;
    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    mXPUSHs(feer_conn_2sv(c));
    XPUSHs(streamer);
    PUTBACK;
    c->pin_writer = 1;
    call_method("_initiate_streaming_psgi", G_DISCARD|G_EVAL|G_VOID);
    c->pin_writer = 0;
    SPAGAIN;
    errored = SvTRUE(ERRSV) ? TRUE : FALSE;
    if (unlikely(errored)) {
        call_died(aTHX_ c, "PSGI stream initiator");
    }
    feersum_writer_unpin(aTHX_ c, errored);
    PUTBACK;
    FREETMPS;
    LEAVE;
}

static void
feersum_handle_psgi_response(
    pTHX_ struct feer_conn *c, SV *ret, bool can_recurse)
{
    if (unlikely(!SvOK(ret) || !SvROK(ret))) {
        sv_setpvs(ERRSV, "Invalid PSGI response (expected reference)");
        call_died(aTHX_ c, "PSGI request");
        return;
    }

    if (unlikely(!IsArrayRef(ret))) {
        if (likely(can_recurse)) {
            trace("PSGI response non-array, c=%p ret=%p\n", c, ret);
            feersum_start_psgi_streaming(aTHX_ c, ret);
        }
        else {
            sv_setpvs(ERRSV, "PSGI attempt to recurse in a streaming callback");
            call_died(aTHX_ c, "PSGI request");
        }
        return;
    }

    AV *psgi_triplet = (AV*)SvRV(ret);
    /* before av_len: a tied FETCHSIZE die has no G_EVAL above it here */
    psgi_triplet = feersum_flatten_magical_av(aTHX_ psgi_triplet);
    if (unlikely(!psgi_triplet)) {
        call_died(aTHX_ c, "PSGI request");
        return;
    }
    if (unlikely(av_len(psgi_triplet)+1 != 3)) {
        sv_setpvs(ERRSV, "Invalid PSGI array response (expected triplet)");
        call_died(aTHX_ c, "PSGI request");
        return;
    }

    trace("PSGI response triplet, c=%p av=%p\n", c, psgi_triplet);
    SV **msg_p  = av_fetch(psgi_triplet,0,0);
    SV **hdrs_p = av_fetch(psgi_triplet,1,0);
    SV **body_p = av_fetch(psgi_triplet,2,0);
    if (unlikely(!msg_p || !hdrs_p || !body_p)) {
        sv_setpvs(ERRSV, "Invalid PSGI array response (NULL element)");
        call_died(aTHX_ c, "PSGI request");
        return;
    }
    SV *msg  = *msg_p;
    SV *hdrs = *hdrs_p;
    SV *body = *body_p;

    AV *headers;
    if (IsArrayRef(hdrs))
        headers = (AV*)SvRV(hdrs);
    else {
        sv_setpvs(ERRSV, "PSGI Headers must be an array-ref");
        call_died(aTHX_ c, "PSGI request");
        return;
    }
    headers = feersum_flatten_headers(aTHX_ headers);
    if (unlikely(!headers)) {
        call_died(aTHX_ c, "PSGI request");
        return;
    }

    /* No G_EVAL is above this path (call_sv's has already exited), so every
     * croak feersum_start_response would raise must be screened here. */
    if (unlikely((av_len(headers) + 1) % 2 == 1)) {
        sv_setpvs(ERRSV, "PSGI headers must be an even-length array");
        call_died(aTHX_ c, "PSGI request");
        return;
    }
    {
        const char *serr = feersum_check_psgi_status(aTHX_ msg);
        if (unlikely(serr)) {
            sv_setpv(ERRSV, serr);
            call_died(aTHX_ c, "PSGI request");
            return;
        }
    }
    /* A psgi.input poll_cb that died mid-handler has already answered. */
    if (unlikely(c->responding != RESPOND_NOT_STARTED)) {
        sv_setpvs(ERRSV, "PSGI app returned a response after the response had "
                         "already started");
        call_died(aTHX_ c, "PSGI request");
        return;
    }
    if (unlikely(c->io_taken)) {
        sv_setpvs(ERRSV, "PSGI app took psgix.io and then returned a response; "
                         "call return_from_psgix_io first");
        call_died(aTHX_ c, "PSGI request");
        return;
    }
    {
        const char *err = feersum_check_response_framing(aTHX_ msg, headers);
        if (unlikely(err)) {
            sv_setpv(ERRSV, err);
            call_died(aTHX_ c, "PSGI request");
            return;
        }
    }

    /* start_response can finish the response itself (H2 reset, bodiless H2
     * stream); writing a body then would croak with no G_EVAL above. */
    if (likely(IsArrayRef(body))) {
        SV *flat = feersum_flatten_magical_body(aTHX_ body);
        if (unlikely(!flat)) {
            call_died(aTHX_ c, "PSGI request");
            return;
        }
        body = flat;
        feersum_start_response(aTHX_ c, msg, headers, 0, 1);
        if (unlikely(c->responding >= RESPOND_SHUTDOWN)) return;
        feersum_write_whole_body(aTHX_ c, body);
    }
    // Only an object, glob or IO answers getline(); screen before start_response
    else if (likely(SvROK(body)
                    && (sv_isobject(body)
                        || SvTYPE(SvRV(body)) == SVt_PVGV
                        || SvTYPE(SvRV(body)) == SVt_PVIO))) {
        feersum_start_response(aTHX_ c, msg, headers, 1, 1);
        if (unlikely(c->responding >= RESPOND_SHUTDOWN)) return;
        c->poll_write_cb = newSVsv(body);
        c->poll_write_cb_is_io_handle = 1;
        conn_write_ready(c);
    }
    else {
        sv_setpvs(ERRSV, "Expected PSGI array-ref or IO::Handle-like body");
        call_died(aTHX_ c, "PSGI request");
        return;
    }
}

static int
feersum_close_handle (pTHX_ struct feer_conn *c, bool is_writer)
{
    int RETVAL;
    if (is_writer) {
        trace("close writer fd=%d, c=%p, refcnt=%d\n", c->fd, c, SvREFCNT(c->self));
        if (c->poll_write_cb) {
            SV *tmp = c->poll_write_cb;
            c->poll_write_cb = NULL;  // NULL before dec: DESTROY can re-enter
            c->poll_write_cb_is_io_handle = 0;
            SvREFCNT_dec(tmp);
        }
#ifdef FEERSUM_HAS_H2
        if (unlikely(c->is_h2_stream)) {
            if (c->responding < RESPOND_SHUTDOWN) {
                feersum_h2_close_write(aTHX_ c);
                change_responding_state(c, RESPOND_SHUTDOWN);
            }
        } else
#endif
        if (c->responding < RESPOND_SHUTDOWN) {
            finish_wbuf(c);
            change_responding_state(c, RESPOND_SHUTDOWN);
            conn_write_ready(c);
        }
        RETVAL = 1;
    }
    else {
        trace("close reader fd=%d, c=%p\n", c->fd, c);
        if (c->poll_read_cb) {
            SV *tmp = c->poll_read_cb;
            c->poll_read_cb = NULL;
            SvREFCNT_dec(tmp);
        }
        /* Body fully received: leave rbuf (it may hold a pipelined request)
         * and the socket alone, or keepalive breaks. */
        if (c->receiving == RECEIVE_SHUTDOWN) {
            RETVAL = 0;
        }
        else {
            /* Still arriving: the app is abandoning an upload. */
            if (c->rbuf) {
                SvREFCNT_dec(c->rbuf);
                c->rbuf = NULL;
            }
            /* fd_given_away: a SHUT_RD here would kill the app's own reads */
            if (c->fd >= 0 && !c->fd_given_away
#ifdef FEERSUM_HAS_H2
                && !c->is_h2_stream
#endif
            )
                RETVAL = shutdown(c->fd, SHUT_RD);
            else
                RETVAL = -1;
            change_receiving_state(c, RECEIVE_SHUTDOWN);
        }
    }

    SvREFCNT_dec(c->self);  // drop the handle's ref to the conn
    return RETVAL;
}

static SV*
feersum_conn_guard(pTHX_ struct feer_conn *c, SV *guard)
{
    if (guard) {
        /* Install before dec: the old guard's DESTROY may register a new one. */
        SV *old = c->ext_guard;
        c->ext_guard = SvOK(guard) ? newSVsv(guard) : NULL;
        SvREFCNT_dec(old);
    }
    return c->ext_guard ? newSVsv(c->ext_guard) : &PL_sv_undef;
}

static void
call_request_callback (struct feer_conn *c)
{
    dTHX;
    dSP;
    int flags;
    struct feer_server *server = c->server;
    c->in_callback++;
    SvREFCNT_inc_void_NN(c->self);
    server->total_requests++;

    /* req->method/uri point into rbuf, which the next request overwrites */
    if (unlikely(server->access_log_cb_cv != NULL) && likely(c->req != NULL)) {
        SvREFCNT_dec(c->log_method);
        SvREFCNT_dec(c->log_uri);
        c->log_method = newSVpvn(c->req->method, c->req->method_len);
        c->log_uri = newSVpvn(c->req->uri, c->req->uri_len);
        c->req_start = ev_now(feersum_ev_loop);
    }

    if (unlikely(server->max_requests)
        && server->total_requests >= server->max_requests
        && !server->shutting_down)
    {
        server->max_requests = 0;      /* one-shot */
        server->retire_pending = 1;    /* check_cb drains at a loop boundary */
    }

    trace("request callback c=%p\n", c);

    ENTER;
    SAVETMPS;
    PUSHMARK(SP);

    if (server->request_cb_is_psgi) {
        HV *env = feersum_env(aTHX_ c);
        mXPUSHs(newRV_noinc((SV*)env));
        flags = G_EVAL|G_SCALAR;
    }
    else {
        mXPUSHs(feer_conn_2sv(c));
        flags = G_DISCARD|G_EVAL|G_VOID;
    }

    PUTBACK;
    c->pin_writer = 1;
    int returned = call_sv(server->request_cb_cv, flags);
    c->pin_writer = 0;
    SPAGAIN;

    trace("called request callback, errsv? %d\n", SvTRUE(ERRSV) ? 1 : 0);

    bool req_cb_errored = SvTRUE(ERRSV) ? TRUE : FALSE;
    if (unlikely(req_cb_errored)) {
        call_died(aTHX_ c, "request");
        // call_sv(G_SCALAR) pushed undef before unwinding and call_died ran
        // more Perl: re-fetch SP and pop it, or one slot leaks per die.
        SPAGAIN;
        if (returned > 0) SP -= returned;
        PUTBACK;
        returned = 0;
    }
    /* Before the PSGI streamer runs: it pins its own writer. */
    feersum_writer_unpin(aTHX_ c, req_cb_errored);

    SV *psgi_response = NULL;
    if (server->request_cb_is_psgi && likely(returned >= 1)) {
        psgi_response = POPs;
        SvREFCNT_inc_void_NN(psgi_response);
    }

    trace("leaving request callback\n");
    PUTBACK;

    if (psgi_response) {
        feersum_handle_psgi_response(aTHX_ c, psgi_response, 1); // can_recurse
        SvREFCNT_dec(psgi_response);
    }

    c->in_callback--;
    SvREFCNT_dec(c->self);

    FREETMPS;
    LEAVE;
}

static void
call_poll_callback (struct feer_conn *c, bool is_write)
{
    dTHX;
    dSP;

    SV *cb = (is_write) ? c->poll_write_cb : c->poll_read_cb;

    if (unlikely(cb == NULL)) return;

    c->in_callback++;

    trace("%s poll callback c=%p cbrv=%p\n",
        is_write ? "write" : "read", c, cb);

    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    SV *hdl = new_feer_conn_handle(aTHX_ c, is_write);
    mXPUSHs(hdl);
    PUTBACK;
    call_sv(cb, G_DISCARD|G_EVAL|G_VOID);
    SPAGAIN;

    trace("called %s poll callback, errsv? %d\n",
        is_write ? "write" : "read", SvTRUE(ERRSV) ? 1 : 0);

    if (unlikely(SvTRUE(ERRSV))) {
        /* A callback left installed after a die re-arms and spins forever. */
        SV **cb_slot = is_write ? &c->poll_write_cb : &c->poll_read_cb;
        if (*cb_slot) {
            SV *tmp = *cb_slot;
            *cb_slot = NULL;
            if (is_write) c->poll_write_cb_is_io_handle = 0;
            SvREFCNT_dec(tmp);
        }
        call_died(aTHX_ c, is_write ? "write poll" : "read poll");
        /* call_died cannot 500 mid-response; end it rather than hang. */
        if (c->responding > RESPOND_NOT_STARTED
            && c->responding < RESPOND_SHUTDOWN) {
            c->is_keepalive = 0;
            change_responding_state(c, RESPOND_SHUTDOWN);
        }
    }

    // Neutralise the mortal handle before FREETMPS, or its DESTROY closes the
    // connection.  SvUVX is already 0 if the callback called close().
    {
        SV *inner = SvRV(hdl);
        if (SvUVX(inner)) {
            SvUVX(inner) = 0;
            SvREFCNT_dec(c->self);  // balance new_feer_conn_handle's inc
        }
    }

    trace("leaving %s poll callback\n", is_write ? "write" : "read");
    PUTBACK;
    FREETMPS;
    LEAVE;

    c->in_callback--;
}

static void
pump_io_handle (struct feer_conn *c)
{
    dTHX;
    dSP;

    if (unlikely(c->poll_write_cb == NULL)) return;

    c->in_callback++;

    trace("pump io handle %d\n", c->fd);

    SV *old_rs = PL_rs;
    SvREFCNT_inc_simple_void(old_rs);

    ENTER;
    SAVETMPS;

    /* Mortalise after SAVETMPS, or the FREETMPS below cannot reap it. */
    PL_rs = sv_2mortal(newRV_noinc(newSViv(IO_PUMP_BUFSZ)));
    sv_setsv(get_sv("/", GV_ADD), PL_rs);

    // HEAD or a bodiless status: a pumped chunk would go out unframed.  Fall
    // through returned=0 into the EOF branch, which closes and finishes.
    int returned;
    if (unlikely(c->no_resp_body || !c->auto_cl)) {
        returned = 0;
    }
    else {
        PUSHMARK(SP);
        XPUSHs(c->poll_write_cb);
        PUTBACK;
        returned = call_method("getline", G_SCALAR|G_EVAL);
        SPAGAIN;
    }

    trace("called getline on io handle fd=%d errsv=%d returned=%d\n",
        c->fd, SvTRUE(ERRSV) ? 1 : 0, returned);

    /* pop before the error exit, which would otherwise leave it on the stack */
    SV *ret = (returned > 0) ? POPs : NULL;

    if (unlikely(SvTRUE(ERRSV))) {
        /* Restore PL_rs first: Feersum::DIED is Perl code that may read $/ */
        PL_rs = old_rs;
        sv_setsv(get_sv("/", GV_ADD), old_rs);
        call_died(aTHX_ c, "getline on io handle");
        if (c->poll_write_cb) {
            SvREFCNT_dec(c->poll_write_cb);
            c->poll_write_cb = NULL;
        }
        c->poll_write_cb_is_io_handle = 0;
        goto done_pump_io;
    }

    if (ret && SvMAGICAL(ret))
        ret = sv_2mortal(newSVsv(ret));

    if (unlikely(!ret || !SvOK(ret))) {
        PUSHMARK(SP);
        XPUSHs(c->poll_write_cb);
        PUTBACK;
        call_method("close", G_VOID|G_DISCARD|G_EVAL);
        SPAGAIN;

        if (unlikely(SvTRUE(ERRSV))) {
            trouble("Couldn't close body IO handle: %-p\n", ERRSV);
            sv_setsv(ERRSV, &PL_sv_undef);
        }

        SvREFCNT_dec(c->poll_write_cb);
        c->poll_write_cb = NULL;
        c->poll_write_cb_is_io_handle = 0;
        finish_wbuf(c);
        change_responding_state(c, RESPOND_SHUTDOWN);

        goto done_pump_io;
    }

    if (c->use_chunked)
        add_chunk_sv_to_wbuf(c, ret);
    else
        add_raw_body_to_wbuf(c, ret);

done_pump_io:
    trace("leaving pump io handle %d\n", c->fd);

    // Restore PL_rs before FREETMPS reaps the mortal RV it points at.
    PL_rs = old_rs;
    sv_setsv(get_sv("/", GV_ADD), old_rs);
    SvREFCNT_dec(old_rs);

    PUTBACK;
    FREETMPS;
    LEAVE;

    c->in_callback--;
}

static int
psgix_io_svt_get (pTHX_ SV *sv, MAGIC *mg)
{
    dSP;

    struct feer_conn *c = sv_2feer_conn(mg->mg_obj);
    trace("invoking psgix.io magic for fd=%d\n", c->fd);

    sv_unmagic(sv, PERL_MAGIC_ext);

#ifdef FEERSUM_HAS_H2
    if (c->is_h2_stream) {
        struct feer_h2_stream *stream = H2_STREAM_FROM_PC(c);
        if (!stream || !stream->is_tunnel) {
            /* Set undef, not croak: magic-get fires from innocent env reads,
             * and the IV left behind would read as a truthy handle. */
            trouble("psgix.io: not supported on regular H2 streams fd=%d\n", c->fd);
            sv_setsv(sv, &PL_sv_undef);
            return 0;
        }
        h2_tunnel_auto_accept(aTHX_ c, stream);
        /* Re-fetch stream: auto_accept -> session_send may have freed it */
        stream = H2_STREAM_FROM_PC(c);
        if (!stream) {
            trouble("psgix.io: stream freed during auto_accept fd=%d\n", c->fd);
            sv_setsv(sv, &PL_sv_undef);
            return 0;
        }
        feer_h2_setup_tunnel(aTHX_ stream);
        if (!stream->tunnel_established) {
            trouble("psgix.io: tunnel setup failed fd=%d\n", c->fd);
            struct feer_conn *parent = stream->parent;
            SvREFCNT_inc_void_NN(parent->self);
            h2_submit_rst(parent->h2_session, stream->stream_id,
                          NGHTTP2_INTERNAL_ERROR);
            feer_h2_session_send(parent);
            SvREFCNT_dec(parent->self);
            sv_setsv(sv, &PL_sv_undef);
            return 0;
        }

        ENTER;
        SAVETMPS;
        PUSHMARK(SP);
        XPUSHs(sv);
        mXPUSHs(newSViv(stream->tunnel_sv1));
        PUTBACK;

        call_pv("Feersum::Connection::_raw", G_VOID|G_DISCARD|G_EVAL);
        SPAGAIN;

        /* new_from_fd can return undef without dying (fdopen failure) */
        if (unlikely(SvTRUE(ERRSV) || !SvROK(sv))) {
            call_died(aTHX_ c, "psgix.io H2 tunnel magic");
            sv_setsv(sv, &PL_sv_undef);
        } else {
            SV *io_glob = SvRV(sv);
            GvSV(io_glob) = newRV_inc(c->self);
            stream->tunnel_sv1 = -1;
        }

        c->io_taken = 1;
        PUTBACK;
        FREETMPS;
        LEAVE;
        return 0;
    }
#endif

#ifdef FEERSUM_HAS_TLS
    if (c->tls) {
        feer_tls_setup_tunnel(c);
        if (!c->tls_tunnel) {
            trouble("psgix.io: TLS tunnel setup failed fd=%d\n", c->fd);
            sv_setsv(sv, &PL_sv_undef);
            return 0;
        }

        ENTER;
        SAVETMPS;
        PUSHMARK(SP);
        XPUSHs(sv);
        mXPUSHs(newSViv(c->tls_tunnel_sv1));
        PUTBACK;

        call_pv("Feersum::Connection::_raw", G_VOID|G_DISCARD|G_EVAL);
        SPAGAIN;

        if (unlikely(SvTRUE(ERRSV) || !SvROK(sv))) {
            call_died(aTHX_ c, "psgix.io TLS tunnel magic");
            sv_setsv(sv, &PL_sv_undef);
            /* _raw did not take the fd; conn cleanup closes it */
        } else {
            SV *io_glob = SvRV(sv);
            GvSV(io_glob) = newRV_inc(c->self);
            c->tls_tunnel_sv1 = -1;
        }

        c->io_taken = 1;
        stop_read_timer(c);
        stop_write_timer(c);
        PUTBACK;
        FREETMPS;
        LEAVE;
        return 0;
    }
#endif

    ENTER;
    SAVETMPS;

    PUSHMARK(SP);
    XPUSHs(sv);
    mXPUSHs(newSViv(c->fd));
    PUTBACK;

    call_pv("Feersum::Connection::_raw", G_VOID|G_DISCARD|G_EVAL);
    SPAGAIN;

    if (unlikely(SvTRUE(ERRSV) || !SvROK(sv))) {
        call_died(aTHX_ c, "psgix.io magic");
        sv_setsv(sv, &PL_sv_undef);
    }
    else {
        SV *io_glob   = SvRV(sv);
        GvSV(io_glob) = newRV_inc(c->self);

        feer_hand_out_raw_fd(aTHX_ c, io_glob, "psgix.io");
    }

    FREETMPS;
    LEAVE;

    return 0;
}

#ifdef FEERSUM_HAS_H2
static void
h2_tunnel_auto_accept(pTHX_ struct feer_conn *c, struct feer_h2_stream *stream)
{
    if (c->responding != RESPOND_NOT_STARTED)
        return;
    AV *empty_hdr = newAV();
    SV *status_sv = newSVpvs("200");
    feersum_start_response(aTHX_ c, status_sv, empty_hdr, 1, 1);
    SvREFCNT_dec(status_sv);
    SvREFCNT_dec((SV *)empty_hdr);
    /* start_response -> session_send may have freed the stream */
    stream = H2_STREAM_FROM_PC(c);
    if (stream)
        stream->tunnel_swallow_response = 1;
}

/* One getline per pump iteration: draining synchronously never reads a
 * WINDOW_UPDATE and buffers the whole body.  Returns 0 at EOF. */
static int
pump_h2_io_step(pTHX_ struct feer_conn *c)
{
    dSP;
    if (unlikely(!c->poll_write_cb)) return 0;

    /* in_callback makes feersum_h2_write_chunk buffer: a flush here re-enters
     * this pump through h2_check_stream_poll_cbs and frees the stream. */
    c->in_callback++;

    SV *old_rs = PL_rs;
    SvREFCNT_inc_simple_void(old_rs);
    ENTER;
    SAVETMPS;
    PL_rs = sv_2mortal(newRV_noinc(newSViv(IO_PUMP_BUFSZ)));
    sv_setsv(get_sv("/", GV_ADD), PL_rs);

    PUSHMARK(SP);
    XPUSHs(c->poll_write_cb);
    PUTBACK;
    int returned = call_method("getline", G_SCALAR|G_EVAL);
    SPAGAIN;

    /* pop before the error exit, which would otherwise leave it on the stack */
    SV *ret = (returned > 0) ? POPs : NULL;

    if (unlikely(SvTRUE(ERRSV))) {
        PL_rs = old_rs;
        sv_setsv(get_sv("/", GV_ADD), old_rs);
        call_died(aTHX_ c, "getline on H2 io handle");
        SvREFCNT_dec(c->poll_write_cb);
        c->poll_write_cb = NULL;
        c->poll_write_cb_is_io_handle = 0;
        PUTBACK; FREETMPS; LEAVE;
        SvREFCNT_dec(old_rs);
        c->in_callback--;
        feersum_h2_close_write(aTHX_ c);
        return 0;
    }

    if (ret && SvMAGICAL(ret)) ret = sv_2mortal(newSVsv(ret));

    int more = 1;
    if (unlikely(!ret || !SvOK(ret))) {   /* undef is EOF; q{} is not */
        PUSHMARK(SP);
        XPUSHs(c->poll_write_cb);
        PUTBACK;
        call_method("close", G_VOID|G_DISCARD|G_EVAL);
        SPAGAIN;
        if (unlikely(SvTRUE(ERRSV))) {
            trouble("Couldn't close body IO handle: %-p\n", ERRSV);
            sv_setsv(ERRSV, &PL_sv_undef);
        }
        SvREFCNT_dec(c->poll_write_cb);
        c->poll_write_cb = NULL;
        c->poll_write_cb_is_io_handle = 0;
        more = 0;
    }
    else {
        feersum_h2_write_chunk(aTHX_ c, ret);
    }

    PL_rs = old_rs;
    sv_setsv(get_sv("/", GV_ADD), old_rs);
    PUTBACK; FREETMPS; LEAVE;
    SvREFCNT_dec(old_rs);

    c->in_callback--;
    if (!more) feersum_h2_close_write(aTHX_ c);
    return more;
}

static SV*
feersum_env_method_h2(pTHX_ struct feer_conn *c, struct feer_req *r)
{
    if (unlikely(c->is_h2_stream)) {
        struct feer_h2_stream *stream = H2_STREAM_FROM_PC(c);
        if (stream && stream->is_tunnel && stream->h2_protocol)
            return SvREFCNT_inc_simple_NN(method_GET);
    }
    return feersum_env_method(aTHX_ r);
}
#endif
