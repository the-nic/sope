/*
  Copyright (C) 2000-2005 SKYRIX Software AG
  Copyright (C) 2011 Jeroen Dekkers <jeroen@dekkers.ch>
  Copyright (C) 2020 Nicolas Höft

  This file is part of SOPE.

  SOPE is free software; you can redistribute it and/or modify it under
  the terms of the GNU Lesser General Public License as published by the
  Free Software Foundation; either version 2, or (at your option) any
  later version.

  SOPE is distributed in the hope that it will be useful, but WITHOUT ANY
  WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public
  License for more details.

  You should have received a copy of the GNU Lesser General Public
  License along with SOPE; see the file COPYING.  If not, write to the
  Free Software Foundation, 59 Temple Place - Suite 330, Boston, MA
  02111-1307, USA.
*/


/*

match_function() and _validateHostname are based on boost asio implementations

Boost Software License - Version 1.0 - August 17th, 2003

Permission is hereby granted, free of charge, to any person or organization
obtaining a copy of the software and accompanying documentation covered by
this license (the "Software") to use, reproduce, display, distribute,
execute, and transmit the Software, and to prepare derivative works of the
Software, and to permit third-parties to whom the Software is furnished to
do so, all subject to the following:

The copyright notices in the Software and this entire statement, including
the above license grant, this restriction and the following disclaimer,
must be included in all copies of the Software, in whole or in part, and
all derivative works of the Software, unless such copies or derivative
works are solely in the form of machine-executable object code generated by
a source language processor.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT
SHALL THE COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE
FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE,
ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
*/


#include <NGStreams/NGActiveSSLSocket.h>
#include "common.h"

#if HAVE_GNUTLS
#  include <gnutls/gnutls.h>
#define LOOP_CHECK(rval, cmd) \
  do { \
    rval = cmd; \
  } while(rval == GNUTLS_E_AGAIN || rval == GNUTLS_E_INTERRUPTED);
#elif HAVE_OPENSSL
#  define id openssl_id
#  include <openssl/ssl.h>
#  include <openssl/err.h>
#  include <openssl/x509v3.h>
#  undef id
#endif


@interface NGActiveSocket(UsedPrivates)
- (BOOL)primaryConnectToAddress:(id<NGSocketAddress>)_address;
#if HAVE_OPENSSL
- (BOOL) _validateHostname: (X509 *) server_cert;
#endif /* HAVE_OPENSSL */
@end

@implementation NGActiveSSLSocket

- (BOOL)primaryConnectToAddress:(id<NGSocketAddress>)_address {

  if (![super primaryConnectToAddress:_address])
    /* could not connect to Unix socket ... */
    return NO;

  return [self startTLS];
}

+ (id) socketConnectedToAddress: (id<NGSocketAddress>) _address
                  onHostName: (NSString *) _hostName
{
  id sock = [[self alloc] initWithDomain:[_address domain]
                      onHostName: _hostName];
  if (![sock connectToAddress:_address]) {
    NSException *e;
    e = [[sock lastException] retain];
    [self release];
    e = [e autorelease];
    [e raise];
    return nil;
  }
  sock = [sock autorelease];
  return sock;
}

#if HAVE_GNUTLS
- (id)initWithDomain:(id<NGSocketDomain>)_domain
      onHostName: (NSString *)_hostName
{
  hostName = [_hostName copy];
  if ((self = [super initWithDomain:_domain])) {
    static BOOL didGlobalInit = NO;
    int ret;

    if (!didGlobalInit) {
      /* Global system initialization*/
      if (gnutls_global_init()) {
        [self release];
        return nil;
      }

      didGlobalInit = YES;
    }

    ret = gnutls_certificate_allocate_credentials((gnutls_certificate_credentials_t *) &self->cred);
    if (ret)
      {
        NSLog(@"ERROR(%s): couldn't create GnuTLS credentials (%s)",
              __PRETTY_FUNCTION__, gnutls_strerror(ret));
        [self release];
        return nil;
      }

    ret = gnutls_certificate_set_x509_system_trust(self->cred);
    if (ret)
      {
        NSLog(@"ERROR(%s): could not set GnuTLS system trust (%s)",
              __PRETTY_FUNCTION__, gnutls_strerror(ret));
        [self release];
        return nil;
      }

    self->session = NULL;
  }
  return self;
}

