# Adjudication is what distinguishes getaca from a downloader, so it is
# tested directly. A fake transport writes chosen bytes to the destination,
# which exercises sizing, hashing and the mirror walk without a network.
fake_transport <- function(...) {
  responses <- list(...)
  i <- 0L
  function(url, dest, progress = NULL) {
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
  function(url, dest, progress = NULL) {
    i <<- i + 1L
    r <- responses[[i]]
    con <- file(dest, open = if (file.exists(dest)) "ab" else "wb")
    on.exit(close(con))
    if (is.null(r$contents)) {
      writeBin(charToRaw("<html>not found</html>"), con)
      return(list(success = FALSE, reason = r$reason %||% "HTTP 404", http = 404L))
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

  expect_true(file.exists(final$path))
  expect_false(file.exists(got$path))
  expect_equal(basename(final$path), "data-1.0.csv")
  expect_equal(getaca:::sha256_file(final$path), rec$sha256)
  expect_true(getaca:::blob_exists(rec$sha256))
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
    "could not place the verified file into the cache"
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

  expect_equal(getaca:::sha256_file(final$path), rec$sha256)
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
  serves_other <- function(url, dest, progress = NULL) {
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
  cut_short <- function(url, dest, progress = NULL) {
    writeBin(charToRaw("pay"), dest)
    list(success = FALSE, reason = "transfer failed")
  }

  expect_error(
    getaca:::fetch_to_temp(id, rec, quiet = TRUE, transport = cut_short,
                           sleep = function(seconds) NULL),
    class = "getaca_error_unavailable"
  )
  expect_true(file.exists(part))
  expect_equal(file.info(part)$size, 3)
})

# A connection that drops partway has left bytes this mirror can continue from.
# Moving to the next mirror would abandon them for a transfer from zero, so the
# same mirror is asked again, and it resumes.
test_that("a connection that drops after delivering is resumed on the same mirror", {
  cache <- local_cache()
  id <- resource_id("demopkg", "res", "1.0")
  rec <- fake_record("payload", c("https://a.invalid/f", "https://b.invalid/f"))
  asked <- character()
  pieces <- c("pay", "lo", "ad")
  drops <- function(url, dest, progress = NULL) {
    asked <<- c(asked, url)
    con <- file(dest, open = "ab")
    writeBin(charToRaw(pieces[length(asked)]), con)
    close(con)
    done <- length(asked) == length(pieces)
    list(success = done, reason = if (done) NA_character_ else "connection reset",
         http = NA_integer_)
  }

  got <- getaca:::fetch_to_temp(id, rec, quiet = TRUE, transport = drops,
                                sleep = function(seconds) NULL)

  expect_equal(asked, rep("https://a.invalid/f", 3))
  expect_equal(got$url, "https://a.invalid/f")
  expect_equal(got$sha256, rec$sha256)
})

test_that("a mirror that never answers is not asked twice", {
  cache <- local_cache()
  id <- resource_id("demopkg", "res", "1.0")
  rec <- fake_record("payload", c("https://a.invalid/f", "https://b.invalid/f"))
  asked <- character()
  silent_then_served <- function(url, dest, progress = NULL) {
    asked <<- c(asked, url)
    if (grepl("//a\\.", url)) {
      return(list(success = FALSE, reason = "could not resolve host",
                  http = NA_integer_))
    }
    writeBin(charToRaw("payload"), dest)
    list(success = TRUE, reason = NA_character_, http = 200L)
  }

  got <- getaca:::fetch_to_temp(id, rec, quiet = TRUE,
                                transport = silent_then_served,
                                sleep = function(seconds) stop("nothing to wait for"))

  expect_equal(asked, c("https://a.invalid/f", "https://b.invalid/f"))
  expect_equal(got$url, "https://b.invalid/f")
})

# A busy server has said the request was fine and the moment was not. It is
# asked again after the interval it named, and a file that is not there is not.
test_that("a busy mirror is asked again after the interval it names", {
  cache <- local_cache()
  id <- resource_id("demopkg", "res", "1.0")
  rec <- fake_record("payload", "https://a.invalid/f")
  calls <- 0L
  waited <- numeric()
  busy_once <- function(url, dest, progress = NULL) {
    calls <<- calls + 1L
    if (calls == 1L) {
      return(list(success = FALSE, reason = "HTTP 429", http = 429L,
                  retry_after = 7))
    }
    writeBin(charToRaw("payload"), dest)
    list(success = TRUE, reason = NA_character_, http = 200L)
  }

  got <- getaca:::fetch_to_temp(id, rec, quiet = TRUE, transport = busy_once,
                                sleep = function(seconds) waited <<- c(waited, seconds))

  expect_equal(calls, 2L)
  expect_equal(waited, 7)
  expect_equal(got$sha256, rec$sha256)
})

test_that("a mirror that stays busy is given up on after the retries allowed", {
  cache <- local_cache()
  withr::local_options(list(getaca.retries = 2))
  id <- resource_id("demopkg", "res", "1.0")
  rec <- fake_record("payload", "https://a.invalid/f")
  calls <- 0L
  waited <- numeric()
  always_busy <- function(url, dest, progress = NULL) {
    calls <<- calls + 1L
    list(success = FALSE, reason = "HTTP 503", http = 503L)
  }

  expect_error(
    getaca:::fetch_to_temp(id, rec, quiet = TRUE, transport = always_busy,
                           sleep = function(seconds) waited <<- c(waited, seconds)),
    class = "getaca_error_unavailable"
  )
  # The first attempt and two more, with the wait doubling between them.
  expect_equal(calls, 3L)
  expect_equal(waited, c(2, 4))
})

test_that("a file that is not there is not asked for again", {
  cache <- local_cache()
  id <- resource_id("demopkg", "res", "1.0")
  rec <- fake_record("payload", "https://a.invalid/f")
  calls <- 0L
  missing <- function(url, dest, progress = NULL) {
    calls <<- calls + 1L
    list(success = FALSE, reason = "HTTP 404", http = 404L)
  }

  expect_error(
    getaca:::fetch_to_temp(id, rec, quiet = TRUE, transport = missing,
                           sleep = function(seconds) stop("nothing to wait for")),
    class = "getaca_error_unavailable"
  )
  expect_equal(calls, 1L)
})

test_that("a wait is never longer than a minute, whatever the server asks", {
  expect_equal(getaca:::retry_wait(1L), 2)
  expect_equal(getaca:::retry_wait(3L), 8)
  expect_equal(getaca:::retry_wait(10L), 60)
  expect_equal(getaca:::retry_wait(1L, retry_after = 5), 5)
  expect_equal(getaca:::retry_wait(1L, retry_after = 86400), 60)
  expect_equal(getaca:::retry_wait(1L, retry_after = NA_real_), 2)
})

test_that("Retry-After is read as seconds or as a date, from the last response", {
  now <- as.POSIXct("2026-01-01 00:00:00", tz = "UTC")
  headers <- function(...) charToRaw(paste0(paste(c(...), collapse = "\r\n"), "\r\n\r\n"))

  expect_equal(getaca:::retry_after(headers("HTTP/1.1 429 Too Many Requests",
                                            "Retry-After: 30"), now), 30)
  expect_equal(getaca:::retry_after(headers("HTTP/1.1 503 Service Unavailable",
                                            "retry-after: Thu, 01 Jan 2026 00:02:00 GMT"),
                                    now), 120)
  expect_true(is.na(getaca:::retry_after(headers("HTTP/1.1 503 Service Unavailable"), now)))
  expect_true(is.na(getaca:::retry_after(headers("HTTP/1.1 503 Service Unavailable",
                                                 "Retry-After: soon"), now)))
})

# Several files move in one call and each is judged on its own, so one that
# cannot be had does not take the others with it.
test_that("several files are fetched together and settle separately", {
  cache <- local_cache()
  good <- fake_record("payload", "https://a.invalid/good")
  bad <- fake_record("other payload", "https://a.invalid/bad")
  serves_one <- function(url, dest, progress = NULL) {
    if (grepl("bad$", url)) {
      return(list(success = FALSE, reason = "HTTP 404", http = 404L))
    }
    writeBin(charToRaw("payload"), dest)
    list(success = TRUE, reason = NA_character_, http = 200L)
  }

  got <- getaca:::fetch_many(
    list(list(id = resource_id("demopkg", "good", "1.0"), record = good),
         list(id = resource_id("demopkg", "bad", "1.0"), record = bad)),
    quiet = TRUE, transport = serves_one
  )

  expect_equal(got[[1]]$sha256, good$sha256)
  expect_s3_class(got[[2]], "getaca_error_unavailable")
})

# A transport that can move several attempts at once is handed all of a round's
# attempts together, which is what makes the transfers concurrent.
test_that("a transport that moves several attempts is given them together", {
  cache <- local_cache()
  one <- fake_record("payload", "https://a.invalid/one")
  two <- fake_record("payload two", "https://a.invalid/two")
  batches <- list()
  contents <- c("https://a.invalid/one" = "payload",
                "https://a.invalid/two" = "payload two")
  together <- structure(
    function(url, dest, progress = NULL) stop("attempts should arrive as a batch"),
    many = function(attempts) {
      batches[[length(batches) + 1L]] <<- vapply(attempts, function(a) a$url, character(1))
      lapply(attempts, function(a) {
        writeBin(charToRaw(contents[[a$url]]), a$dest)
        list(success = TRUE, reason = NA_character_, http = 200L)
      })
    }
  )

  got <- getaca:::fetch_many(
    list(list(id = resource_id("demopkg", "one", "1.0"), record = one),
         list(id = resource_id("demopkg", "two", "1.0"), record = two)),
    quiet = TRUE, transport = together
  )

  expect_equal(batches, list(c("https://a.invalid/one", "https://a.invalid/two")))
  expect_equal(got[[1]]$sha256, one$sha256)
  expect_equal(got[[2]]$sha256, two$sha256)
})

test_that("an end-to-end retrieval records the mirror that served it", {
  local_fetchable()
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
