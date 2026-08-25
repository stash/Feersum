/* TLS 1.3 via picotls: handshake, record layer and the read/write callbacks
 * for TLS connections; plain connections never enter this file. */

#ifdef FEERSUM_HAS_TLS

static ptls_iovec_t tls_alpn_protos[] = {
#ifdef FEERSUM_HAS_H2
    { (uint8_t *)ALPN_H2 + 1, 2 },
#endif
    { (uint8_t *)ALPN_HTTP11 + 1, 8 },
};

static ptls_iovec_t tls_alpn_h1_only[] = {
    { (uint8_t *)ALPN_HTTP11 + 1, 8 },
};

static int
negotiate_alpn(ptls_t *tls, const ptls_iovec_t *protos, size_t num_protos,
               ptls_on_client_hello_parameters_t *params)
{
    size_t i, j;
    for (i = 0; i < num_protos; i++) {
        for (j = 0; j < params->negotiated_protocols.count; j++) {
            if (params->negotiated_protocols.list[j].len == protos[i].len &&
                memcmp(params->negotiated_protocols.list[j].base, protos[i].base,
                       protos[i].len) == 0) {
                ptls_set_negotiated_protocol(tls,
                    (const char *)protos[i].base, protos[i].len);
                return 0;
            }
        }
    }
    /* RFC 7301 3.2: ALPN offered with no overlap must abort, not fall back */
    if (params->negotiated_protocols.count > 0)
        return PTLS_ALERT_NO_APPLICATION_PROTOCOL;

    return 0;
}

static void
sni_lookup(ptls_t *tls, ptls_on_client_hello_parameters_t *params)
{
    struct feer_conn *c = *(struct feer_conn **)ptls_get_data_ptr(tls);
    struct feer_listen *lsnr = c ? c->listener : NULL;
    if (!lsnr || lsnr->n_sni_entries == 0 || !params->server_name.base)
        return;

    /* hostname is pre-lowered at registration; ASCII-only per RFC 6066 */
    size_t name_len = params->server_name.len;
    for (int i = 0; i < lsnr->n_sni_entries; i++) {
        struct feer_sni_entry *e = &lsnr->sni_entries[i];
        if (strlen(e->hostname) == name_len &&
            str_case_eq_fixed(e->hostname,
                              (const char *)params->server_name.base, name_len)) {
            /* Pin the chosen context (a set_tls rotation may free it) and
             * release the old one last: ptls_set_context touches the context
             * it replaces. */
            struct feer_tls_ctx_ref *old = c->tls_ctx_ref;
            e->ctx_ref->refcount++;
            c->tls_ctx_ref = e->ctx_ref;
            ptls_set_context(tls, e->ctx_ref->ctx);
            feer_tls_ctx_ref_dec(old);
            return;
        }
    }
}

static int
on_client_hello_cb(ptls_on_client_hello_t *self, ptls_t *tls,
                   ptls_on_client_hello_parameters_t *params)
{
    PERL_UNUSED_VAR(self);
    sni_lookup(tls, params);
    return negotiate_alpn(tls, tls_alpn_protos,
        sizeof(tls_alpn_protos) / sizeof(tls_alpn_protos[0]), params);
}

static ptls_on_client_hello_t on_client_hello = { on_client_hello_cb };

static int
on_client_hello_no_h2_cb(ptls_on_client_hello_t *self, ptls_t *tls,
                         ptls_on_client_hello_parameters_t *params)
{
    PERL_UNUSED_VAR(self);
    sni_lookup(tls, params);
    return negotiate_alpn(tls, tls_alpn_h1_only,
        sizeof(tls_alpn_h1_only) / sizeof(tls_alpn_h1_only[0]), params);
}

static ptls_on_client_hello_t on_client_hello_no_h2 = { on_client_hello_no_h2_cb };

static ptls_key_exchange_algorithm_t *feer_tls_key_exchanges[] = {
#if PTLS_OPENSSL_HAVE_X25519
    &ptls_openssl_x25519,
#endif
    &ptls_openssl_secp256r1,
    NULL
};

static ptls_cipher_suite_t *feer_tls_cipher_suites[] = {
    &ptls_openssl_aes256gcmsha384,
    &ptls_openssl_aes128gcmsha256,
#if PTLS_OPENSSL_HAVE_CHACHA20_POLY1305
    &ptls_openssl_chacha20poly1305sha256,
#endif
    NULL
};

static ptls_context_t *
feer_tls_create_context(pTHX_ const char *cert_file, const char *key_file, int h2)
{
    ptls_context_t *ctx;
    FILE *fp;
    int ret;

    Newxz(ctx, 1, ptls_context_t);

    ctx->random_bytes = ptls_openssl_random_bytes;
    ctx->get_time = &ptls_get_time;
    ctx->key_exchanges = feer_tls_key_exchanges;
    ctx->cipher_suites = feer_tls_cipher_suites;
    ctx->max_buffer_size = FEER_TLS_MAX_HANDSHAKE_BUF;

    ret = ptls_load_certificates(ctx, cert_file);
    if (ret != 0) {
        warn("Feersum TLS: failed to load certificate from '%s' (error %d)\n",
             cert_file, ret);
        feer_tls_free_context(ctx);
        return NULL;
    }

    fp = fopen(key_file, "r");
    if (!fp) {
        warn("Feersum TLS: failed to open key file '%s': %s\n",
             key_file, strerror(errno));
        goto cert_cleanup;
    }

    /* "" rather than NULL: a NULL passphrase makes OpenSSL prompt on the tty */
    EVP_PKEY *pkey = PEM_read_PrivateKey(fp, NULL, NULL, (void *)"");
    fclose(fp);
    if (!pkey) {
        warn("Feersum TLS: failed to read private key from '%s' "
             "(encrypted keys are not supported)\n", key_file);
        goto cert_cleanup;
    }

    /* picotls's PEM reader loads a truncated certificate as garbage DER without
     * complaint, and nothing else checks that the key matches the leaf */
    if (ctx->certificates.count > 0) {
        const unsigned char *der = ctx->certificates.list[0].base;
        X509 *leaf = d2i_X509(NULL, &der, (long)ctx->certificates.list[0].len);
        if (!leaf) {
            warn("Feersum TLS: certificate in '%s' is not valid DER "
                 "(truncated or corrupt PEM?)\n", cert_file);
            EVP_PKEY_free(pkey);
            goto cert_cleanup;
        }
        if (X509_check_private_key(leaf, pkey) != 1) {
            X509_free(leaf);
            EVP_PKEY_free(pkey);
            warn("Feersum TLS: private key '%s' does not match certificate "
                 "'%s'\n", key_file, cert_file);
            goto cert_cleanup;
        }
        X509_free(leaf);
    }

    ptls_openssl_sign_certificate_t *sign_cert;
    Newx(sign_cert, 1, ptls_openssl_sign_certificate_t);
    if (ptls_openssl_init_sign_certificate(sign_cert, pkey) != 0) {
        Safefree(sign_cert);
        EVP_PKEY_free(pkey);
        warn("Feersum TLS: incompatible private key type in '%s'\n", key_file);
        goto cert_cleanup;
    }
    EVP_PKEY_free(pkey);
    ctx->sign_certificate = &sign_cert->super;

    if (h2)
        ctx->on_client_hello = &on_client_hello;
    else
        ctx->on_client_hello = &on_client_hello_no_h2;

    trace("TLS context created: cert=%s key=%s h2=%d\n", cert_file, key_file, h2);
    return ctx;

cert_cleanup:
    feer_tls_free_context(ctx);
    return NULL;
}

