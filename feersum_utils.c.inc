char DATE_BUF[DATE_HEADER_LENGTH+1] = "Date: Thu, 01 Jan 1970 00:00:00 GMT\015\012";

char header_key_buf[HEADER_KEY_BUFSZ] = "HTTP_";

int FEERSUM_FREELIST_MAX = 32;

struct iomatrix *iomatrix_freelist = NULL;
int iomatrix_freelist_count = 0;
struct feer_req *feer_req_freelist = NULL;
int feer_req_freelist_count = 0;

HV *feer_stash, *feer_conn_stash;
HV *feer_conn_reader_stash = NULL, *feer_conn_writer_stash = NULL;
MGVTBL psgix_io_vtbl;
struct feer_server *default_server = NULL;
struct ev_loop *feersum_ev_loop = NULL;
ev_timer date_timer;
int date_timer_refs = 0;
AV *psgi_ver;
SV *psgi_serv10, *psgi_serv11;
SV *method_GET, *method_POST, *method_HEAD, *method_PUT, *method_PATCH, *method_DELETE, *method_OPTIONS;
SV *status_200, *status_201, *status_204, *status_301, *status_302, *status_304;
SV *status_400, *status_404, *status_500;
SV *empty_query_sv;
SV *psgi_env_version = NULL;
SV *psgi_env_errors = NULL;

const unsigned char ascii_lower[256] = {
    0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,
    16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,
    32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,
    48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63,
    64,'a','b','c','d','e','f','g','h','i','j','k','l','m','n','o',
    'p','q','r','s','t','u','v','w','x','y','z',91,92,93,94,95,
    96,97,98,99,100,101,102,103,104,105,106,107,108,109,110,111,
    112,113,114,115,116,117,118,119,120,121,122,123,124,125,126,127,
    128,129,130,131,132,133,134,135,136,137,138,139,140,141,142,143,
    144,145,146,147,148,149,150,151,152,153,154,155,156,157,158,159,
    160,161,162,163,164,165,166,167,168,169,170,171,172,173,174,175,
    176,177,178,179,180,181,182,183,184,185,186,187,188,189,190,191,
    192,193,194,195,196,197,198,199,200,201,202,203,204,205,206,207,
    208,209,210,211,212,213,214,215,216,217,218,219,220,221,222,223,
    224,225,226,227,228,229,230,231,232,233,234,235,236,237,238,239,
    240,241,242,243,244,245,246,247,248,249,250,251,252,253,254,255
};

const unsigned char ascii_upper[256] = {
    0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,
    16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,
    32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,
    48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63,
    64,65,66,67,68,69,70,71,72,73,74,75,76,77,78,79,
    80,81,82,83,84,85,86,87,88,89,90,91,92,93,94,95,
    96,'A','B','C','D','E','F','G','H','I','J','K','L','M','N','O',
    'P','Q','R','S','T','U','V','W','X','Y','Z',123,124,125,126,127,
    128,129,130,131,132,133,134,135,136,137,138,139,140,141,142,143,
    144,145,146,147,148,149,150,151,152,153,154,155,156,157,158,159,
    160,161,162,163,164,165,166,167,168,169,170,171,172,173,174,175,
    176,177,178,179,180,181,182,183,184,185,186,187,188,189,190,191,
    192,193,194,195,196,197,198,199,200,201,202,203,204,205,206,207,
    208,209,210,211,212,213,214,215,216,217,218,219,220,221,222,223,
    224,225,226,227,228,229,230,231,232,233,234,235,236,237,238,239,
    240,241,242,243,244,245,246,247,248,249,250,251,252,253,254,255
};

const unsigned char ascii_upper_dash[256] = {
    0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,
    16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,
    32,33,34,35,36,37,38,39,40,41,42,43,44,'_',46,47,
    48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63,
    64,65,66,67,68,69,70,71,72,73,74,75,76,77,78,79,
    80,81,82,83,84,85,86,87,88,89,90,91,92,93,94,95,
    96,'A','B','C','D','E','F','G','H','I','J','K','L','M','N','O',
    'P','Q','R','S','T','U','V','W','X','Y','Z',123,124,125,126,127,
    128,129,130,131,132,133,134,135,136,137,138,139,140,141,142,143,
    144,145,146,147,148,149,150,151,152,153,154,155,156,157,158,159,
    160,161,162,163,164,165,166,167,168,169,170,171,172,173,174,175,
    176,177,178,179,180,181,182,183,184,185,186,187,188,189,190,191,
    192,193,194,195,196,197,198,199,200,201,202,203,204,205,206,207,
    208,209,210,211,212,213,214,215,216,217,218,219,220,221,222,223,
    224,225,226,227,228,229,230,231,232,233,234,235,236,237,238,239,
    240,241,242,243,244,245,246,247,248,249,250,251,252,253,254,255
};

