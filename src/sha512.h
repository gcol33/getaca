/* SHA-512 (FIPS 180-4), streaming. */

#ifndef GETACA_SHA512_H
#define GETACA_SHA512_H

#include <stddef.h>
#include <stdint.h>

#define SHA512_DIGEST_LENGTH 64
#define SHA512_BLOCK_LENGTH  128

typedef struct {
  uint64_t state[8];
  unsigned char block[SHA512_BLOCK_LENGTH];
  size_t held;
  uint64_t bytes;
} sha512_ctx;

void sha512_start(sha512_ctx *ctx);
void sha512_update(sha512_ctx *ctx, const unsigned char *data, size_t len);
void sha512_final(sha512_ctx *ctx, unsigned char out[SHA512_DIGEST_LENGTH]);

/* One-shot, for the fixed-size inputs the signature scheme hashes. */
void sha512_hash(unsigned char out[SHA512_DIGEST_LENGTH],
                 const unsigned char *data, size_t len);

#endif
