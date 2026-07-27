# A signature is checked in two halves: the cryptography, and the adjudication
# that decides what a valid signature actually establishes. The second half is
# where the interesting failures live, so signature_problem() is driven
# directly rather than only through a file.

signing_key <- function(env = parent.frame()) {
  path <- withr::local_tempfile(.local_envir = env)
  list(path = path, public = registry_keygen(path))
}

signed_registry <- function(key, created = as.POSIXct("2026-01-01", tz = "UTC"),
                            expires = as.POSIXct("2026-12-31", tz = "UTC"),
                            sha = strrep("a", 64), env = parent.frame()) {
  dir <- withr::local_tempdir(.local_envir = env)
  path <- file.path(dir, "registry.rds")
  reg <- registry(
    "demopkg",
    remote = "https://registry.invalid/demopkg.rds",
    keys = key$public,
    resources = list(
      resource("res", "1.0", urls = "https://example.invalid/res.csv", sha256 = sha)
    )
  )
  registry_write(reg, path, created = created)
  registry_sign(path, key = key$path, expires = expires)
  list(path = path, registry = registry_read(path))
}

test_that("a generated key round-trips through its file", {
  key <- signing_key()
  expect_match(key$public, "^ed25519:[0-9a-f]{64}$")

  stored <- getaca:::read_key_file(key$path)
  expect_length(stored$secret, 64L)
  expect_equal(stored$public, key$public)
  # The expanded secret carries the public half in its tail, which is what
  # lets signing name the key it used.
  expect_equal(paste0("ed25519:", getaca:::raw_to_hex(stored$secret[33:64])),
               key$public)
})

test_that("a key derives reproducibly from a fixed seed", {
  a <- withr::local_tempfile()
  b <- withr::local_tempfile()
  seed <- as.raw(rep(7L, 32L))
  expect_equal(registry_keygen(a, seed = seed), registry_keygen(b, seed = seed))
  expect_error(registry_keygen(withr::local_tempfile(), seed = as.raw(1:8)),
               "32 raw bytes")
})

test_that("a signed registry verifies", {
  key <- signing_key()
  signed <- signed_registry(key)
  expect_true(registry_verify(signed$path))
})

test_that("the signature file says what it covers", {
  key <- signing_key()
  signed <- signed_registry(key)
  sig <- getaca:::signature_read(getaca:::signature_path(signed$path))

  expect_equal(sig$format, getaca:::SIGNATURE_FORMAT)
  expect_equal(sig$digest, registry_digest(signed$registry))
  expect_equal(sig$created, "2026-01-01T00:00:00Z")
  expect_equal(sig$key, key$public)
  expect_match(sig$sig, "^ed25519:[0-9a-f]{128}$")
})

test_that("an unwritten registry cannot be signed", {
  key <- signing_key()
  dir <- withr::local_tempdir()
  path <- file.path(dir, "registry.rds")
  reg <- registry("demopkg", keys = key$public,
                  resources = list(resource("res", "1.0",
                                            urls = "https://example.invalid/res.csv",
                                            sha256 = strrep("a", 64))))
  # Written by saveRDS() rather than registry_write(), so it carries no stamp.
  saveRDS(reg, path, version = 3)
  expect_error(registry_sign(path, key = key$path), "created")
})

test_that("a registry edited after signing no longer verifies", {
  key <- signing_key()
  signed <- signed_registry(key)

  moved <- signed$registry
  moved$resources[[1]]$urls <- "https://elsewhere.invalid/res.csv"
  saveRDS(moved, signed$path, version = 3)

  expect_error(registry_verify(signed$path), class = "getaca_error_signature")
  expect_error(registry_verify(signed$path), "signature covers")
})

test_that("a missing signature is refused rather than ignored", {
  key <- signing_key()
  signed <- signed_registry(key)
  unlink(getaca:::signature_path(signed$path))

  expect_error(registry_verify(signed$path), class = "getaca_error_signature")
  expect_error(registry_verify(signed$path), "no readable signature")
})

# ---------------------------------------------------------------- adjudication

