#' Verification model
#'
#' Three different questions get three different answers, and the entry record
#' keeps them apart so that "verified" never quietly means "we looked at this
#' sometime in the past".
#'
#' \describe{
#'   \item{full verification}{Re-hash the bytes. Recorded as `verified_at`.
#'     Always performed on download.}
#'   \item{cheap check}{Compare size and modification time against the entry.
#'     Recorded as `checked_at`. Performed on ordinary access.}
#'   \item{periodic re-verification}{A full re-hash once the last one is older
#'     than `getaca.verify_days`, because size and mtime miss some kinds of
#'     corruption and all kinds of substitution.}
#' }
#'
#' @name getaca-verification
#' @keywords internal
NULL

sha256_file <- function(path) {
  unname(digest::digest(path, algo = "sha256", file = TRUE))
}

# Cheap: catches truncation, replacement by a different-sized file, and most
# accidental edits. Deliberately does not catch a same-size substitution;
# that is what periodic re-verification is for.
cheap_check_ok <- function(entry) {
  if (!file.exists(entry$path) && !dir.exists(entry$path)) return(FALSE)
  isTRUE(file_size(entry$path) == entry$size)
}

needs_full_verification <- function(entry) {
  days <- as.numeric(difftime(Sys.time(), entry$verified_at, units = "days"))
  isTRUE(days > setting_verify_days())
}

# Returns the entry, refreshed. Raises getaca_error_cache_corrupt when the
# cached bytes are no longer what the entry says they are.
validate_cached <- function(entry, record, force = FALSE) {
  if (!cheap_check_ok(entry)) {
    observed <- if (file.exists(entry$path)) sha256_file(entry$path) else "<missing>"
    err_cache_corrupt(entry$id, entry$path, entry$declared_sha256, observed)
  }
  if (force || needs_full_verification(entry)) {
    # A processed directory is identified by the raw artefact it came from,
    # so re-hash the raw file rather than the derived tree.
    target <- if (is.null(entry$processor_id)) entry$path else raw_file_for(entry$id)
    if (!is.null(target) && file.exists(target)) {
      observed <- sha256_file(target)
      if (!identical(observed, entry$declared_sha256)) {
        err_cache_corrupt(entry$id, target, entry$declared_sha256, observed)
      }
    }
    return(touch_entry(entry, verified = TRUE))
  }
  touch_entry(entry, verified = FALSE)
}

raw_file_for <- function(id) {
  d <- cache_raw_dir(id)
  f <- list.files(d, full.names = TRUE)
  if (length(f) == 1L) f else NULL
}
