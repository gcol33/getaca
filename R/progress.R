#' How a transfer reports itself
#'
#' getaca drives its own transfer loop, so what a download reports is a
#' decision the package makes rather than one libcurl makes for it. A reporter
#' receives an event for every transfer that begins, for the bytes that arrive
#' while it runs, and for how it ended, and renders them however it likes.
#'
#' The events carry what getaca knows and a transfer library cannot: the
#' resource identity, which part of a series is moving, the size the registry
#' declares for it, and how much of it was already on disk when the attempt
#' resumed. That is why the declared total is available before the first byte
#' arrives, and why a series reports `(part 2 of 3)` rather than three
#' unrelated downloads.
#'
#' @section Events:
#' Each event is a list with a `type` and the fields for that type. A handler
#' switches on `type` and ignores what it does not use, so a later release
#' adding an event type leaves an existing reporter working.
#' \describe{
#'   \item{`"begin"`}{A transfer attempt starts. `id` is the resource, which
#'     `format()` renders including the part label where there is one. `url` is
#'     the mirror. `total` is the declared size in bytes, or `NA` when the
#'     declaration gives none. `offset` is what was already on disk, which is
#'     non-zero when an interrupted transfer resumes.}
#'   \item{`"bytes"`}{Bytes have arrived. `bytes` is the cumulative total for
#'     this attempt including `offset`, so it can be compared against `total`
#'     directly. Fires often; a reporter that draws is expected to throttle.}
#'   \item{`"end"`}{The attempt finished. `status` is `"ok"` or `"failed"`,
#'     `reason` is the failure reason or `NA`, and `bytes` is what arrived.}
#' }
#'
#' A reporter never affects the outcome of a retrieval. An error raised inside
#' one is caught, reported once as a warning, and the reporter is switched off
#' for the rest of the session's call rather than being allowed to fail a
#' download that is otherwise fine.
#'
#' @name getaca-progress
#' @seealso [getaca_progress()] to choose one, [reporter()] to write one.
NULL

#' Choose how transfers report progress
#'
#' Reports or sets the progress style for the current session. The default,
#' `"auto"`, draws a bar when the session is interactive and reports nothing
#' when it is not, which keeps a log or a CI transcript clean without asking.
#'
#' `quiet = TRUE` on an individual [getaca()] call overrides whatever is set
#' here, so one silent call never needs the session changed and put back.
#'
#' @section Styles:
#' \describe{
#'   \item{`"auto"`}{A bar when interactive, nothing otherwise. The default.}
#'   \item{`"bar"`}{A single line that redraws in place, with the share
#'     transferred, the rate and an estimate of what is left. Falls back to
#'     bytes and a rate where the registry declares no size.}
#'   \item{`"line"`}{One line when a transfer starts and one when it ends. What
#'     a CI log or a `sink()`ed script wants, where a redrawing bar leaves
#'     thousands of fragments.}
#'   \item{`"none"`}{Nothing at all.}
#' }
#'
#' @param progress A style name, a [reporter()], or `NULL` to query without
#'   setting.
#' @return The reporter in effect, invisibly when setting.
#' @seealso [reporter()] to write your own, and [getaca-progress] for the
#'   events one receives.
#' @export
#'
#' @examples
#' getaca_progress()
#'
#' # A reporter of your own: one line per completed transfer, and nothing
#' # while it runs.
#' logger <- reporter("log", function(event) {
#'   if (identical(event$type, "end") && identical(event$status, "ok")) {
#'     message(format(event$id), " retrieved (", event$bytes, " bytes)")
#'   }
#' })
#' logger
#'
#' # getaca_progress(logger)
#' # getaca_progress("line")
getaca_progress <- function(progress = NULL) {
  if (is.null(progress)) return(as_reporter(setting_progress()))
  rep <- as_reporter(progress)
  options(getaca.progress = progress)
  invisible(rep)
}

setting_progress <- function() getaca_setting("progress", "auto")

