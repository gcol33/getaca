#' Active cache management
#'
#' CRAN policy permits a package to use `tools::R_user_dir()` "provided that by
#' default sizes are kept as small as possible and the contents are actively
#' managed (including removing outdated material)". Actively managed means the
#' package has a retention policy, not that it ships a function users might
#' discover. getaca therefore collects conservatively after every successful
#' retrieval, and [getaca_clean()] exists for the deliberate case.
#'
#' Removal order, cheapest and safest first:
#' \enumerate{
#'   \item broken and incomplete material
#'   \item abandoned temporary transfers
#'   \item superseded unpinned versions, once past the retention period
#'   \item least recently used unpinned resources, only when over the size
#'     ceiling
#'   \item bytes in the store that no declaration references any more
#' }
#'
#' "Superseded" and "not recently used" are different states and age on
#' different clocks, so an expensive resource is not deleted merely for being
#' old.
#'
#' A version slot holds a name for bytes the store owns, so the sweeps above
#' remove names. Bytes go once the last name for them does, which is why the
#' store sweep runs last.
#'
#' Never removed: pinned entries, the version the bundled registry currently
#' names, and anything under an active lock.
#'
#' @name getaca-gc
NULL

#' @rdname getaca-gc
#' @param name Restrict to one resource name.
#' @param package Restrict to one declaring package. `NULL` means all.
#' @param what Which sweeps to run. Any of `"broken"`, `"temp"`,
#'   `"superseded"`, `"lru"`, `"unreferenced"`.
#' @param dry_run Report what would be removed without removing it.
#' @return A data frame of affected entries, invisibly when acting.
#' @export
#'
#' @examples
#' getaca_clean(dry_run = TRUE)
getaca_clean <- function(name = NULL, package = NULL,
                         what = c("broken", "temp", "superseded", "lru",
                                  "unreferenced"),
                         dry_run = FALSE) {
  what <- match.arg(what, several.ok = TRUE)
  pkgs <- package %||% list_cached_packages()
  removed <- list()

  if ("temp" %in% what) {
    removed <- c(removed, list(sweep_temp(dry_run)))
  }
  for (p in pkgs) {
    index <- entries_for(p, name)
    if (!length(index)) next
    if ("broken" %in% what)     removed <- c(removed, list(sweep_broken(index, dry_run)))
    if ("superseded" %in% what) removed <- c(removed, list(sweep_superseded(p, index, dry_run)))
  }
  # The ceiling is a property of the cache rather than of one package, and
  # under a shared store evicting a name frees nothing until the last name for
  # those bytes is gone. Both need every package in view at once.
  if ("lru" %in% what) {
    removed <- c(removed, list(sweep_lru(unlist(lapply(pkgs, entries_for, name = name),
                                                recursive = FALSE, use.names = FALSE),
                                         dry_run)))
  }
  if ("unreferenced" %in% what) {
    removed <- c(removed, list(sweep_unreferenced(dry_run)))
  }

  out <- do.call(rbind, Filter(function(x) !is.null(x) && nrow(x), removed))
  if (is.null(out)) out <- empty_removal()
  if (dry_run) return(out)
  invisible(out)
}

entries_for <- function(package, name = NULL) {
  index <- read_index(package)
  if (is.null(name)) return(index)
  Filter(function(e) identical(e$id$name, name), index)
}

empty_removal <- function() {
  data.frame(package = character(), resource = character(), reason = character(),
             bytes = numeric(), path = character(), stringsAsFactors = FALSE)
}

removal_row <- function(package, resource, reason, path) {
  data.frame(package = package, resource = resource, reason = reason,
             bytes = tryCatch(file_size(path), error = function(e) NA_real_),
             path = path, stringsAsFactors = FALSE)
}

# Removing a cached copy: the slot's name for the bytes, then the record that
# named it. The bytes themselves stay until nothing references them.
drop_cached <- function(entry) {
  remove_view(entry)
  drop_entry(entry$id, entry$processor_id)
}

sweep_temp <- function(dry_run) {
  d <- file.path(getaca_cache_dir(), ".tmp")
  if (!dir.exists(d)) return(NULL)
  files <- list.files(d, full.names = TRUE)
  if (!length(files)) return(NULL)
  age <- as.numeric(difftime(Sys.time(), file.info(files)$mtime, units = "days"))
  stale <- files[!is.na(age) & age > 7]
  if (!length(stale)) return(NULL)
  out <- do.call(rbind, lapply(stale, function(f) {
    removal_row(NA_character_, NA_character_, "abandoned transfer", f)
  }))
  if (!dry_run) for (f in stale) remove_path(f)
  out
}

