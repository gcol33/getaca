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

# One lock per distinct part digest, taken for the whole composition rather than
# only for the transfer, and for two reasons. Two sessions must not both fetch
# one part, which is what the acquisition lock already does for a whole file.
# And a part blob is named by no index until the entry composed from it is
# written, so without a lock another session's opportunistic collection would
# see bytes nothing references and remove them mid-composition; the unreferenced
# sweep treats a blob under an active lock as live, which is exactly this case.
#
# `held` is the digest the caller already holds. A part naming the same bytes as
# the artefact it composes would otherwise wait on a lock this session owns.
lock_parts <- function(id, record, held = character()) {
  shas <- setdiff(unique(part_digests(record)), held)
  lapply(shas, function(sha) acquire_lock(sha, sprintf("a part of %s", format(id))))
}

release_locks <- function(locks) {
  for (l in locks) release_lock(l)
  invisible(NULL)
}

# Returns the path of the composed artefact in .tmp/, verified against the
# record. The caller promotes it, so composition ends where a transfer ends and
# everything after it is one path.
compose_parts <- function(id, record, quiet = FALSE, transport = try_one) {
  n <- length(record$parts)
  paths <- vapply(seq_len(n), function(i) {
    obtain_part(part_id(id, i, n), record$parts[[i]], quiet, transport)
  }, character(1))

  out <- compose_path(record)
  remove_path(out)
  combine <- combiner_fn(record$combiner)
  tryCatch(combine(paths, out), error = function(e) {
    remove_path(out)
    stop(sprintf("getaca: combiner '%s' failed for %s:\n  %s",
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

# A part already in the store needs no transfer, which is the point of declaring
# one: a base appearing in every version is fetched once. It is re-hashed before
# use rather than trusted, because nothing else re-verifies it. Periodic
# re-verification is driven from the entries, and a part blob is named by an
# entry's `parts` field rather than being one, so a rotted base would otherwise
# surface as the declaration failing to produce its own artefact.
obtain_part <- function(pid, prt, quiet, transport) {
  blob <- blob_path(prt$sha256)
  if (file.exists(blob)) {
    if (identical(sha256_file(blob), prt$sha256)) return(blob)
    # Nothing names these bytes and the declaration lists mirrors for them, so
    # the damaged copy is dropped and the part fetched again rather than the run
    # stopping. It is the reasoning attempt_mirror() already applies to a stale
    # partial file: a local copy that fails its own checksum indicts itself.
    remove_path(blob)
  }
  got <- fetch_to_temp(pid, prt, quiet = quiet, transport = transport)
  admit(got$path, prt$sha256)
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