#' Write a progress reporter
#'
#' A reporter turns transfer events into whatever you want a transfer to look
#' like: a bar, a log line, a row in a database, an update to a Shiny session.
#' It carries an `id` so that what is reporting is visible when one is set.
#'
#' See [getaca-progress] for the events and their fields.
#'
#' @param id Short stable identifier, for example `"bar"` or `"shiny"`.
#' @param fn A function of one argument, the event. Its return value is
#'   ignored.
#'
#' @return An object of class `getaca_reporter`.
#' @seealso [getaca_progress()]
#' @export
#'
#' @examples
#' # Only the totals, once each transfer is done.
#' reporter("totals", function(event) {
#'   if (identical(event$type, "end")) {
#'     cat(format(event$id), event$status, event$bytes, "\n")
#'   }
#' })
reporter <- function(id, fn) {
  stopifnot(is_string(id), grepl("^[A-Za-z0-9._-]+$", id), is.function(fn))
  structure(list(id = id, fn = fn), class = "getaca_reporter")
}

#' @export
print.getaca_reporter <- function(x, ...) {
  cat("<getaca reporter> ", x$id, "\n", sep = "")
  invisible(x)
}

# The style names are the API; the reporters behind them are not, so that a
# built-in can gain an argument without becoming a function anyone calls.
as_reporter <- function(x) {
  if (inherits(x, "getaca_reporter")) return(x)
  if (!is_string(x)) {
    stop("getaca: `progress` must be a style name or a reporter().", call. = FALSE)
  }
  switch(
    x,
    auto = if (interactive()) reporter_bar() else reporter_none(),
    bar  = reporter_bar(),
    line = reporter_line(),
    none = reporter_none(),
    stop(sprintf(
      "getaca: unknown progress style '%s'; one of \"auto\", \"bar\", \"line\", \"none\", or a reporter().",
      x
    ), call. = FALSE)
  )
}

# What a retrieval reports, given what the caller asked for. `quiet` is the
# per-call override and wins over the session setting, so one silent call never
# needs the session changed and put back.
effective_reporter <- function(quiet = FALSE, progress = NULL) {
  if (isTRUE(quiet)) return(reporter_none())
  safely(as_reporter(progress %||% setting_progress()))
}

# A reporter is cosmetic and a transfer is not, so a reporter that raises is
# reported once and then switched off rather than being allowed to fail a
# download that is otherwise fine.
safely <- function(rep) {
  broken <- FALSE
  reporter(rep$id, function(event) {
    if (broken) return(invisible(NULL))
    tryCatch(rep$fn(event), error = function(e) {
      broken <<- TRUE
      warning(sprintf("getaca: progress reporter '%s' failed and was switched off:\n  %s",
                      rep$id, conditionMessage(e)), call. = FALSE)
    })
    invisible(NULL)
  })
}

emit <- function(rep, type, ...) {
  if (is.null(rep)) return(invisible(NULL))
  rep$fn(c(list(type = type), list(...)))
  invisible(NULL)
}

# The callback the transport is handed. NULL where nothing is listening, so a
# quiet transfer costs no call per chunk.
byte_callback <- function(rep, id, total) {
  if (is.null(rep) || identical(rep$id, "none")) return(NULL)
  function(bytes) emit(rep, "bytes", id = id, bytes = bytes, total = total)
}

reporter_none <- function() reporter("none", function(event) invisible(NULL))

# One line as a transfer starts and one as it ends. Deliberately not a redraw:
# this is the style for a log, where a bar leaves thousands of fragments.
reporter_line <- function(con = stderr(), now = Sys.time) {
  started <- NULL
  reporter("line", function(event) {
    if (identical(event$type, "begin")) {
      started <<- now()
      resumed <- if (isTRUE(event$offset > 0)) {
        sprintf(", resuming from %s", human_bytes(event$offset))
      } else ""
      writeLines(sprintf("getaca: downloading %s (%s%s)", format(event$id),
                         human_bytes(event$total), resumed), con = con)
    } else if (identical(event$type, "end")) {
      elapsed <- if (is.null(started)) NA_real_ else
        as.numeric(difftime(now(), started, units = "secs"))
      writeLines(
        if (identical(event$status, "ok")) {
          sprintf("getaca: %s done, %s in %s", format(event$id),
                  human_bytes(event$bytes), human_seconds(elapsed))
        } else {
          sprintf("getaca: %s failed (%s)", format(event$id), event$reason)
        },
        con = con
      )
    }
  })
}

