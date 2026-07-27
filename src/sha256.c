/*
 * SHA-256 (FIPS 180-4).
 *
 * Three compression paths, one per instruction set a host may offer. They
 * share the round-constant table, the streaming buffer and the padding, so the
 * only thing that differs between them is how fast a 64-byte block is
 * absorbed:
 *
 *   blocks_shani  x86-64 SHA extensions, selected by CPUID at load time
 *   blocks_armce  ARMv8 SHA-256 extensions, selected when the compiler
 *                 targets a machine that has them
 *   blocks_plain  portable C, and the only path on any other machine
 *
 * The vector paths read four constants at a time from the same K table the
 * portable path indexes one at a time. A digest is a single specified value,
 * so a path that disagreed with the others would be a defect in that path,
 * and keeping one table means a wrong constant cannot be one of them.
 */

#include "sha256.h"

#include <string.h>

/* FIPS 180-4 section 4.2.2: the first 32 bits of the fractional parts of the
   cube roots of the first 64 primes. */
static const uint32_t K[64] = {
  0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u,
  0x3956c25bu, 0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u,
  0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u,
  0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u, 0xc19bf174u,
  0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu,
  0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau,
  0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u,
  0xc6e00bf3u, 0xd5a79147u, 0x06ca6351u, 0x14292967u,
  0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu, 0x53380d13u,
  0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
  0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u,
  0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u,
  0x19a4c116u, 0x1e376c08u, 0x2748774cu, 0x34b0bcb5u,
  0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu, 0x682e6ff3u,
  0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
  0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u
};

/* FIPS 180-4 section 5.3.3. */
static const uint32_t H0[8] = {
  0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
  0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u
};

/* ------------------------------------------------------------------ portable */

#define ROTR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

#define CH(x, y, z)  (((x) & (y)) ^ (~(x) & (z)))
#define MAJ(x, y, z) (((x) & (y)) ^ ((x) & (z)) ^ ((y) & (z)))
#define BSIG0(x) (ROTR(x,  2) ^ ROTR(x, 13) ^ ROTR(x, 22))
#define BSIG1(x) (ROTR(x,  6) ^ ROTR(x, 11) ^ ROTR(x, 25))
#define SSIG0(x) (ROTR(x,  7) ^ ROTR(x, 18) ^ ((x) >>  3))
#define SSIG1(x) (ROTR(x, 17) ^ ROTR(x, 19) ^ ((x) >> 10))

static void blocks_plain(uint32_t *state, const unsigned char *data, size_t nblocks)
{
  while (nblocks--) {
    uint32_t w[64];
    uint32_t a, b, c, d, e, f, g, h, t1, t2;
    int t;

    for (t = 0; t < 16; t++) {
      w[t] = ((uint32_t) data[4 * t]     << 24) |
             ((uint32_t) data[4 * t + 1] << 16) |
             ((uint32_t) data[4 * t + 2] <<  8) |
             ((uint32_t) data[4 * t + 3]);
    }
    for (t = 16; t < 64; t++) {
      w[t] = SSIG1(w[t - 2]) + w[t - 7] + SSIG0(w[t - 15]) + w[t - 16];
    }

    a = state[0]; b = state[1]; c = state[2]; d = state[3];
    e = state[4]; f = state[5]; g = state[6]; h = state[7];

    for (t = 0; t < 64; t++) {
      t1 = h + BSIG1(e) + CH(e, f, g) + K[t] + w[t];
      t2 = BSIG0(a) + MAJ(a, b, c);
      h = g; g = f; f = e; e = d + t1;
      d = c; c = b; b = a; a = t1 + t2;
    }

    state[0] += a; state[1] += b; state[2] += c; state[3] += d;
    state[4] += e; state[5] += f; state[6] += g; state[7] += h;
    data += SHA256_BLOCK_LENGTH;
  }
}

/* ----------------------------------------------------------- x86 SHA-NI */

#if (defined(__x86_64__) || defined(__i386__)) && (defined(__GNUC__) || defined(__clang__))
#  define GETACA_SHANI 1
#  include <cpuid.h>
#  include <immintrin.h>
#endif

#ifdef GETACA_SHANI

/*
 * Four rounds per invocation. `cur` holds the four message words being
 * absorbed; `nxt` and `prv` are the neighbours the message schedule needs,
 * which rotate by one every four rounds. The schedule runs one group ahead of
 * the rounds that consume it, so the msg2 that completes a group of words sits
 * between the two round pairs and the msg1 that begins the next follows them.
 */
