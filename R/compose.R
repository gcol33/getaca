#' Composing an artefact from its parts
#'
#' A resource may name an ordered series of [part()]s instead of locations for
#' the whole file. Each part is retrieved and verified on its own, admitted to
#' the store under its own digest, and the series is then combined into the
#' artefact the resource names.
#'
#' What makes this safe is that the result is held to the resource's own
#' SHA-256, and reaches the store through the same `admit()` every downloaded
#' file goes through. After composition a composed artefact is indistinguishable
#' from a transferred one: the same blob, the same view, the same periodic
#' re-verification.
#'
#' Parts are transport. Which pieces a declaration is assembled from, and where
#' each piece comes from, may change the way a mirror list may change, because
#' what a version means is fixed by the record's checksum rather than by the
#' route to it. A combiner therefore needs no more trust than a mirror does: it
#' cannot produce bytes the declaration did not already name.
#'
#' The saving is in the transfer. A base part shared by every version of a
#' resource is stored once under its own digest, so publishing a new version
#' costs its consumers the delta rather than the whole file.
#'
#' @name getaca-parts
#' @keywords internal
NULL

# Concatenation is what "parts" means when the declaration says nothing else: an
# artefact split for a host with an upload limit is reassembled by writing the
# pieces out in order. Anything beyond that is knowledge about a file format,
# which is the author's to supply through combiner().
CONCAT_ID <- "concat"

combiner_id <- function(x) if (is.null(x)) CONCAT_ID else x$id
combiner_fn <- function(x) if (is.null(x)) concat_parts else x$fn

part_digests <- function(record) {
  if (!length(record$parts)) return(NULL)
  vapply(record$parts, function(p) p$sha256, character(1))
}

release_locks <- function(locks) {
  for (l in locks) release_lock(l)
  invisible(NULL)
}

# Returns the path of the composed artefact in .tmp/, verified against the
# record. The caller promotes it, so composition ends where a transfer ends and
# everything after it is one path.
compose_parts <- function(id, record, quiet = FALSE, transport = try_one,
                          reporter = NULL, auth = NULL) {
  items <- part_items(id, record, auth = auth)
  got <- fetch_many(items, quiet = quiet, transport = transport,
                    reporter = reporter, auth = auth)
  admit_parts(items, got)
  combine_parts(id, record)
}

# The parts of a series that have to be transferred, each as fetch_many() takes
# one. A part already in the store needs no transfer, which is the point of
# declaring one: a base appearing in every version is fetched once, and a part
# named twice in one series is fetched once too. A stored part is re-hashed
# before use rather than trusted, because nothing else re-verifies it. Periodic
# re-verification is driven from the entries, and a part blob is named by an
# entry's `parts` field rather than being one, so a rotted base would otherwise
# surface as the declaration failing to produce its own artefact.
part_items <- function(id, record, auth = NULL) {
  n <- length(record$parts)
  items <- list()
  for (i in seq_len(n)) {
    prt <- record$parts[[i]]
    if (!is.null(items[[prt$sha256]]) || stored_intact(prt)) next
    items[[prt$sha256]] <- list(id = part_id(id, i, n), record = prt, auth = auth)
  }
  items
}

# Whether the store holds the bytes a record names, asked by hashing them. A
# new name is about to be given to these bytes and stamped as verified, and
# the blob's being filed under the right digest only says what it was when it
# was admitted.
stored_intact <- function(record) {
  blob <- blob_path(record$sha256)
  if (!file.exists(blob)) return(FALSE)
  if (identical(sha256_file(blob), record$sha256)) return(TRUE)
  # The declaration lists mirrors for these bytes, so the damaged copy is
  # dropped and fetched again rather than the run stopping. It is the
  # reasoning that drops a stale partial file: a local copy that fails its own
  # checksum indicts itself. A view another slot holds of it is that slot's to
  # find on its own next verification.
  remove_path(blob)
  FALSE
}

# What fetch_many() returned for a set of parts, moved into the store. The
# first part that could not be had is the reason the artefact cannot be.
admit_parts <- function(items, got) {
  for (k in seq_along(items)) {
    if (inherits(got[[k]], "condition")) stop(got[[k]])
  }
  for (k in seq_along(items)) admit(got[[k]]$path, items[[k]]$record$sha256)
  invisible(NULL)
}

# Every part is in the store. Combined into .tmp/ and held to the record.
combine_parts <- function(id, record) {
  n <- length(record$parts)
  paths <- blob_path(part_digests(record))
  out <- compose_path(record)
  remove_path(out)
  combine <- combiner_fn(record$combiner)
  tryCatch(combine(paths, out), error = function(e) {
    remove_path(out)
    stop(sprintf("getaca: combiner '%s' failed for %s:
  %s",
                 combiner_id(record$combiner), format(id), conditionMessage(e)),
         call. = FALSE)
  })

  if (!file.exists(out)) {
    stop(sprintf("getaca: combiner '%s' wrote nothing for %s",
                 combiner_id(record$combiner), format(id)), call. = FALSE)
  }
  observed <- sha256_file(out)
  if (!identical(observed, record$sha256)) {
    remove_path(out)
    err_composition(id, record$sha256, observed, n, combiner_id(record$combiner))
  }
  out
}

# Composition writes into .tmp/, where a transfer lands, so bytes that are never
# verified are never anywhere a reader could reach. Named after the artefact's
# digest, so an interrupted composition is overwritten by the retry rather than
# accumulating.
compose_path <- function(record) {
  file.path(cache_tmp_dir(), sprintf("%s.compose", substr(record$sha256, 1, 16)))
}

# Streamed in blocks. A composed artefact is the size of the resource, which is
# the size this package exists for, so reading one into memory to write it back
# out is not available.
CONCAT_BLOCK <- 8L * 1024L * 1024L

concat_parts <- function(parts, output) {
  out <- file(output, "wb")
  on.exit(close(out), add = TRUE)
  for (p in parts) append_file(out, p)
  invisible(output)
}

append_file <- function(out, path) {
  con <- file(path, "rb")
  on.exit(close(con), add = TRUE)
  repeat {
    block <- readBin(con, "raw", n = CONCAT_BLOCK)
    if (!length(block)) break
    writeBin(block, out)
  }
  invisible(NULL)
}