- (void)dealloc {
  if (self->session) {
    gnutls_deinit((gnutls_session_t) self->session);
    self->session = NULL;
  }
  if (self->cred) {
    gnutls_certificate_free_credentials((gnutls_certificate_credentials_t) self->cred);
    self->cred = NULL;
  }
  [hostName release];
  [super dealloc];
}

/* basic IO, reading and writing bytes */

- (unsigned)readBytes:(void *)_buf count:(unsigned)_len {
  ssize_t ret;

  if (self->session == NULL)
    // should throw error
    return NGStreamError;


  LOOP_CHECK(ret, gnutls_record_recv((gnutls_session_t) self->session, _buf, _len));
  if (ret <= 0)
    return NGStreamError;
  else
    return ret;
}

- (unsigned)writeBytes:(const void *)_buf count:(unsigned)_len {
  ssize_t ret;

  if (self->session == NULL)
    // should throw error
    return NGStreamError;

  LOOP_CHECK(ret, gnutls_record_send((gnutls_session_t) self->session, _buf, _len));
  if (ret <= 0)
    return NGStreamError;
  else
    return ret;
}

/* connection and shutdown */

- (BOOL)markNonblockingAfterConnect {
  return NO;
}

- (BOOL) startTLS
{
  int ret;
  gnutls_session_t sess;

  [self disableNagle: YES];

  ret = gnutls_init((gnutls_session_t *) &self->session, GNUTLS_CLIENT);
  if (ret) {
    // should set exception !
    NSLog(@"ERROR(%s): couldn't create GnuTLS session (%s)",
          __PRETTY_FUNCTION__, gnutls_strerror(ret));
    return NO;
  }
  sess = (gnutls_session_t) self->session;

  gnutls_set_default_priority(sess);

  ret = gnutls_credentials_set(sess, GNUTLS_CRD_CERTIFICATE, (gnutls_certificate_credentials_t) self->cred);
  if (ret) {
    // should set exception !
    NSLog(@"ERROR(%s): couldn't set GnuTLS credentials (%s)",
          __PRETTY_FUNCTION__, gnutls_strerror(ret));
    return NO;
  }

  // set SNI
  ret = gnutls_server_name_set(sess, GNUTLS_NAME_DNS, [hostName UTF8String], [hostName length]);
  if (ret) {
    // should set exception !
    NSLog(@"ERROR(%s): couldn't set GnuTLS SNI (%s)",
          __PRETTY_FUNCTION__, gnutls_strerror(ret));
    return NO;
  }

  gnutls_session_set_verify_cert(sess, [hostName UTF8String], 0);

#if GNUTLS_VERSION_NUMBER < 0x030109
  gnutls_transport_set_ptr(sess, (gnutls_transport_ptr_t)(long)self->fd);
#else
  gnutls_transport_set_int(sess, self->fd);
#endif /* GNUTLS_VERSION_NUMBER < 0x030109 */

  gnutls_handshake_set_timeout(sess, GNUTLS_DEFAULT_HANDSHAKE_TIMEOUT);
  do {
    ret = gnutls_handshake(sess);
  } while (ret < 0 && gnutls_error_is_fatal(ret) == 0);

  if (ret < 0) {
    NSLog(@"ERROR(%s):GnutTLS handshake failed on socket (%s)",
      __PRETTY_FUNCTION__, gnutls_strerror(ret));
    if (ret == GNUTLS_E_FATAL_ALERT_RECEIVED) {
      NSLog(@"Alert: %s", gnutls_alert_get_name(gnutls_alert_get(sess)));
    }
    [self shutdown];
    return NO;
  }

  return YES;
}

- (BOOL)shutdown {

  if (self->session) {
    int ret;
    LOOP_CHECK(ret, gnutls_bye((gnutls_session_t)self->session, GNUTLS_SHUT_RDWR));
    gnutls_deinit((gnutls_session_t) self->session);
    self->session = NULL;
  }
  if (self->cred) {
    gnutls_certificate_free_credentials((gnutls_certificate_credentials_t) self->cred);
    self->cred = NULL;
  }
  return [super shutdown];
}