#define SHANI_GROUP(gi, cur, nxt, prv)                                        \
  do {                                                                        \
    msg = _mm_add_epi32(cur, _mm_loadu_si128((const __m128i *) (K + 4 * (gi)))); \
    s1 = _mm_sha256rnds2_epu32(s1, s0, msg);                                   \
    if ((gi) >= 3 && (gi) <= 14) {                                            \
      tmp = _mm_alignr_epi8(cur, prv, 4);                                     \
      nxt = _mm_sha256msg2_epu32(_mm_add_epi32(nxt, tmp), cur);               \
    }                                                                         \
    msg = _mm_shuffle_epi32(msg, 0x0e);                                       \
    s0 = _mm_sha256rnds2_epu32(s0, s1, msg);                                  \
    if ((gi) >= 1 && (gi) <= 12) {                                            \
      prv = _mm_sha256msg1_epu32(prv, cur);                                   \
    }                                                                         \
  } while (0)

__attribute__((target("sha,sse4.1,ssse3")))
static void blocks_shani(uint32_t *state, const unsigned char *data, size_t nblocks)
{
  /* Reverses each 4-byte group, since a block is big-endian words and the
     load is little-endian. */
  const __m128i endian = _mm_set_epi64x((long long) 0x0c0d0e0f08090a0bLL,
                                        (long long) 0x0405060700010203LL);
  __m128i s0, s1, tmp, msg, w0, w1, w2, w3, abef, cdgh;

  /* The instruction takes the state as {a,b,e,f} and {c,d,g,h}. */
  tmp = _mm_loadu_si128((const __m128i *) &state[0]);
  s1  = _mm_loadu_si128((const __m128i *) &state[4]);
  tmp = _mm_shuffle_epi32(tmp, 0xb1);
  s1  = _mm_shuffle_epi32(s1, 0x1b);
  s0  = _mm_alignr_epi8(tmp, s1, 8);
  s1  = _mm_blend_epi16(s1, tmp, 0xf0);

  while (nblocks--) {
    abef = s0;
    cdgh = s1;

    w0 = _mm_shuffle_epi8(_mm_loadu_si128((const __m128i *) (data + 0)),  endian);
    w1 = _mm_shuffle_epi8(_mm_loadu_si128((const __m128i *) (data + 16)), endian);
    w2 = _mm_shuffle_epi8(_mm_loadu_si128((const __m128i *) (data + 32)), endian);
    w3 = _mm_shuffle_epi8(_mm_loadu_si128((const __m128i *) (data + 48)), endian);

    SHANI_GROUP( 0, w0, w1, w3);
    SHANI_GROUP( 1, w1, w2, w0);
    SHANI_GROUP( 2, w2, w3, w1);
    SHANI_GROUP( 3, w3, w0, w2);
    SHANI_GROUP( 4, w0, w1, w3);
    SHANI_GROUP( 5, w1, w2, w0);
    SHANI_GROUP( 6, w2, w3, w1);
    SHANI_GROUP( 7, w3, w0, w2);
    SHANI_GROUP( 8, w0, w1, w3);
    SHANI_GROUP( 9, w1, w2, w0);
    SHANI_GROUP(10, w2, w3, w1);
    SHANI_GROUP(11, w3, w0, w2);
    SHANI_GROUP(12, w0, w1, w3);
    SHANI_GROUP(13, w1, w2, w0);
    SHANI_GROUP(14, w2, w3, w1);
    SHANI_GROUP(15, w3, w0, w2);

    s0 = _mm_add_epi32(s0, abef);
    s1 = _mm_add_epi32(s1, cdgh);
    data += SHA256_BLOCK_LENGTH;
  }

  tmp = _mm_shuffle_epi32(s0, 0x1b);
  s1  = _mm_shuffle_epi32(s1, 0xb1);
  s0  = _mm_blend_epi16(tmp, s1, 0xf0);
  s1  = _mm_alignr_epi8(s1, tmp, 8);

  _mm_storeu_si128((__m128i *) &state[0], s0);
  _mm_storeu_si128((__m128i *) &state[4], s1);
}

/* The compression uses byte shuffles from SSSE3 and a blend from SSE4.1
   alongside the SHA instructions, so all three are required. */
