#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

/* Template hash for clone approach */
static HV *tmpl_env = NULL;

/* Constants for direct approach */
static AV *psgi_ver = NULL;
static SV *env_version = NULL;
static SV *env_url_scheme = NULL;
static SV *env_errors = NULL;
static SV *env_script_name = NULL;
static SV *env_content_length_zero = NULL;

static void
init_template(pTHX)
{
    if (tmpl_env) return;

    psgi_ver = newAV();
    av_push(psgi_ver, newSViv(1));
    av_push(psgi_ver, newSViv(1));

    tmpl_env = newHV();
    hv_ksplit(tmpl_env, 32);

    /* Constants */
    hv_stores(tmpl_env, "psgi.version", newRV((SV*)psgi_ver));
    hv_stores(tmpl_env, "psgi.url_scheme", newSVpvs("http"));
    hv_stores(tmpl_env, "psgi.run_once", &PL_sv_no);
    hv_stores(tmpl_env, "psgi.nonblocking", &PL_sv_yes);
    hv_stores(tmpl_env, "psgi.multithread", &PL_sv_no);
    hv_stores(tmpl_env, "psgi.multiprocess", &PL_sv_no);
    hv_stores(tmpl_env, "psgi.streaming", &PL_sv_yes);
    hv_stores(tmpl_env, "psgi.errors", newRV((SV*)PL_stderrgv));
    hv_stores(tmpl_env, "psgix.output.buffered", &PL_sv_yes);
    hv_stores(tmpl_env, "psgix.body.scalar_refs", &PL_sv_yes);
    hv_stores(tmpl_env, "psgix.output.guard", &PL_sv_yes);
    hv_stores(tmpl_env, "SCRIPT_NAME", newSVpvs(""));

    /* Placeholders */
    hv_stores(tmpl_env, "SERVER_PROTOCOL", &PL_sv_undef);
    hv_stores(tmpl_env, "SERVER_NAME", &PL_sv_undef);
    hv_stores(tmpl_env, "SERVER_PORT", &PL_sv_undef);
    hv_stores(tmpl_env, "REQUEST_URI", &PL_sv_undef);
    hv_stores(tmpl_env, "REQUEST_METHOD", &PL_sv_undef);
    hv_stores(tmpl_env, "PATH_INFO", &PL_sv_undef);
    hv_stores(tmpl_env, "QUERY_STRING", newSVpvs(""));
    hv_stores(tmpl_env, "CONTENT_LENGTH", newSViv(0));
    hv_stores(tmpl_env, "REMOTE_ADDR", &PL_sv_placeholder);
    hv_stores(tmpl_env, "REMOTE_PORT", &PL_sv_placeholder);
    hv_stores(tmpl_env, "psgi.input", &PL_sv_undef);

    /* Anticipated headers */
    hv_stores(tmpl_env, "CONTENT_TYPE", &PL_sv_placeholder);
    hv_stores(tmpl_env, "HTTP_HOST", &PL_sv_placeholder);
    hv_stores(tmpl_env, "HTTP_USER_AGENT", &PL_sv_placeholder);
    hv_stores(tmpl_env, "HTTP_ACCEPT", &PL_sv_placeholder);
    hv_stores(tmpl_env, "HTTP_CONNECTION", &PL_sv_placeholder);
    hv_stores(tmpl_env, "HTTP_COOKIE", &PL_sv_placeholder);
    hv_stores(tmpl_env, "psgix.io", &PL_sv_placeholder);
}

static void
init_constants(pTHX)
{
    if (env_version) return;

    if (!psgi_ver) {
        psgi_ver = newAV();
        av_push(psgi_ver, newSViv(1));
        av_push(psgi_ver, newSViv(1));
    }

    env_version = newRV((SV*)psgi_ver);
    env_url_scheme = newSVpvs("http");
    env_errors = newRV((SV*)PL_stderrgv);
    env_script_name = newSVpvs("");
    env_content_length_zero = newSViv(0);
}

