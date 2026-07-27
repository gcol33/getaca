/*
 * SHA-512 (FIPS 180-4).
 *
 * One portable compression path, unlike the digest in sha256.c. SHA-512 here
 * only ever absorbs a signature's worth of input: two 32-byte points and a
 * manifest, none of which is large enough for an instruction-set path to be
 * worth the test surface it would add.
 */

#include "sha512.h"

#include <string.h>

/* FIPS 180-4 section 4.2.3: the first 64 bits of the fractional parts of the
   cube roots of the first 80 primes. The leading 32 bits of the first 64
   entries are the SHA-256 table in sha256.c, which is what the two tables
   being derived from the same primes means. */
static const uint64_t K[80] = {
  0x428a2f98d728ae22ULL, 0x7137449123ef65cdULL,
  0xb5c0fbcfec4d3b2fULL, 0xe9b5dba58189dbbcULL,
  0x3956c25bf348b538ULL, 0x59f111f1b605d019ULL,
  0x923f82a4af194f9bULL, 0xab1c5ed5da6d8118ULL,
  0xd807aa98a3030242ULL, 0x12835b0145706fbeULL,
  0x243185be4ee4b28cULL, 0x550c7dc3d5ffb4e2ULL,
  0x72be5d74f27b896fULL, 0x80deb1fe3b1696b1ULL,
  0x9bdc06a725c71235ULL, 0xc19bf174cf692694ULL,
  0xe49b69c19ef14ad2ULL, 0xefbe4786384f25e3ULL,
  0x0fc19dc68b8cd5b5ULL, 0x240ca1cc77ac9c65ULL,
  0x2de92c6f592b0275ULL, 0x4a7484aa6ea6e483ULL,
  0x5cb0a9dcbd41fbd4ULL, 0x76f988da831153b5ULL,
  0x983e5152ee66dfabULL, 0xa831c66d2db43210ULL,
  0xb00327c898fb213fULL, 0xbf597fc7beef0ee4ULL,
  0xc6e00bf33da88fc2ULL, 0xd5a79147930aa725ULL,
  0x06ca6351e003826fULL, 0x142929670a0e6e70ULL,
  0x27b70a8546d22ffcULL, 0x2e1b21385c26c926ULL,
  0x4d2c6dfc5ac42aedULL, 0x53380d139d95b3dfULL,
  0x650a73548baf63deULL, 0x766a0abb3c77b2a8ULL,
  0x81c2c92e47edaee6ULL, 0x92722c851482353bULL,
  0xa2bfe8a14cf10364ULL, 0xa81a664bbc423001ULL,
  0xc24b8b70d0f89791ULL, 0xc76c51a30654be30ULL,
  0xd192e819d6ef5218ULL, 0xd69906245565a910ULL,
  0xf40e35855771202aULL, 0x106aa07032bbd1b8ULL,
  0x19a4c116b8d2d0c8ULL, 0x1e376c085141ab53ULL,
  0x2748774cdf8eeb99ULL, 0x34b0bcb5e19b48a8ULL,
  0x391c0cb3c5c95a63ULL, 0x4ed8aa4ae3418acbULL,
  0x5b9cca4f7763e373ULL, 0x682e6ff3d6b2b8a3ULL,
  0x748f82ee5defb2fcULL, 0x78a5636f43172f60ULL,
  0x84c87814a1f0ab72ULL, 0x8cc702081a6439ecULL,
  0x90befffa23631e28ULL, 0xa4506cebde82bde9ULL,
  0xbef9a3f7b2c67915ULL, 0xc67178f2e372532bULL,
  0xca273eceea26619cULL, 0xd186b8c721c0c207ULL,
  0xeada7dd6cde0eb1eULL, 0xf57d4f7fee6ed178ULL,
  0x06f067aa72176fbaULL, 0x0a637dc5a2c898a6ULL,
  0x113f9804bef90daeULL, 0x1b710b35131c471bULL,
  0x28db77f523047d84ULL, 0x32caab7b40c72493ULL,
  0x3c9ebe0a15c9bebcULL, 0x431d67c49c100d4cULL,
  0x4cc5d4becb3e42b6ULL, 0x597f299cfc657e2aULL,
  0x5fcb6fab3ad6faecULL, 0x6c44198c4a475817ULL
};

/* FIPS 180-4 section 5.3.5. */
static const uint64_t H0[8] = {
  0x6a09e667f3bcc908ULL, 0xbb67ae8584caa73bULL,
  0x3c6ef372fe94f82bULL, 0xa54ff53a5f1d36f1ULL,
  0x510e527fade682d1ULL, 0x9b05688c2b3e6c1fULL,
  0x1f83d9abfb41bd6bULL, 0x5be0cd19137e2179ULL
};

#define ROTR(x, n) (((x) >> (n)) | ((x) << (64 - (n))))