static int host_has_shani(void)
{
  unsigned int eax = 0, ebx = 0, ecx = 0, edx = 0;

  if (!__get_cpuid(1, &eax, &ebx, &ecx, &edx)) return 0;
  if (!(ecx & (1u <<  9))) return 0;   /* SSSE3  */
  if (!(ecx & (1u << 19))) return 0;   /* SSE4.1 */

  eax = ebx = ecx = edx = 0;
  if (!__get_cpuid_count(7, 0, &eax, &ebx, &ecx, &edx)) return 0;
  return (ebx & (1u << 29)) != 0;      /* SHA    */
}

#endif /* GETACA_SHANI */

/* ------------------------------------------------- ARMv8 crypto extensions */

/*
 * Compiled only when the compiler is already targeting a machine with the
 * SHA-256 instructions, which is the default on Apple silicon and an explicit
 * `-march=armv8-a+crypto` elsewhere. Nothing is decided at run time: a host
 * that does not advertise the extension never compiles this path in.
 */
#if defined(__aarch64__) && (defined(__ARM_FEATURE_CRYPTO) || defined(__ARM_FEATURE_SHA2))
#  define GETACA_ARMCE 1
#  include <arm_neon.h>
#endif

#ifdef GETACA_ARMCE

#define ARMCE_GROUP(gi, cur, n1, n2, n3)                                      \
  do {                                                                        \
    uint32x4_t kw = vaddq_u32(cur, vld1q_u32(K + 4 * (gi)));                  \
    uint32x4_t before = s0;                                                   \
    s0 = vsha256hq_u32(s0, s1, kw);                                           \
    s1 = vsha256h2q_u32(s1, before, kw);                                      \
    if ((gi) < 12) cur = vsha256su1q_u32(vsha256su0q_u32(cur, n1), n2, n3);   \
  } while (0)

static void blocks_armce(uint32_t *state, const unsigned char *data, size_t nblocks)
{
  uint32x4_t s0 = vld1q_u32(&state[0]);
  uint32x4_t s1 = vld1q_u32(&state[4]);

  while (nblocks--) {
    uint32x4_t abcd = s0, efgh = s1, w0, w1, w2, w3;

    w0 = vreinterpretq_u32_u8(vrev32q_u8(vld1q_u8(data +  0)));
    w1 = vreinterpretq_u32_u8(vrev32q_u8(vld1q_u8(data + 16)));
    w2 = vreinterpretq_u32_u8(vrev32q_u8(vld1q_u8(data + 32)));
    w3 = vreinterpretq_u32_u8(vrev32q_u8(vld1q_u8(data + 48)));

    ARMCE_GROUP( 0, w0, w1, w2, w3);
    ARMCE_GROUP( 1, w1, w2, w3, w0);
    ARMCE_GROUP( 2, w2, w3, w0, w1);
    ARMCE_GROUP( 3, w3, w0, w1, w2);
    ARMCE_GROUP( 4, w0, w1, w2, w3);
    ARMCE_GROUP( 5, w1, w2, w3, w0);
    ARMCE_GROUP( 6, w2, w3, w0, w1);
    ARMCE_GROUP( 7, w3, w0, w1, w2);
    ARMCE_GROUP( 8, w0, w1, w2, w3);
    ARMCE_GROUP( 9, w1, w2, w3, w0);
    ARMCE_GROUP(10, w2, w3, w0, w1);
    ARMCE_GROUP(11, w3, w0, w1, w2);
    ARMCE_GROUP(12, w0, w1, w2, w3);
    ARMCE_GROUP(13, w1, w2, w3, w0);
    ARMCE_GROUP(14, w2, w3, w0, w1);
    ARMCE_GROUP(15, w3, w0, w1, w2);

    s0 = vaddq_u32(s0, abcd);
    s1 = vaddq_u32(s1, efgh);
    data += SHA256_BLOCK_LENGTH;
  }

  vst1q_u32(&state[0], s0);
  vst1q_u32(&state[4], s1);
}

#endif /* GETACA_ARMCE */

/* ------------------------------------------------------------------ dispatch */

/*
 * Compiling a path in is not the same as the host being able to run it. Every
 * x86-64 build carries blocks_shani, because the compiler can always emit it,
 * and a machine whose CPU lacks the SHA extension does not get a wrong digest
 * from it: the first instruction traps and takes the session with it. So a
 * path also carries the question of whether it can run here, and every answer
 * below is drawn from the paths that can.
 *
 * The portable path is first because it is the one every build has, and the
 * accelerated paths follow it, so the last runnable entry is the fastest one
 * this host offers.
 */
