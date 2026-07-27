/* Ed25519 (RFC 8032), detached signatures. */

#ifndef GETACA_ED25519_H
#define GETACA_ED25519_H

#include <stddef.h>

#define ED25519_PUBLIC_LENGTH  32
#define ED25519_SECRET_LENGTH  64
#define ED25519_SEED_LENGTH    32
#define ED25519_SIGNATURE_LENGTH 64

/* The secret key is the RFC 8032 expanded form: the 32-byte seed followed by
   the public key it derives, which is what lets signing recover the public key
   without carrying it separately. */
int ed25519_keypair(unsigned char pk[ED25519_PUBLIC_LENGTH],
                    unsigned char sk[ED25519_SECRET_LENGTH],
                    const unsigned char seed[ED25519_SEED_LENGTH]);

void ed25519_sign(unsigned char sig[ED25519_SIGNATURE_LENGTH],
                  const unsigned char *m, size_t n,
                  const unsigned char sk[ED25519_SECRET_LENGTH]);

/* Non-zero when the signature is valid for these bytes under this key. */
int ed25519_verify(const unsigned char sig[ED25519_SIGNATURE_LENGTH],
                   const unsigned char *m, size_t n,
                   const unsigned char pk[ED25519_PUBLIC_LENGTH]);

/* Fills `out` from the operating system's cryptographic random source.
   Non-zero on success; a caller that gets zero must not invent a key. */
int ed25519_random(unsigned char *out, size_t n);

#endif