static void
feer_tls_free_context(ptls_context_t *ctx)
{
    if (!ctx) return;
    if (ctx->certificates.list) {
        size_t i;
        for (i = 0; i < ctx->certificates.count; i++)
            free(ctx->certificates.list[i].base);
        free(ctx->certificates.list);
    }
    if (ctx->sign_certificate) {
        ptls_openssl_sign_certificate_t *sign_cert =
            (ptls_openssl_sign_certificate_t *)ctx->sign_certificate;
        ptls_openssl_dispose_sign_certificate(sign_cert);
        Safefree(sign_cert);
    }
    Safefree(ctx);
}

/* Live connections hold a ref, so set_tls rotation or listener slot reuse
 * cannot free a context a ptls_t still points at. */
static struct feer_tls_ctx_ref *
feer_tls_ctx_ref_new(ptls_context_t *ctx)
{
    struct feer_tls_ctx_ref *ref;
    Newx(ref, 1, struct feer_tls_ctx_ref);
    ref->ctx = ctx;
    ref->refcount = 1;
    return ref;
}

static void
feer_tls_ctx_ref_dec(struct feer_tls_ctx_ref *ref)
{
    if (--ref->refcount <= 0) {
        feer_tls_free_context(ref->ctx);
        Safefree(ref);
    }
}

static void
feer_tls_cleanup_listener(struct feer_listen *lsnr)
{
    if (lsnr->tls_ctx_ref) {
        feer_tls_ctx_ref_dec(lsnr->tls_ctx_ref);
        lsnr->tls_ctx_ref = NULL;
    }
    for (int i = 0; i < lsnr->n_sni_entries; i++) {
        Safefree(lsnr->sni_entries[i].hostname);
        feer_tls_ctx_ref_dec(lsnr->sni_entries[i].ctx_ref);
    }
    lsnr->n_sni_entries = 0;
}

static void
feer_tls_init_conn(struct feer_conn *c, struct feer_tls_ctx_ref *ref)
{
    c->tls = ptls_new(ref->ctx, 1 /* is_server */);
    if (unlikely(!c->tls)) {
        trouble("ptls_new failed for fd=%d\n", c->fd);
        return;
    }
    /* read back by sni_lookup */
    *ptls_get_data_ptr(c->tls) = c;
    ref->refcount++;
    c->tls_ctx_ref = ref;
    ptls_buffer_init(&c->tls_wbuf, "", 0);
    c->tls_tunnel_sv0 = -1;
    c->tls_tunnel_sv1 = -1;
}

static void
feer_tls_free_conn(struct feer_conn *c)
{
    if (c->tls) {
        ptls_free(c->tls);
        c->tls = NULL;
    }
    if (c->tls_ctx_ref) {
        feer_tls_ctx_ref_dec(c->tls_ctx_ref);
        c->tls_ctx_ref = NULL;
    }
    ptls_buffer_dispose(&c->tls_wbuf);
    if (c->tls_rbuf) {
        Safefree(c->tls_rbuf);
        c->tls_rbuf = NULL;
        c->tls_rbuf_len = 0;
    }
    if (c->tls_tunnel) {
        ev_io_stop(feersum_ev_loop, &c->tls_tunnel_read_w);
        ev_io_stop(feersum_ev_loop, &c->tls_tunnel_write_w);
        c->tls_tunnel = 0;
        if (c->tls_tunnel_sv0 >= 0) {
            close(c->tls_tunnel_sv0);
            c->tls_tunnel_sv0 = -1;
        }
        if (c->tls_tunnel_sv1 >= 0) {
            close(c->tls_tunnel_sv1);
            c->tls_tunnel_sv1 = -1;
        }
        if (c->tls_tunnel_wbuf) {
            dTHX;
            SvREFCNT_dec(c->tls_tunnel_wbuf);
            c->tls_tunnel_wbuf = NULL;
            c->tls_tunnel_wbuf_pos = 0;
        }
    }
}

/* Returns bytes written (0 if nothing pending), -1 on EAGAIN, -2 on error */
static int
feer_tls_flush_wbuf(struct feer_conn *c)
{
    if (c->tls_wbuf.off == 0)
        return 0;

    ssize_t written = write(c->fd, c->tls_wbuf.base, c->tls_wbuf.off);
    if (written < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
            return -1;
        }
        trace("TLS flush write error fd=%d: %s\n", c->fd, strerror(errno));
        return -2;
    }

    if ((size_t)written < c->tls_wbuf.off) {
        memmove(c->tls_wbuf.base, c->tls_wbuf.base + written,
                c->tls_wbuf.off - written);
        c->tls_wbuf.off -= written;
        return (int)written;
    }

    c->tls_wbuf.off = 0;
    return (int)written;
}


/* TLS tunnel for io()/psgix.io: a socketpair, sv0 Feersum's end, sv1 the app's */

