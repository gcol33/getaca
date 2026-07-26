test_that("broken entries are swept and their records dropped", {
  cache <- local_cache()
  src <- withr::local_tempdir()
  f <- seed_file(src)
  reg <- demo_registry(f$sha256)
  seeded <- seed_cache(reg, f)

  unlink(seeded$path)
  out <- getaca_clean(package = "demopkg", what = "broken")
  expect_equal(nrow(out), 1L)
  expect_equal(out$reason, "broken or incomplete")
  expect_equal(length(getaca:::read_index("demopkg")), 0L)
})

test_that("a dry run reports without removing", {
  cache <- local_cache()
  src <- withr::local_tempdir()
  f <- seed_file(src)
  reg <- demo_registry(f$sha256)
  seeded <- seed_cache(reg, f)
  unlink(seeded$path)

  out <- getaca_clean(package = "demopkg", what = "broken", dry_run = TRUE)
  expect_equal(nrow(out), 1L)
  expect_equal(length(getaca:::read_index("demopkg")), 1L)
})

test_that("a healthy cache is left alone", {
  cache <- local_cache()
  src <- withr::local_tempdir()
  f <- seed_file(src)
  reg <- demo_registry(f$sha256)
  seed_cache(reg, f)

  out <- getaca_clean(package = "demopkg", what = c("broken", "superseded"))
  expect_equal(nrow(out), 0L)
  expect_equal(length(getaca:::read_index("demopkg")), 1L)
})

test_that("abandoned transfers are swept once stale", {
  cache <- local_cache()
  tmp <- getaca:::cache_tmp_dir()
  part <- file.path(tmp, "deadbeef.part")
  writeLines("partial", part)
  Sys.setFileTime(part, Sys.time() - 30 * 86400)

  out <- getaca_clean(what = "temp")
  expect_equal(nrow(out), 1L)
  expect_equal(out$reason, "abandoned transfer")
  expect_false(file.exists(part))
})

test_that("a recent transfer is not mistaken for an abandoned one", {
  cache <- local_cache()
  tmp <- getaca:::cache_tmp_dir()
  part <- file.path(tmp, "fresh.part")
  writeLines("partial", part)

  out <- getaca_clean(what = "temp")
  expect_equal(nrow(out), 0L)
  expect_true(file.exists(part))
})

test_that("a pinned entry is never collected", {
  cache <- local_cache()
  src <- withr::local_tempdir()
  f <- seed_file(src)
  reg <- demo_registry(f$sha256)
  seed_cache(reg, f)

  getaca_keep("res", registry = reg)
  expect_true(getaca_info("res", registry = reg)$pinned)

  withr::local_options(list(getaca.max_bytes = 1, getaca.supersede_days = -1))
  out <- getaca_clean(package = "demopkg", what = c("superseded", "lru"))
  expect_equal(nrow(out), 0L)
  expect_equal(length(getaca:::read_index("demopkg")), 1L)
})

test_that("size ceiling eviction takes the least recently used first", {
  cache <- local_cache()
  src <- withr::local_tempdir()

  for (v in c("1.0", "2.0")) {
    f <- seed_file(src, contents = paste0("payload-", v, "\n"), name = paste0(v, ".csv"))
    reg <- demo_registry(f$sha256, version = v)
    seeded <- seed_cache(reg, f)
    e <- seeded$entry
    e$accessed_at <- Sys.time() - if (v == "1.0") 1e6 else 0
    getaca:::put_entry(e)
  }
  expect_equal(length(getaca:::read_index("demopkg")), 2L)

  withr::local_options(list(getaca.max_bytes = 1))
  out <- getaca_clean(package = "demopkg", what = "lru")
  expect_true(nrow(out) >= 1L)
  expect_match(out$resource[1], "@1\\.0$")
})

test_that("an entry under an active lock is never collected", {
  cache <- local_cache()
  src <- withr::local_tempdir()
  f <- seed_file(src)
  reg <- demo_registry(f$sha256)
  seeded <- seed_cache(reg, f)

  lock <- getaca:::acquire_lock(seeded$id)
  on.exit(getaca:::release_lock(lock))

  withr::local_options(list(getaca.supersede_days = -1, getaca.max_bytes = 1))
  out <- getaca_clean(package = "demopkg", what = c("superseded", "lru"))
  expect_equal(nrow(out), 0L)
})
