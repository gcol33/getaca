/* SHA-256 (FIPS 180-4), streaming, with a compression path chosen per host. */

#ifndef GETACA_SHA256_H
#define GETACA_SHA256_H

#include <stddef.h>
#include <stdint.h>

#define SHA256_DIGEST_LENGTH 32
#define SHA256_BLOCK_LENGTH  64

typedef void (*sha256_blocks_fn)(uint32_t *state, const unsigned char *data,
                                 size_t nblocks);

typedef struct {
  uint32_t state[8];
  unsigned char block[SHA256_BLOCK_LENGTH];
  size_t held;
  uint64_t bytes;
  /* Held per digest rather than read from a global, so a caller can drive any
     compiled path without disturbing the one this host selected. */
  sha256_blocks_fn compress;
} sha256_ctx;

/* Picks the fastest compression path this host can run. Idempotent, and the
   only part of the digest that varies between machines. */
void sha256_backend_select(void);
const char *sha256_backend_name(void);

/* Every path this host can execute, so all of them can be compared against each
   other on whichever machine happens to be running the tests. A path the build
   compiled but the host would trap on is not among them. */
int sha256_backend_count(void);
const char *sha256_backend_at(int i);

void sha256_start(sha256_ctx *ctx);
int sha256_start_with(sha256_ctx *ctx, const char *backend);
void sha256_update(sha256_ctx *ctx, const unsigned char *data, size_t len);
void sha256_final(sha256_ctx *ctx, unsigned char out[SHA256_DIGEST_LENGTH]);

#endif