# The parts of a verification that are decisions rather than arithmetic, each
# reachable without writing a file.
problem_for <- function(key, ..., keys = key$public, now = as.POSIXct("2026-06-01", tz = "UTC"),
                        floor = NULL, env = parent.frame()) {
  signed <- signed_registry(key, ..., env = env)
  sig <- getaca:::signature_read(getaca:::signature_path(signed$path))
  getaca:::signature_problem(sig, signed$registry, keys, now = now, floor = floor)
}

test_that("a signature from an untrusted key is refused by name", {
  key <- signing_key()
  other <- signing_key()

  problem <- problem_for(key, keys = other$public)
  expect_match(problem, "does not list as a signing key")
  expect_match(problem, substr(key$public, 1, 20), fixed = TRUE)
})

test_that("a registry that trusts no key cannot be signed into trust", {
  key <- signing_key()
  expect_match(problem_for(key, keys = character()), "declares no signing keys")
})

test_that("an expired signature is refused", {
  key <- signing_key()
  problem <- problem_for(key, expires = as.POSIXct("2026-03-01", tz = "UTC"),
                         now = as.POSIXct("2026-06-01", tz = "UTC"))
  expect_match(problem, "expired on 2026-03-01")

  # The same signature, judged before its expiry.
  expect_null(problem_for(key, expires = as.POSIXct("2026-03-01", tz = "UTC"),
                          now = as.POSIXct("2026-02-01", tz = "UTC")))
})

test_that("a signature with no expiry never expires", {
  key <- signing_key()
  expect_null(problem_for(key, expires = NA,
                          now = as.POSIXct("2099-01-01", tz = "UTC")))
})

test_that("a declaration older than the installed one is refused as a rollback", {
  key <- signing_key()
  problem <- problem_for(key, created = as.POSIXct("2026-01-01", tz = "UTC"),
                         floor = as.POSIXct("2026-05-01", tz = "UTC"))
  expect_match(problem, "older than the declaration already installed")

  # A remote ahead of the installed declaration is the ordinary case.
  expect_null(problem_for(key, created = as.POSIXct("2026-01-01", tz = "UTC"),
                          floor = as.POSIXct("2025-01-01", tz = "UTC")))
})

test_that("a signature from a newer format is refused rather than guessed at", {
  key <- signing_key()
  signed <- signed_registry(key)
  sig <- getaca:::signature_read(getaca:::signature_path(signed$path))
  sig$format <- getaca:::SIGNATURE_FORMAT + 1L

  problem <- getaca:::signature_problem(sig, signed$registry, key$public)
  expect_match(problem, "newer than this getaca reads")
})

test_that("a malformed signature file is refused", {
  key <- signing_key()
  signed <- signed_registry(key)
  sig <- getaca:::signature_read(getaca:::signature_path(signed$path))

  broken <- sig
  broken$sig <- "ed25519:not-hex"
  expect_match(getaca:::signature_problem(broken, signed$registry, key$public),
               "malformed")

  broken <- sig
  broken$key <- "rsa:0011"
  expect_match(getaca:::signature_problem(broken, signed$registry, key$public),
               "malformed")

  # A signature naming no key at all, which cannot be checked against the
  # trusted set and so never reaches it.
  broken <- sig
  broken$key <- NULL
  expect_match(getaca:::signature_problem(broken, signed$registry, key$public),
               "malformed")
})

test_that("a signature whose bytes were altered does not verify", {
  key <- signing_key()
  signed <- signed_registry(key)
  path <- getaca:::signature_path(signed$path)

  lines <- readLines(path)
  at <- grep("^created ", lines)
  lines[at] <- "created 2026-06-01T00:00:00Z"
  writeLines(lines, path)

  # The claim moved, and the signature covers the claim.
  expect_error(registry_verify(signed$path), "does not match these bytes")
})

test_that("a signature and a registry must agree on the publication time", {
  key <- signing_key()
  signed <- signed_registry(key)

  # Rewritten with a later stamp, which the digest does not cover because
  # `created` is deliberately outside the manifest. The signature does cover
  # it, which is what closes that gap.
  moved <- signed$registry
  registry_write(moved, signed$path, created = as.POSIXct("2026-06-01", tz = "UTC"))

  expect_error(registry_verify(signed$path), class = "getaca_error_signature")
  expect_error(registry_verify(signed$path), "disagree about when it was published")
})

