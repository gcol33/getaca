#' Get a declared external resource
#'
#' The single retrieval verb. Packages declare resources; getaca retrieves
#' them. Returns an ordinary local path, always: getaca never reads data and
#' knows nothing about file formats.
#'
#' The returned path is guaranteed to be a complete file, verified against the
#' declared SHA-256, at the requested version, in a cache slot getaca owns and
#' tracks.
#'
#' @param name Resource name as declared by `package`.
#' @param package Declaring package. The resource identity is
#'   `package / name / version`, so two packages declaring the same name never
#'   collide.
#' @param registry A [registry()] object, for standalone use without a
#'   declaring package.
#' @param version Explicit version, bypassing channel resolution. Use this to
#'   hold an analysis to one release.
#' @param policy Resolution policy for this call. Defaults to
#'   [getaca_policy()].
#' @param verify Force a full re-hash of the cached copy before returning it.
#'   Ordinary access performs a cheap size check and re-hashes on a schedule.
#' @param processed Apply the declared [processor()], when there is one, and
#'   return the processed path. `FALSE` returns the raw artefact.
#' @param quiet Suppress progress reporting.
#'
#' @return A local file or directory path.
#'
#' @seealso [getaca_available()] to test without downloading,
#'   [getaca_info()] for provenance, [getaca_clean()] for cache management.
#' @export
#'
#' @examples
#' # Resources are declared by the packages that need them:
#' reg <- registry("demo", list(
#'   resource("example", "1.0",
#'            urls = "https://example.org/example-1.0.csv",
#'            sha256 = strrep("c", 64))
#' ))
#' reg
#'
#' # getaca("example", registry = reg)   # would download and verify
getaca <- function(name, package = NULL, registry = NULL, version = NULL,
                   policy = NULL, verify = FALSE, processed = TRUE,
                   quiet = FALSE) {
  res <- resolve_resource(name, package = package, registry = registry,
                          policy = policy, version = version)
  id <- res$id
  record <- res$record
  proc <- if (processed) record$processor else NULL
  proc_id <- if (is.null(proc)) NULL else proc$id

  entry <- get_entry(id, proc_id)
  if (!is.null(entry) && path_exists(entry$path)) {
    entry <- validate_cached(entry, record, force = verify)
    return(entry$path)
  }

  if (identical(effective_policy(), "offline")) {
    err_offline(id, if (in_r_check()) "running under R CMD check" else "offline mode is in effect")
  }

  lock <- acquire_lock(id)
  on.exit(release_lock(lock), add = TRUE)

  # Another session may have finished while this one waited for the lock.
  entry <- get_entry(id, proc_id)
  if (!is.null(entry) && path_exists(entry$path)) {
    entry <- validate_cached(entry, record, force = verify)
    return(entry$path)
  }

  raw <- raw_file_for(id)
  if (is.null(raw) || !identical(sha256_file(raw), record$sha256)) {
    got <- fetch_to_temp(id, record, quiet = quiet)
    raw <- promote(id, record, got$path)
    url_used <- got$url
  } else {
    url_used <- NA_character_
  }

  final <- if (is.null(proc)) raw else apply_processor(id, proc, raw)

  entry <- new_entry(id, record, final, record$sha256,
                     source = res$source, revision = res$revision,
                     url_used = url_used, processor_id = proc_id)
  put_entry(entry)
  gc_opportunistic(id$package)
  final
}

path_exists <- function(p) !is.null(p) && (file.exists(p) || dir.exists(p))

# The processed result gets its own slot and its own provenance, so getaca
# always knows which derived tree the returned path refers to and which raw
# artefact produced it.
apply_processor <- function(id, proc, raw) {
  out <- cache_proc_dir(id, proc$id)
  staging <- paste0(out, ".staging-", Sys.getpid())
  unlink(staging, recursive = TRUE)
  dir.create(staging, recursive = TRUE, showWarnings = FALSE)

  result <- tryCatch(proc$fn(raw, staging), error = function(e) {
    unlink(staging, recursive = TRUE)
    stop(sprintf("getaca: processor '%s' failed for %s:\n  %s",
                 proc$id, format(id), conditionMessage(e)), call. = FALSE)
  })

  if (file.exists(out) || dir.exists(out)) unlink(out, recursive = TRUE)
  if (!file.rename(staging, out)) {
    unlink(staging, recursive = TRUE)
    stop(sprintf("getaca: could not promote the processed result for %s", format(id)),
         call. = FALSE)
  }
  sub(paste0("^", escape_re(staging)), out, result)
}

