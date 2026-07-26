test_that("resource identity is the package/name/version triple", {
  id <- resource_id("taxify", "wfo", "2026-06")
  expect_equal(format(id), "taxify/wfo@2026-06")
  expect_s3_class(id, "getaca_id")
})

test_that("a resource declaration requires a real SHA-256", {
  expect_error(
    resource("res", "1.0", urls = "https://e.org/f", sha256 = "abc"),
    class = "getaca_error_invalid_registry"
  )
  expect_error(
    resource("res", "1.0", urls = "https://e.org/f", sha256 = strrep("Z", 64)),
    class = "getaca_error_invalid_registry"
  )
})

test_that("checksums are stored lowercase whatever the author typed", {
  rec <- resource("res", "1.0", urls = "https://e.org/f", sha256 = strrep("A", 64))
  expect_equal(rec$sha256, strrep("a", 64))
})

test_that("insecure and missing transports are refused", {
  expect_error(
    resource("res", "1.0", urls = "http://e.org/f", sha256 = strrep("a", 64)),
    class = "getaca_error_invalid_registry"
  )
  expect_error(
    resource("res", "1.0", urls = character(), sha256 = strrep("a", 64)),
    class = "getaca_error_invalid_registry"
  )
})

test_that("names and versions must be usable as directory names", {
  expect_error(
    resource("res/../etc", "1.0", urls = "https://e.org/f", sha256 = strrep("a", 64)),
    class = "getaca_error_invalid_registry"
  )
  expect_error(
    resource("res", "1.0/../2.0", urls = "https://e.org/f", sha256 = strrep("a", 64)),
    class = "getaca_error_invalid_registry"
  )
})

test_that("a derived artefact records what it was built from", {
  rec <- resource(
    "wfo-db", "source-2026-06_build-3",
    urls = "https://e.org/f", sha256 = strrep("a", 64),
    upstream = list(wfo_release = "2026-06", taxifydb_build = "3")
  )
  expect_equal(rec$upstream$wfo_release, "2026-06")
  expect_output(print(rec), "built from")
})

test_that("a processor must come from processor()", {
  expect_error(
    resource("res", "1.0", urls = "https://e.org/f", sha256 = strrep("a", 64),
             processor = function(x, y) x),
    class = "getaca_error_invalid_registry"
  )
  p <- processor("unzip", function(input, output_dir) output_dir)
  expect_s3_class(p, "getaca_processor")
})
