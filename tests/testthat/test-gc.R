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

# A deliberate removal: the copy is healthy, current and declared, so none of
# the sweeps that run on their own would touch it.
test_that("a cached copy is removed on request, and its bytes with it", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir())
  reg <- demo_registry(f$sha256)
  seeded <- seed_cache(reg, f)

  expect_equal(nrow(getaca_clean("res", package = "demopkg")), 0L)

  out <- getaca_clean("res", package = "demopkg", what = "cached")
  expect_equal(out$reason[1], "removed on request")
  expect_equal(length(getaca:::read_index("demopkg")), 0L)
  expect_false(file.exists(seeded$path))
  expect_false(getaca:::blob_exists(f$sha256))
})

test_that("removal on request is never part of an unqualified clean", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir())
  seeded <- seed_cache(demo_registry(f$sha256), f)

  getaca_clean()
  expect_true(file.exists(seeded$path))
})

test_that("removal on request can be held to one version", {
  cache <- local_cache()
  old <- seed_file(withr::local_tempdir(), contents = "older")
  new <- seed_file(withr::local_tempdir(), contents = "newer")
  reg <- registry("demopkg", current = c(res = "2.0"), resources = list(
    resource("res", "1.0", urls = "https://example.invalid/res-1.0.csv", sha256 = old$sha256),
    resource("res", "2.0", urls = "https://example.invalid/res-2.0.csv", sha256 = new$sha256)
  ))
  rec <- reg$resources
  for (i in seq_along(rec)) {
    id <- resource_id("demopkg", "res", rec[[i]]$version)
    f <- list(old, new)[[i]]
    staged <- file.path(getaca:::cache_tmp_dir(), paste0("v", i))
    file.copy(f$path, staged)
    getaca:::admit(staged, f$sha256)
    placed <- getaca:::place(id, rec[[i]])
    getaca:::put_entry(getaca:::new_entry(id, rec[[i]], placed$path, f$sha256,
                                          source = "bundled",
                                          digest = registry_digest(reg),
                                          url_used = rec[[i]]$urls[1],
                                          link = placed$link))
  }

  out <- getaca_clean("res", package = "demopkg", version = "1.0",
                      what = "cached", dry_run = TRUE)
  expect_equal(out$resource, "demopkg/res@1.0")
  expect_equal(length(getaca:::read_index("demopkg")), 2L)

  getaca_clean("res", package = "demopkg", version = "1.0", what = "cached")
  left <- getaca:::read_index("demopkg")
  expect_equal(vapply(left, function(e) e$id$version, character(1), USE.NAMES = FALSE), "2.0")
  expect_true(getaca:::blob_exists(new$sha256))
  expect_false(getaca:::blob_exists(old$sha256))
})

test_that("removal on request takes a pinned copy and leaves a locked one", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir())
  reg <- demo_registry(f$sha256)
  seeded <- seed_cache(reg, f)
  getaca_keep("res", registry = reg)

  lock <- getaca:::acquire_lock(f$sha256)
  expect_equal(nrow(getaca_clean("res", package = "demopkg", what = "cached")), 0L)
  expect_true(file.exists(seeded$path))
  getaca:::release_lock(lock)

  getaca_clean("res", package = "demopkg", what = "cached")
  expect_false(file.exists(seeded$path))
})

# A lock directory left by a session that has gone protects nothing, and a blob
# under one is as unreferenced as any other.
test_that("a lock nobody is behind any more does not keep bytes alive", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir())
  staged <- file.path(getaca:::cache_tmp_dir(), "orphan")
  file.copy(f$path, staged)
  getaca:::admit(staged, f$sha256)
  path <- getaca:::lock_dir(f$sha256)
  dir.create(path)
  getaca:::write_holder(path, list(pid = 4242L, host = "another-machine", start = 100))
  Sys.setFileTime(getaca:::holder_path(path), Sys.time() - 86400)

  getaca_clean(what = "unreferenced")
  expect_false(getaca:::blob_exists(f$sha256))
})