const unsigned char ascii_lower_dash[256] = {
    0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,
    16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,
    32,33,34,35,36,37,38,39,40,41,42,43,44,'_',46,47,
    48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63,
    64,'a','b','c','d','e','f','g','h','i','j','k','l','m','n','o',
    'p','q','r','s','t','u','v','w','x','y','z',91,92,93,94,95,
    96,97,98,99,100,101,102,103,104,105,106,107,108,109,110,111,
    112,113,114,115,116,117,118,119,120,121,122,123,124,125,126,127,
    128,129,130,131,132,133,134,135,136,137,138,139,140,141,142,143,
    144,145,146,147,148,149,150,151,152,153,154,155,156,157,158,159,
    160,161,162,163,164,165,166,167,168,169,170,171,172,173,174,175,
    176,177,178,179,180,181,182,183,184,185,186,187,188,189,190,191,
    192,193,194,195,196,197,198,199,200,201,202,203,204,205,206,207,
    208,209,210,211,212,213,214,215,216,217,218,219,220,221,222,223,
    224,225,226,227,228,229,230,231,232,233,234,235,236,237,238,239,
    240,241,242,243,244,245,246,247,248,249,250,251,252,253,254,255
};

const unsigned char hex_decode_table[256] = {
    0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,
    0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,
    0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,
    0,1,2,3,4,5,6,7,8,9,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,
    0xFF,10,11,12,13,14,15,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,
    0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,
    0xFF,10,11,12,13,14,15,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,
    0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,
    0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,
    0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,
    0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,
    0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,
    0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,
    0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,
    0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,
    0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF
};

// Returns 0-15 for valid hex digit, -1 for invalid
#define hex_decode(ch) ((int)(signed char)hex_decode_table[(unsigned char)(ch)])

/* neither side pre-lowered; lengths already checked */
INLINE_UNLESS_DEBUG bool
str_case_eq_both(const char *a, const char *b, size_t len)
{
    for (size_t i = 0; i < len; i++)
        if (ascii_lower[(unsigned char)a[i]] != ascii_lower[(unsigned char)b[i]]) return 0;
    return 1;
}

/* a must be a pre-lowered literal; only b is lowered */
INLINE_UNLESS_DEBUG bool
str_case_eq_fixed(const char *a, const char *b, size_t len)
{
    for (size_t i = 0; i < len; i++)
        if (a[i] != ascii_lower[(unsigned char)b[i]]) return 0;
    return 1;
}

/* memmem(3) is not portable and core ninstr is not public API on every perl */
static const char *
feer_memfind(const char *hay, size_t hay_len, const char *needle, size_t n_len)
{
    const char *p = hay, *end;
    if (n_len == 0 || hay_len < n_len) return NULL;
    end = hay + (hay_len - n_len);      /* last valid match start */
    while (p <= end) {
        p = (const char *)memchr(p, needle[0], (size_t)(end - p) + 1);
        if (!p) return NULL;
        if (memcmp(p, needle, n_len) == 0) return p;
        p++;
    }
    return NULL;
}

static void
uri_decode_sv (SV *sv)
{
    STRLEN len;
    char *ptr, *end, *decoded;

    ptr = SvPV(sv, len);
    end = SvEND(sv);

    while (ptr < end) {
        if (unlikely(*ptr == '%')) goto needs_decode;
        ptr++;
    }
    return;

needs_decode:

    // in place: everything before the first % is already decoded
    decoded = ptr;

    for (; ptr < end; ptr++) {
        if (unlikely(*ptr == '%') && likely(end - ptr > 2)) {
            int c1 = hex_decode(ptr[1]);
            int c2 = hex_decode(ptr[2]);
            if (likely(c1 != -1 && c2 != -1)) {
                *decoded++ = (c1 << 4) + c2;
                ptr += 2;
                continue;
            }
        }
        *decoded++ = *ptr;
    }

    *decoded = '\0';

    SvCUR_set(sv, decoded - SvPVX(sv));
}

static void
feersum_set_conn_remote_info(pTHX_ struct feer_conn *c)
{
    if (c->remote_addr) return;
    struct sockaddr *sa = (struct sockaddr *)&c->sa;
    switch (sa->sa_family) {
        case AF_INET: {
            struct sockaddr_in *in = (struct sockaddr_in *)sa;
            char buf[INET_ADDRSTRLEN];
            if (inet_ntop(AF_INET, &in->sin_addr, buf, sizeof(buf))) {
                c->remote_addr = newSVpv(buf, 0);
            } else {
                c->remote_addr = newSVpvs("0.0.0.0");
            }
            c->remote_port = newSViv(ntohs(in->sin_port));
            break;
        }
#ifdef AF_INET6
        case AF_INET6: {
            struct sockaddr_in6 *in6 = (struct sockaddr_in6 *)sa;
            char buf[INET6_ADDRSTRLEN];
            if (inet_ntop(AF_INET6, &in6->sin6_addr, buf, sizeof(buf))) {
                c->remote_addr = newSVpv(buf, 0);
            } else {
                c->remote_addr = newSVpvs("::");
            }
            c->remote_port = newSViv(ntohs(in6->sin6_port));
            break;
        }
#endif
#ifdef AF_UNIX
        case AF_UNIX:
            c->remote_addr = newSVpvs("unix");
            c->remote_port = newSViv(0);
            break;
#endif
        default:
            c->remote_addr = newSVpvs("unspec");
            c->remote_port = newSViv(0);
            break;
    }
}

