test_that("a cached resource is returned without touching the network", {
  cache <- local_cache()
  src <- withr::local_tempdir()
  f <- seed_file(src)
  reg <- demo_registry(f$sha256)
  seeded <- seed_cache(reg, f)

  # The declared URL is unresolvable, so a network attempt would fail loudly.
  expect_equal(getaca("res", registry = reg), seeded$path)
})

test_that("provenance survives the round trip", {
  cache <- local_cache()
  src <- withr::local_tempdir()
  f <- seed_file(src)
  reg <- demo_registry(f$sha256, licence = "CC-BY-4.0")
  seed_cache(reg, f)

  info <- getaca_info("res", registry = reg)
  expect_s3_class(info, "getaca_entry")
  expect_equal(info$declared_sha256, f$sha256)
  expect_equal(info$observed_sha256, f$sha256)
  expect_equal(info$licence, "CC-BY-4.0")
  expect_equal(info$source, "bundled")
  expect_equal(format(info$id), "demopkg/res@1.0")
})

test_that("the catalogue reports what is cached", {
  cache <- local_cache()
  src <- withr::local_tempdir()
  f <- seed_file(src)
  reg <- demo_registry(f$sha256)
  seed_cache(reg, f)

  cat_df <- getaca_catalogue()
  expect_equal(nrow(cat_df), 1L)
  expect_equal(cat_df$package, "demopkg")
  expect_equal(cat_df$name, "res")
  expect_equal(cat_df$version, "1.0")
})

test_that("an empty cache produces an empty catalogue, not an error", {
  cache <- local_cache()
  expect_equal(nrow(getaca_catalogue()), 0L)
})

test_that("forced verification catches a substituted file of the same size", {
  cache <- local_cache()
  src <- withr::local_tempdir()
  f <- seed_file(src, contents = "aaaaaaaa")
  reg <- demo_registry(f$sha256)
  seeded <- seed_cache(reg, f)

  # Same length, different bytes: the cheap check cannot see this, which is
  # exactly why periodic and forced full re-hashing exist.
  writeBin(charToRaw("bbbbbbbb"), seeded$path)
  expect_identical(unname(file.info(seeded$path)$size), seeded$entry$size)
  expect_true(getaca:::cheap_check_ok(seeded$entry))

  expect_error(
    getaca("res", registry = reg, verify = TRUE),
    class = "getaca_error_cache_corrupt"
  )
})

test_that("a truncated cache entry is caught by the cheap check", {
  cache <- local_cache()
  src <- withr::local_tempdir()
  f <- seed_file(src, contents = strrep("x", 100))
  reg <- demo_registry(f$sha256)
  seeded <- seed_cache(reg, f)

  writeBin(charToRaw("short"), seeded$path)
  expect_false(getaca:::cheap_check_ok(seeded$entry))
  expect_error(
    getaca("res", registry = reg),
    class = "getaca_error_cache_corrupt"
  )
})

test_that("availability is a plain logical and never reaches the network", {
  cache <- local_cache()
  src <- withr::local_tempdir()
  f <- seed_file(src)
  reg <- demo_registry(f$sha256)

  expect_false(getaca_available("res", registry = reg))
  seed_cache(reg, f)
  expect_true(getaca_available("res", registry = reg))
})

test_that("an uncached resource under offline policy names the prefetch call", {
  cache <- local_cache()
  reg <- demo_registry(strrep("a", 64))
  withr::local_envvar(list(GETACA_OFFLINE = "true"))

  expect_error(getaca("res", registry = reg), class = "getaca_error_offline")
  expect_error(getaca("res", registry = reg), class = "getaca_error_unavailable")
  expect_error(getaca("res", registry = reg), "getaca_prefetch")
})

test_that("getaca_optional degrades to NULL with a message", {
  cache <- local_cache()
  reg <- demo_registry(strrep("a", 64))
  withr::local_envvar(list(GETACA_OFFLINE = "true"))

  expect_message(res <- getaca_optional("res", registry = reg))
  expect_null(res)
})

test_that("the index survives a write that finds an existing file", {
  cache <- local_cache()
  src <- withr::local_tempdir()
  f <- seed_file(src)
  reg <- demo_registry(f$sha256)
  seeded <- seed_cache(reg, f)

  getaca:::put_entry(seeded$entry)
  getaca:::put_entry(seeded$entry)
  expect_equal(length(getaca:::read_index("demopkg")), 1L)
})
