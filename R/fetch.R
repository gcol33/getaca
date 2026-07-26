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
#' was last fully verified, its licence, any processor applied, and the local
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
#' @param package Restrict to one declaring package. `NULL` reports every
#'   package with cached resources.
#' @return A data frame, one row per resource, with cache state.
#' @export
getaca_catalogue <- function(package = NULL) {
  pkgs <- package %||% list_cached_packages()
  rows <- list()
  for (p in pkgs) {
    for (e in read_index(p)) {
      rows[[length(rows) + 1L]] <- data.frame(
        package = e$package,
        name = e$id$name,
        version = e$id$version,
        processor = e$processor_id %||% NA_character_,
        size = e$size,
        licence = e$licence %||% NA_character_,
        source = e$source,
        revision = e$revision,
        verified_at = e$verified_at,
        accessed_at = e$accessed_at,
        pinned = isTRUE(e$pinned),
        path = e$path,
        stringsAsFactors = FALSE
      )
    }
  }
  if (!length(rows)) {
    return(data.frame(
      package = character(), name = character(), version = character(),
      processor = character(), size = numeric(), licence = character(),
      source = character(), revision = integer(),
      verified_at = as.POSIXct(character()), accessed_at = as.POSIXct(character()),
      pinned = logical(), path = character(), stringsAsFactors = FALSE
    ))
  }
  do.call(rbind, rows)
}

list_cached_packages <- function() {
  root <- getaca_cache_dir()
  if (!dir.exists(root)) return(character())
  d <- list.dirs(root, full.names = FALSE, recursive = FALSE)
  d[!startsWith(d, ".")]
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
