# Adjudication is what distinguishes getaca from a downloader, so it is
# tested directly. A fake transport writes chosen bytes to the destination,
# which exercises sizing, hashing and the mirror walk without a network.
fake_transport <- function(...) {
  responses <- list(...)
  i <- 0L
  function(url, dest, quiet = FALSE) {
    i <<- i + 1L
    r <- responses[[i]]
    if (is.null(r$contents)) {
      return(list(success = FALSE, reason = r$reason %||% "HTTP 404"))
    }
    writeBin(charToRaw(r$contents), dest)
    list(success = TRUE, reason = NA_character_)
  }
}

`%||%` <- function(x, y) if (is.null(x)) y else x

fake_record <- function(contents, urls, size = NA_real_) {
  tmp <- withr::local_tempfile()
  writeBin(charToRaw(contents), tmp)
  resource("res", "1.0", urls = urls,
           sha256 = getaca:::sha256_file(tmp), size = size)
}

test_that("the first mirror that serves the declared bytes wins", {
  cache <- local_cache()
  id <- resource_id("demopkg", "res", "1.0")
  rec <- fake_record("payload", c("https://a.invalid/f", "https://b.invalid/f"))

  got <- getaca:::fetch_to_temp(
    id, rec, quiet = TRUE,
    transport = fake_transport(list(contents = "payload"))
  )
  expect_equal(got$url, "https://a.invalid/f")
  expect_equal(got$sha256, rec$sha256)
})

test_that("a dead first mirror falls through to a live second", {
  cache <- local_cache()
  id <- resource_id("demopkg", "res", "1.0")
  rec <- fake_record("payload", c("https://a.invalid/f", "https://b.invalid/f"))

  got <- getaca:::fetch_to_temp(
    id, rec, quiet = TRUE,
    transport = fake_transport(
      list(contents = NULL, reason = "HTTP 503"),
      list(contents = "payload")
    )
  )
  expect_equal(got$url, "https://b.invalid/f")
})

test_that("no mirror answering is a user-actionable unavailability", {
  cache <- local_cache()
  id <- resource_id("demopkg", "res", "1.0")
  rec <- fake_record("payload", c("https://a.invalid/f", "https://b.invalid/f"))

  err <- tryCatch(
    getaca:::fetch_to_temp(id, rec, quiet = TRUE,
      transport = fake_transport(
        list(contents = NULL, reason = "HTTP 503"),
        list(contents = NULL, reason = "connection refused")
      )),
    getaca_error = function(e) e
  )
  expect_s3_class(err, "getaca_error_unavailable")
  expect_equal(err$actor, "user")
  expect_match(conditionMessage(err), "HTTP 503")
  expect_match(conditionMessage(err), "connection refused")
})

test_that("one mirror returning other bytes is an upstream mutation", {
  cache <- local_cache()
  id <- resource_id("demopkg", "res", "1.0")
  rec <- fake_record("payload", "https://a.invalid/f")

  err <- tryCatch(
    getaca:::fetch_to_temp(id, rec, quiet = TRUE,
      transport = fake_transport(list(contents = "something else"))),
    getaca_error = function(e) e
  )
  expect_s3_class(err, "getaca_error_upstream_changed")
  expect_equal(err$actor, "upstream")
  expect_match(conditionMessage(err), "left untouched")
})

test_that("mirrors agreeing with each other and not the registry blame the author", {
  cache <- local_cache()
  id <- resource_id("demopkg", "res", "1.0")
  rec <- fake_record("payload", c("https://a.invalid/f", "https://b.invalid/f"))

  err <- tryCatch(
    getaca:::fetch_to_temp(id, rec, quiet = TRUE,
      transport = fake_transport(
        list(contents = "the actual data"),
        list(contents = "the actual data")
      )),
    getaca_error = function(e) e
  )
  expect_s3_class(err, "getaca_error_declaration")
  expect_equal(err$actor, "author")
  expect_match(conditionMessage(err), "2 independent sources agreed")
})

test_that("mirrors disagreeing with each other stay an upstream problem", {
  cache <- local_cache()
  id <- resource_id("demopkg", "res", "1.0")
  rec <- fake_record("payload", c("https://a.invalid/f", "https://b.invalid/f"))

  err <- tryCatch(
    getaca:::fetch_to_temp(id, rec, quiet = TRUE,
      transport = fake_transport(
        list(contents = "one thing"),
        list(contents = "another thing")
      )),
    getaca_error = function(e) e
  )
  expect_s3_class(err, "getaca_error_upstream_changed")
})

test_that("a short response is treated as truncation, not as wrong content", {
  cache <- local_cache()
  id <- resource_id("demopkg", "res", "1.0")
  rec <- fake_record("payload-that-is-long", "https://a.invalid/f", size = 20)

  err <- tryCatch(
    getaca:::fetch_to_temp(id, rec, quiet = TRUE,
      transport = fake_transport(list(contents = "short"))),
    getaca_error = function(e) e
  )
  expect_s3_class(err, "getaca_error_unavailable")
  expect_match(conditionMessage(err), "truncated \\(5 of 20 bytes\\)")
})

test_that("verified bytes are promoted into the cache atomically", {
  cache <- local_cache()
  id <- resource_id("demopkg", "res", "1.0")
  rec <- fake_record("payload", "https://a.invalid/data-1.0.csv")

  got <- getaca:::fetch_to_temp(id, rec, quiet = TRUE,
    transport = fake_transport(list(contents = "payload")))
  final <- getaca:::promote(id, rec, got$path)

  expect_true(file.exists(final))
  expect_false(file.exists(got$path))
  expect_equal(basename(final), "data-1.0.csv")
  expect_equal(getaca:::sha256_file(final), rec$sha256)
})

test_that("a URL with a query string still yields a usable file name", {
  expect_equal(getaca:::url_basename("https://e.org/a/b.zip?token=x"), "b.zip")
  expect_equal(getaca:::url_basename("https://e.org/a/b.zip#frag"), "b.zip")
  expect_equal(getaca:::url_basename("https://e.org/"), "resource.bin")
})

test_that("an end-to-end retrieval records the mirror that served it", {
  cache <- local_cache()
  reg <- registry("demopkg", list(
    fake_record("payload", c("https://a.invalid/f.csv", "https://b.invalid/f.csv"))
  ))

  testthat::local_mocked_bindings(
    try_one = fake_transport(
      list(contents = NULL, reason = "HTTP 503"),
      list(contents = "payload")
    ),
    .package = "getaca"
  )

  path <- getaca("res", registry = reg, quiet = TRUE)
  expect_true(file.exists(path))

  info <- getaca_info("res", registry = reg)
  expect_equal(info$url_used, "https://b.invalid/f.csv")
  expect_equal(info$observed_sha256, reg$resources$res$sha256)
  expect_equal(info$source, "bundled")
})
