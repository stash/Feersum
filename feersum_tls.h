/* TLS 1.3 via picotls: constants for feersum_tls.c.inc */

#ifndef FEERSUM_TLS_H
#define FEERSUM_TLS_H

#ifdef FEERSUM_HAS_TLS

#include <picotls.h>
#include <picotls/openssl.h>
#include <openssl/pem.h>
#include <openssl/x509.h>

#define TLS_RAW_BUFSZ 16384

/* handshake reassembly cap; picotls's default of 0 is unlimited */
#define FEER_TLS_MAX_HANDSHAKE_BUF 65536

/* length-prefixed ALPN protocol ids */
#define ALPN_H2     "\x02h2"
#define ALPN_HTTP11     "\x08http/1.1"


#endif /* FEERSUM_HAS_TLS */
#endif /* FEERSUM_TLS_H */
