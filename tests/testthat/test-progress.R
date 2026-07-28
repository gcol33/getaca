# A reporter is the one part of a transfer that exists to be looked at, so what
# it is handed is asserted directly: the events, their fields, and the rendering
# they produce. A clock is an argument to both built-in reporters, so a rate and
# an estimate are testable without waiting for one.

# Records every event, which is what lets a test assert the sequence rather than
# the drawing.
recording_reporter <- function() {
  seen <- list()
  rep <- getaca::reporter("recording", function(event) {
    seen[[length(seen) + 1L]] <<- event
  })
  list(reporter = rep, events = function() seen,
       types = function() vapply(seen, function(e) e$type, character(1)))
}

# A transport that reports its bytes the way the real one does, so the events a
# fetch produces can be exercised without a network.
reporting_transport <- function(contents, chunks = 2L) {
  function(url, dest, progress = NULL) {
    raw_bytes <- charToRaw(contents)
    con <- file(dest, open = "wb")
    on.exit(close(con))
    written <- 0
    for (piece in split(raw_bytes, ceiling(seq_along(raw_bytes) / max(1, ceiling(length(raw_bytes) / chunks))))) {
      writeBin(piece, con)
      written <- written + length(piece)
      if (!is.null(progress)) progress(written)
    }
    list(success = TRUE, reason = NA_character_)
  }
}

# A clock that answers from a fixed sequence, so elapsed time is stated by the
# test rather than measured.
fake_clock <- function(seconds) {
  base <- as.POSIXct("2026-01-01 00:00:00", tz = "UTC")
  i <- 0L
  function() {
    i <<- i + 1L
    base + seconds[min(i, length(seconds))]
  }
}

# A bar redraws with carriage returns and no newlines, so what it wrote is read
# back as bytes rather than as lines: readLines() would treat every redraw as a
# line of its own and hide exactly what the throttle is asserted on.
capture_reporter <- function(build) {
  path <- withr::local_tempfile(.local_envir = parent.frame())
  con <- file(path, open = "w")
  open <- TRUE
  shut <- function() {
    if (open) {
      close(con)
      open <<- FALSE
    }
  }
  text <- function() {
    shut()
    if (!file.exists(path) || file.size(path) == 0) return("")
    readChar(path, file.size(path), useBytes = TRUE)
  }
  list(reporter = build(con), close = shut, text = text,
       lines = function() {
         out <- text()
         if (!nzchar(out)) return(character())
         strsplit(sub("\n$", "", out), "\n", fixed = TRUE)[[1]]
       })
}

test_that("a reporter is an id and a function, and both are checked", {
  rep <- reporter("mine", function(event) NULL)
  expect_s3_class(rep, "getaca_reporter")
  expect_equal(rep$id, "mine")

  expect_error(reporter("has space", function(e) NULL))
  expect_error(reporter("mine", "not a function"))
})

test_that("a style name selects a built-in and an unknown one is refused", {
  expect_equal(getaca:::as_reporter("none")$id, "none")
  expect_equal(getaca:::as_reporter("bar")$id, "bar")
  expect_equal(getaca:::as_reporter("line")$id, "line")
  expect_error(getaca:::as_reporter("sparkles"), "unknown progress style")
  expect_error(getaca:::as_reporter(42), "style name or a reporter")
})

test_that("a reporter object passes through as itself", {
  mine <- reporter("mine", function(event) NULL)
  expect_identical(getaca:::as_reporter(mine), mine)
})

test_that("the style is read from the option, then the environment", {
  withr::local_options(list(getaca.progress = NULL))
  withr::local_envvar(list(GETACA_PROGRESS = "line"))
  expect_equal(getaca_progress()$id, "line")

  withr::local_options(list(getaca.progress = "none"))
  expect_equal(getaca_progress()$id, "none")
})

test_that("setting the style returns the reporter and records the setting", {
  withr::local_options(list(getaca.progress = NULL))
  rep <- getaca_progress("line")
  expect_equal(rep$id, "line")
  expect_equal(getOption("getaca.progress"), "line")
})

test_that("quiet on one call beats whatever the session is set to", {
  withr::local_options(list(getaca.progress = "bar"))
  expect_equal(getaca:::effective_reporter(quiet = TRUE)$id, "none")
  expect_equal(getaca:::effective_reporter(quiet = FALSE)$id, "bar")
})

test_that("nothing listening means no per-chunk callback at all", {
  expect_null(getaca:::byte_callback(getaca:::reporter_none(), NULL, NA_real_))
  expect_true(is.function(
    getaca:::byte_callback(reporter("mine", function(e) NULL), NULL, NA_real_)
  ))
})

