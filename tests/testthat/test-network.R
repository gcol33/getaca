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
  res <- getaca:::try_one(FIXTURE_URL, probe, quiet = TRUE)
  testthat::skip_if(!isTRUE(res$success),
                    paste("the fixture URL did not respond:", res$reason))
  getaca:::sha256_file(probe)
}

test_that("a real transfer reports success and writes the bytes", {
  online_only()
  dest <- withr::local_tempfile()

  res <- getaca:::try_one(FIXTURE_URL, dest, quiet = TRUE)

  expect_true(res$success)
  expect_true(is.na(res$reason))
  expect_gt(file.info(dest)$size, 0)
})

test_that("a missing path is an HTTP failure, not wrong content", {
  online_only()
  dest <- withr::local_tempfile()

  res <- getaca:::try_one(MISSING_URL, dest, quiet = TRUE)

  expect_false(res$success)
  expect_match(res$reason, "404")
  # The error body must not survive as something a later attempt resumes onto.
  expect_false(file.exists(dest))
})

test_that("an unresolvable host is a transfer failure", {
  testthat::skip_on_cran()
  dest <- withr::local_tempfile()

  res <- getaca:::try_one("https://getaca-no-such-host.invalid/f", dest, quiet = TRUE)

  expect_false(res$success)
  expect_true(is.character(res$reason) && nzchar(res$reason))
})

test_that("bytes fetched over https verify against their declared checksum", {
  online_only()
  cache <- local_cache()
  sha <- live_checksum()

  rec <- resource("fixture", "1.0", urls = FIXTURE_URL, sha256 = sha)
  got <- getaca:::fetch_to_temp(resource_id("demopkg", "fixture", "1.0"), rec,
                                quiet = TRUE)

  expect_equal(got$sha256, sha)
  expect_equal(got$url, FIXTURE_URL)
})

test_that("real bytes that do not match the declaration are an upstream mutation", {
  online_only()
  cache <- local_cache()
  rec <- resource("fixture", "1.0", urls = FIXTURE_URL, sha256 = strrep("d", 64))

  err <- tryCatch(
    getaca:::fetch_to_temp(resource_id("demopkg", "fixture", "1.0"), rec, quiet = TRUE),
    getaca_error = function(e) e
  )

  expect_s3_class(err, "getaca_error_upstream_changed")
  expect_equal(err$actor, "upstream")
})

test_that("a dead mirror ahead of a live one is transparent", {
  online_only()
  cache <- local_cache()
  sha <- live_checksum()

  rec <- resource("fixture", "1.0", urls = c(MISSING_URL, FIXTURE_URL), sha256 = sha)
  got <- getaca:::fetch_to_temp(resource_id("demopkg", "fixture", "1.0"), rec,
                                quiet = TRUE)

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

  path <- getaca("fixture", registry = reg, quiet = TRUE)
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

  fetched <- getaca:::remote_channel(bundled)
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

  expect_error(
    getaca:::remote_channel(bundled),
    class = "getaca_error_invalid_registry"
  )
})
