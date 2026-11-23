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
#' Never removed by those: pinned entries, the version the bundled registry
#' currently names, and anything under an active lock.
#'
#' One further sweep is never run unless asked for. `"cached"` removes every
#' cached copy the `name`, `package` and `version` arguments select, whatever
#' state it is in and whether or not it is pinned, and then the bytes nothing
#' references any more. It is how a resource you are finished with is given
#' its disk back, and how a copy is dropped so that the next [getaca()] call
#' fetches it again. Only a copy under an active lock is left.
#'
#' @name getaca-gc
NULL

#' @rdname getaca-gc
#' @param name Restrict to one resource name.
#' @param package Restrict to one declaring package. `NULL` means all.
#' @param what Which sweeps to run. Any of `"broken"`, `"temp"`,
#'   `"superseded"`, `"lru"`, `"unreferenced"`, which together are the
#'   default, and `"cached"`, which runs only when named.
#' @param dry_run Report what would be removed without removing it.
#' @param version Restrict to one version of the resources selected.
#' @return A data frame of affected entries, invisibly when acting.
#' @export
#'
#' @examples
#' getaca_clean(dry_run = TRUE)
#'
#' # Everything cached for one resource, as a report of what would go:
#' getaca_clean("backbone", package = "yourpkg", what = "cached", dry_run = TRUE)
getaca_clean <- function(name = NULL, package = NULL,
                         what = c("broken", "temp", "superseded", "lru",
                                  "unreferenced"),
                         dry_run = FALSE, version = NULL) {
  what <- match.arg(what, c(SWEEPS, "cached"), several.ok = TRUE)
  # Removing a name frees nothing while the store still holds the bytes, and
  # freeing them is what a deliberate removal is for.
  if ("cached" %in% what) what <- union(what, "unreferenced")
  pkgs <- package %||% list_cached_packages()
  removed <- list()

  if ("temp" %in% what) {
    removed <- c(removed, list(sweep_temp(dry_run)))
  }
  for (p in pkgs) {
    index <- entries_for(p, name, version)
    if (!length(index)) next
    if ("cached" %in% what) {
      removed <- c(removed, list(sweep_cached(index, dry_run)))
      if (!dry_run) index <- entries_for(p, name, version)
    }
    if ("broken" %in% what)     removed <- c(removed, list(sweep_broken(index, dry_run)))
    if ("superseded" %in% what) removed <- c(removed, list(sweep_superseded(p, index, dry_run)))
  }
  # The ceiling is a property of the cache rather than of one package, and
  # under a shared store evicting a name frees nothing until the last name for
  # those bytes is gone. Both need every package in view at once.
  if ("lru" %in% what) {
    removed <- c(removed, list(sweep_lru(unlist(lapply(pkgs, entries_for, name = name,
                                                       version = version),
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

# The sweeps that only ever remove what is no longer wanted, and so run
# without being asked for.
SWEEPS <- c("broken", "temp", "superseded", "lru", "unreferenced")

entries_for <- function(package, name = NULL, version = NULL) {
  Filter(function(e) {
    (is.null(name) || identical(e$id$name, name)) &&
      (is.null(version) || identical(e$id$version, version))
  }, read_index(package))
}

# A deliberate removal. What a pin holds off is collection, and this is the
# caller saying which copies are to go; what it cannot override is another
# session at work on the same bytes.
sweep_cached <- function(index, dry_run) {
  chosen <- Filter(function(e) !locked(e), index)
  if (!length(chosen)) return(NULL)
  out <- do.call(rbind, lapply(chosen, function(e) {
    removal_row(e$package, format(e$id), "removed on request", e$path)
  }))
  if (!dry_run) for (e in chosen) drop_cached(e)
  out
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
  stale <- files[!is.na(age) & age > setting_temp_days()]
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
    vapply(reg$resources, version_key, character(1))
  }
  cutoff <- Sys.time() - setting_supersede_days() * 86400

  candidates <- Filter(function(e) {
    key <- version_key(e$id)
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

    # Every blob this entry was the last to reach, which for a composed resource
    # is the artefact and whichever of its parts no surviving version still
    # holds. A base declared by a version that stays cached keeps its reference.
    last <- character()
    for (sha in entry_blobs(e)) {
      refs[[sha]] <- (refs[[sha]] %||% 1L) - 1L
      if (refs[[sha]] <= 0L) {
        last <- c(last, sha)
        total <- total - blob_bytes(sha)
      }
    }
    if (!dry_run) {
      drop_cached(e)
      for (sha in last) remove_path(blob_path(sha))
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
  dead <- blobs[!shas %in% live & !vapply(shas, lock_is_live, logical(1))]
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
      for (sha in entry_blobs(e)) refs[[sha]] <- (refs[[sha]] %||% 0L) + 1L
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
locked <- function(entry) lock_is_live(entry$declared_sha256)

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
