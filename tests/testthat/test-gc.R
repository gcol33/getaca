test_that("broken entries are swept and their records dropped", {
  cache <- local_cache()
  src <- withr::local_tempdir()
  f <- seed_file(src)
  reg <- demo_registry(f$sha256)
  seeded <- seed_cache(reg, f)

  getaca:::remove_path(seeded$path)
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
  getaca:::remove_path(seeded$path)

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

  lock <- getaca:::acquire_lock(seeded$entry$declared_sha256)
  on.exit(getaca:::release_lock(lock))

  withr::local_options(list(getaca.supersede_days = -1, getaca.max_bytes = 1))
  out <- getaca_clean(package = "demopkg", what = c("superseded", "lru"))
  expect_equal(nrow(out), 0L)
})

# What a version is superseded by is whatever the installed registry names now,
# so this sweep is only meaningful against a real declaring package. Retention
# is what separates "superseded" from "collectable": the bytes stay until the
# period passes, which is why an expensive resource is not deleted the moment a
# new version is declared.
test_that("a version the registry no longer names is swept once past retention", {
  cache <- local_cache()
  local_registries()
  src <- withr::local_tempdir()
  old <- seed_file(src, contents = "the old backbone", name = "res-1.0.csv")
  seed_cache(demo_registry(old$sha256, package = "declaringpkg", version = "1.0"), old)
  install_declaring_package(
    "declaringpkg",
    demo_registry(strrep("b", 64), package = "declaringpkg", version = "2.0")
  )

  withr::local_options(list(getaca.supersede_days = 30))
  expect_equal(nrow(getaca_clean(package = "declaringpkg", what = "superseded")), 0L)

  withr::local_options(list(getaca.supersede_days = -1))
  out <- getaca_clean(package = "declaringpkg", what = "superseded")

  expect_equal(nrow(out), 1L)
  expect_equal(out$reason, "superseded version past retention")
  expect_match(out$resource, "@1\\.0$")
  expect_equal(length(getaca:::read_index("declaringpkg")), 0L)
})

test_that("a version the registry still names is kept however old it is", {
  cache <- local_cache()
  local_registries()
  src <- withr::local_tempdir()
  f <- seed_file(src, contents = "still declared")
  reg <- demo_registry(f$sha256, package = "declaringpkg")
  seed_cache(reg, f)
  install_declaring_package("declaringpkg", reg)

  withr::local_options(list(getaca.supersede_days = -1))
  out <- getaca_clean(package = "declaringpkg", what = "superseded")

  expect_equal(nrow(out), 0L)
  expect_equal(length(getaca:::read_index("declaringpkg")), 1L)
})

# Eviction is a means to get back under the ceiling, not an end, so it stops at
# the first entry that achieves it rather than emptying the cache.
test_that("eviction stops once the cache is back under the ceiling", {
  cache <- local_cache()
  src <- withr::local_tempdir()

  for (v in c("1.0", "2.0", "3.0")) {
    f <- seed_file(src, contents = strrep(v, 100), name = paste0(v, ".csv"))
    seeded <- seed_cache(demo_registry(f$sha256, version = v), f)
    e <- seeded$entry
    e$accessed_at <- Sys.time() - switch(v, "1.0" = 1e6, "2.0" = 1e5, 0)
    getaca:::put_entry(e)
  }

  # Three 300 byte resources against a 700 byte ceiling: dropping the oldest
  # clears it, so the other two stay.
  withr::local_options(list(getaca.max_bytes = 700))
  out <- getaca_clean(package = "demopkg", what = "lru")

  expect_equal(nrow(out), 1L)
  expect_match(out$resource, "@1\\.0$")
  expect_equal(length(getaca:::read_index("demopkg")), 2L)
})

test_that("keeping a resource that was never cached says so", {
  cache <- local_cache()
  reg <- demo_registry(strrep("a", 64))

  expect_error(getaca_keep("res", registry = reg), "is not cached")
})

test_that("a blob that is already gone contributes nothing to free", {
  cache <- local_cache()
  expect_equal(getaca:::blob_bytes(strrep("a", 64)), 0)
})
