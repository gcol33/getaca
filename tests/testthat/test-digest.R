# The digest is the one thing every other guarantee in the package rests on, so
# it is held against three independent references: the published FIPS 180-4
# vectors, R's own implementation, and every other compression path compiled
# into this build.

# tools::sha256sum() arrived in R 4.6.0, which is above the floor this package
# supports, so the checks that use it as an outside reference are the only ones
# that can be skipped. The vectors and the cross-path comparison run everywhere.
needs_r_reference <- function() {
  testthat::skip_if(getRversion() < "4.6.0", "tools::sha256sum() needs R >= 4.6.0")
}

test_that("the published FIPS 180-4 vectors come out right", {
  expect_equal(getaca:::sha256_bytes(raw(0)),
               "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
  expect_equal(getaca:::sha256_bytes(charToRaw("abc")),
               "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  expect_equal(
    getaca:::sha256_bytes(charToRaw(paste0("abcdbcdecdefdefgefghfghighijhijkijkl",
                                           "jklmklmnlmnomnopnopq"))),
    "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
  expect_equal(getaca:::sha256_bytes(charToRaw(strrep("a", 1e6))),
               "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
})

# Padding is where a hash implementation goes wrong, so the sizes swept include
# every offset within a block and both sides of the boundary where the length
# word stops fitting in the block it lands in.
test_that("hashing bytes agrees with tools::sha256sum across every block offset", {
  needs_r_reference()
  set.seed(20260727)
  for (n in c(0:129, 190:195, 254:258, 511:513)) {
    bytes <- if (n == 0) raw(0) else as.raw(sample.int(256L, n, replace = TRUE) - 1L)
    expect_equal(getaca:::sha256_bytes(bytes), unname(tools::sha256sum(bytes = bytes)),
                 info = paste("length", n))
  }
})

test_that("hashing a file agrees with tools::sha256sum across the read chunk", {
  needs_r_reference()
  set.seed(20260727)
  path <- withr::local_tempfile()
  chunk <- 1024L^2L
  for (n in c(0L, 1L, 63L, 64L, 65L, chunk - 1L, chunk, chunk + 1L, 2L * chunk + 17L)) {
    writeBin(if (n == 0L) raw(0) else as.raw(sample.int(256L, n, replace = TRUE) - 1L),
             path)
    expect_equal(getaca:::sha256_file(path), unname(tools::sha256sum(path)),
                 info = paste("length", n))
  }
})

# A host selects one compression path and never exercises the others, so the
# comparison has to be asked for explicitly or an accelerated machine would
# never test the portable path it falls back to.
test_that("every compiled compression path agrees with the others", {
  backends <- getaca:::sha256_backends()
  expect_true("portable" %in% backends)
  expect_true(getaca:::sha256_backend() %in% backends)

  # The portable path is the reference because it is the one path every build
  # has, and the vectors above are what tie it to the standard.
  set.seed(20260727)
  for (n in c(0:70, 118:130, 254:258, 1000L)) {
    bytes <- if (n == 0) raw(0) else as.raw(sample.int(256L, n, replace = TRUE) - 1L)
    reference <- getaca:::sha256_bytes(bytes, "portable")
    for (backend in backends) {
      expect_equal(getaca:::sha256_bytes(bytes, backend), reference,
                   info = paste(backend, "length", n))
    }
  }
})

test_that("an unnamed backend is refused rather than quietly substituted", {
  expect_error(getaca:::sha256_bytes(raw(0), "not-a-backend"), "no sha256 backend")
})

test_that("a file that cannot be read digests to NA", {
  expect_true(is.na(getaca:::sha256_file(file.path(tempdir(), "absent-a4f2c1"))))
  expect_true(is.na(getaca:::sha256_file(NA_character_)))
})

test_that("a directory digests to NA rather than to the empty digest", {
  dir <- withr::local_tempdir()
  expect_true(is.na(getaca:::sha256_file(dir)))
})

test_that("the digest of raw bytes and of the same bytes on disk agree", {
  bytes <- as.raw(0:255)
  path <- withr::local_tempfile()
  writeBin(bytes, path)
  expect_equal(getaca:::sha256_file(path), getaca:::sha256_bytes(bytes))
})

test_that("registry_digest hashes the manifest text, not the R object", {
  reg <- demo_registry(strrep("a", 64))
  text <- paste0(paste(unclass(registry_manifest(reg)), collapse = "\n"), "\n")
  expect_equal(registry_digest(reg),
               paste0("sha256:", getaca:::sha256_bytes(charToRaw(enc2utf8(text)))))
})
