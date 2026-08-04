/* R entry points for the digest, and the routine registration. */

#define R_NO_REMAP

#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>
#include <R_ext/Visibility.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#  include <windows.h>
#  include <wchar.h>
#endif

#include "sha256.h"
#include "sha512.h"
#include "ed25519.h"

/* Large enough that the read stops being the bottleneck on a fast disk, and
   small enough to be an unremarkable allocation in any session. */
#define READ_CHUNK (1024 * 1024)

static void hex_digest(const unsigned char *raw, char *out)
{
  static const char digits[] = "0123456789abcdef";
  int i;

  for (i = 0; i < SHA256_DIGEST_LENGTH; i++) {
    out[2 * i]     = digits[raw[i] >> 4];
    out[2 * i + 1] = digits[raw[i] & 0x0f];
  }
  out[2 * SHA256_DIGEST_LENGTH] = '\0';
}

/*
 * Windows needs the wide-character call: a cache path under a user profile
 * whose name is not representable in the active code page cannot be opened by
 * fopen() at all, and R hands the path over as UTF-8.
 */
static FILE *open_binary(SEXP path)
{
#ifdef _WIN32
  const char *utf8 = Rf_translateCharUTF8(STRING_ELT(path, 0));
  wchar_t *wide;
  int n = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, NULL, 0);

  if (n <= 0) return NULL;
  wide = (wchar_t *) R_alloc((size_t) n, sizeof(wchar_t));
  if (MultiByteToWideChar(CP_UTF8, 0, utf8, -1, wide, n) <= 0) return NULL;
  return _wfopen(wide, L"rb");
#else
  return fopen(R_ExpandFileName(Rf_translateChar(STRING_ELT(path, 0))), "rb");
#endif
}

/*
 * NA for anything that could not be read, which is what a caller comparing
 * against a declared checksum needs: an unreadable file is not a file that
 * matches. The read loop takes no interrupts, so an abandoned call cannot
 * leave an open handle on a cached blob that a later sweep then fails to
 * remove.
 */
static SEXP sha256_file(SEXP path)
{
  sha256_ctx ctx;
  unsigned char digest[SHA256_DIGEST_LENGTH];
  unsigned char *buffer;
  char hex[2 * SHA256_DIGEST_LENGTH + 1];
  FILE *fp;
  size_t got;
  int bad;

  if (TYPEOF(path) != STRSXP || LENGTH(path) != 1) {
    Rf_error("getaca: a digest takes one file path");
  }
  if (STRING_ELT(path, 0) == NA_STRING) return Rf_ScalarString(NA_STRING);

  fp = open_binary(path);
  if (fp == NULL) return Rf_ScalarString(NA_STRING);

  buffer = (unsigned char *) R_alloc(READ_CHUNK, 1);
  sha256_start(&ctx);
  while ((got = fread(buffer, 1, READ_CHUNK, fp)) > 0) {
    sha256_update(&ctx, buffer, got);
  }
  bad = ferror(fp);
  fclose(fp);
  if (bad) return Rf_ScalarString(NA_STRING);

  sha256_final(&ctx, digest);
  hex_digest(digest, hex);
  return Rf_mkString(hex);
}

/*
 * `backend` names which compression path to drive. NULL takes the one this
 * host selected; anything else lets the tests hold every path the host can run
 * against the others, since a machine only ever selects one of them for itself.
 */
static SEXP sha256_raw(SEXP bytes, SEXP backend)
{
  sha256_ctx ctx;
  unsigned char digest[SHA256_DIGEST_LENGTH];
  char hex[2 * SHA256_DIGEST_LENGTH + 1];

  if (TYPEOF(bytes) != RAWSXP) {
    Rf_error("getaca: a digest of bytes takes a raw vector");
  }

  if (backend == R_NilValue) {
    sha256_start(&ctx);
  } else {
    const char *name = Rf_translateChar(STRING_ELT(backend, 0));
    if (!sha256_start_with(&ctx, name)) {
      Rf_error("getaca: no sha256 backend '%s' on this host", name);
    }
  }

  sha256_update(&ctx, RAW(bytes), (size_t) XLENGTH(bytes));
  sha256_final(&ctx, digest);
  hex_digest(digest, hex);
  return Rf_mkString(hex);
}

/*
 * A digest driven across several calls, for bytes that are never all in memory
 * and never on disk. The context outlives the call that made it, so it is held
 * behind an external pointer with a finaliser: a transfer abandoned partway
 * leaves the R object unreachable and the memory is returned at the next
 * collection rather than leaked.
 */
static SEXP stream_tag = NULL;