static int
tls_tunnel_write_or_buffer(struct feer_conn *c, const char *data, size_t len)
{
    dTHX;
    if (c->tls_tunnel_sv0 < 0) return -1;

    /* A queued remainder goes first, or this write overtakes it and the app
     * sees its stream out of order. */
    ssize_t nw = 0;
    if (!(c->tls_tunnel_wbuf
          && SvCUR(c->tls_tunnel_wbuf) > c->tls_tunnel_wbuf_pos)) {
        nw = write(c->tls_tunnel_sv0, data, len);
        if (nw == (ssize_t)len)
            return 0;

        if (nw < 0) {
            if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
                return -1;
            nw = 0;
        }
    }

    size_t remaining = len - nw;
    if (!c->tls_tunnel_wbuf) {
        c->tls_tunnel_wbuf = newSV_buf(remaining + 256);
    }

    if (c->tls_tunnel_wbuf_pos > 0) {
        STRLEN remain = SvCUR(c->tls_tunnel_wbuf) - c->tls_tunnel_wbuf_pos;
        if (remain > 0)
            memmove(SvPVX(c->tls_tunnel_wbuf),
                    SvPVX(c->tls_tunnel_wbuf) + c->tls_tunnel_wbuf_pos,
                    remain);
        SvCUR_set(c->tls_tunnel_wbuf, remain);
        c->tls_tunnel_wbuf_pos = 0;
    }

    if (SvCUR(c->tls_tunnel_wbuf) + remaining > FEER_TUNNEL_MAX_WBUF) {
        trouble("TLS tunnel wbuf overflow fd=%d\n", c->fd);
        return -1;
    }

    sv_catpvn(c->tls_tunnel_wbuf, data + nw, remaining);
    if (!ev_is_active(&c->tls_tunnel_write_w))
        ev_io_start(feersum_ev_loop, &c->tls_tunnel_write_w);
    return 0;
}

static int feer_tls_drain_one_record(struct feer_conn *c, ptls_buffer_t *decbuf);

static void
drain_tls_tunnel_rbuf(struct feer_conn *c)
{
    while (c->tls_tunnel && c->tls_rbuf_len > 0) {
        if (ev_is_active(&c->tls_tunnel_write_w))
            break; /* sv[0] full - let write watcher drain first */
        ptls_buffer_t db;
        int drain_rv = feer_tls_drain_one_record(c, &db);
        if (unlikely(drain_rv == -2)) {
            feer_shutdown_conn(c, "TLS receive error (tunnel drain)");
            return;
        }
        if (drain_rv < 0) break;
        if (drain_rv == 1) continue; /* non-data (e.g. KeyUpdate) */
        if (tls_tunnel_write_or_buffer(c, (const char *)db.base, db.off) < 0) {
            ptls_buffer_dispose(&db);
            feer_shutdown_conn(c, "TLS tunnel drain error");
            return;
        }
        ptls_buffer_dispose(&db);
    }
}

/* Stop the watchers (a readable-at-EOF sv0 spins the loop) and close sv0 so
 * the app sees EOF; sv1 belongs to feer_tls_free_conn.  Idempotent. */
static void
feer_tls_tunnel_shutdown(struct feer_conn *c)
{
    if (!c->tls_tunnel) return;
    ev_io_stop(feersum_ev_loop, &c->tls_tunnel_read_w);
    ev_io_stop(feersum_ev_loop, &c->tls_tunnel_write_w);
    if (c->tls_tunnel_sv0 >= 0) {
        close(c->tls_tunnel_sv0);
        c->tls_tunnel_sv0 = -1;
    }
}

static void
tls_tunnel_sv0_read_cb(EV_P_ struct ev_io *w, int revents)
{
    struct feer_conn *c = (struct feer_conn *)w->data;
    PERL_UNUSED_VAR(revents);
    SvREFCNT_inc_void_NN(c->self);

    char buf[FEER_TUNNEL_BUFSZ];
    ssize_t nread = read(c->tls_tunnel_sv0, buf, sizeof(buf));

    if (nread < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
            goto cleanup;
        /* Linux AF_UNIX reports ECONNRESET, not EOF, when sv1 closes with
         * unread inbound bytes; take the EOF path so queued ciphertext is
         * still flushed */
        if (errno != ECONNRESET && errno != EPIPE) {
            feer_shutdown_conn(c, "TLS tunnel read error");
            goto cleanup;
        }
        nread = 0;
    }

    if (nread == 0) {
        /* App closed sv1: flush queued ciphertext before shutting down */
        ev_io_stop(feersum_ev_loop, &c->tls_tunnel_read_w);
        if (c->tls_wbuf.off > 0 && feer_tls_flush_wbuf(c) != -2
            && c->tls_wbuf.off > 0) {
            c->tls_tunnel_eof = 1;
            start_write_watcher(c);
            /* write_timeout is off for a takeover; re-arm now the app is gone */
            ensure_write_timer(c);
            goto cleanup;
        }
        feer_shutdown_conn(c, "TLS tunnel EOF");
        goto cleanup;
    }
    if (feer_tls_send(c, buf, nread) != 0) {
        feer_shutdown_conn(c, "TLS tunnel encrypt error");
        goto cleanup;
    }

    int flush_ret = feer_tls_flush_wbuf(c);
    if (flush_ret == -2) {
        feer_shutdown_conn(c, "TLS tunnel flush error");
        goto cleanup;
    }
    if (c->tls_wbuf.off > 0)
        start_write_watcher(c);

    /* Backpressure: tls_wbuf has no bound of its own, so stop pulling from the
     * app past the cap; try_tls_conn_write re-arms this watcher once the wire
     * catches up. */
    if (unlikely(c->tls_wbuf.off > FEER_TUNNEL_MAX_WBUF))
        ev_io_stop(feersum_ev_loop, &c->tls_tunnel_read_w);

cleanup:
    SvREFCNT_dec(c->self);
}

