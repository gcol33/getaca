# The signature scheme is held against its published vectors rather than
# against itself. A primitive that agrees with its own output proves only that
# it is deterministic, which every wrong implementation also is.

hex_raw <- function(x) getaca:::hex_to_raw(x)
raw_hex <- function(x) getaca:::raw_to_hex(x)

test_that("SHA-512 matches the FIPS 180-4 vectors", {
  digest <- function(s) getaca:::sha512_bytes(charToRaw(s))

  expect_equal(
    digest(""),
    paste0("cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce",
           "47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e")
  )
  expect_equal(
    digest("abc"),
    paste0("ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a",
           "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
  )
  expect_equal(
    digest("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
    paste0("204a8fc6dda82f0a0ced7beb8e08a41657c16ef468b228a8279be331a703c335",
           "96fd15c13b1b07f9aa1d3bea57789ca031ad85c7a71dd70354ec631238ca3445")
  )
})

test_that("SHA-512 absorbs a multi-block message correctly", {
  # 1,000,000 'a' characters, the FIPS 180-4 long vector, which is the only
  # one here that exercises the streaming path across many blocks.
  million <- paste(rep("a", 1e6L), collapse = "")
  expect_equal(
    getaca:::sha512_bytes(charToRaw(million)),
    paste0("e718483d0ce769644e2e42c7bc15b4638e1f98b13b2044285632a803afa973eb",
           "de0ff244877ea60a4cb0432ce577c31beb009c5c2c49aa2e4eadb217ad8cc09b")
  )
})

# RFC 8032 section 7.1. Each case gives the secret seed, the public key it
# derives, the message and the signature, so key derivation and signing are
# both checked against a value neither this code nor this machine produced.
rfc8032 <- list(
  list(
    seed = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
    public = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
    message = "",
    signature = paste0(
      "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155",
      "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b")
  ),
  list(
    seed = "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
    public = "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
    message = "72",
    signature = paste0(
      "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da",
      "085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00")
  ),
  list(
    seed = "c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
    public = "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025",
    message = "af82",
    signature = paste0(
      "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac",
      "18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a")
  )
)

test_that("Ed25519 derives the public keys RFC 8032 gives", {
  for (v in rfc8032) {
    pair <- getaca:::ed25519_keypair(hex_raw(v$seed))
    expect_equal(raw_hex(pair$public), v$public)
  }
})

test_that("Ed25519 produces the signatures RFC 8032 gives", {
  for (v in rfc8032) {
    pair <- getaca:::ed25519_keypair(hex_raw(v$seed))
    sig <- getaca:::ed25519_sign(hex_raw(v$message), pair$secret)
    expect_equal(raw_hex(sig), v$signature)
  }
})

test_that("Ed25519 accepts the signatures RFC 8032 gives", {
  for (v in rfc8032) {
    expect_true(getaca:::ed25519_verify(
      hex_raw(v$signature), hex_raw(v$message), hex_raw(v$public)
    ))
  }
})

test_that("a signature is refused for anything it was not made over", {
  v <- rfc8032[[3]]
  sig <- hex_raw(v$signature)
  message <- hex_raw(v$message)
  public <- hex_raw(v$public)

  flip <- function(x, i) {
    x[i] <- as.raw(bitwXor(as.integer(x[i]), 1L))
    x
  }

  expect_false(getaca:::ed25519_verify(sig, flip(message, 1L), public))
  expect_false(getaca:::ed25519_verify(flip(sig, 1L), message, public))
  expect_false(getaca:::ed25519_verify(flip(sig, 40L), message, public))
  expect_false(getaca:::ed25519_verify(sig, message, flip(public, 1L)))
  expect_false(getaca:::ed25519_verify(sig, raw(0), public))
})

test_that("a signature carrying a non-canonical scalar is refused", {
  # S and S + L satisfy the verification equation equally, so a scheme that
  # does not require S < L lets a third party derive a second valid signature
  # over bytes that were signed once. The order, little-endian, added into the
  # scalar half:
  v <- rfc8032[[3]]
  sig <- hex_raw(v$signature)
  order <- hex_raw(paste0("edd3f55c1a631258d69cf7a2def9de14",
                          strrep("00", 15L), "10"))

  expect_true(getaca:::ed25519_verify(sig, hex_raw(v$message), hex_raw(v$public)))

  # S + L, carried by hand across the 32 bytes of the scalar half.
  s <- as.integer(sig[33:64])
  l <- as.integer(order[1:32])
  carry <- 0L
  for (i in seq_len(32L)) {
    total <- s[i] + l[i] + carry
    s[i] <- total %% 256L
    carry <- total %/% 256L
  }
  malleable <- sig
  malleable[33:64] <- as.raw(s)

  expect_false(identical(malleable, sig))
  expect_false(getaca:::ed25519_verify(malleable, hex_raw(v$message), hex_raw(v$public)))
})

test_that("a key pair from the operating system signs and verifies", {
  pair <- getaca:::ed25519_keypair()
  expect_length(pair$public, 32L)
  expect_length(pair$secret, 64L)

  message <- charToRaw("a registry manifest stands in for itself here")
  sig <- getaca:::ed25519_sign(message, pair$secret)
  expect_length(sig, 64L)
  expect_true(getaca:::ed25519_verify(sig, message, pair$public))

  # Two calls must not produce one key, which is what a random source that
  # silently failed would look like.
  other <- getaca:::ed25519_keypair()
  expect_false(identical(pair$public, other$public))
  expect_false(getaca:::ed25519_verify(sig, message, other$public))
})

test_that("verification refuses a key or signature of the wrong size", {
  pair <- getaca:::ed25519_keypair(hex_raw(rfc8032[[1]]$seed))
  message <- charToRaw("x")
  sig <- getaca:::ed25519_sign(message, pair$secret)

  expect_false(getaca:::ed25519_verify(sig[1:63], message, pair$public))
  expect_false(getaca:::ed25519_verify(sig, message, pair$public[1:31]))
})
