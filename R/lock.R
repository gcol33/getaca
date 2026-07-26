#' Per-resource locking
#'
#' Two sessions asking for the same multi-gigabyte file must not both download
#' it, and must never mistake each other's in-flight temporary file for a
#' finished resource. Locking is foundational rather than an optimisation, so
#' it is present from the first version.
#'
#' The lock is a directory. `dir.create()` is atomic on both POSIX and
#' Windows, which makes it a portable mutex without a compiled dependency. A
#' waiter either observes that the holder finished successfully, or takes over
#' once the lock goes stale.
#'
#' @name getaca-locking
#' @keywords internal
NULL

lock_dir <- function(id) {
  d <- file.path(getaca_cache_dir(), ".locks")
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
  file.path(d, paste(id$package, id$name, id$version, sep = "__"))
}

acquire_lock <- function(id, timeout = 300, poll = 0.5) {
  path <- lock_dir(id)
  deadline <- Sys.time() + timeout
  repeat {
    if (dir.create(path, showWarnings = FALSE)) {
      writeLines(
        c(as.character(Sys.getpid()), format(Sys.time(), "%Y-%m-%dT%H:%M:%S")),
        file.path(path, "holder")
      )
      return(structure(list(path = path), class = "getaca_lock"))
    }
    if (lock_is_stale(path)) {
      unlink(path, recursive = TRUE)
      next
    }
    if (Sys.time() > deadline) {
      stop(sprintf(
        paste0("getaca: timed out waiting for another session to finish fetching %s.\n",
               "If no other session is running, remove the stale lock:\n  unlink(\"%s\", recursive = TRUE)"),
        format(id), path
      ), call. = FALSE)
    }
    Sys.sleep(poll)
  }
}

lock_is_stale <- function(path) {
  holder <- file.path(path, "holder")
  if (!file.exists(holder)) return(TRUE)
  age <- as.numeric(difftime(Sys.time(), file.info(holder)$mtime, units = "secs"))
  isTRUE(age > setting_lock_stale())
}

release_lock <- function(lock) {
  if (!is.null(lock)) unlink(lock$path, recursive = TRUE)
  invisible(NULL)
}