escape_re <- function(x) gsub("([.\\\\^$|()\\[\\]{}*+?])", "\\\\\\1", x)

err_offline <- function(id, why, call = NULL) {
  cond <- list(
    message = paste(c(
      sprintf("%s is not cached and cannot be downloaded (%s).", format(id), why),
      "",
      sprintf("Action: on a connected machine run getaca_prefetch(\"%s\", package = \"%s\"),",
              id$name, id$package),
      sprintf("or point GETACA_CACHE at a cache that already holds it."),
      "",
      "Fix: this is expected during checks. Use getaca_skip_if_unavailable()",
      "in tests and getaca_optional() in examples."
    ), collapse = "\n"),
    call = call,
    actor = "user",
    id = id
  )
  class(cond) <- c("getaca_error_offline", "getaca_error_unavailable",
                   "getaca_error", "error", "condition")
  stop(cond)
}

#' Provenance for a resource
#'
#' Answers, for a cached resource: which package declared it, which registry
#' revision and which policy resolved it, the exact version, declared and
#' observed checksums, which mirror served it, when it was fetched and when it
#' was last fully verified, its license, any processor applied, and the local
#' path. Suitable for a reproducibility appendix or a bug report.
#'
#' @inheritParams getaca
#' @return A `getaca_entry`, or `NULL` when the resource is not cached.
#' @export
getaca_info <- function(name, package = NULL, registry = NULL, version = NULL,
                        processed = TRUE) {
  res <- resolve_resource(name, package = package, registry = registry,
                          policy = "offline", version = version)
  proc <- if (processed) res$record$processor else NULL
  get_entry(res$id, if (is.null(proc)) NULL else proc$id)
}

#' What is declared, and what is cached
#'
#' Reports both halves. Declared resources appear whether or not they have ever
#' been downloaded, so "what does this package need, and what do I already
#' have" is one table rather than two. Cached copies of versions that are no
#' longer declared appear as well, since those are what [getaca_clean()]
#' reclaims.
#'
#' @param package Restrict to one declaring package. `NULL` reports every
#'   installed package that ships a registry, together with any package holding
#'   cached resources.
#' @param registry A [registry()] object, for standalone use without an
#'   installed declaring package.
#'
#' @return A data frame, one row per resource version. `declared` is `TRUE`
#'   when the registry in force names that version, `FALSE` when it does not,
#'   and `NA` when no registry could be read for the package. `cached` says
#'   whether a local copy is recorded; the provenance columns are `NA` for
#'   declared resources that are not cached.
#' @export
#'
#' @examples
#' reg <- registry("demo", list(
#'   resource("example", "1.0",
#'            urls = "https://example.org/example-1.0.csv",
#'            sha256 = strrep("c", 64))
#' ))
#' getaca_catalogue(registry = reg)
getaca_catalogue <- function(package = NULL, registry = NULL) {
  rows <- if (!is.null(registry)) {
    catalogue_rows(registry$package, registry)
  } else {
    pkgs <- package %||% sort(unique(c(packages_declaring_resources(),
                                       list_cached_packages())))
    do.call(rbind, lapply(pkgs, catalogue_rows))
  }
  if (is.null(rows) || !nrow(rows)) return(empty_catalogue())
  rownames(rows) <- NULL
  rows
}