# Redraws in place, so the terminal keeps one line per transfer however many
# times the bytes move. `now` is an argument because rate and estimate are
# functions of a clock, and a bar whose output cannot be predicted is a bar
# that cannot be tested.
reporter_bar <- function(con = stderr(), now = Sys.time) {
  st <- new.env(parent = emptyenv())
  reporter("bar", function(event) {
    switch(
      event$type,
      begin = {
        st$started <- now()
        st$drawn <- NULL
        st$label <- format(event$id)
        st$total <- event$total
        st$offset <- event$offset %||% 0
        st$bytes <- st$offset
        st$cells <- plan_cells(st$label, st$total, bar_width())
      },
      bytes = {
        st$bytes <- event$bytes
        # Ten redraws a second is past what an eye resolves, and a 4 GB
        # transfer delivers a few hundred thousand chunks.
        if (is.null(st$drawn) ||
            as.numeric(difftime(now(), st$drawn, units = "secs")) >= 0.1) {
          st$drawn <- now()
          draw_bar(con, bar_line(st, now(), width = bar_width(), cells = st$cells))
        }
      },
      end = {
        st$bytes <- event$bytes %||% st$bytes
        if (identical(event$status, "ok")) {
          draw_bar(con, bar_line(st, now(), done = TRUE, width = bar_width(), cells = st$cells))
        } else {
          draw_bar(con, sprintf("%s  failed: %s", st$label %||% "", event$reason))
        }
        writeLines("", con = con)
      },
      invisible(NULL)
    )
  })
}

bar_width <- function() as.integer(getOption("width", 80L))

# One carriage return and no newline, so the next draw lands on this line.
# Padded to the width it last occupied, since a shorter line would otherwise
# leave the tail of the longer one behind it.
draw_bar <- function(con, text) {
  width <- bar_width()
  if (nchar(text) > width) text <- substr(text, 1L, width)
  cat("\r", formatC(text, width = -width), sep = "", file = con)
  utils::flush.console()
  invisible(NULL)
}

# A number that moves is right-aligned in the width of the widest value it can
# take, so a transfer crossing 9.9 MB to 10 MB to 105 MB leaves the fields to
# its right where they were. Below an exabyte human_bytes() renders no wider
# than "999 kB", and human_seconds() no wider than "9:59:59" until an estimate
# passes ten hours. Past either the field is outgrown rather than enforced, and
# the line reflows the way it does whenever it runs out of room.
BYTES_FIELD <- 6L
CLOCK_FIELD <- 7L

pad_field <- function(text, width) formatC(text, width = width)

# Everything the bar knows how to say. The numbers are what the line is for, so
# they are laid out first and the glyph takes what is left; a declaration
# without a size still gets bytes and a rate, since a share and an estimate are
# the two things that do not exist without a total.
bar_line <- function(st, at, done = FALSE, width = getOption("width", 80L),
                     cells = NULL) {
  elapsed <- as.numeric(difftime(at, st$started, units = "secs"))
  moved <- st$bytes - st$offset
  rate <- if (is.finite(elapsed) && elapsed > 0) moved / elapsed else NA_real_

  size <- pad_field(human_bytes(st$bytes), BYTES_FIELD)
  if (!is.na(st$total)) size <- paste0(size, " / ", human_bytes(st$total))
  if (done) size <- paste0(size, " in ", human_seconds(elapsed))
  rate_text <- if (!is.na(rate) && !done) {
    paste0("  ", pad_field(human_bytes(rate), BYTES_FIELD), "/s")
  } else ""

  if (is.na(st$total) || st$total <= 0) {
    return(paste0(st$label, "  ", size, rate_text))
  }
  share <- min(1, st$bytes / st$total)
  eta <- if (!done && !is.na(rate) && rate > 0 && share < 1) {
    paste0("  ETA ", human_seconds((st$total - st$bytes) / rate))
  } else ""
  share_text <- sprintf(" %3.0f%%  ", 100 * share)

  # One column short of the terminal, so the line never wraps onto the one the
  # next redraw is going to overwrite. What gives way as a line runs out of
  # room, in order: the width of the bar, then the estimate, then the rate. The
  # share and the bytes are what the line is for and are never dropped.
  room <- as.integer(width) - 1L
  fixed <- nchar(st$label) + 2L + nchar(share_text)
  for (tail in c(paste0(size, rate_text, eta), paste0(size, rate_text), size)) {
    n <- cells %||% glyph_cells(room - fixed - nchar(tail))
    line <- paste0(st$label, "  ", bar_glyph(share, n), share_text, tail)
    if (nchar(line) <= room) return(line)
  }
  line
}

