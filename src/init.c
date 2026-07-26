/* R entry points for the digest, and the routine registration. */

#define R_NO_REMAP

#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>
#include <R_ext/Visibility.h>

#include <stdio.h>

#ifdef _WIN32
#  include <windows.h>
#  include <wchar.h>
#endif

#include "sha256.h"

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
 * host selected; anything else lets the tests hold every compiled path against
 * the others on whichever machine is running them, since a machine only ever
 * selects one of them for itself.
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
      Rf_error("getaca: no sha256 backend '%s' in this build", name);
    }
  }

  sha256_update(&ctx, RAW(bytes), (size_t) XLENGTH(bytes));
  sha256_final(&ctx, digest);
  hex_digest(digest, hex);
  return Rf_mkString(hex);
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

static const R_CallMethodDef call_methods[] = {
  {"sha256_file",     (DL_FUNC) &sha256_file,     1},
  {"sha256_raw",      (DL_FUNC) &sha256_raw,      2},
  {"sha256_backend",  (DL_FUNC) &sha256_backend,  0},
  {"sha256_backends", (DL_FUNC) &sha256_backends, 0},
  {NULL, NULL, 0}
};

void attribute_visible R_init_getaca(DllInfo *dll)
{
  sha256_backend_select();
  R_registerRoutines(dll, NULL, call_methods, NULL, NULL);
  R_useDynamicSymbols(dll, FALSE);
  R_forceSymbols(dll, TRUE);
}
