test_that("a lock is exclusive while held", {
  cache <- local_cache()
  key <- strrep("a", 64)

  lock <- getaca:::acquire_lock(key)
  expect_true(dir.exists(lock$path))
  expect_error(
    getaca:::acquire_lock(key, timeout = 0.2, poll = 0.05),
    "timed out"
  )

  getaca:::release_lock(lock)
  expect_false(dir.exists(lock$path))
})

test_that("a stale lock is taken over rather than waited on", {
  cache <- local_cache()
  withr::local_options(list(getaca.lock_stale_seconds = -1))
  key <- strrep("a", 64)

  first <- getaca:::acquire_lock(key)
  second <- getaca:::acquire_lock(key, timeout = 2)
  expect_true(dir.exists(second$path))
  getaca:::release_lock(second)
})

test_that("a lock names its own removal in the timeout message", {
  cache <- local_cache()
  key <- strrep("a", 64)
  lock <- getaca:::acquire_lock(key)
  on.exit(getaca:::release_lock(lock))

  expect_error(getaca:::acquire_lock(key, timeout = 0.2, poll = 0.05), "unlink")
})

# Whoever waited for the lock is looking at a cache that has changed since they
# last read it: the session that held it may have finished the very transfer
# they were about to start. The entry is therefore read again after the wait,
# and the waiter serves what arrived rather than fetching it a second time.
test_that("a resource another session completed during the wait is not fetched again", {
  local_fetchable()
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir(), contents = "payload")
  reg <- demo_registry(f$sha256)

  # Standing in for the other session: the entry appears while the lock is
  # being acquired, which is exactly the window the re-check exists for.
  real_acquire <- getaca:::acquire_lock
  testthat::local_mocked_bindings(
    acquire_lock = function(...) {
      held <- real_acquire(...)
      seed_cache(reg, f)
      held
    },
    try_one = function(...) stop("the other session's result should have answered this"),
    .package = "getaca"
  )

  path <- getaca("res", registry = reg, quiet = TRUE)
  expect_equal(getaca:::sha256_file(path), f$sha256)
})

test_that("the lock is on the bytes, so two declarations of one file wait", {
  cache <- local_cache()
  sha <- strrep("b", 64)

  # Different packages, different names, same declared checksum: one transfer
  # is what the second session should be waiting for.
  expect_identical(getaca:::lock_dir(sha), getaca:::lock_dir(sha))

  lock <- getaca:::acquire_lock(sha, "demopkg/backbone@2026-06")
  on.exit(getaca:::release_lock(lock))
  expect_error(
    getaca:::acquire_lock(sha, "other/backbone@1.0", timeout = 0.2, poll = 0.05),
    "other/backbone@1.0",
    fixed = TRUE
  )
})
