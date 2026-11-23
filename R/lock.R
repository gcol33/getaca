#' Per-resource locking
#'
#' Two sessions asking for the same multi-gigabyte file must not both download
#' it, and must never mistake each other's in-flight temporary file for a
#' finished resource. Locking is foundational rather than an optimisation, so
#' it is present from the first version.
#'
#' The lock is a directory. `dir.create()` is atomic on both POSIX and
#' Windows, and on the network filesystems a shared cache tends to live on,
#' which makes it a mutex that works wherever the cache does.
#'
#' The key is the declared checksum rather than the identity triple, because
#' what a waiter is waiting for is a transfer of particular bytes. Two packages
#' declaring the same file wait on each other, and the second finds the blob
#' the first admitted instead of downloading it again.
#'
#' @section Whether a holder is still there:
#' A lock records the process that took it, the machine that process runs on
#' and when the process started. A waiter on the same machine asks the
#' operating system whether that process is still running, so a lock is held
#' for exactly as long as its holder lives: a transfer of any length keeps it,
#' and a session that crashed loses it at once.
#'
#' A waiter on another machine, which a cache on a shared filesystem makes
#' possible, cannot ask that question. There the holder shows it is alive by
#' touching its lock on a timer, from a second thread, for as long as it holds
#' the lock: under a transfer, a [combiner()] and a [processor()] alike. The
#' lock is abandoned once it has gone untouched for
#' `getaca.lock_stale_seconds`, which is how long a crash on another machine
#' takes to be noticed.
#'
#' A waiter waits for as long as the holder is alive, since the alternative is
#' a second transfer of the same bytes. `getaca.lock_wait_seconds` bounds the
#' wait where that is wanted.
#'
#' @name getaca-locking
#' @keywords internal
NULL

lock_dir <- function(key) {
  d <- file.path(getaca_cache_dir(), ".locks")
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
  file.path(d, key)
}

holder_path <- function(path) file.path(path, "holder")

# NA when no such process is running, 0 when one is and its start cannot be
# read, and otherwise a stamp of when it started.
process_stamp <- function(pid) .Call(C_process_stamp, as.integer(pid))

this_host <- function() unname(Sys.info()[["nodename"]])

this_process <- function() {
  pid <- Sys.getpid()
  list(pid = pid, host = this_host(), start = process_stamp(pid))
}

write_holder <- function(path, who = this_process()) {
  writeLines(
    c(as.character(who$pid), who$host, sprintf("%.0f", who$start),
      format(Sys.time(), "%Y-%m-%dT%H:%M:%S")),
    holder_path(path)
  )
}

# NULL where there is no holder file to read. A lock written by a getaca that
# recorded only the process and the time has no machine to compare, and is
# judged the way a lock from another machine is.
read_holder <- function(path) {
  lines <- tryCatch(suppressWarnings(readLines(holder_path(path))),
                    error = function(e) NULL)
  if (!length(lines)) return(NULL)
  full <- length(lines) >= 4L
  list(
    pid = suppressWarnings(as.integer(lines[1])),
    host = if (full) lines[2] else NA_character_,
    start = if (full) suppressWarnings(as.numeric(lines[3])) else NA_real_
  )
}

same_process <- function(a, b) {
  identical(a$pid, b$pid) && identical(a$host, b$host) &&
    isTRUE(a$start == b$start)
}

file_age <- function(path) {
  as.numeric(difftime(Sys.time(), file.info(path)$mtime, units = "secs"))
}

# A lock directory exists for an instant before its holder file does, and a
# waiter looking in that instant must not take it for an abandoned one.
HOLDER_GRACE_SECONDS <- 10

# `stamp` is the question put to the operating system, and an argument for the
# reason `transport` is one in fetch_to_temp(): what a dead holder, a reused
# process id and a holder on another machine each mean is the part worth
# testing, and none of them can be arranged on demand.
lock_is_stale <- function(path, stamp = process_stamp) {
  holder <- read_holder(path)
  if (is.null(holder)) {
    return(!dir.exists(path) || isTRUE(file_age(path) > HOLDER_GRACE_SECONDS))
  }
  if (identical(holder$host, this_host())) {
    running <- stamp(holder$pid)
    if (is.na(running)) return(TRUE)
    # Both stamps readable and different: the number was handed to a process
    # started since, and the holder is gone.
    return(isTRUE(running != 0 && holder$start != 0 && running != holder$start))
  }
  isTRUE(file_age(holder_path(path)) > setting_lock_stale())
}

# A lock some session is still behind, as opposed to a directory one left.
lock_is_live <- function(key) {
  path <- lock_dir(key)
  dir.exists(path) && !lock_is_stale(path)
}

# The locks this process holds. A child forked from a session holding some
# starts with none: they are its parent's to keep alive and to release.
lock_state <- new.env(parent = emptyenv())
lock_state$held <- character()
lock_state$pid <- NA_integer_

# How a holder tells a waiter on another machine that it is still there. The
# holder files are touched from a second thread (`src/heartbeat.c`) for as
# long as any lock is held, so the touching goes on under a transfer, a
# combiner and a processor alike. The interval stays well inside the staleness
# threshold, since a lock touched only as often as it expires would expire
# between touches.
beat_interval <- function() max(1, min(30, setting_lock_stale() / 4))

keep_alive <- function(held) {
  lock_state$held <- held
  lock_state$pid <- Sys.getpid()
  # Absolute, so a session that changes directory goes on touching the same
  # files.
  files <- normalizePath(holder_path(held), mustWork = FALSE)
  .Call(C_heartbeat, enc2utf8(files), beat_interval())
  invisible(NULL)
}

held_locks <- function() {
  if (identical(lock_state$pid, Sys.getpid())) lock_state$held else character()
}

describe_holder <- function(path) {
  holder <- read_holder(path)
  if (is.null(holder) || is.na(holder$pid)) return("another session")
  if (is.na(holder$host)) return(sprintf("another session (process %d)", holder$pid))
  sprintf("another session (process %d on %s)", holder$pid, holder$host)
}

acquire_lock <- function(key, label = key, timeout = setting_lock_wait(),
                         poll = 0.5, quiet = FALSE) {
  path <- lock_dir(key)
  deadline <- Sys.time() + timeout
  announced <- isTRUE(quiet)
  repeat {
    if (dir.create(path, showWarnings = FALSE)) {
      write_holder(path)
      keep_alive(union(held_locks(), path))
      return(structure(list(path = path), class = "getaca_lock"))
    }
    if (lock_is_stale(path)) {
      unlink(path, recursive = TRUE)
      next
    }
    if (Sys.time() > deadline) {
      stop(sprintf(
        paste0("getaca: timed out waiting for %s to finish fetching %s.\n",
               "If no other session is running, remove the stale lock:\n  unlink(\"%s\", recursive = TRUE)"),
        describe_holder(path), label, path
      ), call. = FALSE)
    }
    if (!announced) {
      message(sprintf("getaca: waiting for %s to finish fetching %s.",
                      describe_holder(path), label))
      announced <- TRUE
    }
    Sys.sleep(poll)
  }
}

# A lock that went stale under a holder on another machine may since have been
# taken over, and removing it then would release someone else's.
release_lock <- function(lock) {
  if (is.null(lock)) return(invisible(NULL))
  keep_alive(setdiff(held_locks(), lock$path))
  holder <- read_holder(lock$path)
  if (is.null(holder) || same_process(holder, this_process())) {
    unlink(lock$path, recursive = TRUE)
  }
  invisible(NULL)
}