static void
tls_tunnel_sv0_write_cb(EV_P_ struct ev_io *w, int revents)
{
    PERL_UNUSED_VAR(revents);
    struct feer_conn *c = (struct feer_conn *)w->data;
    SvREFCNT_inc_void_NN(c->self);

    if (!c->tls_tunnel_wbuf ||
        SvCUR(c->tls_tunnel_wbuf) <= c->tls_tunnel_wbuf_pos) {
        ev_io_stop(feersum_ev_loop, &c->tls_tunnel_write_w);
        if (c->tls_tunnel_wbuf) {
            SvCUR_set(c->tls_tunnel_wbuf, 0);
            c->tls_tunnel_wbuf_pos = 0;
        }
        goto cleanup;
    }

    STRLEN avail = SvCUR(c->tls_tunnel_wbuf) - c->tls_tunnel_wbuf_pos;
    const char *ptr = SvPVX(c->tls_tunnel_wbuf) + c->tls_tunnel_wbuf_pos;
    ssize_t nw = write(c->tls_tunnel_sv0, ptr, avail);

    if (nw < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
            goto cleanup;
        feer_shutdown_conn(c, "TLS tunnel write error");
        goto cleanup;
    }

    c->tls_tunnel_wbuf_pos += nw;
    if (c->tls_tunnel_wbuf_pos >= SvCUR(c->tls_tunnel_wbuf)) {
        ev_io_stop(feersum_ev_loop, &c->tls_tunnel_write_w);
        SvCUR_set(c->tls_tunnel_wbuf, 0);
        c->tls_tunnel_wbuf_pos = 0;

        if (c->tls_rbuf_len > 0)
            drain_tls_tunnel_rbuf(c);
    }

cleanup:
    SvREFCNT_dec(c->self);
}

static void
feer_tls_setup_tunnel(struct feer_conn *c)
{
    if (c->tls_tunnel) return;

    int sv[2];
    if (feer_socketpair_nb(sv) < 0) {
        trouble("socketpair/fcntl failed for TLS tunnel fd=%d: %s\n",
                c->fd, strerror(errno));
        return;
    }

    c->tls_tunnel_sv0 = sv[0];
    c->tls_tunnel_sv1 = sv[1];

    ev_io_init(&c->tls_tunnel_read_w, tls_tunnel_sv0_read_cb, sv[0], EV_READ);
    c->tls_tunnel_read_w.data = (void *)c;
    ev_io_start(feersum_ev_loop, &c->tls_tunnel_read_w);

    ev_io_init(&c->tls_tunnel_write_w, tls_tunnel_sv0_write_cb, sv[0], EV_WRITE);
    c->tls_tunnel_write_w.data = (void *)c;

    c->tls_tunnel = 1;

    if (c->rbuf && SvOK(c->rbuf) && SvCUR(c->rbuf) > 0) {
        dTHX;
        if (tls_tunnel_write_or_buffer(c, SvPVX(c->rbuf), SvCUR(c->rbuf)) < 0) {
            trouble("TLS tunnel rbuf flush failed fd=%d\n", c->fd);
        }
        SvCUR_set(c->rbuf, 0);
    }

    start_read_watcher(c);

    trace("TLS tunnel socketpair established fd=%d sv0=%d sv1=%d\n",
          c->fd, sv[0], sv[1]);
}

/* Precondition: c->tls_rbuf is NULL, or the old buffer leaks */
INLINE_UNLESS_DEBUG static void
feer_tls_save_rbuf(struct feer_conn *c, const uint8_t *src, size_t len)
{
    Newx(c->tls_rbuf, len, uint8_t);
    memcpy(c->tls_rbuf, src, len);
    c->tls_rbuf_len = len;
}

/* Record the alert owed to the peer; safe_close_conn sends it in place of
 * close_notify */
INLINE_UNLESS_DEBUG static void
feer_tls_note_alert(struct feer_conn *c, int ret)
{
    if (PTLS_ERROR_GET_CLASS(ret) == PTLS_ERROR_CLASS_SELF_ALERT)
        c->tls_fatal_alert = (uint8_t)PTLS_ERROR_TO_ALERT(ret);
}

/* Returns 0: app data in decbuf (caller disposes); 1: non-data record
 * (KeyUpdate, NewSessionTicket), retry while tls_rbuf remains; -1: nothing
 * left or peer close_notify; -2: undecryptable, caller must tear down */
static int
feer_tls_drain_one_record(struct feer_conn *c, ptls_buffer_t *decbuf)
{
    if (!c->tls_rbuf || c->tls_rbuf_len == 0) return -1;

    uint8_t *saved = c->tls_rbuf;
    size_t saved_len = c->tls_rbuf_len;
    c->tls_rbuf = NULL;
    c->tls_rbuf_len = 0;

    ptls_buffer_init(decbuf, "", 0);
    size_t consumed = saved_len;
    int ret = ptls_receive(c->tls, decbuf, saved, &consumed);
    if (ret == 0 && consumed < saved_len)
        feer_tls_save_rbuf(c, saved + consumed, saved_len - consumed);
    Safefree(saved);

    if (ret != 0) {
        ptls_buffer_dispose(decbuf);
        /* close_notify arrives as an error but must not tear down here: a
         * request coalesced ahead of it is decrypted and still owed a response */
        if (ret == PTLS_ERROR_CLASS_PEER_ALERT + PTLS_ALERT_CLOSE_NOTIFY)
            return -1;
        feer_tls_note_alert(c, ret);
        return -2;
    }
    if (decbuf->off == 0) {
        ptls_buffer_dispose(decbuf);
        return 1;
    }
    return 0;
}

/* Appends decbuf and every further complete record to rbuf; disposes decbuf.
 * Returns bytes appended; *failed is set when a record would not decrypt */
static size_t
feer_tls_rbuf_append_drain(struct feer_conn *c, ptls_buffer_t *decbuf, int *failed)
{
    dTHX;
    size_t added = 0;
    if (decbuf->off > 0) {
        if (!c->rbuf)
            c->rbuf = newSV_buf(decbuf->off + READ_BUFSZ);
        sv_catpvn(c->rbuf, (const char *)decbuf->base, decbuf->off);
        added = decbuf->off;
    }
    ptls_buffer_dispose(decbuf);
    ptls_buffer_t db;
    int drain_rv;
    while ((drain_rv = feer_tls_drain_one_record(c, &db)) >= 0) {
        if (drain_rv == 1) continue; /* non-data TLS record */
        if (!c->rbuf)
            c->rbuf = newSV_buf(db.off + READ_BUFSZ);
        sv_catpvn(c->rbuf, (const char *)db.base, db.off);
        added += db.off;
        ptls_buffer_dispose(&db);
    }
    if (unlikely(drain_rv == -2))
        *failed = 1;
    return added;
}