#elif HAVE_OPENSSL

#if OPENSSL_VERSION_NUMBER < 0x10020000L
static BOOL match_pattern(const char* pattern, size_t pattern_length, const char* host)
{
  const char* p = pattern;
  const char* p_end = p + pattern_length;
  const char* h = host;

  while (p != p_end && *h) {
    if (*p == '*') {
      ++p;
      while (*h && *h != '.') {
        if (match_pattern(p, p_end - p, h++)) {
          return YES;
        }
      }
    }
    else if (tolower(*p) == tolower(*h)) {
      ++p;
      ++h;
    }
    else {
      return NO;
    }
  }

  return p == p_end && !*h;
}

- (BOOL) _validateHostname: (X509 *) server_cert
{
  // Go through the alternate names in the certificate looking for matching DNS
  // entries.
  int i;
  GENERAL_NAMES* gens = (GENERAL_NAMES*) X509_get_ext_d2i(server_cert, NID_subject_alt_name, 0, 0);

  for (i = 0; i < sk_GENERAL_NAME_num(gens); ++i) {
    GENERAL_NAME* gen = sk_GENERAL_NAME_value(gens, i);
    if (gen->type == GEN_DNS) {
      ASN1_IA5STRING* dns_name = gen->d.dNSName;
      if (dns_name->type == V_ASN1_IA5STRING && dns_name->data && dns_name->length) {
        const char* pattern = (const char*)dns_name->data;
        size_t pattern_length = dns_name->length;
        if (match_pattern(pattern, pattern_length, [hostName UTF8String])) {
          GENERAL_NAMES_free(gens);
          return YES;
        }
      }
    }
  }
  GENERAL_NAMES_free(gens);

  // No match in the alternate names, so try the common names. We should only
  // use the "most specific" common name, which is the last one in the list.
  X509_NAME* name = X509_get_subject_name(server_cert);
  ASN1_STRING* common_name = 0;
  while ((i = X509_NAME_get_index_by_NID(name, NID_commonName, i)) >= 0) {
    X509_NAME_ENTRY* name_entry = X509_NAME_get_entry(name, i);
    common_name = X509_NAME_ENTRY_get_data(name_entry);
  }

  if (common_name && common_name->data && common_name->length) {
    const char* pattern =  (const char*) common_name->data;
    size_t pattern_length = common_name->length;
    if (match_pattern(pattern, pattern_length, [hostName UTF8String])) {
      return YES;
    }
  }

  return NO;
}


/* See http://archives.seul.org/libevent/users/Jan-2013/msg00039.html */
static int cert_verify_callback(X509_STORE_CTX *x509_ctx, void *arg)
{
    NGActiveSSLSocket *sslsock = (NGActiveSSLSocket *)arg;
    BOOL validation_result = NO;

    /* This is the function that OpenSSL would call if we hadn't called
     * SSL_CTX_set_cert_verify_callback().  Therefore, we are "wrapping"
     * the default functionality, rather than replacing it. */
    int ok_so_far = 0;

    X509 *server_cert = NULL;

    ok_so_far = X509_verify_cert(x509_ctx) == 1;

    server_cert = X509_STORE_CTX_get_current_cert(x509_ctx);

    if (ok_so_far) {
        validation_result = [sslsock _validateHostname: server_cert];
    }

    if (validation_result == YES) {
        return 1;
    } else {
        NSLog(@"SSL(%@): Certificate validation failed",
            __PRETTY_FUNCTION__);
        return 0;
    }
}
#endif /* #OPENSSL_VERSION_NUMBER < 0x10020000L */