test_that("a transfer reports begin, bytes and end with the declared total", {
  cache <- local_cache()
  rec <- resource("res", "1.0", urls = "https://a.invalid/f",
                  sha256 = getaca:::sha256_bytes(charToRaw("payload")),
                  size = 7)
  id <- resource_id("demopkg", "res", "1.0")
  log <- recording_reporter()

  getaca:::fetch_to_temp(id, rec, transport = reporting_transport("payload"),
                         reporter = log$reporter)

  expect_equal(log$types()[1], "begin")
  expect_equal(log$types()[length(log$types())], "end")
  expect_true("bytes" %in% log$types())

  begin <- log$events()[[1]]
  expect_equal(begin$total, 7)
  expect_equal(begin$offset, 0)
  expect_equal(begin$url, "https://a.invalid/f")
  expect_equal(format(begin$id), "demopkg/res@1.0")

  end <- log$events()[[length(log$events())]]
  expect_equal(end$status, "ok")
  expect_equal(end$bytes, 7)
  expect_true(is.na(end$reason))
})

test_that("a failing mirror ends its own event and the next one begins", {
  cache <- local_cache()
  rec <- resource("res", "1.0",
                  urls = c("https://a.invalid/f", "https://b.invalid/f"),
                  sha256 = getaca:::sha256_bytes(charToRaw("payload")), size = 7)
  id <- resource_id("demopkg", "res", "1.0")
  log <- recording_reporter()
  attempt <- 0L

  getaca:::fetch_to_temp(
    id, rec, reporter = log$reporter,
    transport = function(url, dest, progress = NULL) {
      attempt <<- attempt + 1L
      if (attempt == 1L) return(list(success = FALSE, reason = "HTTP 503"))
      reporting_transport("payload")(url, dest, progress)
    }
  )

  ends <- Filter(function(e) identical(e$type, "end"), log$events())
  expect_equal(vapply(ends, function(e) e$status, character(1)),
               c("failed", "ok"))
  expect_equal(ends[[1]]$reason, "HTTP 503")
})

test_that("a resumed attempt reports what was already on disk", {
  cache <- local_cache()
  rec <- resource("res", "1.0", urls = "https://a.invalid/f",
                  sha256 = getaca:::sha256_bytes(charToRaw("payload")), size = 7)
  id <- resource_id("demopkg", "res", "1.0")
  writeBin(charToRaw("pay"), getaca:::partial_path(rec, rec$urls[1]))
  log <- recording_reporter()

  getaca:::fetch_to_temp(id, rec, reporter = log$reporter,
                         transport = reporting_transport("payload"))

  expect_equal(log$events()[[1]]$offset, 3)
})

test_that("each part of a series reports under its own label", {
  cache <- local_cache()
  pieces <- c("aaaa", "bbbb")
  whole <- paste0(pieces, collapse = "")
  rec <- resource(
    "res", "1.0", sha256 = getaca:::sha256_bytes(charToRaw(whole)),
    file = "res.bin",
    parts = list(
      part("https://a.invalid/p1", sha256 = getaca:::sha256_bytes(charToRaw(pieces[1])), size = 4),
      part("https://a.invalid/p2", sha256 = getaca:::sha256_bytes(charToRaw(pieces[2])), size = 4)
    )
  )
  id <- resource_id("demopkg", "res", "1.0")
  log <- recording_reporter()

  getaca:::compose_parts(
    id, rec, reporter = log$reporter,
    transport = function(url, dest, progress = NULL) {
      which <- if (endsWith(url, "p1")) pieces[1] else pieces[2]
      reporting_transport(which)(url, dest, progress)
    }
  )

  begins <- Filter(function(e) identical(e$type, "begin"), log$events())
  expect_equal(vapply(begins, function(e) format(e$id), character(1)),
               c("demopkg/res@1.0 (part 1 of 2)", "demopkg/res@1.0 (part 2 of 2)"))
  # The total a part reports is its own, not the artefact's.
  expect_equal(vapply(begins, function(e) e$total, numeric(1)), c(4, 4))
})

test_that("a reporter that raises is switched off rather than failing a fetch", {
  cache <- local_cache()
  rec <- resource("res", "1.0", urls = "https://a.invalid/f",
                  sha256 = getaca:::sha256_bytes(charToRaw("payload")), size = 7)
  id <- resource_id("demopkg", "res", "1.0")
  calls <- 0L
  angry <- reporter("angry", function(event) {
    calls <<- calls + 1L
    stop("no")
  })

  expect_warning(
    got <- getaca:::fetch_to_temp(id, rec, reporter = getaca:::safely(angry),
                                  transport = reporting_transport("payload")),
    "switched off"
  )
  expect_equal(got$sha256, rec$sha256)
  # Once, and then never again for the rest of the transfer.
  expect_equal(calls, 1L)
})

