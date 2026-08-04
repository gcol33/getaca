# The transport is the one layer a fake cannot stand in for. These tests move
# real bytes over real https, and are skipped on CRAN and when the network is
# unreachable, so an offline machine still gets a clean run.
#
# The target is a registry file committed to this repository, so its content
# changes only when fixtures/make-remote-registry.R is rerun.
FIXTURE_URL <- paste0(
  "https://raw.githubusercontent.com/gcol33/getaca/main/",
  "tests/testthat/fixtures/remote-registry.rds"
)

MISSING_URL <- paste0(
  "https://raw.githubusercontent.com/gcol33/getaca/main/",
  "tests/testthat/fixtures/no-such-fixture"
)

# Fetch once, hash what arrived, and declare that. Nothing upstream is
# hardcoded, so the test asserts the round trip rather than someone else's
# bytes.
live_checksum <- function() {
  probe <- withr::local_tempfile(.local_envir = parent.frame())
  res <- served(getaca:::try_one(FIXTURE_URL, probe))
  getaca:::sha256_file(probe)
}

# Reachability is settled once, before each of these tests, and a shared runner
# occasionally has the host stop answering after that. A transfer that fails
# because nothing was there to answer says nothing about the adjudication under
# test, so it skips on the same terms an offline machine does.
served <- function(res) {
  testthat::skip_if(!isTRUE(res$success),
                    paste("the fixture URL stopped responding:", res$reason))
  res
}

# The same outage, arriving as a condition rather than as a result. Only an
# attempt that reached the live mirror and got nothing is an outage: one that
# never reached it is the failure these tests exist to catch, and is raised.
live_transfer <- function(expr) {
  tryCatch(expr, getaca_error_unavailable = function(e) {
    hit <- match(FIXTURE_URL, e$urls)
    if (is.na(hit)) stop(e)
    testthat::skip(paste("the fixture URL stopped responding:", e$reasons[hit]))
  })
}

# The same outage where it is not a failure at all: the remote channel reports
# one as a message and resolves through the bundled registry, so a test
# asserting what the remote did would otherwise read the fallback as a verdict.
# A channel that reached its remote never emits this, so nothing real is hidden.
live_registry <- function(expr) {
  withCallingHandlers(expr, message = function(m) {
    if (grepl("could not reach the remote registry", conditionMessage(m))) {
      testthat::skip("the remote registry URL stopped responding")
    }
  })
}

test_that("a real transfer reports success and writes the bytes", {
  online_only()
  dest <- withr::local_tempfile()

  res <- getaca:::try_one(FIXTURE_URL, dest)

  expect_true(res$success)
  expect_true(is.na(res$reason))
  expect_gt(file.info(dest)$size, 0)
})

test_that("a missing path is an HTTP failure, not wrong content", {
  online_only()
  dest <- withr::local_tempfile()

  res <- getaca:::try_one(MISSING_URL, dest)

  expect_false(res$success)
  expect_match(res$reason, "404")
  # The error body must not survive as something a later attempt resumes onto.
  expect_false(file.exists(dest))
})

test_that("a real transfer reports its bytes as they arrive", {
  online_only()
  dest <- withr::local_tempfile()
  seen <- numeric()

  res <- getaca:::try_one(FIXTURE_URL, dest,
                          progress = function(bytes) seen <<- c(seen, bytes))

  expect_true(res$success)
  expect_gt(length(seen), 0)
  # Cumulative and non-decreasing, ending at what is on disk.
  expect_false(is.unsorted(seen))
  expect_equal(seen[length(seen)], unname(file.info(dest)$size))
})

test_that("a partial transfer resumes onto what is already there", {
  online_only()
  whole <- withr::local_tempfile()
  served(getaca:::try_one(FIXTURE_URL, whole))
  full_size <- unname(file.info(whole)$size)
  full_sha <- getaca:::sha256_file(whole)
  testthat::skip_if(full_size < 100, "the fixture is too small to resume into")

  # The first 100 bytes of the real file, as an interrupted transfer leaves.
  dest <- withr::local_tempfile()
  writeBin(readBin(whole, "raw", n = 100), dest)
  seen <- numeric()

  res <- getaca:::try_one(FIXTURE_URL, dest,
                          progress = function(bytes) seen <<- c(seen, bytes))

  expect_true(res$success)
  # The rest arrived and the whole file is what it should be, which only holds
  # if the range was honoured and appended rather than restarted.
  expect_equal(getaca:::sha256_file(dest), full_sha)
  expect_equal(unname(file.info(dest)$size), full_size)
  # Reported bytes count from the offset, so the first report is already past
  # what was on disk. A server ignoring the range would report from zero.
  expect_gt(seen[1], 100)
})