sweep_broken <- function(index, dry_run) {
  bad <- Filter(function(e) !path_exists(e$path) || !cheap_check_ok(e), index)
  if (!length(bad)) return(NULL)
  out <- do.call(rbind, lapply(bad, function(e) {
    removal_row(e$package, format(e$id), "broken or incomplete", e$path)
  }))
  if (!dry_run) for (e in bad) drop_cached(e)
  out
}

sweep_superseded <- function(package, index, dry_run) {
  reg <- tryCatch(registry_for(package), error = function(e) NULL)
  keep <- if (is.null(reg)) character() else {
    vapply(reg$resources, function(r) paste0(r$name, "@", r$version), character(1))
  }
  cutoff <- Sys.time() - setting_supersede_days() * 86400

  candidates <- Filter(function(e) {
    key <- paste0(e$id$name, "@", e$id$version)
    !isTRUE(e$pinned) && !(key %in% keep) && e$accessed_at < cutoff && !locked(e)
  }, index)
  if (!length(candidates)) return(NULL)

  out <- do.call(rbind, lapply(candidates, function(e) {
    removal_row(e$package, format(e$id), "superseded version past retention", e$path)
  }))
  if (!dry_run) for (e in candidates) drop_cached(e)
  out
}

sweep_lru <- function(candidates, dry_run) {
  total <- cache_bytes()
  ceiling_bytes <- setting_max_bytes()
  if (total <= ceiling_bytes) return(NULL)

  evictable <- Filter(function(e) !isTRUE(e$pinned) && !locked(e), candidates)
  if (!length(evictable)) return(NULL)
  ord <- order(vapply(evictable, function(e) as.numeric(e$accessed_at), numeric(1)))
  evictable <- evictable[ord]

  # Counted over every entry rather than over the eviction candidates, so bytes
  # another package still names are never credited to this sweep.
  refs <- blob_refs()

  out <- list()
  for (e in evictable) {
    if (total <= ceiling_bytes) break
    out[[length(out) + 1L]] <- removal_row(
      e$package, format(e$id), "over cache size ceiling, least recently used", e$path
    )
    total <- total - unshared_bytes(e)

    sha <- entry_blob(e)
    last <- FALSE
    if (!is.null(sha)) {
      refs[[sha]] <- (refs[[sha]] %||% 1L) - 1L
      last <- refs[[sha]] <= 0L
      if (last) total <- total - blob_bytes(sha)
    }
    if (!dry_run) {
      drop_cached(e)
      if (last) remove_path(blob_path(sha))
    }
  }
  if (!length(out)) return(NULL)
  do.call(rbind, out)
}

# Bytes nothing declares any more. A blob under an active lock belongs to a
# session that has admitted it and not yet written its entry, so it is live
# even though no index names it yet.
sweep_unreferenced <- function(dry_run) {
  blobs <- all_blobs()
  if (!length(blobs)) return(NULL)
  live <- live_blobs()
  shas <- basename(blobs)
  dead <- blobs[!shas %in% live & !dir.exists(lock_dir(shas))]
  if (!length(dead)) return(NULL)

  out <- do.call(rbind, lapply(dead, function(b) {
    removal_row(NA_character_, NA_character_, "no declaration references these bytes", b)
  }))
  if (!dry_run) for (b in dead) remove_path(b)
  out
}

blob_refs <- function() {
  refs <- list()
  for (p in list_cached_packages()) {
    for (e in read_index(p)) {
      sha <- entry_blob(e)
      if (!is.null(sha)) refs[[sha]] <- (refs[[sha]] %||% 0L) + 1L
    }
  }
  refs
}

blob_bytes <- function(sha) {
  p <- blob_path(sha)
  if (!file.exists(p)) return(0)
  unname(file.info(p)$size)
}

# Keyed on the checksum, the way the acquisition lock is.
locked <- function(entry) dir.exists(lock_dir(entry$declared_sha256))

# Runs after a successful retrieval. Deliberately narrow: the sweeps that only
# ever remove material which is already useless.
gc_opportunistic <- function(package) {
  tryCatch(
    getaca_clean(package = package, what = c("broken", "temp", "unreferenced"),
                 dry_run = FALSE),
    error = function(e) invisible(NULL)
  )
  invisible(NULL)
}

#' Keep a resource from being collected
#'
#' @inheritParams getaca
#' @param pinned Set `FALSE` to release the pin.
#' @return The updated entry, invisibly.
#' @export
getaca_keep <- function(name, package = NULL, registry = NULL, version = NULL,
                        processed = TRUE, pinned = TRUE) {
  entry <- getaca_info(name, package = package, registry = registry,
                       version = version, processed = processed)
  if (is.null(entry)) {
    stop(sprintf("getaca: '%s' is not cached, so there is nothing to keep.", name),
         call. = FALSE)
  }
  entry$pinned <- pinned
  invisible(put_entry(entry))
}