test_that("the bar states the share, the rate and what is left", {
  withr::local_options(list(width = 100))
  cap <- capture_reporter(function(con) {
    getaca:::reporter_bar(con = con, now = fake_clock(c(0, 2, 2)))
  })
  rep <- cap$reporter

  rep$fn(list(type = "begin", id = resource_id("demopkg", "backbone", "2026-09"),
              url = "https://a.invalid/f", total = 1e9, offset = 0))
  rep$fn(list(type = "bytes", id = NULL, bytes = 25e7, total = 1e9))
  cap$close()

  line <- cap$text()
  expect_match(line, "demopkg/backbone@2026-09")
  expect_match(line, "25%")
  expect_match(line, "250 MB / 1.0 GB")
  # 250 MB in 2 seconds, and 750 MB still to come at that rate.
  expect_match(line, "125 MB/s")
  expect_match(line, "ETA 00:06")
})

test_that("a declaration with no size still gets bytes and a rate", {
  withr::local_options(list(width = 100))
  cap <- capture_reporter(function(con) {
    getaca:::reporter_bar(con = con, now = fake_clock(c(0, 4, 4)))
  })
  rep <- cap$reporter

  rep$fn(list(type = "begin", id = resource_id("demopkg", "res", "1.0"),
              url = "https://a.invalid/f", total = NA_real_, offset = 0))
  rep$fn(list(type = "bytes", id = NULL, bytes = 4e6, total = NA_real_))
  cap$close()

  line <- cap$text()
  expect_match(line, "4.0 MB")
  expect_match(line, "1.0 MB/s")
  expect_false(grepl("%", line))
  expect_false(grepl("ETA", line))
})

test_that("the bar redraws at most ten times a second", {
  withr::local_options(list(width = 100))
  # begin, then four byte events a hundredth of a second apart.
  cap <- capture_reporter(function(con) {
    getaca:::reporter_bar(con = con,
                          now = fake_clock(c(0, 0.01, 0.01, 0.02, 0.03, 0.04)))
  })
  rep <- cap$reporter

  rep$fn(list(type = "begin", id = resource_id("demopkg", "res", "1.0"),
              url = "https://a.invalid/f", total = 100, offset = 0))
  for (b in c(10, 20, 30, 40)) {
    rep$fn(list(type = "bytes", id = NULL, bytes = b, total = 100))
  }
  cap$close()

  # One draw, not four: the first byte event draws and the rest are inside the
  # window it opened.
  expect_equal(length(gregexpr("\r", cap$text())[[1]]), 1L)
})

test_that("the bar closes its line when the transfer ends", {
  withr::local_options(list(width = 100))
  cap <- capture_reporter(function(con) {
    getaca:::reporter_bar(con = con, now = fake_clock(c(0, 3, 3)))
  })
  rep <- cap$reporter

  rep$fn(list(type = "begin", id = resource_id("demopkg", "res", "1.0"),
              url = "https://a.invalid/f", total = 300, offset = 0))
  rep$fn(list(type = "end", id = NULL, status = "ok", bytes = 300,
              reason = NA_character_))
  cap$close()

  line <- cap$text()
  expect_match(line, "100%")
  expect_match(line, "in 00:03")
  expect_false(grepl("ETA", line))
})

test_that("a failed transfer says so on the bar's line", {
  withr::local_options(list(width = 100))
  cap <- capture_reporter(function(con) {
    getaca:::reporter_bar(con = con, now = fake_clock(c(0, 1)))
  })
  rep <- cap$reporter

  rep$fn(list(type = "begin", id = resource_id("demopkg", "res", "1.0"),
              url = "https://a.invalid/f", total = 300, offset = 0))
  rep$fn(list(type = "end", id = NULL, status = "failed", bytes = 0,
              reason = "HTTP 503"))
  cap$close()

  expect_match(cap$text(), "failed: HTTP 503")
})

test_that("the line style writes one line to start and one to finish", {
  cap <- capture_reporter(function(con) {
    getaca:::reporter_line(con = con, now = fake_clock(c(0, 12)))
  })
  rep <- cap$reporter

  rep$fn(list(type = "begin", id = resource_id("demopkg", "backbone", "2026-09"),
              url = "https://a.invalid/f", total = 8.12e8, offset = 0))
  rep$fn(list(type = "end", id = resource_id("demopkg", "backbone", "2026-09"),
              status = "ok", bytes = 8.12e8, reason = NA_character_))
  cap$close()

  out <- cap$lines()
  expect_length(out, 2L)
  expect_match(out[1], "downloading demopkg/backbone@2026-09 \\(812 MB\\)")
  expect_match(out[2], "done, 812 MB in 00:12")
})

