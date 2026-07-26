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

# Mimics a resuming transport the way curl behaves: a refused request still
# writes an error body, and a successful one appends to whatever the
# destination already holds. That combination is what made a dead mirror
# corrupt the next mirror's download.
resuming_transport <- function(...) {
  responses <- list(...)
  i <- 0L
  function(url, dest, quiet = FALSE) {
    i <<- i + 1L
    r <- responses[[i]]
    con <- file(dest, open = if (file.exists(dest)) "ab" else "wb")
    on.exit(close(con))
    if (is.null(r$contents)) {
      writeBin(charToRaw("<html>not found</html>"), con)
      return(list(success = FALSE, reason = r$reason %||% "HTTP 404"))
    }
    writeBin(charToRaw(r$contents), con)
    list(success = TRUE, reason = NA_character_)
  }
}

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
  expect_s3_class(err, "getaca_error_incomplete")
  expect_match(conditionMessage(err), "expected 20 bytes, received 5 bytes")
  expect_equal(err$actor, "user")
})

test_that("a mirror ending short and one refusing to answer stay unavailable", {
  cache <- local_cache()
  id <- resource_id("demopkg", "res", "1.0")
  rec <- fake_record(strrep("x", 20), c("https://a.invalid/f", "https://b.invalid/f"),
                     size = 20)

  err <- tryCatch(
    getaca:::fetch_to_temp(id, rec, quiet = TRUE,
      transport = fake_transport(list(contents = "short"), list(reason = "HTTP 503"))),
    getaca_error = function(e) e
  )

  # Retrying helps one of them and not the other, so the broader condition is
  # the honest one; both reasons are still named.
  expect_s3_class(err, "getaca_error_unavailable")
  expect_false(inherits(err, "getaca_error_incomplete"))
  expect_match(conditionMessage(err), "truncated \\(5 of 20 bytes\\)")
  expect_match(conditionMessage(err), "HTTP 503")
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

test_that("a promotion blocked at its destination says so", {
  cache <- local_cache()
  id <- resource_id("demopkg", "res", "1.0")
  rec <- fake_record("payload", "https://a.invalid/data.csv")
  got <- getaca:::fetch_to_temp(id, rec, quiet = TRUE,
    transport = fake_transport(list(contents = "payload")))

  # A file standing where the version directory belongs, so the raw directory
  # cannot be created and nothing can be written beneath it.
  version_dir <- getaca:::cache_version_dir(id)
  dir.create(dirname(version_dir), recursive = TRUE, showWarnings = FALSE)
  writeBin(charToRaw("in the way"), version_dir)

  expect_error(
    suppressWarnings(getaca:::promote(id, rec, got$path)),
    "could not move the verified file into the cache"
  )
})

test_that("a rename that cannot cross a filesystem boundary falls back to copying", {
  dir <- withr::local_tempdir()
  from <- file.path(dir, "verified.bin")
  writeBin(charToRaw("payload"), from)
  to <- file.path(dir, "cache", "verified.bin")
  dir.create(dirname(to))

  expect_true(getaca:::move_file(from, to, rename = function(...) FALSE))
  expect_true(file.exists(to))
  expect_false(file.exists(from))
  expect_equal(readBin(to, "raw", 7L), charToRaw("payload"))
})

test_that("a move that neither renames nor copies leaves the verified bytes alone", {
  dir <- withr::local_tempdir()
  from <- file.path(dir, "verified.bin")
  writeBin(charToRaw("payload"), from)

  moved <- suppressWarnings(
    getaca:::move_file(from, file.path(dir, "absent", "verified.bin"),
                       rename = function(...) FALSE)
  )

  expect_false(moved)
  expect_true(file.exists(from))
})

test_that("promotion replaces whatever occupied the slot", {
  cache <- local_cache()
  id <- resource_id("demopkg", "res", "1.0")
  rec <- fake_record("payload", "https://a.invalid/data.csv")
  raw <- getaca:::cache_raw_dir(id)
  dir.create(raw, recursive = TRUE, showWarnings = FALSE)
  writeBin(charToRaw("stale"), file.path(raw, "data.csv"))

  got <- getaca:::fetch_to_temp(id, rec, quiet = TRUE,
    transport = fake_transport(list(contents = "payload")))
  final <- getaca:::promote(id, rec, got$path)

  expect_equal(getaca:::sha256_file(final), rec$sha256)
})

test_that("a URL with a query string still yields a usable file name", {
  expect_equal(getaca:::url_basename("https://e.org/a/b.zip?token=x"), "b.zip")
  expect_equal(getaca:::url_basename("https://e.org/a/b.zip#frag"), "b.zip")
  expect_equal(getaca:::url_basename("https://e.org/"), "resource.bin")
})

test_that("each mirror transfers into its own partial file", {
  cache <- local_cache()
  rec <- fake_record("payload", c("https://a.invalid/f", "https://b.invalid/f"))

  expect_false(identical(
    getaca:::partial_path(rec, rec$urls[1]),
    getaca:::partial_path(rec, rec$urls[2])
  ))
})

test_that("what a dead mirror leaves behind cannot contaminate the next one", {
  cache <- local_cache()
  id <- resource_id("demopkg", "res", "1.0")
  rec <- fake_record("payload", c("https://a.invalid/f", "https://b.invalid/f"))

  got <- getaca:::fetch_to_temp(
    id, rec, quiet = TRUE,
    transport = resuming_transport(
      list(contents = NULL, reason = "HTTP 404"),
      list(contents = "payload")
    )
  )

  expect_equal(got$url, "https://b.invalid/f")
  expect_equal(got$sha256, rec$sha256)
})

test_that("a stale partial that fails to verify is discarded and refetched", {
  cache <- local_cache()
  id <- resource_id("demopkg", "res", "1.0")
  rec <- fake_record("payload", "https://a.invalid/f")
  writeBin(charToRaw("left over from an earlier run"),
           getaca:::partial_path(rec, rec$urls[1]))

  got <- getaca:::fetch_to_temp(
    id, rec, quiet = TRUE,
    transport = resuming_transport(
      list(contents = "payload"),
      list(contents = "payload")
    )
  )

  expect_equal(got$sha256, rec$sha256)
})

test_that("a mirror serving other bytes is judged on a single attempt", {
  cache <- local_cache()
  id <- resource_id("demopkg", "res", "1.0")
  rec <- fake_record("payload", "https://a.invalid/f")
  calls <- 0L
  serves_other <- function(url, dest, quiet = FALSE) {
    calls <<- calls + 1L
    writeBin(charToRaw("something else"), dest)
    list(success = TRUE, reason = NA_character_)
  }

  expect_error(
    getaca:::fetch_to_temp(id, rec, quiet = TRUE, transport = serves_other),
    class = "getaca_error_upstream_changed"
  )
  expect_equal(calls, 1L)
})

test_that("bytes that fail to verify are not left behind as a partial", {
  cache <- local_cache()
  id <- resource_id("demopkg", "res", "1.0")
  rec <- fake_record("payload", "https://a.invalid/f")

  expect_error(
    getaca:::fetch_to_temp(id, rec, quiet = TRUE,
      transport = fake_transport(list(contents = "something else"))),
    class = "getaca_error_upstream_changed"
  )
  expect_false(file.exists(getaca:::partial_path(rec, rec$urls[1])))
})

test_that("an interrupted transfer keeps its partial for the next attempt", {
  cache <- local_cache()
  id <- resource_id("demopkg", "res", "1.0")
  rec <- fake_record("payload", "https://a.invalid/f")
  part <- getaca:::partial_path(rec, rec$urls[1])
  cut_short <- function(url, dest, quiet = FALSE) {
    writeBin(charToRaw("pay"), dest)
    list(success = FALSE, reason = "transfer failed")
  }

  expect_error(
    getaca:::fetch_to_temp(id, rec, quiet = TRUE, transport = cut_short),
    class = "getaca_error_unavailable"
  )
  expect_true(file.exists(part))
  expect_equal(file.info(part)$size, 3)
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
