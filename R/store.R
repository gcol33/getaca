#' The content-addressed store
#'
#' Bytes live once, under their own digest. A version slot holds a *view*: a
#' second name for the blob, carrying the readable file name the declaration
#' implies. Two packages declaring the same file therefore store it once and,
#' because the acquisition lock keys on the digest, download it once.
#'
#' ```
#' <cache>/blobs/sha256/<aa>/<sha256>
#' ```
#'
#' The store keeps no metadata. A blob's name is its digest, which is the only
#' fact about a blob worth recording; liveness is derived from the package
#' indexes and integrity by hashing. There is no reference count to drift out
#' of step with the indexes it would be summarising.
#'
#' @name getaca-store
#' @keywords internal
NULL

blob_root <- function() file.path(getaca_cache_dir(), "blobs", "sha256")

# Sharded on the first two hex characters, so a cache holding thousands of
# resources never asks the filesystem for one enormous directory.
blob_path <- function(sha) file.path(blob_root(), substr(sha, 1L, 2L), sha)

blob_exists <- function(sha) file.exists(blob_path(sha))

# Admission is a rename: .tmp/ and blobs/ both sit under the cache root, so
# they share a filesystem by construction. Bytes already in the store are
# already named by their digest, so admitting the same file twice is a no-op.
admit <- function(temp_path, sha) {
  dest <- blob_path(sha)
  if (file.exists(dest)) {
    unlink(temp_path)
    return(dest)
  }
  dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
  if (!move_file(temp_path, dest)) {
    stop(sprintf("getaca: could not admit verified bytes to the store at %s", dest),
         call. = FALSE)
  }
  seal(dest)
  dest
}

# A view is a name for a blob. The name matters: consumers routinely choose a
# reader by file extension, and a digest has none.
materialise <- function(sha, dest, link = link_file) {
  dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
  if (file.exists(dest) || dir.exists(dest)) remove_path(dest)
  method <- link(blob_path(sha), dest)
  if (is.na(method)) {
    stop(sprintf("getaca: could not place the verified file into the cache at %s", dest),
         call. = FALSE)
  }
  seal(dest)
  method
}

# Hardlink first: constant time, no privilege on NTFS, and the view keeps the
# bytes readable if the blob name is ever removed. Symlink next, for
# filesystems that refuse hardlinks. Copy last, which is what a FAT volume or
# a network mount leaves.
link_file <- function(from, to) {
  if (isTRUE(suppressWarnings(file.link(from, to)))) return("hardlink")
  if (isTRUE(suppressWarnings(file.symlink(from, to)))) return("symlink")
  if (isTRUE(suppressWarnings(file.copy(from, to)))) return("copy")
  NA_character_
}

# A copy left in a version slot by a cache built before the store existed, or
# by a sweep that took the blob and left the view. Linking it in costs one hash
# and saves the transfer, and leaves the file in place so an entry that still
# names it keeps working.
adopt <- function(id, record) {
  local <- raw_file_for(id)
  if (is.null(local) || !identical(sha256_file(local), record$sha256)) return(FALSE)
  dest <- blob_path(record$sha256)
  dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
  method <- link_file(local, dest)
  if (is.na(method)) return(FALSE)
  seal(dest)
  TRUE
}

# Shared bytes make one caller's accidental write every declaring package's
# corruption, so everything the store owns is read-only. A caller needing a
# writable layout declares a processor(), which gets its own slot.
seal <- function(path) {
  Sys.chmod(path, "0444")
  invisible(path)
}

# A hardlinked view shares its permissions with the blob, so removing a view
# unseals the blob as a side effect.
reseal_blob <- function(sha) {
  if (is.null(sha) || is.na(sha)) return(invisible(NULL))
  p <- blob_path(sha)
  if (file.exists(p)) seal(p)
  invisible(NULL)
}

# unlink() will not remove a read-only file on Windows, nor a directory
# containing one, so removal restores write permission first.
remove_path <- function(path) {
  if (dir.exists(path)) {
    inner <- list.files(path, recursive = TRUE, all.files = TRUE,
                        full.names = TRUE, include.dirs = TRUE, no.. = TRUE)
    if (length(inner)) Sys.chmod(inner, "0666")
    Sys.chmod(path, "0777")
  } else if (file.exists(path)) {
    Sys.chmod(path, "0666")
  }
  identical(unlink(path, recursive = TRUE), 0L)
}

# Removing a view, and restoring the store invariant the removal broke.
remove_view <- function(entry) {
  ok <- remove_path(entry$path)
  reseal_blob(entry_blob(entry))
  ok
}

# The blob backing an entry, or NULL for one cached before the store existed.
# Derived from the checksum already recorded rather than stored beside it; the
# `link` field is what says the bytes are in the store at all.
entry_blob <- function(entry) {
  if (is.null(entry$link)) NULL else entry$observed_sha256
}

# Every path that is another name for an entry's bytes rather than a separate
# copy of them: the blob itself, and the raw view wherever the filesystem
# allowed a link. A copy is the slot's own, and a processed tree is derived
# rather than named, so neither belongs here.
blob_names <- function(entry) {
  sha <- entry_blob(entry)
  if (is.null(sha)) return(character())
  c(blob_path(sha), if (!identical(entry$link, "copy")) raw_file_for(entry$id))
}

all_blobs <- function() {
  root <- blob_root()
  if (!dir.exists(root)) return(character())
  list.files(root, recursive = TRUE, full.names = TRUE)
}

# Every blob some package index still names. Always reads every package, never
# the filtered subset a sweep was asked about: a blob one package no longer
# wants may be the only copy another package has.
live_blobs <- function() {
  shas <- unlist(lapply(list_cached_packages(), function(p) {
    entries <- read_index(p)
    if (!length(entries)) return(character())
    unlist(lapply(entries, entry_blob), use.names = FALSE)
  }), use.names = FALSE)
  unique(shas)
}

# What the cache occupies. Blobs count once, which is the point of the store.
# A processed tree, a copy made where the filesystem refused a link, and an
# entry cached before the store existed each count on their own.
cache_bytes <- function() {
  blobs <- all_blobs()
  total <- if (length(blobs)) sum(file.info(blobs)$size, na.rm = TRUE) else 0
  for (p in list_cached_packages()) {
    for (e in read_index(p)) total <- total + unshared_bytes(e)
  }
  total
}

unshared_bytes <- function(entry) {
  own <- !is.null(entry$processor_id) ||
    is.null(entry$link) ||
    identical(entry$link, "copy")
  if (own) entry$size %||% 0 else 0
}