#ifdef FEERSUM_HAS_H2
static void
drain_h2_tls_records(struct feer_conn *c)
{
    dTHX;
    while (c->h2_session) {
        ptls_buffer_t db;
        int drain_rv = feer_tls_drain_one_record(c, &db);
        if (unlikely(drain_rv == -2)) {
            stop_all_watchers(c);
            safe_close_conn(c, "TLS receive error (H2 drain)");
            break;
        }
        if (drain_rv < 0) break;
        if (drain_rv == 1) continue; /* non-data TLS record */
        feer_h2_session_recv(c, db.base, db.off);
        ptls_buffer_dispose(&db);
        if (c->fd < 0) break;
        h2_session_send_and_poll(aTHX_ c);
        restart_read_timer(c);
    }
}
#endif

static void
try_tls_conn_read(EV_P_ ev_io *w, int revents)
{
    struct feer_conn *c = (struct feer_conn *)w->data;
    PERL_UNUSED_VAR(revents);
    PERL_UNUSED_VAR(loop);

    dTHX;
    SvREFCNT_inc_void_NN(c->self);
    feer_conn_set_busy(c);
    trace("tls_conn_read fd=%d hs_done=%d\n", c->fd, c->tls_handshake_done);

    ssize_t got_n = 0;

    if (unlikely(c->pipelined)) goto tls_pipelined;

    if (unlikely(!c->tls)) {
        trouble("tls_conn_read: no TLS context fd=%d\n", c->fd);
        change_receiving_state(c, RECEIVE_SHUTDOWN);
        stop_all_watchers(c);
        safe_close_conn(c, "no TLS context");
        goto tls_read_cleanup;
    }

    uint8_t rawbuf[TLS_RAW_BUFSZ];
    ssize_t nread = read(c->fd, rawbuf, sizeof(rawbuf));

    if (nread == 0) {
        trace("TLS EOF fd=%d\n", c->fd);
        /* Peer half-close on a tunnel: relay EOF to the app via SHUT_WR and
         * keep the write side alive; closing here drops what the app still
         * owes the peer */
        if (c->tls_tunnel && c->tls_tunnel_sv0 >= 0 && !c->tls_tunnel_eof) {
            ev_io_stop(feersum_ev_loop, &c->read_ev_io);
            shutdown(c->tls_tunnel_sv0, SHUT_WR);
            goto tls_read_cleanup;
        }
        change_receiving_state(c, RECEIVE_SHUTDOWN);
        stop_all_watchers(c);
        safe_close_conn(c, "TLS EOF");
        goto tls_read_cleanup;
    }

    if (nread < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
            goto tls_read_cleanup;
        trace("TLS read error fd=%d: %s\n", c->fd, strerror(errno));
        change_receiving_state(c, RECEIVE_SHUTDOWN);
        stop_all_watchers(c);
        safe_close_conn(c, "TLS read error");
        goto tls_read_cleanup;
    }

    /* A PROXY header precedes the ClientHello in plaintext */
    if (unlikely(c->receiving == RECEIVE_PROXY_HEADER)) {
        if (!c->rbuf) {
            c->rbuf = newSV_buf(nread + 256);
        }
        sv_catpvn(c->rbuf, (const char *)rawbuf, nread);

        int ret = try_parse_proxy_header(c);
        if (ret == -1) {
            feer_shutdown_conn(c, "Invalid PROXY header on TLS listener");
            change_receiving_state(c, RECEIVE_SHUTDOWN);
            goto tls_read_cleanup;
        }
        if (ret == -2) goto tls_read_cleanup; /* need more data */

        STRLEN remaining = SvCUR(c->rbuf) - ret;

        feer_clear_remote_cache(c);

        change_receiving_state(c, RECEIVE_HEADERS);

        if (remaining > 0) {
            /* the leftover ClientHello may exceed rawbuf, so park it in tls_rbuf */
            feer_tls_save_rbuf(c, (const uint8_t *)SvPVX(c->rbuf) + ret, remaining);
            nread = 0;
        }
        SvREFCNT_dec(c->rbuf);
        c->rbuf = NULL;
        if (remaining == 0)
            goto tls_read_cleanup;
    }

    /* Prepend the unconsumed tail of the previous read (a record split across reads) */
    uint8_t *inbuf = rawbuf;
    size_t inlen = (size_t)nread;
    uint8_t *merged = NULL;

    if (c->tls_rbuf_len > 0) {
        if (nread > 0) {
            inlen = c->tls_rbuf_len + (size_t)nread;
            Newx(merged, inlen, uint8_t);
            memcpy(merged, c->tls_rbuf, c->tls_rbuf_len);
            memcpy(merged + c->tls_rbuf_len, rawbuf, (size_t)nread);
            inbuf = merged;
            Safefree(c->tls_rbuf);
        } else {
            /* PROXY leftover only - transfer ownership to merged, no copy */
            merged = c->tls_rbuf;
            inbuf = merged;
            inlen = c->tls_rbuf_len;
        }
        c->tls_rbuf = NULL;
        c->tls_rbuf_len = 0;
    }

    if (!c->tls_handshake_done) {
        size_t consumed = inlen;

        int ret = ptls_handshake(c->tls, &c->tls_wbuf, inbuf, &consumed, NULL);

        if (c->tls_wbuf.off > 0) {
            int flush_ret = feer_tls_flush_wbuf(c);
            if (flush_ret == -2) {
                trouble("TLS flush error during handshake fd=%d\n", c->fd);
                if (merged) Safefree(merged);
                stop_all_watchers(c);
                safe_close_conn(c, "TLS handshake flush error");
                goto tls_read_cleanup;
            }
            if (flush_ret == -1 || c->tls_wbuf.off > 0) {
                start_write_watcher(c);
            }
        }

        if (ret == 0) {
            c->tls_handshake_done = 1;
            trace("TLS handshake complete fd=%d\n", c->fd);

            const char *proto = ptls_get_negotiated_protocol(c->tls);
            if (proto && strcmp(proto, "h2") == 0) {
                trace("TLS ALPN: h2 negotiated fd=%d\n", c->fd);
#ifdef FEERSUM_HAS_H2
                feer_h2_init_session(c);
#endif
            } else {
                trace("TLS ALPN: http/1.1 (or none) fd=%d\n", c->fd);
            }

            if (consumed < inlen) {
                size_t remaining = inlen - consumed;
                uint8_t *extra = inbuf + consumed;

#ifdef FEERSUM_HAS_H2
                if (c->h2_session) {
                    ptls_buffer_t decbuf;
                    ptls_buffer_init(&decbuf, "", 0);
                    size_t dec_consumed = remaining;
                    int dec_ret = ptls_receive(c->tls, &decbuf, extra, &dec_consumed);
                    if (dec_ret != 0) {
                        ptls_buffer_dispose(&decbuf);
                        if (merged) Safefree(merged);
                        feer_tls_note_alert(c, dec_ret);
                        stop_all_watchers(c);
                        safe_close_conn(c, "TLS receive error (post-handshake H2)");
                        goto tls_read_cleanup;
                    }
                    if (dec_consumed < remaining)
                        feer_tls_save_rbuf(c, extra + dec_consumed, remaining - dec_consumed);
                    if (decbuf.off > 0) {
                        feer_h2_session_recv(c, decbuf.base, decbuf.off);
                    }
                    ptls_buffer_dispose(&decbuf);
                    if (c->fd < 0) {
                        if (merged) Safefree(merged);
                        goto tls_read_cleanup;
                    }
                    h2_session_send_and_poll(aTHX_ c);
                    restart_read_timer(c);

                    drain_h2_tls_records(c);

                    if (merged) Safefree(merged);
                    goto tls_read_cleanup;
                }
#endif
                ptls_buffer_t decbuf;
                ptls_buffer_init(&decbuf, "", 0);
                size_t dec_consumed = remaining;
                int dec_ret = ptls_receive(c->tls, &decbuf, extra, &dec_consumed);
                if (dec_ret != 0) {
                    ptls_buffer_dispose(&decbuf);
                    if (merged) Safefree(merged);
                    feer_tls_note_alert(c, dec_ret);
                    stop_all_watchers(c);
                    safe_close_conn(c, "TLS receive error (post-handshake H1)");
                    goto tls_read_cleanup;
                }
                if (dec_consumed < remaining)
                    feer_tls_save_rbuf(c, extra + dec_consumed, remaining - dec_consumed);
                int drain_failed = 0;
                size_t added = feer_tls_rbuf_append_drain(c, &decbuf, &drain_failed);
                if (unlikely(drain_failed)) {
                    if (merged) Safefree(merged);
                    change_receiving_state(c, RECEIVE_SHUTDOWN);
                    stop_all_watchers(c);
                    safe_close_conn(c, "TLS receive error (H1 drain)");
                    goto tls_read_cleanup;
                }
                if (added > 0) {
                    if (merged) Safefree(merged);
                    got_n = (ssize_t)added;
                    goto tls_parse;
                }
            }
        } else if (ret == PTLS_ERROR_IN_PROGRESS) {
            trace("TLS handshake in progress fd=%d\n", c->fd);
            if (consumed < inlen)
                feer_tls_save_rbuf(c, inbuf + consumed, inlen - consumed);
        } else {
            trace("TLS handshake error fd=%d ret=%d\n", c->fd, ret);
            stop_all_watchers(c);
            safe_close_conn(c, "TLS handshake error");
        }
        if (merged) Safefree(merged);
        goto tls_read_cleanup;
    }

    {
        ptls_buffer_t decbuf;
        ptls_buffer_init(&decbuf, "", 0);
        size_t consumed = inlen;
        int ret = ptls_receive(c->tls, &decbuf, inbuf, &consumed);

        if (ret == 0 && consumed < inlen)
            feer_tls_save_rbuf(c, inbuf + consumed, inlen - consumed);

        if (merged) Safefree(merged);

        if (ret != 0) {
            trace("TLS receive error fd=%d ret=%d\n", c->fd, ret);
            ptls_buffer_dispose(&decbuf);
            feer_tls_note_alert(c, ret);
            change_receiving_state(c, RECEIVE_SHUTDOWN);
            stop_all_watchers(c);
            safe_close_conn(c, "TLS receive error");
            goto tls_read_cleanup;
        }

        if (decbuf.off == 0) {
            ptls_buffer_dispose(&decbuf);
            goto tls_read_cleanup; /* non-data record (KeyUpdate etc.) */
        }

#ifdef FEERSUM_HAS_H2
        if (c->h2_session) {
            feer_h2_session_recv(c, decbuf.base, decbuf.off);
            ptls_buffer_dispose(&decbuf);
            if (c->fd < 0) goto tls_read_cleanup;
            h2_session_send_and_poll(aTHX_ c);
            restart_read_timer(c);

            drain_h2_tls_records(c);

            goto tls_read_cleanup;
        }
#endif

        if (c->tls_tunnel) {
            if (tls_tunnel_write_or_buffer(c, (const char *)decbuf.base, decbuf.off) < 0) {
                ptls_buffer_dispose(&decbuf);
                feer_shutdown_conn(c, "TLS tunnel write error");
                goto tls_read_cleanup;
            }
            ptls_buffer_dispose(&decbuf);

            /* Records coalesced in tls_rbuf would otherwise wait for the next read event */
            drain_tls_tunnel_rbuf(c);

            goto tls_read_cleanup;
        }

        int drain_failed = 0;
        got_n = (ssize_t)feer_tls_rbuf_append_drain(c, &decbuf, &drain_failed);
        if (unlikely(drain_failed)) {
            change_receiving_state(c, RECEIVE_SHUTDOWN);
            stop_all_watchers(c);
            safe_close_conn(c, "TLS receive error (H1 drain)");
            goto tls_read_cleanup;
        }
    }
    goto tls_parse;

tls_pipelined:
    got_n = c->pipelined;
    c->pipelined = 0;

tls_parse:
    restart_read_timer(c);
    begin_request_headers(c);

    if (likely(c->receiving <= RECEIVE_HEADERS)) {
        int parse_ret = try_parse_http(c, (size_t)got_n);
        if (parse_ret == -1) {
            /* picohttpparser returns -1 for both; only the header cap leaves
             * num_headers at MAX_HEADERS */
            if (unlikely(c->req && c->req->num_headers >= MAX_HEADERS))
                respond_with_server_error(c, "Too many header fields\n", 431);
            else
                respond_with_server_error(c, "Malformed request\n", 400);
            finish_receiving(c);
            goto tls_read_cleanup;
        }
        if (parse_ret == -2) {
            if (unlikely(SvCUR(c->rbuf) > c->cached_max_read_buf)) {
                trace("tls header buffer too large %d: %"Sz_uf" > %"Sz_uf"\n",
                    c->fd, (Sz)SvCUR(c->rbuf), (Sz)c->cached_max_read_buf);
                respond_with_server_error(c,
                    "Request header fields too large\n", 431);
                finish_receiving(c);
            }
            goto tls_read_cleanup;
        }
        /* parse_ret is the header block size; SvCUR may already include body bytes */
        if (unlikely((STRLEN)parse_ret > c->cached_max_read_buf)) {
            trace("tls header block too large %d: %"Sz_uf" > %"Sz_uf"\n",
                c->fd, (Sz)parse_ret, (Sz)c->cached_max_read_buf);
            respond_with_server_error(c,
                "Request header fields too large\n", 431);
            finish_receiving(c);
            goto tls_read_cleanup;
        }
        if (!process_request_headers(c, parse_ret))
            finish_receiving(c);
    }
    else if (likely(c->receiving == RECEIVE_BODY)) {
        c->received_cl += got_n;
        if (c->received_cl >= c->expected_cl) {
            sched_request_callback(c);
            finish_receiving(c);
        }
    }
    else if (c->receiving == RECEIVE_CHUNKED) {
        int ret = try_parse_chunked(c);
        if (ret == -2) {
            /* -2 is the size cap, not a protocol error */
            respond_with_server_error(c, "Request body too large\n", 413);
            finish_receiving(c);
        }
        else if (ret == -1) {
            respond_with_server_error(c, "Malformed chunked encoding\n", 400);
            finish_receiving(c);
        }
        else if (ret == 0) {
            sched_request_callback(c);
            finish_receiving(c);
        }
        else if (unlikely(SvCUR(c->rbuf) > c->cached_max_read_buf)) {
            /* ret == 1: still need more, but rbuf is already past the cap */
            trace("tls chunked buffer too large %d: %"Sz_uf" > %"Sz_uf"\n",
                c->fd, (Sz)SvCUR(c->rbuf), (Sz)c->cached_max_read_buf);
            respond_with_server_error(c, "Request too large\n", 413);
            finish_receiving(c);
        }
        /* ret == 1: need more data, watcher stays active */
    }
    else if (c->receiving == RECEIVE_STREAMING) {
        c->received_cl += got_n;
        if (c->poll_read_cb) {
            call_poll_callback(c, 0);
        }
        if (c->receiving >= RECEIVE_SHUTDOWN) {
            finish_receiving(c);
            goto tls_read_cleanup;
        }
        if (c->expected_cl > 0 && c->received_cl >= c->expected_cl)
            finish_receiving(c);
    }

tls_read_cleanup:
    SvREFCNT_dec(c->self);
}