static void stream_finalize(SEXP ptr)
{
  sha256_ctx *ctx = (sha256_ctx *) R_ExternalPtrAddr(ptr);

  if (ctx == NULL) return;
  free(ctx);
  R_ClearExternalPtr(ptr);
}

/*
 * A context that has already produced its digest has been freed, and one
 * carried across a save and reload never had a context at all. Both arrive as
 * a null address, and neither has anything left to absorb.
 */
static sha256_ctx *stream_context(SEXP ptr)
{
  sha256_ctx *ctx;

  if (TYPEOF(ptr) != EXTPTRSXP || R_ExternalPtrTag(ptr) != stream_tag) {
    Rf_error("getaca: not a sha256 stream");
  }
  ctx = (sha256_ctx *) R_ExternalPtrAddr(ptr);
  if (ctx == NULL) Rf_error("getaca: this sha256 stream is already finished");
  return ctx;
}

static SEXP sha256_stream_new(void)
{
  sha256_ctx *ctx = (sha256_ctx *) calloc(1, sizeof(sha256_ctx));
  SEXP ptr;

  if (ctx == NULL) Rf_error("getaca: could not allocate a sha256 stream");
  sha256_start(ctx);
  ptr = PROTECT(R_MakeExternalPtr(ctx, stream_tag, R_NilValue));
  R_RegisterCFinalizerEx(ptr, stream_finalize, TRUE);
  UNPROTECT(1);
  return ptr;
}

static SEXP sha256_stream_update(SEXP ptr, SEXP bytes)
{
  sha256_ctx *ctx = stream_context(ptr);

  if (TYPEOF(bytes) != RAWSXP) {
    Rf_error("getaca: a digest of bytes takes a raw vector");
  }
  sha256_update(ctx, RAW(bytes), (size_t) XLENGTH(bytes));
  return R_NilValue;
}

/*
 * The digest, and the count of everything that went into it. The context is
 * released here rather than left to the finaliser, since a completed transfer
 * knows it is done and a caller may drive many in one session.
 */
static SEXP sha256_stream_final(SEXP ptr)
{
  sha256_ctx *ctx = stream_context(ptr);
  unsigned char digest[SHA256_DIGEST_LENGTH];
  char hex[2 * SHA256_DIGEST_LENGTH + 1];
  double bytes = (double) ctx->bytes;
  SEXP out, names;

  sha256_final(ctx, digest);
  hex_digest(digest, hex);
  free(ctx);
  R_ClearExternalPtr(ptr);

  out = PROTECT(Rf_allocVector(VECSXP, 2));
  SET_VECTOR_ELT(out, 0, Rf_mkString(hex));
  SET_VECTOR_ELT(out, 1, Rf_ScalarReal(bytes));
  names = PROTECT(Rf_allocVector(STRSXP, 2));
  SET_STRING_ELT(names, 0, Rf_mkChar("sha256"));
  SET_STRING_ELT(names, 1, Rf_mkChar("size"));
  Rf_setAttrib(out, R_NamesSymbol, names);

  UNPROTECT(2);
  return out;
}

static SEXP sha256_backend(void)
{
  return Rf_mkString(sha256_backend_name());
}

static SEXP sha256_backends(void)
{
  int i, n = sha256_backend_count();
  SEXP out = PROTECT(Rf_allocVector(STRSXP, n));

  for (i = 0; i < n; i++) {
    SET_STRING_ELT(out, i, Rf_mkChar(sha256_backend_at(i)));
  }
  UNPROTECT(1);
  return out;
}

/*
 * Exposed so the compiled digest can be held against the FIPS 180-4 vectors
 * directly, rather than only through the signatures that consume it.
 */
static SEXP sha512_raw(SEXP bytes)
{
  unsigned char digest[SHA512_DIGEST_LENGTH];
  char hex[2 * SHA512_DIGEST_LENGTH + 1];
  int i;

  if (TYPEOF(bytes) != RAWSXP) {
    Rf_error("getaca: a digest of bytes takes a raw vector");
  }
  sha512_hash(digest, RAW(bytes), (size_t) XLENGTH(bytes));

  for (i = 0; i < SHA512_DIGEST_LENGTH; i++) {
    static const char digits[] = "0123456789abcdef";
    hex[2 * i]     = digits[digest[i] >> 4];
    hex[2 * i + 1] = digits[digest[i] & 0x0f];
  }
  hex[2 * SHA512_DIGEST_LENGTH] = '\0';
  return Rf_mkString(hex);
}