- (id)initWithDomain:(id<NGSocketDomain>)_domain
          onHostName: (NSString *)_hostName
{

  hostName = [_hostName copy];
  if ((self = [super initWithDomain:_domain])) {

#if OPENSSL_VERSION_NUMBER < 0x10100000L
    static BOOL didGlobalInit = NO;
    if (!didGlobalInit) {
      /* Global system initialization*/
      SSL_library_init();
      SSL_load_error_strings();
      didGlobalInit = YES;
    }
#endif /* OPENSSL_VERSION_NUMBER < 0x10100000L */


    /* Create our context*/
    if ((self->ctx = SSL_CTX_new(SSLv23_method())) == NULL) {
      NSLog(@"ERROR(%s): couldn't create SSL context for v23 method !",
            __PRETTY_FUNCTION__);
      [self release];
      return nil;
    }
    // use system default trust store
    SSL_CTX_set_default_verify_paths(self->ctx);

    if ((self->ssl = SSL_new(self->ctx)) == NULL) {
      // should set exception !
      NSLog(@"ERROR(%s): couldn't create SSL socket structure ...",
            __PRETTY_FUNCTION__);
      return nil;
    }
#if OPENSSL_VERSION_NUMBER < 0x10020000L
    SSL_CTX_set_cert_verify_callback(self->ctx, cert_verify_callback, (void *)self);
#elif OPENSSL_VERSION_NUMBER < 0x10100000L
    X509_VERIFY_PARAM *param = NULL;
    param = SSL_get0_param(self->ssl);
    X509_VERIFY_PARAM_set_hostflags(param, X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS);
    if (!X509_VERIFY_PARAM_set1_host(param, [hostName UTF8String], 0)) {
      return nil;
    }
#else
    SSL_set1_host(self->ssl, [hostName UTF8String]);
#endif /* OPENSSL_VERSION_NUMBER < 0x10100000L */

    // send SNI
    SSL_set_tlsext_host_name(self->ssl, [hostName UTF8String]);
    // verify the peer
    SSL_set_verify(self->ssl, SSL_VERIFY_PEER, NULL);

  }
  return self;
}

- (void)dealloc {
  [self shutdown];
  [hostName release];
  [super dealloc];
}

/* basic IO, reading and writing bytes */

- (unsigned)readBytes:(void *)_buf count:(unsigned)_len {
  int ret;

  if (self->ssl == NULL)
    // should throw error
    return NGStreamError;

  ret = SSL_read(self->ssl, _buf, _len);

  if (ret <= 0)
    return NGStreamError;

  return ret;
}

- (unsigned)writeBytes:(const void *)_buf count:(unsigned)_len {
  return SSL_write(self->ssl, _buf, _len);
}

/* connection and shutdown */

- (BOOL)markNonblockingAfterConnect {
  return NO;
}

- (BOOL) startTLS
{
  int ret;

  [self disableNagle: YES];

  if (self->ssl == NULL) {
    NSLog(@"ERROR(%s): SSL structure is not set up!",
          __PRETTY_FUNCTION__);
    return NO;
  }

  if (SSL_set_fd(self->ssl, self->fd) <= 0) {
    // should set exception !
    NSLog(@"ERROR(%s): couldn't set FD ...",
          __PRETTY_FUNCTION__);
    return NO;
  }

  ret = SSL_connect(self->ssl);
  if (ret <= 0) {
    NSLog(@"ERROR(%s): couldn't setup SSL connection on host %@ (%s)...",
      __PRETTY_FUNCTION__, hostName, ERR_error_string(SSL_get_error(self->ssl, ret), NULL));
    [self shutdown];
    return NO;
  }

  return YES;
}

- (BOOL)shutdown {
  if (self->ssl) {
    int ret = SSL_shutdown(self->ssl);
    // call shutdown a second time
    if (ret == 0)
      SSL_shutdown(self->ssl);
    SSL_free(self->ssl);
    self->ssl = NULL;
  }
  if (self->ctx) {
    SSL_CTX_free(self->ctx);
    self->ctx = NULL;
  }
  return [super shutdown];
}

#else /* no OpenSSL available */

+ (void)initialize {
  NSLog(@"WARNING: The NGActiveSSLSocket class was accessed, "
        @"but OpenSSL support is turned off.");
}
- (id)initWithDomain:(id<NGSocketDomain>)_domain onHostName: (NSString *)_hostName {
  [self release];
  return nil;
}


#endif

@end /* NGActiveSSLSocket */