static void
try_tls_conn_write(EV_P_ ev_io *w, int revents)
{
    struct feer_conn *c = (struct feer_conn *)w->data;
    PERL_UNUSED_VAR(revents);
    PERL_UNUSED_VAR(loop);

    dTHX;
    SvREFCNT_inc_void_NN(c->self);
    trace("tls_conn_write fd=%d\n", c->fd);

    if (unlikely(!c->tls)) {
        trouble("tls_conn_write: no TLS context fd=%d\n", c->fd);
        stop_write_watcher(c);
        goto tls_write_cleanup;
    }

    if (c->tls_wbuf.off > 0) {
        int flush_ret = feer_tls_flush_wbuf(c);
        if (flush_ret == -1) goto tls_write_again;
        if (flush_ret == -2) goto tls_write_error;
        /* Once the body is fully encrypted this is the only progress point;
         * without it write_timeout reaps a slow but steady reader */
        if (flush_ret > 0) restart_write_timer(c);
        if (c->tls_wbuf.off > 0) goto tls_write_again;
    }

#ifdef FEERSUM_HAS_H2
    /* The last H2 stream closed during shutdown and its response has only now
     * reached the wire; linger so it is delivered before the close */
    if (unlikely(c->h2_close_pending) && c->tls_wbuf.off == 0) {
        c->h2_close_pending = 0;
        c->want_linger_close = 1;
        feer_shutdown_conn(c, "last H2 stream closed during shutdown");
        goto tls_write_cleanup;
    }
#endif

    /* The app closed its tunnel end and the last ciphertext has now gone out. */
    if (unlikely(c->tls_tunnel_eof)) {
        c->tls_tunnel_eof = 0;
        feer_shutdown_conn(c, "TLS tunnel EOF drained");
        goto tls_write_cleanup;
    }

    /* wire caught up: resume the tunnel reader paused at the backpressure cap */
    if (unlikely(c->tls_tunnel) && c->tls_tunnel_sv0 >= 0
        && !ev_is_active(&c->tls_tunnel_read_w))
        ev_io_start(feersum_ev_loop, &c->tls_tunnel_read_w);

#ifdef FEERSUM_HAS_H2
    if (c->h2_session) {
        h2_session_send_and_poll(aTHX_ c);
        if (c->tls_wbuf.off > 0) {
            int flush_ret = feer_tls_flush_wbuf(c);
            if (flush_ret == -1) goto tls_write_again;
            if (flush_ret == -2) goto tls_write_error;
            if (flush_ret > 0) restart_write_timer(c);
        }
        if (c->tls_wbuf.off == 0) {
            /* a pump stopped on its iteration budget: keep the watcher so the
             * next loop iteration re-enters it, nothing else would */
            if (unlikely(c->h2_pump_pending)) {
                c->h2_pump_pending = 0;
            }
            /* stop the deadline too, or an idle conn is reaped write_timeout
             * after its last byte */
            else {
                stop_write_watcher(c);
                stop_write_timer(c);
            }
        } else
            goto tls_write_again;
        goto tls_write_cleanup;
    }
#endif

    if (c->wbuf_rinq && c->cached_wbuf_low_water > 0
        && c->wbuf_len <= c->cached_wbuf_low_water
        && c->responding == RESPOND_STREAMING && c->poll_write_cb) {
        if (c->poll_write_cb_is_io_handle)
            pump_io_handle(c);
        else
            call_poll_callback(c, 1);
    }

    /* wbuf_rinq before sendfile: headers first */
    if (c->wbuf_rinq) {
        struct iomatrix *m;
        while ((m = (struct iomatrix *)rinq_shift(&c->wbuf_rinq)) != NULL) {
            unsigned int i;
            for (i = 0; i < m->count; i++) {
                if (m->iov[i].iov_len == 0) continue;

                c->wbuf_len -= m->iov[i].iov_len;

                int ret = ptls_send(c->tls, &c->tls_wbuf,
                                    m->iov[i].iov_base, m->iov[i].iov_len);
                if (ret != 0) {
                    unsigned int j;
                    trouble("ptls_send error fd=%d ret=%d\n", c->fd, ret);
                    for (j = 0; j < m->count; j++) SvREFCNT_dec(m->sv[j]);
                    IOMATRIX_FREE(m);
                    goto tls_write_error;
                }
            }

            for (i = 0; i < m->count; i++) SvREFCNT_dec(m->sv[i]);
            IOMATRIX_FREE(m);

            /* Refill only once the wire has taken everything: an IO::Handle
             * body pumps to EOF, so refilling on an unflushed buffer piles the
             * whole encrypted file into tls_wbuf */
            if (c->cached_wbuf_low_water > 0
                && c->wbuf_len <= c->cached_wbuf_low_water
                && c->responding == RESPOND_STREAMING && c->poll_write_cb) {
                int lw_flush = feer_tls_flush_wbuf(c);
                if (unlikely(lw_flush == -2)) goto tls_write_error;
                if (c->tls_wbuf.off == 0) {
                    if (c->poll_write_cb_is_io_handle)
                        pump_io_handle(c);
                    else
                        call_poll_callback(c, 1);
                }
            }
        }

        int flush_ret = feer_tls_flush_wbuf(c);
        if (flush_ret == -1) goto tls_write_again;
        if (flush_ret == -2) goto tls_write_error;
        if (flush_ret > 0) restart_write_timer(c);
        /* tls_write_finished needs tls_wbuf empty; falling through with a
         * remainder leaves nothing armed to drain it */
        if (c->tls_wbuf.off > 0) goto tls_write_again;
    }

    if (c->sendfile_fd >= 0 && c->sendfile_remain > 0) {
        uint8_t filebuf[TLS_RAW_BUFSZ];
        size_t to_read = c->sendfile_remain;
        if (to_read > sizeof(filebuf)) to_read = sizeof(filebuf);

        ssize_t file_nread = pread(c->sendfile_fd, filebuf, to_read, c->sendfile_off);
        if (file_nread < 0) {
            if (errno == EINTR)
                goto tls_write_again;
            trouble("TLS pread(sendfile_fd) fd=%d: %s\n", c->fd, strerror(errno));
            CLOSE_SENDFILE_FD(c);
            /* body truncated: the connection cannot be reused */
            c->is_keepalive = 0;
            change_responding_state(c, RESPOND_SHUTDOWN);
            goto tls_write_finished;
        }
        if (file_nread == 0) {
            CLOSE_SENDFILE_FD(c);
            /* file shrank mid-transfer: body is short of the committed
             * Content-Length, so the connection cannot be reused */
            c->is_keepalive = 0;
            change_responding_state(c, RESPOND_SHUTDOWN);
            goto tls_write_finished;
        }

        int ret = ptls_send(c->tls, &c->tls_wbuf, filebuf, file_nread);
        if (ret != 0) {
            trouble("ptls_send(sendfile) error fd=%d ret=%d\n", c->fd, ret);
            CLOSE_SENDFILE_FD(c);
            goto tls_write_error;
        }

        c->sendfile_off += file_nread;
        c->sendfile_remain -= file_nread;

        if (c->sendfile_remain == 0) {
            CLOSE_SENDFILE_FD(c);
        }

        {
            int sf_flush_ret = feer_tls_flush_wbuf(c);
            if (sf_flush_ret == -1) goto tls_write_again;
            if (sf_flush_ret == -2) goto tls_write_error;
        }
        /* without this write_timeout reaps a long sendfile mid-file */
        if (file_nread > 0)
            restart_write_timer(c);
        if (c->sendfile_remain > 0 || c->tls_wbuf.off > 0)
            goto tls_write_again;
        goto tls_write_finished;
    }

tls_write_finished:
    if ((!c->wbuf_rinq || (c->cached_wbuf_low_water > 0
         && c->wbuf_len <= c->cached_wbuf_low_water))
        && c->sendfile_fd < 0 && c->tls_wbuf.off == 0) {
        if (c->responding == RESPOND_SHUTDOWN || c->responding == RESPOND_NORMAL) {
            handle_keepalive_or_close(c, try_tls_conn_read);
        } else if (c->responding == RESPOND_STREAMING && c->poll_write_cb) {
            unsigned int writes_before = c->poll_writes_seen;
            if (c->poll_write_cb_is_io_handle)
                pump_io_handle(c);
            else
                call_poll_callback(c, 1 /* is_write */);
            /* pure decline: park and pace, as try_conn_write does */
            if (!c->wbuf_rinq && c->tls_wbuf.off == 0
                && c->responding == RESPOND_STREAMING && c->poll_write_cb
                && c->poll_writes_seen == writes_before) {
                if (unlikely(peer_is_gone(c))) {
                    trace("TLS poll_cb declined and the peer is gone %d\n", c->fd);
                    feer_shutdown_conn(c, "poll_cb decline, peer gone");
                }
                else
                    feersum_poll_retry_park(c);
            }
            else {
                /* a paced-retry entry has no watcher armed, and pump_io_handle
                 * buffers without arming one */
                start_write_watcher(c);
            }
        } else if (c->responding == RESPOND_STREAMING) {
            stop_write_watcher(c);
            stop_write_timer(c);
        } else if (c->responding == RESPOND_NOT_STARTED) {
            /* tunnel or handshake flush drained; stop the deadline too, or an
             * established tunnel is reaped write_timeout after its last byte */
            stop_write_watcher(c);
            stop_write_timer(c);
        }
    }
    goto tls_write_cleanup;

tls_write_again:
    /* conn_write_ready() also enters here directly, so the watcher is not
     * necessarily armed */
    start_write_watcher(c);
    ensure_write_timer(c);
    goto tls_write_cleanup;

tls_write_error:
    feer_shutdown_conn(c, "TLS write error");

tls_write_cleanup:
    SvREFCNT_dec(c->self);
}

static int
feer_tls_send(struct feer_conn *c, const void *data, size_t len)
{
    if (!c->tls || len == 0) return 0;

    int ret = ptls_send(c->tls, &c->tls_wbuf, data, len);
    if (ret != 0) {
        trouble("feer_tls_send error fd=%d ret=%d\n", c->fd, ret);
        return -1;
    }
    return 0;
}

#endif /* FEERSUM_HAS_TLS */