# The glyph is what the line can spare rather than a fixed size, so a long
# resource name or a narrow terminal shortens the bar instead of wrapping it.
# Below a floor there is nothing a bar conveys that the percentage does not,
# and it is dropped.
BAR_MIN_CELLS <- 6L
BAR_MAX_CELLS <- 30L

glyph_cells <- function(room) {
  cells <- min(BAR_MAX_CELLS, as.integer(room) - 2L)
  if (is.na(cells) || cells < BAR_MIN_CELLS) 0L else cells
}

bar_glyph <- function(share, cells) {
  if (is.na(cells) || cells <= 0L) return("")
  filled <- as.integer(round(share * cells))
  sprintf("[%s%s]", strrep("=", filled), strrep("-", cells - filled))
}

# How wide the bar is, decided once when a transfer starts and from the widest
# line it will ever draw. The rate and the estimate leave the line when a
# transfer finishes, and a bar that grew into the room they freed would jump at
# the moment it stopped moving. The budget is the width of each field rather
# than the width of the total, since a transfer at 1.5 MB renders wider than
# one whose declaration says 10 MB.
plan_cells <- function(label, total, width = getOption("width", 80L)) {
  if (is.null(total) || is.na(total) || total <= 0) return(0L)
  widest <- BYTES_FIELD + nchar(" / ") + nchar(human_bytes(total)) +
    2L + BYTES_FIELD + nchar("/s") + nchar("  ETA ") + CLOCK_FIELD
  glyph_cells(as.integer(width) - 1L - nchar(label) - 2L -
                nchar(" 100%  ") - widest)
}

BYTE_UNITS <- c("B", "kB", "MB", "GB", "TB", "PB")

human_bytes <- function(x) {
  if (length(x) != 1L || is.na(x)) return("unknown size")
  if (x < 1000) return(sprintf("%.0f B", x))
  i <- min(length(BYTE_UNITS), 1L + as.integer(floor(log(x, 1000))))
  scaled <- x / 1000^(i - 1L)
  # Both boundaries are decided on the value as it will be rounded rather than
  # as it arrives, since sprintf rounds after the unit and the decimal are
  # chosen: 9.99 kB would otherwise render "10.0 kB" where 10 kB renders
  # "10 kB", and 999.6 kB would render "1000 kB" rather than the megabyte it
  # rounds to.
  if (scaled >= 999.5 && i < length(BYTE_UNITS)) {
    i <- i + 1L
    scaled <- x / 1000^(i - 1L)
  }
  sprintf(if (scaled < 9.95) "%.1f %s" else "%.0f %s", scaled, BYTE_UNITS[i])
}

human_seconds <- function(x) {
  if (length(x) != 1L || is.na(x) || !is.finite(x)) return("--:--")
  x <- max(0, round(x))
  if (x >= 3600) {
    sprintf("%d:%02d:%02d", x %/% 3600, (x %% 3600) %/% 60, x %% 60)
  } else {
    sprintf("%02d:%02d", x %/% 60, x %% 60)
  }
}
