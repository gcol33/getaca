# Serves a known file as though it had been downloaded, so processing can be
# exercised end to end without a network.
serves <- function(file) {
  function(url, dest, quiet = FALSE) {
    file.copy(file$path, dest, overwrite = TRUE)
    list(success = TRUE, reason = NA_character_)
  }
}

unpacker <- function(id = "unpack") {
  processor(id, function(input, output_dir) {
    out <- file.path(output_dir, "unpacked.txt")
    file.copy(input, out)
    out
  })
}

processed_registry <- function(sha, proc = unpacker()) {
  registry("demopkg", list(
    resource("res", "1.0", urls = "https://a.invalid/res.csv",
             sha256 = sha, processor = proc)
  ))
}

test_that("a processed result gets its own slot and its own provenance", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir(), contents = "payload")
  reg <- processed_registry(f$sha256)
  testthat::local_mocked_bindings(try_one = serves(f), .package = "getaca")

  path <- getaca("res", registry = reg, quiet = TRUE)

  expect_true(file.exists(path))
  expect_equal(basename(path), "unpacked.txt")
  expect_match(path, "proc-unpack", fixed = TRUE)
  expect_equal(getaca_info("res", registry = reg)$processor_id, "unpack")
})

test_that("the raw artefact stays reachable beside the processed one", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir(), contents = "payload")
  reg <- processed_registry(f$sha256)
  testthat::local_mocked_bindings(try_one = serves(f), .package = "getaca")

  processed <- getaca("res", registry = reg, quiet = TRUE)
  raw <- getaca("res", registry = reg, processed = FALSE, quiet = TRUE)

  expect_false(identical(raw, processed))
  expect_equal(getaca:::sha256_file(raw), f$sha256)
  expect_true(file.exists(processed))
})

test_that("changing the processor id gives the result a different slot", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir(), contents = "payload")
  testthat::local_mocked_bindings(try_one = serves(f), .package = "getaca")

  first <- getaca("res", registry = processed_registry(f$sha256, unpacker("unpack")),
                  quiet = TRUE)
  second <- getaca("res", registry = processed_registry(f$sha256, unpacker("unpack-v2")),
                   quiet = TRUE)

  expect_false(identical(first, second))
  expect_true(file.exists(first))
  expect_true(file.exists(second))
})

test_that("a failing processor names itself and the resource it was applied to", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir(), contents = "payload")
  boom <- processor("boom", function(input, output_dir) stop("could not unpack"))
  reg <- processed_registry(f$sha256, boom)
  testthat::local_mocked_bindings(try_one = serves(f), .package = "getaca")

  expect_error(getaca("res", registry = reg, quiet = TRUE),
               "processor 'boom' failed for demopkg/res@1.0")
  expect_error(getaca("res", registry = reg, quiet = TRUE), "could not unpack")
})

test_that("a failed processor leaves no staging directory behind", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir(), contents = "payload")
  reg <- processed_registry(f$sha256, processor("boom", function(i, o) stop("no")))
  testthat::local_mocked_bindings(try_one = serves(f), .package = "getaca")

  try(getaca("res", registry = reg, quiet = TRUE), silent = TRUE)

  id <- resource_id("demopkg", "res", "1.0")
  leftovers <- list.files(getaca:::cache_version_dir(id), pattern = "staging")
  expect_length(leftovers, 0L)
})

test_that("a processed resource re-verifies against its raw artefact", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir(), contents = "payload")
  reg <- processed_registry(f$sha256)
  testthat::local_mocked_bindings(try_one = serves(f), .package = "getaca")

  path <- getaca("res", registry = reg, quiet = TRUE)
  expect_equal(getaca("res", registry = reg, verify = TRUE, quiet = TRUE), path)
})

test_that("prefetch warms every resource a registry declares", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir(), contents = "payload")
  reg <- registry("demopkg", list(
    resource("one", "1.0", urls = "https://a.invalid/one", sha256 = f$sha256),
    resource("two", "1.0", urls = "https://a.invalid/two", sha256 = f$sha256)
  ))
  testthat::local_mocked_bindings(try_one = serves(f), .package = "getaca")

  paths <- getaca_prefetch(registry = reg, quiet = TRUE)

  expect_length(paths, 2L)
  expect_true(all(file.exists(paths)))
  expect_true(all(getaca_catalogue(registry = reg)$cached))
})

test_that("prefetching a named subset leaves the rest alone", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir(), contents = "payload")
  reg <- registry("demopkg", list(
    resource("one", "1.0", urls = "https://a.invalid/one", sha256 = f$sha256),
    resource("two", "1.0", urls = "https://a.invalid/two", sha256 = f$sha256)
  ))
  testthat::local_mocked_bindings(try_one = serves(f), .package = "getaca")

  getaca_prefetch("one", registry = reg, quiet = TRUE)

  out <- getaca_catalogue(registry = reg)
  expect_equal(out$cached[out$name == "one"], TRUE)
  expect_equal(out$cached[out$name == "two"], FALSE)
})

test_that("prefetching a package that declares nothing says so", {
  expect_error(getaca_prefetch(package = "stats"),
               class = "getaca_error_invalid_registry")
})