# A time the signature covers but this getaca cannot read is a signature that
# establishes nothing about freshness, so both stamps fail closed rather than
# being treated as absent. Mutating the parsed object leaves the payload alone,
# so the cryptography still passes and the decision under test is the one
# reached.
test_that("a publication time that cannot be read is refused, not skipped", {
  key <- signing_key()
  signed <- signed_registry(key)
  sig <- getaca:::signature_read(getaca:::signature_path(signed$path))

  garbled <- sig
  garbled$created <- "the first of January"
  expect_match(getaca:::signature_problem(garbled, signed$registry, key$public),
               "no readable publication time")

  absent <- sig
  absent$created <- NULL
  expect_match(getaca:::signature_problem(absent, signed$registry, key$public),
               "no readable publication time")
})

test_that("an expiry that cannot be read is refused rather than ignored", {
  key <- signing_key()
  signed <- signed_registry(key)
  sig <- getaca:::signature_read(getaca:::signature_path(signed$path))
  sig$expires <- "whenever"

  expect_match(getaca:::signature_problem(sig, signed$registry, key$public),
               "no readable expiry")
})

# signature_read() answers one question: is there a signature here to check.
# Every no is the same answer, so that resolution can tell "nothing to check"
# from "checked and failed" without parsing error text.
test_that("anything that is not a signature file reads as no signature", {
  path <- withr::local_tempfile()

  writeLines("digest sha256:0000", path)
  expect_null(getaca:::signature_read(path))

  writeLines(c("getaca-signature one", "sig ed25519:00"), path)
  expect_null(getaca:::signature_read(path))

  # A file that names no signature covers nothing, whatever else it carries.
  writeLines(c(paste("getaca-signature", getaca:::SIGNATURE_FORMAT),
               "digest sha256:0000"), path)
  expect_null(getaca:::signature_read(path))
})

test_that("a signing key that is absent or unreadable says which", {
  dir <- withr::local_tempdir()
  missing <- file.path(dir, "no-such-key")
  expect_error(getaca:::read_key_file(missing), "No signing key at")
  expect_error(getaca:::read_key_file(missing), "registry_keygen")

  not_a_key <- file.path(dir, "notes.txt")
  writeLines(c("getaca-key 1", "secret ed25519:xyz"), not_a_key)
  expect_error(getaca:::read_key_file(not_a_key), "not readable as one")
})

# ---------------------------------------------------------------------- model

test_that("a registry refuses a key it cannot parse", {
  make <- function(keys) {
    registry("demopkg", keys = keys,
             resources = list(resource("res", "1.0",
                                       urls = "https://example.invalid/res.csv",
                                       sha256 = strrep("a", 64))))
  }
  expect_error(make("not-a-key"), class = "getaca_error_invalid_registry")
  expect_error(make("ed25519:abc"), "64 hex characters")
  expect_error(make("ed25519:ZZZZ"), "64 hex characters")
  expect_silent(make(paste0("ed25519:", strrep("a", 64))))
})

test_that("signing keys are part of the declaration a digest identifies", {
  key <- signing_key()
  resources <- list(resource("res", "1.0",
                             urls = "https://example.invalid/res.csv",
                             sha256 = strrep("a", 64)))
  bare <- registry("demopkg", resources = resources)
  keyed <- registry("demopkg", resources = resources, keys = key$public)

  expect_false(identical(registry_digest(bare), registry_digest(keyed)))
  expect_true(any(grepl("^key ed25519:", registry_manifest(keyed))))
  # A registry declaring no key renders what it always did, which is what let
  # the field arrive without invalidating a digest already in someone's
  # provenance.
  expect_false(any(grepl("^key ", registry_manifest(bare))))
})

test_that("the key set is sorted, so declaration order is not identity", {
  a <- paste0("ed25519:", strrep("1", 64))
  b <- paste0("ed25519:", strrep("2", 64))
  resources <- list(resource("res", "1.0",
                             urls = "https://example.invalid/res.csv",
                             sha256 = strrep("a", 64)))

  expect_equal(
    registry_digest(registry("demopkg", resources = resources, keys = c(a, b))),
    registry_digest(registry("demopkg", resources = resources, keys = c(b, a)))
  )
})
