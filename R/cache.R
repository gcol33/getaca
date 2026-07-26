#' Cache layout
#'
#' Everything is scoped by declaring package, then resource name, then
#' version. Two packages that happen to declare the same resource name never
#' share a slot, and a version can never be silently overwritten by another.
#'
#' ```
#' <cache>/
#'   .locks/                        per-resource locks
#'   .tmp/                          in-flight downloads, never visible as cache
#'   <package>/
#'     index.rds                    provenance for this package only
#'     <name>/<version>/
#'       raw/<file>                 verified bytes as served
#'       proc-<processor-id>/       processed result, own provenance
#' ```
#'
#' @name getaca-cache
#' @keywords internal
NULL

cache_pkg_dir <- function(package) file.path(getaca_cache_dir(), package)

cache_version_dir <- function(id) {
  file.path(cache_pkg_dir(id$package), id$name, id$version)
}

cache_raw_dir <- function(id) file.path(cache_version_dir(id), "raw")

cache_proc_dir <- function(id, processor_id) {
  file.path(cache_version_dir(id), paste0("proc-", processor_id))
}

cache_tmp_dir <- function() {
  d <- file.path(getaca_cache_dir(), ".tmp")
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
  d
}

index_path <- function(package) file.path(cache_pkg_dir(package), "index.rds")

read_index <- function(package) {
  p <- index_path(package)
  if (!file.exists(p)) return(list())
  tryCatch(readRDS(p), error = function(e) list())
}

# Written to a sibling temporary file and renamed, so a reader never observes
# a half-written index.
write_index <- function(package, index) {
  dir.create(cache_pkg_dir(package), recursive = TRUE, showWarnings = FALSE)
  p <- index_path(package)
  tmp <- paste0(p, ".tmp-", Sys.getpid())
  saveRDS(index, tmp, version = 3)
  if (file.exists(p)) unlink(p)
  ok <- file.rename(tmp, p)
  if (!ok) {
    unlink(tmp)
    warning("getaca: could not update the cache index", call. = FALSE)
  }
  invisible(p)
}

# The identity two declarations of one resource have to agree on. Taken from
# anything carrying a name and a version, which is both an id and a record.
version_key <- function(x) paste0(x$name, "@", x$version)

entry_key <- function(id, processor_id = NULL) {
  paste0(version_key(id), if (!is.null(processor_id)) paste0("#", processor_id))
}

# What this machine has already accepted for each version it holds. A version
# whose bytes are cached is published as far as this machine is concerned,
# whether or not the bundled registry is the declaration that named it.
cached_checksums <- function(package) {
  entries <- read_index(package)
  if (!length(entries)) return(character())
  keys <- vapply(entries, function(e) version_key(e$id), character(1))
  shas <- vapply(entries, function(e) e$declared_sha256, character(1))
  keep <- !duplicated(keys)
  stats::setNames(shas[keep], keys[keep])
}

get_entry <- function(id, processor_id = NULL) {
  read_index(id$package)[[entry_key(id, processor_id)]]
}

put_entry <- function(entry) {
  index <- read_index(entry$package)
  index[[entry_key(entry$id, entry$processor_id)]] <- entry
  write_index(entry$package, index)
  invisible(entry)
}

drop_entry <- function(id, processor_id = NULL) {
  index <- read_index(id$package)
  index[[entry_key(id, processor_id)]] <- NULL
  write_index(id$package, index)
}

new_entry <- function(id, record, path, observed_sha, source, digest,
                      created = .POSIXct(NA_real_), url_used,
                      processor_id = NULL, link = NULL) {
  now <- Sys.time()
  structure(
    list(
      package = id$package,
      id = id,
      path = path,
      declared_sha256 = record$sha256,
      observed_sha256 = observed_sha,
      size = file_size(path),
      license = record$license,
      upstream = record$upstream,
      source = source,
      # Which declaration state resolved these bytes, when that state was
      # published, and which getaca acted on it. Together these answer the
      # question a reproducibility appendix asks years later.
      registry_digest = digest,
      registry_created = created,
      getaca_version = getaca_version(),
      url_used = url_used,
      processor_id = processor_id,
      # How the version slot reaches the bytes. Absent means the bytes sit in
      # the slot itself, which is what a cache built before the store holds.
      link = link,
      fetched_at = now,
      verified_at = now,
      checked_at = now,
      accessed_at = now,
      pinned = FALSE
    ),
    class = "getaca_entry"
  )
}

touch_entry <- function(entry, verified = FALSE) {
  now <- Sys.time()
  entry$accessed_at <- now
  entry$checked_at <- now
  if (verified) entry$verified_at <- now
  put_entry(entry)
  entry
}

# Recorded per entry, because how a resource was retrieved and verified is a
# property of the getaca that did it. Falls back during load-time use, when the
# namespace is not yet registered.
getaca_version <- function() {
  tryCatch(as.character(utils::packageVersion("getaca")),
           error = function(e) NA_character_)
}

file_size <- function(path) {
  if (dir.exists(path)) {
    sum(file.info(list.files(path, recursive = TRUE, full.names = TRUE))$size, na.rm = TRUE)
  } else {
    unname(file.info(path)$size)
  }
}

#' @export
print.getaca_entry <- function(x, ...) {
  cat("<getaca cache entry> ", format(x$id), "\n", sep = "")
  cat("  path        ", x$path, "\n", sep = "")
  if (!is.null(x$link)) {
    cat("  store       ", x$link, " to blobs/sha256/",
        substr(x$observed_sha256, 1, 2), "/", substr(x$observed_sha256, 1, 12),
        "\n", sep = "")
  }
  cat("  sha256      ", x$observed_sha256, "\n", sep = "")
  cat("  size        ", format(x$size, big.mark = ","), " bytes\n", sep = "")
  cat("  license     ", x$license, "\n", sep = "")
  if (!is.null(x$upstream)) {
    for (nm in names(x$upstream)) {
      cat("  built from  ", nm, ": ", as.character(x$upstream[[nm]]), "\n", sep = "")
    }
  }
  cat("  resolved by ", x$source, " registry ", short_digest(x$registry_digest),
      if (!is.na(x$registry_created)) {
        paste0(" (published ", format(x$registry_created, "%Y-%m-%d"), ")")
      },
      "\n", sep = "")
  cat("  source url  ", x$url_used, "\n", sep = "")
  if (!is.null(x$processor_id)) cat("  processor   ", x$processor_id, "\n", sep = "")
  cat("  getaca      ", x$getaca_version %||% "unknown", "\n", sep = "")
  cat("  fetched     ", format(x$fetched_at, "%Y-%m-%d %H:%M:%S"), "\n", sep = "")
  cat("  verified    ", format(x$verified_at, "%Y-%m-%d %H:%M:%S"), " (full re-hash)\n", sep = "")
  cat("  checked     ", format(x$checked_at, "%Y-%m-%d %H:%M:%S"), " (size and mtime)\n", sep = "")
  if (isTRUE(x$pinned)) cat("  pinned      yes (never garbage collected)\n")
  invisible(x)
}
