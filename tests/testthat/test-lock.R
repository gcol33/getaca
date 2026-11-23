test_that("a lock is exclusive while held", {
  cache <- local_cache()
  key <- strrep("a", 64)

  lock <- getaca:::acquire_lock(key)
  expect_true(dir.exists(lock$path))
  expect_error(
    getaca:::acquire_lock(key, timeout = 0.2, poll = 0.05, quiet = TRUE),
    "timed out"
  )

  getaca:::release_lock(lock)
  expect_false(dir.exists(lock$path))
})

# A lock left by a process that has gone is taken over at once, and one whose
# process is still running is waited on however old it is. Which of the two a
# lock is depends on what the operating system says about the process named in
# it, so the tests put a holder of their choosing into a lock and stand in for
# the operating system's answer.
plant_lock <- function(key, pid = 4242L, host = getaca:::this_host(), start = 100,
                       age = 0) {
  path <- getaca:::lock_dir(key)
  dir.create(path)
  getaca:::write_holder(path, list(pid = pid, host = host, start = start))
  if (age > 0) Sys.setFileTime(getaca:::holder_path(path), Sys.time() - age)
  path
}

test_that("this session's own process is running and keeps one start stamp", {
  stamp <- getaca:::process_stamp(Sys.getpid())
  expect_false(is.na(stamp))
  expect_identical(getaca:::process_stamp(Sys.getpid()), stamp)
  expect_true(is.na(getaca:::process_stamp(NA_integer_)))
  expect_true(is.na(getaca:::process_stamp(-1L)))
})

test_that("a lock whose process has gone is stale at once", {
  cache <- local_cache()
  path <- plant_lock(strrep("a", 64))

  expect_true(getaca:::lock_is_stale(path, stamp = function(pid) NA_real_))
})

test_that("a lock whose process is running is live however old it is", {
  cache <- local_cache()
  withr::local_options(list(getaca.lock_stale_seconds = 1))
  path <- plant_lock(strrep("a", 64), start = 100, age = 86400)

  expect_false(getaca:::lock_is_stale(path, stamp = function(pid) 100))
  # A start that cannot be read on either side leaves the process id to go on.
  expect_false(getaca:::lock_is_stale(path, stamp = function(pid) 0))
})

test_that("a process id handed to a later process does not keep a lock alive", {
  cache <- local_cache()
  path <- plant_lock(strrep("a", 64), start = 100)

  expect_true(getaca:::lock_is_stale(path, stamp = function(pid) 250))
})

# A waiter on another machine cannot ask about the holder's process, so the
# holder's last touch of the lock is all there is to go on.
test_that("a lock held on another machine is judged by when it was last touched", {
  cache <- local_cache()
  withr::local_options(list(getaca.lock_stale_seconds = 600))
  never <- function(pid) stop("a process on another machine cannot be asked after")

  fresh <- plant_lock(strrep("a", 64), host = "another-machine", age = 60)
  expect_false(getaca:::lock_is_stale(fresh, stamp = never))

  quiet <- plant_lock(strrep("b", 64), host = "another-machine", age = 3600)
  expect_true(getaca:::lock_is_stale(quiet, stamp = never))
})

test_that("a lock directory without its holder file yet is not taken for abandoned", {
  cache <- local_cache()
  path <- getaca:::lock_dir(strrep("a", 64))
  dir.create(path)

  expect_false(getaca:::lock_is_stale(path))
  Sys.setFileTime(path, Sys.time() - 3600)
  expect_true(getaca:::lock_is_stale(path))
})

test_that("a stale lock is taken over rather than waited on", {
  cache <- local_cache()
  withr::local_options(list(getaca.lock_stale_seconds = 600))
  key <- strrep("a", 64)
  plant_lock(key, host = "another-machine", age = 3600)

  lock <- getaca:::acquire_lock(key, timeout = 2, quiet = TRUE)
  expect_true(getaca:::same_process(getaca:::read_holder(lock$path),
                                    getaca:::this_process()))
  getaca:::release_lock(lock)
  expect_false(dir.exists(lock$path))
})