static SV*
feersum_env_method(pTHX_ struct feer_req *r)
{
    switch (r->method_len) {
        case 3:
            if (likely(memcmp(r->method, "GET", 3) == 0))
                return SvREFCNT_inc_simple_NN(method_GET);
            if (memcmp(r->method, "PUT", 3) == 0)
                return SvREFCNT_inc_simple_NN(method_PUT);
            break;
        case 4:
            if (likely(memcmp(r->method, "POST", 4) == 0))
                return SvREFCNT_inc_simple_NN(method_POST);
            if (memcmp(r->method, "HEAD", 4) == 0)
                return SvREFCNT_inc_simple_NN(method_HEAD);
            break;
        case 5:
            if (memcmp(r->method, "PATCH", 5) == 0)
                return SvREFCNT_inc_simple_NN(method_PATCH);
            break;
        case 6:
            if (memcmp(r->method, "DELETE", 6) == 0)
                return SvREFCNT_inc_simple_NN(method_DELETE);
            break;
        case 7:
            if (memcmp(r->method, "OPTIONS", 7) == 0)
                return SvREFCNT_inc_simple_NN(method_OPTIONS);
            break;
    }
    return newSVpvn(r->method, r->method_len);
}

INLINE_UNLESS_DEBUG static SV*
feersum_env_uri(pTHX_ struct feer_req *r)
{
    return newSVpvn(r->uri, r->uri_len);
}

INLINE_UNLESS_DEBUG static SV*
feersum_env_protocol(pTHX_ struct feer_req *r)
{
    return (r->minor_version == 1) ? psgi_serv11 : psgi_serv10;
}

INLINE_UNLESS_DEBUG static void
feersum_set_path_and_query(pTHX_ struct feer_req *r)
{
    const char *uri = r->uri;
    STRLEN uri_len = r->uri_len;

    /* absolute-form (RFC 9112 3.2.2): drop scheme://authority so PATH_INFO
     * is the path; REQUEST_URI keeps the raw target */
    if (unlikely(uri_len && uri[0] != '/')) {
        const char *p = uri, *end = uri + uri_len;
        /* scheme = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ) */
        while (p < end && ((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z')
                        || (*p >= '0' && *p <= '9')
                        || *p == '+' || *p == '-' || *p == '.')) p++;
        if (p > uri && end - p >= 3 && p[0] == ':' && p[1] == '/' && p[2] == '/') {
            const char *q = p + 3;   /* start of authority */
            while (q < end && *q != '/' && *q != '?') q++;
            if (q < end && *q == '/') {
                uri = q;
                uri_len = end - q;
            }
            else {
                /* no path segment: "http://h" -> "/", "http://h?x" -> "/?x" */
                r->path = newSVpvs("/");
                r->query = (q < end) ? newSVpvn(q + 1, end - (q + 1))
                                     : SvREFCNT_inc_simple_NN(empty_query_sv);
                return;
            }
        }
    }

    const char *qpos = (const char *)memchr(uri, '?', uri_len);
    if (qpos != NULL) {
        r->path = newSVpvn(uri, (qpos - uri));
        qpos++;
        r->query = newSVpvn(qpos, uri_len - (qpos - uri));
    } else {
        r->path = newSVpvn(uri, uri_len);
        r->query = SvREFCNT_inc_simple_NN(empty_query_sv);
    }
    uri_decode_sv(r->path);
}

INLINE_UNLESS_DEBUG static SV*
feersum_env_path(pTHX_ struct feer_req *r)
{
    if (unlikely(!r->path)) feersum_set_path_and_query(aTHX_ r);
    return r->path;
}

INLINE_UNLESS_DEBUG static SV*
feersum_env_query(pTHX_ struct feer_req *r)
{
    if (unlikely(!r->query)) feersum_set_path_and_query(aTHX_ r);
    return r->query;
}

INLINE_UNLESS_DEBUG static SV*
feersum_env_addr(pTHX_ struct feer_conn *c)
{
    feersum_set_conn_remote_info(aTHX_ c);
    return c->remote_addr;
}

INLINE_UNLESS_DEBUG static SV*
feersum_env_port(pTHX_ struct feer_conn *c)
{
    feersum_set_conn_remote_info(aTHX_ c);
    return c->remote_port;
}

static const char*
find_header_value(struct feer_req *r, const char *name, size_t name_len, size_t *value_len)
{
    for (size_t i = 0; i < r->num_headers; i++) {
        struct phr_header *hdr = &r->headers[i];
        // a NULL name is an obs-fold continuation
        if (hdr->name && hdr->name_len == name_len &&
            str_case_eq_fixed(name, hdr->name, name_len))
        {
            *value_len = hdr->value_len;
            return hdr->value;
        }
    }
    *value_len = 0;
    return NULL;
}

static int
feer_socketpair_nb(int sv[2])
{
#if defined(SOCK_CLOEXEC) && defined(SOCK_NONBLOCK)
    if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0, sv) == 0)
        return 0;
    if (errno != EINVAL) return -1;
    /* fallthrough: kernel too old for SOCK_CLOEXEC/SOCK_NONBLOCK */