static SEXP ed25519_sign_call(SEXP message, SEXP secret)
{
  SEXP out;

  if (TYPEOF(message) != RAWSXP || TYPEOF(secret) != RAWSXP) {
    Rf_error("getaca: signing takes raw vectors");
  }
  if (XLENGTH(secret) != ED25519_SECRET_LENGTH) {
    Rf_error("getaca: a signing key is %d bytes", ED25519_SECRET_LENGTH);
  }

  out = PROTECT(Rf_allocVector(RAWSXP, ED25519_SIGNATURE_LENGTH));
  ed25519_sign(RAW(out), RAW(message), (size_t) XLENGTH(message), RAW(secret));
  UNPROTECT(1);
  return out;
}

static SEXP ed25519_verify_call(SEXP sig, SEXP message, SEXP public)
{
  if (TYPEOF(sig) != RAWSXP || TYPEOF(message) != RAWSXP ||
      TYPEOF(public) != RAWSXP) {
    Rf_error("getaca: verification takes raw vectors");
  }
  /* A key or signature of the wrong length is a malformed signature file
     rather than an error: the caller is asking whether these bytes verify. */
  if (XLENGTH(sig) != ED25519_SIGNATURE_LENGTH ||
      XLENGTH(public) != ED25519_PUBLIC_LENGTH) {
    return Rf_ScalarLogical(FALSE);
  }

  return Rf_ScalarLogical(
    ed25519_verify(RAW(sig), RAW(message), (size_t) XLENGTH(message),
                   RAW(public)));
}

/*
 * `seed` supplies the 32 bytes a key derives from. R_NilValue takes them from
 * the operating system, which is the only shape a real key generation uses;
 * an explicit seed is what lets the tests drive the RFC 8032 vectors.
 */
static SEXP ed25519_keypair_call(SEXP seed)
{
  unsigned char bytes[ED25519_SEED_LENGTH];
  SEXP pk, sk, out, names;

  if (seed == R_NilValue) {
    if (!ed25519_random(bytes, sizeof(bytes))) {
      Rf_error("getaca: the operating system supplied no random bytes for a key");
    }
  } else {
    if (TYPEOF(seed) != RAWSXP || XLENGTH(seed) != ED25519_SEED_LENGTH) {
      Rf_error("getaca: a seed is %d raw bytes", ED25519_SEED_LENGTH);
    }
    memcpy(bytes, RAW(seed), sizeof(bytes));
  }

  pk = PROTECT(Rf_allocVector(RAWSXP, ED25519_PUBLIC_LENGTH));
  sk = PROTECT(Rf_allocVector(RAWSXP, ED25519_SECRET_LENGTH));
  ed25519_keypair(RAW(pk), RAW(sk), bytes);
  memset(bytes, 0, sizeof(bytes));

  out = PROTECT(Rf_allocVector(VECSXP, 2));
  SET_VECTOR_ELT(out, 0, pk);
  SET_VECTOR_ELT(out, 1, sk);
  names = PROTECT(Rf_allocVector(STRSXP, 2));
  SET_STRING_ELT(names, 0, Rf_mkChar("public"));
  SET_STRING_ELT(names, 1, Rf_mkChar("secret"));
  Rf_setAttrib(out, R_NamesSymbol, names);

  UNPROTECT(4);
  return out;
}

static const R_CallMethodDef call_methods[] = {
  {"sha256_file",      (DL_FUNC) &sha256_file,         1},
  {"sha256_raw",       (DL_FUNC) &sha256_raw,          2},
  {"sha256_backend",   (DL_FUNC) &sha256_backend,      0},
  {"sha256_backends",  (DL_FUNC) &sha256_backends,     0},
  {"sha256_stream_new",    (DL_FUNC) &sha256_stream_new,    0},
  {"sha256_stream_update", (DL_FUNC) &sha256_stream_update, 2},
  {"sha256_stream_final",  (DL_FUNC) &sha256_stream_final,  1},
  {"sha512_raw",       (DL_FUNC) &sha512_raw,          1},
  {"ed25519_sign",     (DL_FUNC) &ed25519_sign_call,   2},
  {"ed25519_verify",   (DL_FUNC) &ed25519_verify_call, 3},
  {"ed25519_keypair",  (DL_FUNC) &ed25519_keypair_call, 1},
  {NULL, NULL, 0}
};

void attribute_visible R_init_getaca(DllInfo *dll)
{
  sha256_backend_select();
  /* A symbol, so it is never collected and the tag survives as long as any
     pointer carrying it. */
  stream_tag = Rf_install("getaca_sha256_stream");
  R_registerRoutines(dll, NULL, call_methods, NULL, NULL);
  R_useDynamicSymbols(dll, FALSE);
  R_forceSymbols(dll, TRUE);
}
