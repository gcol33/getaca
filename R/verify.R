#' Verification model
#'
#' Three different questions get three different answers, and the entry record
#' keeps them apart so that "verified" never quietly means "we looked at this
#' sometime in the past".
#'
#' \describe{
#'   \item{full verification}{Re-hash the bytes the caller is handed. Recorded
#'     as `verified_at`. Always performed on download.}
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
#' A mismatch is a verdict on bytes rather than on the slot that found it.
#' Where those bytes are ones the store shares, the verdict withdraws
#' `verified_at` from every other slot naming that digest, so each re-hashes
#' against its own copy on next access instead of continuing on a stamp this
#' failure has already contradicted.
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

# The same digest, driven a chunk at a time, for bytes that pass through
# without ever being held whole: nothing has to be in memory and nothing has to
# be written down to be hashed. The context lives behind an external pointer,
# so an abandoned transfer's is collected rather than leaked.
sha256_stream <- function() {
  .Call(C_sha256_stream_new)
}

sha256_stream_update <- function(stream, bytes) {
  invisible(.Call(C_sha256_stream_update, stream, bytes))
}

# The digest and the byte count, which is the only measurement left once
# nothing was written to ask the filesystem about.
sha256_stream_final <- function(stream) {
  .Call(C_sha256_stream_final, stream)
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
  # No stamp at all means nothing currently establishes these bytes, which is
  # the state a verdict reached elsewhere in the cache leaves a sharer in.
  if (isTRUE(is.na(entry$verified_at))) return(TRUE)
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
    withdraw_shared_verification(entry, entry$path)
    err_cache_corrupt(entry$id, entry$path, entry$declared_sha256, observed)
  }
  if (force || needs_full_verification(entry)) {
    target <- verification_target(entry)
    # Nothing left to hash. Recording that as a verification would move the
    # clock forward on a check that never ran, and every later access would do
    # the same, so the entry would never be verified again.
    if (is.null(target) || !file.exists(target)) {
      err_cache_corrupt(entry$id, entry$path, entry$declared_sha256, "<missing>")
    }
    observed <- sha256_file(target)
    if (!identical(observed, entry$declared_sha256)) {
      withdraw_shared_verification(entry, target)
      err_cache_corrupt(entry$id, target, entry$declared_sha256, observed)
    }
    return(touch_entry(entry, verified = TRUE))
  }
  touch_entry(entry, verified = FALSE)
}

# What the declared checksum describes, which has to be the file the caller is
# handed. A raw slot holds exactly that file: where the filesystem allowed a
# link it is the blob's own bytes, and where it refused one it is an
# independent copy that nothing else would ever read. A processed slot holds a
# derived tree the checksum does not describe, so it is verified against the
# artefact it was made from, by way of the blob and then the raw view.
verification_target <- function(entry) {
  if (is.null(entry$processor_id)) return(entry$path)
  blob <- entry_blob(entry)
  if (!is.null(blob) && file.exists(blob_path(blob))) return(blob_path(blob))
  raw_file_for(entry$id)
}

raw_file_for <- function(id) {
  d <- cache_raw_dir(id)
  f <- list.files(d, full.names = TRUE)
  if (length(f) == 1L) f else NULL
}

# A verdict on bytes the store shares reaches past the slot that asked for it.
# Every other slot naming that digest holds its own verified_at, keeps passing
# the cheap size check, and would keep handing those bytes out as verified
# until its own window elapsed. Withdrawing the stamp is not a claim that those
# slots are corrupt: it says the last verification of these bytes is no longer
# evidence, which is what the mismatch established. Each sharer then re-hashes
# its own target and reaches its own verdict, which is the only thing that can
# speak for a slot holding an independent copy.
withdraw_shared_verification <- function(entry, target) {
  sha <- shared_digest(entry, target)
  if (is.null(sha)) return(invisible(NULL))
  # Never allowed to displace the condition it accompanies. An index that
  # cannot be written leaves that sharer on the window it already had.
  tryCatch(clear_verified(sha, except = entry), error = function(e) NULL)
  invisible(NULL)
}

# What a mismatch indicts beyond the entry that found it. Bytes reached through
# a link are the store's, so the verdict covers the blob and every other name
# for it. An independent copy and a processed tree are one slot's own.
shared_digest <- function(entry, target) {
  if (is.null(target) || !target %in% blob_names(entry)) return(NULL)
  entry_blob(entry)
}

clear_verified <- function(sha, except) {
  skip <- entry_key(except$id, except$processor_id)
  for (p in list_cached_packages()) {
    index <- read_index(p)
    withdrawn <- FALSE
    for (k in names(index)) {
      if (identical(p, except$package) && identical(k, skip)) next
      if (!identical(entry_blob(index[[k]]), sha)) next
      if (isTRUE(is.na(index[[k]]$verified_at))) next
      index[[k]]$verified_at <- na_time()
      withdrawn <- TRUE
    }
    if (withdrawn) write_index(p, index)
  }
  invisible(NULL)
}