test_that("a transfer with nowhere to go hashes what arrives and writes nothing", {
  online_only()
  dest <- withr::local_tempfile()
  written <- served(getaca:::try_one(FIXTURE_URL, dest))

  seen <- numeric()
  hashed <- served(getaca:::try_one(FIXTURE_URL, NULL,
                                    progress = function(b) seen <<- c(seen, b)))

  # The same bytes over the same wire, measured without touching the disk.
  expect_identical(hashed$sha256, getaca:::sha256_file(dest))
  expect_equal(hashed$bytes, unname(file.info(dest)$size))
  expect_gt(length(seen), 0)
  expect_equal(seen[length(seen)], hashed$bytes)
})

test_that("a missing path with nowhere to go is still an HTTP failure", {
  online_only()

  res <- getaca:::try_one(MISSING_URL, NULL)

  expect_false(res$success)
  expect_match(res$reason, "404")
  # The error page has a body, and hashing it would report a digest for a file
  # that was never served.
  expect_null(res$sha256)
})

test_that("an unresolvable host is a transfer failure", {
  testthat::skip_on_cran()
  dest <- withr::local_tempfile()

  res <- getaca:::try_one("https://getaca-no-such-host.invalid/f", dest)

  expect_false(res$success)
  expect_true(is.character(res$reason) && nzchar(res$reason))
})

test_that("bytes fetched over https verify against their declared checksum", {
  online_only()
  cache <- local_cache()
  sha <- live_checksum()

  rec <- resource("fixture", "1.0", urls = FIXTURE_URL, sha256 = sha)
  got <- live_transfer(
    getaca:::fetch_to_temp(resource_id("demopkg", "fixture", "1.0"), rec,
                           quiet = TRUE))

  expect_equal(got$sha256, sha)
  expect_equal(got$url, FIXTURE_URL)
})

test_that("real bytes that do not match the declaration are an upstream mutation", {
  online_only()
  cache <- local_cache()
  rec <- resource("fixture", "1.0", urls = FIXTURE_URL, sha256 = strrep("d", 64))

  err <- live_transfer(tryCatch(
    getaca:::fetch_to_temp(resource_id("demopkg", "fixture", "1.0"), rec, quiet = TRUE),
    getaca_error_upstream_changed = function(e) e
  ))

  expect_s3_class(err, "getaca_error_upstream_changed")
  expect_equal(err$actor, "upstream")
})

test_that("a dead mirror ahead of a live one is transparent", {
  online_only()
  cache <- local_cache()
  sha <- live_checksum()

  rec <- resource("fixture", "1.0", urls = c(MISSING_URL, FIXTURE_URL), sha256 = sha)
  got <- live_transfer(
    getaca:::fetch_to_temp(resource_id("demopkg", "fixture", "1.0"), rec,
                           quiet = TRUE))

  expect_equal(got$url, FIXTURE_URL)
})

test_that("an end-to-end retrieval works over real https", {
  online_only()
  cache <- local_cache()
  sha <- live_checksum()

  reg <- registry("demopkg", list(
    resource("fixture", "1.0", urls = FIXTURE_URL, sha256 = sha,
             license = "MIT")
  ))

  path <- live_transfer(getaca("fixture", registry = reg, quiet = TRUE))
  expect_true(file.exists(path))
  expect_equal(getaca:::sha256_file(path), sha)

  info <- getaca_info("fixture", registry = reg)
  expect_equal(info$url_used, FIXTURE_URL)
  expect_equal(info$license, "MIT")

  # The second call is served from the cache, so no transfer is attempted.
  testthat::local_mocked_bindings(
    try_one = function(...) stop("the cache should have answered this"),
    .package = "getaca"
  )
  expect_equal(getaca("fixture", registry = reg, quiet = TRUE), path)
})

test_that("a remote registry is fetched over https and takes effect", {
  online_only()
  local_registries()

  bundled <- registry("getacademo", list(
    resource("demo", "1.0", urls = "https://example.org/demo-1.0.csv",
             sha256 = strrep("a", 64))
  ), remote = FIXTURE_URL)

  fetched <- live_registry(getaca:::remote_channel(bundled))
  expect_false(identical(registry_digest(fetched), registry_digest(bundled)))
  expect_length(fetched$resources, 2L)

  res <- resolve_resource("demo", registry = bundled, policy = "current")
  expect_equal(res$id$version, "2.0")
  expect_equal(res$source, "current")
})

test_that("a remote registry served from the wrong place is refused, not trusted", {
  online_only()
  local_registries()

  # The fixture declares getacademo, so any other package name is a mismatch
  # the channel has to catch before it can affect resolution.
  bundled <- registry("demopkg", list(
    resource("res", "1.0", urls = "https://example.invalid/res.csv",
             sha256 = strrep("a", 64))
  ), remote = FIXTURE_URL)

  live_registry(expect_error(
    getaca:::remote_channel(bundled),
    class = "getaca_error_invalid_registry"
  ))
})