test_that("a waiter says once whom it is waiting for", {
  cache <- local_cache()
  key <- strrep("a", 64)
  lock <- getaca:::acquire_lock(key)
  on.exit(getaca:::release_lock(lock))

  expect_message(
    try(getaca:::acquire_lock(key, "demopkg/res@1.0", timeout = 0.3, poll = 0.05),
        silent = TRUE),
    sprintf("process %d on %s.*demopkg/res@1.0", Sys.getpid(), getaca:::this_host())
  )
})

test_that("a held lock is touched while the session is busy with something else", {
  cache <- local_cache()
  withr::local_options(getaca.lock_stale_seconds = 4)
  beats <- function() .Call(getaca:::C_heartbeat_count)
  lock <- getaca:::acquire_lock(strrep("a", 64))
  on.exit(getaca:::release_lock(lock))
  holder <- getaca:::holder_path(lock$path)

  # Standing in for a processor: R does nothing for longer than one interval.
  Sys.sleep(0.3)
  Sys.setFileTime(holder, Sys.time() - 3600)
  Sys.sleep(1.5)
  expect_lt(getaca:::file_age(holder), 60)

  getaca:::release_lock(lock)
  expect_false(dir.exists(lock$path))
  after <- beats()
  Sys.sleep(1.3)
  expect_identical(beats(), after)
})

test_that("each lock a session holds is touched, and a released one no longer", {
  cache <- local_cache()
  withr::local_options(getaca.lock_stale_seconds = 4)
  first <- getaca:::acquire_lock(strrep("a", 64))
  second <- getaca:::acquire_lock(strrep("b", 64))
  on.exit({
    getaca:::release_lock(first)
    getaca:::release_lock(second)
  })
  getaca:::release_lock(first)
  expect_identical(getaca:::held_locks(), second$path)

  holder <- getaca:::holder_path(second$path)
  Sys.sleep(0.3)
  Sys.setFileTime(holder, Sys.time() - 3600)
  Sys.sleep(1.5)
  expect_lt(getaca:::file_age(holder), 60)
})

test_that("a forked child leaves its parent's locks held and touched", {
  skip_on_os("windows")
  skip_if_not_installed("parallel")
  cache <- local_cache()
  withr::local_options(getaca.lock_stale_seconds = 4)
  lock <- getaca:::acquire_lock(strrep("a", 64))
  on.exit(getaca:::release_lock(lock))

  job <- parallel::mcparallel({
    inherited <- getaca:::held_locks()
    own <- getaca:::acquire_lock(strrep("b", 64))
    held <- getaca:::held_locks()
    getaca:::release_lock(own)
    getaca:::release_lock(lock)
    list(inherited = inherited, held = held, own = own$path)
  })
  child <- parallel::mccollect(job)[[1]]
  expect_identical(child$inherited, character())
  expect_identical(child$held, child$own)
  expect_true(dir.exists(lock$path))

  holder <- getaca:::holder_path(lock$path)
  Sys.setFileTime(holder, Sys.time() - 3600)
  Sys.sleep(1.5)
  expect_lt(getaca:::file_age(holder), 60)
})

test_that("releasing leaves alone a lock another session has since taken", {
  cache <- local_cache()
  key <- strrep("a", 64)
  lock <- getaca:::acquire_lock(key)
  getaca:::write_holder(lock$path, list(pid = 4242L, host = "another-machine",
                                        start = 100))

  getaca:::release_lock(lock)
  expect_true(dir.exists(lock$path))
  expect_false(lock$path %in% getaca:::held_locks())
})

test_that("a lock names its own removal in the timeout message", {
  cache <- local_cache()
  key <- strrep("a", 64)
  lock <- getaca:::acquire_lock(key)
  on.exit(getaca:::release_lock(lock))

  expect_error(getaca:::acquire_lock(key, timeout = 0.2, poll = 0.05, quiet = TRUE), "unlink")
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
    getaca:::acquire_lock(sha, "other/backbone@1.0", timeout = 0.2, poll = 0.05,
                          quiet = TRUE),
    "other/backbone@1.0",
    fixed = TRUE
  )
})
