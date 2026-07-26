test_that("a lock is exclusive while held", {
  cache <- local_cache()
  id <- resource_id("demopkg", "res", "1.0")

  lock <- getaca:::acquire_lock(id)
  expect_true(dir.exists(lock$path))
  expect_error(
    getaca:::acquire_lock(id, timeout = 0.2, poll = 0.05),
    "timed out"
  )

  getaca:::release_lock(lock)
  expect_false(dir.exists(lock$path))
})

test_that("a stale lock is taken over rather than waited on", {
  cache <- local_cache()
  withr::local_options(list(getaca.lock_stale_seconds = -1))
  id <- resource_id("demopkg", "res", "1.0")

  first <- getaca:::acquire_lock(id)
  second <- getaca:::acquire_lock(id, timeout = 2)
  expect_true(dir.exists(second$path))
  getaca:::release_lock(second)
})

test_that("a lock names its own removal in the timeout message", {
  cache <- local_cache()
  id <- resource_id("demopkg", "res", "1.0")
  lock <- getaca:::acquire_lock(id)
  on.exit(getaca:::release_lock(lock))

  expect_error(getaca:::acquire_lock(id, timeout = 0.2, poll = 0.05), "unlink")
})