static const struct {
  const char *name;
  sha256_blocks_fn fn;
  /* NULL where compiling the path already settles it. */
  int (*runnable)(void);
} paths[] = {
  {"portable",  blocks_plain, NULL},
#ifdef GETACA_SHANI
  {"x86-shani", blocks_shani, host_has_shani},
#endif
#ifdef GETACA_ARMCE
  {"arm-sha2",  blocks_armce, NULL},
#endif
  {NULL, NULL, NULL}
};

#define PATH_COUNT ((int) (sizeof paths / sizeof paths[0]))

/* Indices into paths[], settled once at load. The initial state names the
   portable path alone, so a digest taken before the selection runs still has a
   path it can execute. */
static int runnable[PATH_COUNT];
static int n_runnable = 1;
static int selected = 0;

static int find_path(const char *name)
{
  int i;
  for (i = 0; i < n_runnable; i++) {
    if (strcmp(paths[runnable[i]].name, name) == 0) return runnable[i];
  }
  return -1;
}

void sha256_backend_select(void)
{
  int i;

  n_runnable = 0;
  for (i = 0; paths[i].name != NULL; i++) {
    if (paths[i].runnable == NULL || paths[i].runnable()) {
      runnable[n_runnable++] = i;
    }
  }
  selected = runnable[n_runnable - 1];
}

const char *sha256_backend_name(void)
{
  return paths[selected].name;
}

int sha256_backend_count(void)
{
  return n_runnable;
}

const char *sha256_backend_at(int i)
{
  if (i < 0 || i >= n_runnable) return NULL;
  return paths[runnable[i]].name;
}

/* ----------------------------------------------------------------- streaming */

void sha256_start(sha256_ctx *ctx)
{
  memcpy(ctx->state, H0, sizeof(H0));
  ctx->held = 0;
  ctx->bytes = 0;
  ctx->compress = paths[selected].fn;
}

int sha256_start_with(sha256_ctx *ctx, const char *backend)
{
  int i = find_path(backend);
  if (i < 0) return 0;
  sha256_start(ctx);
  ctx->compress = paths[i].fn;
  return 1;
}

void sha256_update(sha256_ctx *ctx, const unsigned char *data, size_t len)
{
  ctx->bytes += (uint64_t) len;

  if (ctx->held) {
    size_t want = SHA256_BLOCK_LENGTH - ctx->held;
    if (len < want) {
      memcpy(ctx->block + ctx->held, data, len);
      ctx->held += len;
      return;
    }
    memcpy(ctx->block + ctx->held, data, want);
    ctx->compress(ctx->state, ctx->block, 1);
    ctx->held = 0;
    data += want;
    len -= want;
  }

  if (len >= SHA256_BLOCK_LENGTH) {
    size_t whole = len / SHA256_BLOCK_LENGTH;
    ctx->compress(ctx->state, data, whole);
    data += whole * SHA256_BLOCK_LENGTH;
    len -= whole * SHA256_BLOCK_LENGTH;
  }

  if (len) {
    memcpy(ctx->block, data, len);
    ctx->held = len;
  }
}

/* FIPS 180-4 section 5.1.1: a single 1 bit, zeroes, then the message length in
   bits as a big-endian 64-bit value, filling the block it lands in. */
void sha256_final(sha256_ctx *ctx, unsigned char out[SHA256_DIGEST_LENGTH])
{
  uint64_t bits = ctx->bytes << 3;
  size_t at = ctx->held;
  int i;

  ctx->block[at++] = 0x80;
  if (at > SHA256_BLOCK_LENGTH - 8) {
    memset(ctx->block + at, 0, SHA256_BLOCK_LENGTH - at);
    ctx->compress(ctx->state, ctx->block, 1);
    at = 0;
  }
  memset(ctx->block + at, 0, SHA256_BLOCK_LENGTH - 8 - at);
  for (i = 0; i < 8; i++) {
    ctx->block[SHA256_BLOCK_LENGTH - 1 - i] = (unsigned char) (bits >> (8 * i));
  }
  ctx->compress(ctx->state, ctx->block, 1);

  for (i = 0; i < 8; i++) {
    out[4 * i]     = (unsigned char) (ctx->state[i] >> 24);
    out[4 * i + 1] = (unsigned char) (ctx->state[i] >> 16);
    out[4 * i + 2] = (unsigned char) (ctx->state[i] >>  8);
    out[4 * i + 3] = (unsigned char) (ctx->state[i]);
  }
}