test_that("the line style says where a resumed transfer started", {
  cap <- capture_reporter(function(con) {
    getaca:::reporter_line(con = con, now = fake_clock(c(0, 1)))
  })
  rep <- cap$reporter

  rep$fn(list(type = "begin", id = resource_id("demopkg", "res", "1.0"),
              url = "https://a.invalid/f", total = 1e6, offset = 4e5))
  cap$close()

  expect_match(cap$lines()[1], "resuming from 400 kB")
})

test_that("sizes and durations read the way a human writes them", {
  expect_equal(getaca:::human_bytes(0), "0 B")
  expect_equal(getaca:::human_bytes(999), "999 B")
  expect_equal(getaca:::human_bytes(1000), "1.0 kB")
  expect_equal(getaca:::human_bytes(9.9e3), "9.9 kB")
  expect_equal(getaca:::human_bytes(1e5), "100 kB")
  expect_equal(getaca:::human_bytes(1.5e9), "1.5 GB")
  expect_equal(getaca:::human_bytes(NA_real_), "unknown size")

  expect_equal(getaca:::human_seconds(0), "00:00")
  expect_equal(getaca:::human_seconds(75), "01:15")
  expect_equal(getaca:::human_seconds(3725), "1:02:05")
  expect_equal(getaca:::human_seconds(NA_real_), "--:--")
  expect_equal(getaca:::human_seconds(Inf), "--:--")
})

test_that("the glyph draws the cells it is given", {
  expect_match(getaca:::bar_glyph(0.5, 10), "^\\[={5}-{5}\\]$")
  expect_match(getaca:::bar_glyph(1, 30), "^\\[={30}\\]$")
  expect_equal(getaca:::bar_glyph(0.5, 0), "")
})

test_that("the cells are what the line can spare, down to a floor", {
  expect_equal(getaca:::glyph_cells(12), 10L)
  expect_equal(getaca:::glyph_cells(60), 30L)
  # Below a floor a bar says nothing the percentage does not.
  expect_equal(getaca:::glyph_cells(7), 0L)
  expect_equal(getaca:::glyph_cells(-4), 0L)
})

test_that("the bar keeps the width it started with when it finishes", {
  # The rate and the estimate leave the line at the end, and the bar must not
  # grow into the room they free.
  label <- "demopkg/backbone@2026-09 (part 1 of 3)"
  cells <- getaca:::plan_cells(label, 797e6, width = 96)
  st <- list(label = label, total = 797e6, offset = 0, bytes = 4e8,
             started = as.POSIXct("2026-01-01", tz = "UTC"))
  at <- as.POSIXct("2026-01-01 00:00:03", tz = "UTC")

  running <- getaca:::bar_line(st, at, width = 96, cells = cells)
  st$bytes <- 797e6
  done <- getaca:::bar_line(st, at, done = TRUE, width = 96, cells = cells)

  glyph_of <- function(line) regmatches(line, regexpr("\\[[^]]*\\]", line))
  expect_equal(nchar(glyph_of(running)), nchar(glyph_of(done)))
  expect_lte(nchar(running), 95L)
  expect_lte(nchar(done), 95L)
})

test_that("a declaration with no size plans no bar at all", {
  expect_equal(getaca:::plan_cells("res", NA_real_, width = 100), 0L)
  expect_equal(getaca:::plan_cells("res", 0, width = 100), 0L)
})

test_that("a long label shortens the bar rather than wrapping the line", {
  st <- list(label = strrep("x", 50), total = 1e9, offset = 0, bytes = 5e8,
             started = as.POSIXct("2026-01-01", tz = "UTC"))
  at <- as.POSIXct("2026-01-01 00:00:10", tz = "UTC")

  wide <- getaca:::bar_line(st, at, width = 120)
  narrow <- getaca:::bar_line(st, at, width = 80)

  expect_lte(nchar(wide), 119L)
  expect_lte(nchar(narrow), 79L)
  # The numbers survive at both widths; the glyph is what gives way.
  expect_match(narrow, "500 MB / 1.0 GB")
  expect_true(nchar(wide) > nchar(narrow))
})

test_that("a line longer than the terminal is cut rather than wrapped", {
  withr::local_options(list(width = 40))
  path <- withr::local_tempfile()
  con <- file(path, open = "w")
  getaca:::draw_bar(con, strrep("x", 100))
  close(con)

  written <- readChar(path, file.size(path), useBytes = TRUE)
  # One carriage return and exactly the terminal's width after it, so the line
  # a redraw lands on is the one it replaced.
  expect_equal(nchar(written), 41L)
  expect_true(startsWith(written, "\r"))
})