# One package's declarations joined to its cache, keyed on name@version. The
# join runs in declaration order so the table reads the way the registry does.
catalogue_rows <- function(package, registry = NULL) {
  reg <- registry %||% tryCatch(registry_for(package), error = function(e) NULL)
  entries <- read_index(package)
  keys <- vapply(entries, function(e) paste0(e$id$name, "@", e$id$version),
                 character(1))

  rows <- list()
  declared_keys <- character()
  if (!is.null(reg)) {
    for (rec in reg$resources) {
      key <- paste0(rec$name, "@", rec$version)
      declared_keys <- c(declared_keys, key)
      hits <- entries[keys == key]
      if (length(hits)) {
        for (e in hits) rows[[length(rows) + 1L]] <- entry_row(e, TRUE)
      } else {
        rows[[length(rows) + 1L]] <- declared_row(package, rec)
      }
    }
  }

  # Cached under a version the registry no longer names, or under a package
  # whose registry could not be read at all. Those are different claims.
  for (e in entries[!keys %in% declared_keys]) {
    rows[[length(rows) + 1L]] <- entry_row(e, if (is.null(reg)) NA else FALSE)
  }

  if (!length(rows)) return(NULL)
  do.call(rbind, rows)
}

entry_row <- function(e, declared) {
  data.frame(
    package = e$package,
    name = e$id$name,
    version = e$id$version,
    processor = e$processor_id %||% NA_character_,
    declared = declared,
    cached = TRUE,
    size = e$size,
    license = e$license %||% NA_character_,
    source = e$source,
    revision = e$revision,
    verified_at = e$verified_at,
    accessed_at = e$accessed_at,
    pinned = isTRUE(e$pinned),
    path = e$path,
    stringsAsFactors = FALSE
  )
}

declared_row <- function(package, rec) {
  data.frame(
    package = package,
    name = rec$name,
    version = rec$version,
    processor = if (is.null(rec$processor)) NA_character_ else rec$processor$id,
    declared = TRUE,
    cached = FALSE,
    size = as.numeric(rec$size),
    license = rec$license %||% NA_character_,
    source = NA_character_,
    revision = NA_integer_,
    verified_at = na_time(),
    accessed_at = na_time(),
    pinned = FALSE,
    path = NA_character_,
    stringsAsFactors = FALSE
  )
}

na_time <- function(n = 1L) .POSIXct(rep(NA_real_, n))

empty_catalogue <- function() {
  data.frame(
    package = character(), name = character(), version = character(),
    processor = character(), declared = logical(), cached = logical(),
    size = numeric(), license = character(),
    source = character(), revision = integer(),
    verified_at = na_time(0L), accessed_at = na_time(0L),
    pinned = logical(), path = character(), stringsAsFactors = FALSE
  )
}

list_cached_packages <- function() {
  root <- getaca_cache_dir()
  if (!dir.exists(root)) return(character())
  d <- list.dirs(root, full.names = FALSE, recursive = FALSE)
  d[!startsWith(d, ".")]
}

# Discovery is by convention: a package declares resources by shipping
# inst/getaca/registry.rds, so finding declarations is a file test across the
# library paths rather than a registration call or a load hook.
packages_declaring_resources <- function() {
  found <- character()
  for (lib in .libPaths()) {
    pkgs <- list.dirs(lib, full.names = FALSE, recursive = FALSE)
    if (!length(pkgs)) next
    found <- c(found, pkgs[file.exists(file.path(lib, pkgs, "getaca", "registry.rds"))])
  }
  unique(found)
}

#' Warm the cache ahead of time
#'
#' Downloads and verifies without returning anything, so a connected machine
#' can prepare a cache that a check run, a CI job or an offline session will
#' then find already populated.
#'
#' @param names Resource names. `NULL` prefetches everything the package
#'   declares.
#' @inheritParams getaca
#' @return A character vector of paths, invisibly.
#' @export
getaca_prefetch <- function(names = NULL, package = NULL, registry = NULL,
                            quiet = FALSE) {
  reg <- registry %||% registry_for(package)
  if (is.null(reg)) {
    err_invalid_registry(
      sprintf("package '%s' ships no getaca registry", package), package = package
    )
  }
  names <- names %||% unique(vapply(reg$resources, function(r) r$name, character(1)))
  paths <- vapply(names, function(n) {
    getaca(n, registry = reg, quiet = quiet)
  }, character(1))
  invisible(paths)
}