/* OLD approach: clone template hash */
static HV*
build_env_clone(pTHX)
{
    HV *e = newHVhv(tmpl_env);

    /* Simulate per-request values */
    hv_stores(e, "SERVER_NAME", newSVpvs("localhost"));
    hv_stores(e, "SERVER_PORT", newSVpvs("8080"));
    hv_stores(e, "REQUEST_URI", newSVpvs("/api/test?foo=bar"));
    hv_stores(e, "REQUEST_METHOD", newSVpvs("GET"));
    hv_stores(e, "SERVER_PROTOCOL", newSVpvs("HTTP/1.1"));
    hv_stores(e, "PATH_INFO", newSVpvs("/api/test"));
    hv_stores(e, "QUERY_STRING", newSVpvs("foo=bar"));
    hv_stores(e, "REMOTE_ADDR", newSVpvs("127.0.0.1"));
    hv_stores(e, "REMOTE_PORT", newSVpvs("54321"));

    /* Simulate headers */
    hv_stores(e, "HTTP_HOST", newSVpvs("localhost:8080"));
    hv_stores(e, "HTTP_USER_AGENT", newSVpvs("Mozilla/5.0"));
    hv_stores(e, "HTTP_ACCEPT", newSVpvs("text/html"));
    hv_stores(e, "HTTP_CONNECTION", newSVpvs("keep-alive"));

    return e;
}

/* NEW approach: direct build with shared constants */
static HV*
build_env_direct(pTHX)
{
    HV *e = newHV();
    hv_ksplit(e, 48);

    /* Constants - shared via refcount */
    hv_stores(e, "psgi.version", SvREFCNT_inc_simple_NN(env_version));
    hv_stores(e, "psgi.url_scheme", SvREFCNT_inc_simple_NN(env_url_scheme));
    hv_stores(e, "psgi.run_once", SvREFCNT_inc_simple_NN(&PL_sv_no));
    hv_stores(e, "psgi.nonblocking", SvREFCNT_inc_simple_NN(&PL_sv_yes));
    hv_stores(e, "psgi.multithread", SvREFCNT_inc_simple_NN(&PL_sv_no));
    hv_stores(e, "psgi.multiprocess", SvREFCNT_inc_simple_NN(&PL_sv_no));
    hv_stores(e, "psgi.streaming", SvREFCNT_inc_simple_NN(&PL_sv_yes));
    hv_stores(e, "psgi.errors", SvREFCNT_inc_simple_NN(env_errors));
    hv_stores(e, "psgix.output.buffered", SvREFCNT_inc_simple_NN(&PL_sv_yes));
    hv_stores(e, "psgix.body.scalar_refs", SvREFCNT_inc_simple_NN(&PL_sv_yes));
    hv_stores(e, "psgix.output.guard", SvREFCNT_inc_simple_NN(&PL_sv_yes));
    hv_stores(e, "SCRIPT_NAME", SvREFCNT_inc_simple_NN(env_script_name));

    /* Per-request values */
    hv_stores(e, "SERVER_NAME", newSVpvs("localhost"));
    hv_stores(e, "SERVER_PORT", newSVpvs("8080"));
    hv_stores(e, "REQUEST_URI", newSVpvs("/api/test?foo=bar"));
    hv_stores(e, "REQUEST_METHOD", newSVpvs("GET"));
    hv_stores(e, "SERVER_PROTOCOL", newSVpvs("HTTP/1.1"));
    hv_stores(e, "PATH_INFO", newSVpvs("/api/test"));
    hv_stores(e, "QUERY_STRING", newSVpvs("foo=bar"));
    hv_stores(e, "CONTENT_LENGTH", SvREFCNT_inc_simple_NN(env_content_length_zero));
    hv_stores(e, "REMOTE_ADDR", newSVpvs("127.0.0.1"));
    hv_stores(e, "REMOTE_PORT", newSVpvs("54321"));

    /* Headers */
    hv_stores(e, "HTTP_HOST", newSVpvs("localhost:8080"));
    hv_stores(e, "HTTP_USER_AGENT", newSVpvs("Mozilla/5.0"));
    hv_stores(e, "HTTP_ACCEPT", newSVpvs("text/html"));
    hv_stores(e, "HTTP_CONNECTION", newSVpvs("keep-alive"));

    return e;
}

MODULE = BenchEnv  PACKAGE = BenchEnv

BOOT:
    init_template(aTHX);
    init_constants(aTHX);

void
bench_clone(n)
    int n
PPCODE:
    int i;
    for (i = 0; i < n; i++) {
        HV *e = build_env_clone(aTHX);
        SvREFCNT_dec((SV*)e);
    }
    XSRETURN_EMPTY;

void
bench_direct(n)
    int n
PPCODE:
    int i;
    for (i = 0; i < n; i++) {
        HV *e = build_env_direct(aTHX);
        SvREFCNT_dec((SV*)e);
    }
    XSRETURN_EMPTY;

HV*
get_env_clone()
CODE:
    RETVAL = build_env_clone(aTHX);
OUTPUT:
    RETVAL

HV*
get_env_direct()
CODE:
    RETVAL = build_env_direct(aTHX);
OUTPUT:
    RETVAL
