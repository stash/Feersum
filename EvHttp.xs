#include "EVAPI.h"
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <errno.h>

#include "ppport.h"

#include "picohttpparser/picohttpparser.c"

#define MAX_HEADERS 128

struct ev_io_mybuf;
struct ev_io_mybuf {
    struct ev_io rd;
    struct ev_io wr;

    char *r_buf;
    size_t r_offset;
    size_t r_len;

    char *w_buf;
    size_t w_offset;
    size_t w_len;

    size_t body_offset;

    const char* method;
    size_t method_len;
    const char* path; 
    size_t path_len;
    int minor_version;
    size_t num_headers;
    struct phr_header headers[MAX_HEADERS];
};

static ev_io accept_w;
static ev_prepare ep;

static void
try_client_write(EV_P_ struct ev_io *w, int revents);
static void
try_client_read(EV_P_ struct ev_io *w, int revents);

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

static struct ev_io_mybuf *
new_ev_io_mybuf (EV_P_ int client_fd)
{
    struct ev_io_mybuf *b = malloc(sizeof(struct ev_io_mybuf));
    setnonblock(client_fd);

    b->r_buf = b->w_buf = NULL;
    b->r_offset = b->w_offset = 0;
    b->r_len = b->w_len = 0;

    ev_io_init(&b->rd, try_client_read, client_fd, EV_READ);
    ev_io_init(&b->wr, try_client_write, client_fd, EV_WRITE);
    b->rd.data = (void *)b;
    b->wr.data = (void *)b;
}

static void
free_ev_io_mybuf (struct ev_io_mybuf *b)
{
    if (b->r_buf) free(b->r_buf);
    if (b->w_buf) free(b->w_buf);
    free(b);
}

static void
prepare_cb (EV_P_ ev_prepare *w, int revents)
{
    warn("prepare!\n");
    if (!ev_is_active(&accept_w)) {
        ev_io_start(EV_A, &accept_w);
        ev_prepare_stop(EV_A, w);
    }
}

static void
try_client_write(EV_P_ struct ev_io *w, int revents)
{
    struct ev_io_mybuf *b = (struct ev_io_mybuf *)w->data;
    ssize_t wrote;

    warn("going to write %d\n",w->fd);
    wrote = write(w->fd, b->w_buf + b->w_offset, b->w_len - b->w_offset);
    if (wrote == -1) {
        if (errno == EAGAIN) goto try_write_again;
        perror("try_client_write");
        goto try_write_error;
    }

    b->w_offset += wrote;
    if (b->w_len - b->w_offset == 0) {
        warn("All done with %d\n",w->fd);
        ev_io_stop(EV_A, w);
        free_ev_io_mybuf(b);
    }
    return;

try_write_error:
    ev_io_stop(EV_A, w);
    close(w->fd);
    free_ev_io_mybuf(b);
    return;

try_write_again:
    if (!ev_is_active(w)) {
        warn("going to try write again %d\n",w->fd);
        ev_io_start(EV_A, w);
    }
    return;
}

static int
try_parse_http(struct ev_io_mybuf *b, size_t last_len)
{
    b->num_headers = MAX_HEADERS;
    return phr_parse_request(b->r_buf, b->r_len,
        &b->method, &b->method_len,
        &b->path, &b->path_len, &b->minor_version,
        b->headers, &b->num_headers, 
        last_len);
}

#define READ_CHUNK 4096

static void
try_client_read(EV_P_ ev_io *w, int revents)
{
    struct ev_io_mybuf *b = (struct ev_io_mybuf *)w->data;
    int attempts = 0;

    warn("try read %d\n",w->fd);

    if (b->r_len == 0) {
        b->r_len = 4 * READ_CHUNK;
        b->r_buf = (char *)malloc(b->r_len);
        b->r_offset = 0;
    }

    while (attempts < 20) {
        if (b->r_len - b->r_offset < READ_CHUNK) {
            warn("moar memory %d\n",w->fd);
            // XXX: unbounded, unchecked realloc
            b->r_len += READ_CHUNK;
            b->r_buf = (char *)realloc(b->r_buf, b->r_len);
        }

        attempts ++;
        ssize_t got_n = read(w->fd, b->r_buf + b->r_offset, READ_CHUNK);

        if (got_n == -1) {
            int errno_copy = errno;
            if (errno_copy == EAGAIN) goto try_read_again;
            perror("try_client_read");
            goto try_read_error;
        }
        else if (got_n == 0) {
            warn("EOF %d after %d\n",w->fd,b->r_offset);
            goto try_read_error;
        }
        else {
            warn("read %d %d\n", w->fd, got_n);
            b->r_offset += got_n;
            int ret = try_parse_http(b, (size_t)got_n);
            if (ret == -1) goto try_read_error;
            if (ret == -2) goto try_read_again;
            b->body_offset = (size_t)ret;
            warn("GOT HTTP %d: %.*s", b->r_len, b->body_offset, b->r_buf);
            ev_io_stop(EV_A, w);

            // XXX: here's where we'd check the content length or chunked
            // input stuff, read the body if it's not too big, then bubble
            // that request up to Perl-land.
            // Instead, synthesize a response.
            b->w_buf = strdup("HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nok");
            b->w_len = strlen(b->w_buf);
            try_client_write(EV_A, &b->wr, EV_WRITE);
            break;
        }
    }

    return;

try_read_again:
    if (!ev_is_active(w)) {
        warn("set up read watcher %d\n", w->fd);
        ev_io_start(EV_A,w);
    }
    return;

try_read_error:
    ev_io_stop(EV_A, w);
    close(w->fd);
    free_ev_io_mybuf(b);
    return;
}

static void
accept_cb (EV_P_ ev_io *w, int revents)
{
    int client_fd;
    struct sockaddr_in client_sockaddr;
    socklen_t client_socklen = sizeof(struct sockaddr_in);

    warn("accept! %08x %d\n", revents, revents & EV_READ);
    // TODO: accept as many as possible
    client_fd = accept(w->fd,
                       (struct sockaddr *)&client_sockaddr, &client_socklen);

    struct ev_io_mybuf *b = new_ev_io_mybuf(EV_A, client_fd);
    try_client_read(EV_A, &b->rd, EV_READ);
}

MODULE = Socialtext::EvHttp		PACKAGE = Socialtext::EvHttp		

void
accept_on_socket(fd)
        int fd;
    CODE:
        warn("going to accept on %d\n",fd);
        ev_prepare_init(&ep, prepare_cb);
        ev_prepare_start(EV_DEFAULT, &ep);
        ev_io_init(&accept_w, accept_cb, fd, EV_READ);

BOOT:
    {
        I_EV_API("Socialtext::EvHttp");
    }
