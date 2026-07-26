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
#' All three ask whether the bytes are still the bytes. A cache hit is checked
#' for one thing first: that the declaration still names the same bytes it
#' named when they were fetched. Bytes matching a superseded declaration are
#' not what was asked for, however intact they are.
#'
#' @name getaca-verification
#' @keywords internal
NULL

# Both call shapes reach one implementation, in src/sha256.c, which absorbs a
# block with the host's SHA-256 instructions where it has them. A path that
# could not be read digests to NA, so an unreadable file compares unequal to a
# declared checksum rather than raising from inside the comparison.
sha256_file <- function(path) {
  .Call(C_sha256_file, path.expand(path))
}

sha256_bytes <- function(bytes, backend = NULL) {
  .Call(C_sha256_raw, bytes, backend)
}

sha256_backend <- function() {
  .Call(C_sha256_backend)
}

sha256_backends <- function() {
  .Call(C_sha256_backends)
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
  # The entry was verified against whichever declaration was in force when the
  # bytes arrived. A declaration naming different bytes for the same version is
  # a redefinition, and a cache hit is not licence to keep resolving quietly
  # through it: the two disagree about what the version means.
  if (!identical(entry$declared_sha256, record$sha256)) {
    err_redeclared(entry$id, entry$declared_sha256, record$sha256)
  }
  if (!cheap_check_ok(entry)) {
    observed <- if (file.exists(entry$path)) sha256_file(entry$path) else "<missing>"
    err_cache_corrupt(entry$id, entry$path, entry$declared_sha256, observed)
  }
  if (force || needs_full_verification(entry)) {
    target <- verification_target(entry)
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

# What the declared checksum describes. A store-backed entry hashes the blob,
# which is the artefact itself; a processed directory is identified by the
# artefact it came from rather than by the derived tree, and stays verifiable
# after its own view has been swept.
verification_target <- function(entry) {
  blob <- entry_blob(entry)
  if (!is.null(blob)) return(blob_path(blob))
  if (is.null(entry$processor_id)) return(entry$path)
  raw_file_for(entry$id)
}

raw_file_for <- function(id) {
  d <- cache_raw_dir(id)
  f <- list.files(d, full.names = TRUE)
  if (length(f) == 1L) f else NULL
}