#define CH(x, y, z)  (((x) & (y)) ^ (~(x) & (z)))
#define MAJ(x, y, z) (((x) & (y)) ^ ((x) & (z)) ^ ((y) & (z)))
#define BSIG0(x) (ROTR(x, 28) ^ ROTR(x, 34) ^ ROTR(x, 39))
#define BSIG1(x) (ROTR(x, 14) ^ ROTR(x, 18) ^ ROTR(x, 41))
#define SSIG0(x) (ROTR(x,  1) ^ ROTR(x,  8) ^ ((x) >> 7))
#define SSIG1(x) (ROTR(x, 19) ^ ROTR(x, 61) ^ ((x) >> 6))

static void blocks(uint64_t *state, const unsigned char *data, size_t nblocks)
{
  while (nblocks--) {
    uint64_t w[80];
    uint64_t a, b, c, d, e, f, g, h, t1, t2;
    int t;

    for (t = 0; t < 16; t++) {
      w[t] = ((uint64_t) data[8 * t]     << 56) |
             ((uint64_t) data[8 * t + 1] << 48) |
             ((uint64_t) data[8 * t + 2] << 40) |
             ((uint64_t) data[8 * t + 3] << 32) |
             ((uint64_t) data[8 * t + 4] << 24) |
             ((uint64_t) data[8 * t + 5] << 16) |
             ((uint64_t) data[8 * t + 6] <<  8) |
             ((uint64_t) data[8 * t + 7]);
    }
    for (t = 16; t < 80; t++) {
      w[t] = SSIG1(w[t - 2]) + w[t - 7] + SSIG0(w[t - 15]) + w[t - 16];
    }

    a = state[0]; b = state[1]; c = state[2]; d = state[3];
    e = state[4]; f = state[5]; g = state[6]; h = state[7];

    for (t = 0; t < 80; t++) {
      t1 = h + BSIG1(e) + CH(e, f, g) + K[t] + w[t];
      t2 = BSIG0(a) + MAJ(a, b, c);
      h = g; g = f; f = e; e = d + t1;
      d = c; c = b; b = a; a = t1 + t2;
    }

    state[0] += a; state[1] += b; state[2] += c; state[3] += d;
    state[4] += e; state[5] += f; state[6] += g; state[7] += h;
    data += SHA512_BLOCK_LENGTH;
  }
}

void sha512_start(sha512_ctx *ctx)
{
  memcpy(ctx->state, H0, sizeof(H0));
  ctx->held = 0;
  ctx->bytes = 0;
}

void sha512_update(sha512_ctx *ctx, const unsigned char *data, size_t len)
{
  ctx->bytes += (uint64_t) len;

  if (ctx->held) {
    size_t want = SHA512_BLOCK_LENGTH - ctx->held;
    if (len < want) {
      memcpy(ctx->block + ctx->held, data, len);
      ctx->held += len;
      return;
    }
    memcpy(ctx->block + ctx->held, data, want);
    blocks(ctx->state, ctx->block, 1);
    ctx->held = 0;
    data += want;
    len -= want;
  }

  if (len >= SHA512_BLOCK_LENGTH) {
    size_t whole = len / SHA512_BLOCK_LENGTH;
    blocks(ctx->state, data, whole);
    data += whole * SHA512_BLOCK_LENGTH;
    len -= whole * SHA512_BLOCK_LENGTH;
  }

  if (len) {
    memcpy(ctx->block, data, len);
    ctx->held = len;
  }
}

/* FIPS 180-4 section 5.1.2: a single 1 bit, zeroes, then the message length in
   bits as a big-endian 128-bit value. The high half is zero for any input this
   package hashes, which is bounded by a manifest. */
void sha512_final(sha512_ctx *ctx, unsigned char out[SHA512_DIGEST_LENGTH])
{
  uint64_t bits = ctx->bytes << 3;
  size_t at = ctx->held;
  int i;

  ctx->block[at++] = 0x80;
  if (at > SHA512_BLOCK_LENGTH - 16) {
    memset(ctx->block + at, 0, SHA512_BLOCK_LENGTH - at);
    blocks(ctx->state, ctx->block, 1);
    at = 0;
  }
  memset(ctx->block + at, 0, SHA512_BLOCK_LENGTH - 8 - at);
  for (i = 0; i < 8; i++) {
    ctx->block[SHA512_BLOCK_LENGTH - 1 - i] = (unsigned char) (bits >> (8 * i));
  }
  blocks(ctx->state, ctx->block, 1);

  for (i = 0; i < 8; i++) {
    out[8 * i]     = (unsigned char) (ctx->state[i] >> 56);
    out[8 * i + 1] = (unsigned char) (ctx->state[i] >> 48);
    out[8 * i + 2] = (unsigned char) (ctx->state[i] >> 40);
    out[8 * i + 3] = (unsigned char) (ctx->state[i] >> 32);
    out[8 * i + 4] = (unsigned char) (ctx->state[i] >> 24);
    out[8 * i + 5] = (unsigned char) (ctx->state[i] >> 16);
    out[8 * i + 6] = (unsigned char) (ctx->state[i] >>  8);
    out[8 * i + 7] = (unsigned char) (ctx->state[i]);
  }
}

void sha512_hash(unsigned char out[SHA512_DIGEST_LENGTH],
                 const unsigned char *data, size_t len)
{
  sha512_ctx ctx;
  sha512_start(&ctx);
  sha512_update(&ctx, data, len);
  sha512_final(&ctx, out);
}