#endif
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0)
        return -1;
    if (fcntl(sv[0], F_SETFL, O_NONBLOCK) < 0 ||
        fcntl(sv[1], F_SETFL, O_NONBLOCK) < 0 ||
        fcntl(sv[0], F_SETFD, FD_CLOEXEC) < 0 ||
        fcntl(sv[1], F_SETFD, FD_CLOEXEC) < 0)
    {
        close(sv[0]);
        close(sv[1]);
        return -1;
    }
    return 0;
}

static SV*
newSV_buf(STRLEN size)
{
    SV *sv = newSV(size);
    SvPOK_on(sv);
    SvCUR_set(sv, 0);
    if (size > 0)
        *SvPVX(sv) = '\0';
    return sv;
}

static time_t last_generated_time = 0;

static void date_timer_cb(EV_P_ ev_timer *w, int revents) {
    PERL_UNUSED_VAR(EV_A);
    PERL_UNUSED_VAR(revents);
    PERL_UNUSED_VAR(w);

    time_t now;
#if defined(__linux__) && defined(CLOCK_REALTIME_COARSE)
    struct timespec ts;
    if (likely(clock_gettime(CLOCK_REALTIME_COARSE, &ts) == 0)) {
        now = ts.tv_sec;
    } else {
        now = time(NULL);
    }
#else
    now = time(NULL);
#endif
    if (now == last_generated_time) return;

    last_generated_time = now;
    struct tm tm_buf;
    if (unlikely(!gmtime_r(&now, &tm_buf))) return;

    /* RFC 7231 requires English day/month names; strftime is locale-dependent */
    static const char *days[] = {"Sun","Mon","Tue","Wed","Thu","Fri","Sat"};
    static const char *months[] = {"Jan","Feb","Mar","Apr","May","Jun",
                                   "Jul","Aug","Sep","Oct","Nov","Dec"};
    snprintf(DATE_BUF + 6, DATE_VALUE_LENGTH + 1,
        "%s, %02d %s %04d %02d:%02d:%02d GMT",
        days[tm_buf.tm_wday], tm_buf.tm_mday, months[tm_buf.tm_mon],
        tm_buf.tm_year + 1900, tm_buf.tm_hour, tm_buf.tm_min, tm_buf.tm_sec);
    DATE_BUF[DATE_HEADER_LENGTH-2] = '\r';
    DATE_BUF[DATE_HEADER_LENGTH-1] = '\n';
}

static int
format_content_length(char *buf, size_t len)
{
    static const char prefix[] = "Content-Length: ";
    memcpy(buf, prefix, 16);

    char *p = buf + 16;

    if (len == 0) {
        *p++ = '0';
    } else {
        char tmp[20];
        char *t = tmp;
        while (len > 0) {
            *t++ = '0' + (len % 10);
            len /= 10;
        }
        while (t > tmp) {
            *p++ = *--t;
        }
    }

    *p++ = '\r'; *p++ = '\n'; *p++ = '\r'; *p++ = '\n';
    return p - buf;
}

#ifdef FEERSUM_HAS_OUTQ
/* bytes the kernel still holds (unsent + unacked); -1 when it cannot say */
static int
feer_sock_outq(int fd)
{
    int n;
# if defined(__linux__) && defined(TIOCOUTQ)
    if (ioctl(fd, TIOCOUTQ, &n) < 0) return -1;
# elif defined(SO_NWRITE)
    socklen_t len = sizeof(n);
    if (getsockopt(fd, SOL_SOCKET, SO_NWRITE, &n, &len) < 0) return -1;
# elif defined(FIONWRITE)
    if (ioctl(fd, FIONWRITE, &n) < 0) return -1;
# endif
    return n < 0 ? -1 : n;
}
#endif
