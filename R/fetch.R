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
#' @param quiet Report nothing for this call, whatever [getaca_progress()] is
#'   set to.
#'
#' @return A local file or directory path.
#'
#' @seealso [getaca_available()] to test without downloading,
#'   [getaca_info()] for provenance, [getaca_clean()] for cache management.
#' @export
#'
#' @examples
#' # Resources are declared by the packages that need them. This one is a zip
#' # its host would not take whole, uploaded in two pieces and unpacked on
#' # arrival:
#' unzipper <- processor("unzip", function(input, output_dir) {
#'   utils::unzip(input, exdir = output_dir)
#'   output_dir
#' })
#'
#' atlas <- resource("atlas", "1.0",
#'                   sha256 = strrep("c", 64),
#'                   size = 1572864,
#'                   file = "atlas.zip",
#'                   license = "CC-BY-4.0",
#'                   parts = list(
#'                     part("https://example.org/atlas-1.0.zip.001",
#'                          sha256 = strrep("a", 64), size = 1048576),
#'                     part("https://example.org/atlas-1.0.zip.002",
#'                          sha256 = strrep("b", 64), size = 524288)
#'                   ),
#'                   processor = unzipper)
#' atlas
#'
#' reg <- registry("demo", list(atlas))
#'
#' \dontrun{
#' # Each piece is fetched and verified on its own, the two are concatenated,
#' # and the zip is held to the resource's own sha256 before the processor
#' # sees it. The returned path is the unpacked directory:
#' getaca("atlas", registry = reg)
#'
#' # The raw zip, without unpacking:
#' getaca("atlas", registry = reg, processed = FALSE)
#' }
getaca <- function(name, package = NULL, registry = NULL, version = NULL,
                   policy = NULL, verify = FALSE, processed = TRUE,
                   quiet = FALSE) {
  res <- resolve_resource(name, package = package, registry = registry,
                          policy = policy, version = version)
  out <- retrieve(list(list(res = res, processed = processed, verify = verify)),
                  quiet = quiet)[[1]]
  if (inherits(out, "condition")) stop(out)
  out
}

# The one retrieval path, for however many resources are asked for at once.
# Each request is a resolution together with what the caller wants of it, and
# each comes back as a path or as the condition that stopped it, so one
# resource failing leaves the others to finish.
#
# The steps are the ones a single retrieval takes, each applied to every
# request before the next begins: answer from the cache, take the locks, look
# again, work out which bytes are missing, transfer them together, and then
# finish each resource on its own. Bytes are counted by digest throughout, so
# a file two requests both name, or a part two series share, moves once.
retrieve <- function(requests, quiet = FALSE) {
  n <- length(requests)
  out <- vector("list", n)
  unsettled <- function() which(vapply(out, is.null, logical(1)))
  ids <- lapply(requests, function(r) r$res$id)
  records <- lapply(requests, function(r) r$res$record)
  shas <- vapply(records, function(r) r$sha256, character(1))

  answer <- function(todo) {
    for (i in todo) {
      hit <- tryCatch(cached_path(requests[[i]]), error = function(e) e)
      if (!is.null(hit)) out[[i]] <<- hit
    }
  }
  answer(seq_len(n))

  # The policy resolution already folded in the argument, the session setting,
  # the registry default and the check clamp, so asking again here would answer
  # a narrower question than the one that chose the record.
  for (i in unsettled()) {
    if (identical(requests[[i]]$res$policy, "offline")) {
      why <- if (in_r_check()) "running under R CMD check" else "offline mode is in effect"
      out[[i]] <- tryCatch(err_offline(ids[[i]], why), error = function(e) e)
    }
  }
  todo <- unsettled()
  if (!length(todo)) return(out)

  # In the order of the digests, so two sessions asking for overlapping sets
  # reach for the shared locks in the same order.
  locks <- list()
  on.exit(release_locks(locks), add = TRUE)
  for (sha in sort(unique(shas[todo]))) {
    label <- format(ids[[todo[match(sha, shas[todo])]]])
    locks[[length(locks) + 1L]] <- acquire_lock(sha, label, quiet = quiet)
  }

  # Another session may have finished while this one waited for the locks.
  answer(todo)
  todo <- unsettled()

  # Bytes already in the store, or a copy in the slot that hashes to the
  # declaration, are both reasons not to transfer anything. This is checked
  # ahead of the parts, since an artefact already composed needs none of them.
  route <- character(n)
  need <- list()
  for (i in todo) {
    route[i] <- if (stored_intact(records[[i]]) || adopt(ids[[i]], records[[i]])) {
      "store"
    } else if (length(records[[i]]$parts)) {
      "parts"
    } else {
      "whole"
    }
    if (identical(route[i], "whole") && is.null(need[[shas[i]]])) {
      need[[shas[i]]] <- list(id = ids[[i]], record = records[[i]],
                              auth = requests[[i]]$res$auth)
    }
  }

  # Part locks are held until this call returns, which is after the entries
  # naming the parts have been written. Until then nothing else knows the blobs
  # are wanted.
  composed <- todo[route[todo] == "parts"]
  part_shas <- unlist(lapply(records[composed], part_digests), use.names = FALSE)
  for (sha in sort(setdiff(unique(part_shas), shas[todo]))) {
    owner <- composed[vapply(records[composed], function(r) {
      sha %in% part_digests(r)
    }, logical(1))][1]
    locks[[length(locks) + 1L]] <- acquire_lock(
      sha, sprintf("a part of %s", format(ids[[owner]])), quiet = quiet
    )
  }
  for (i in composed) {
    items <- part_items(ids[[i]], records[[i]], auth = requests[[i]]$res$auth)
    for (sha in setdiff(names(items), names(need))) need[[sha]] <- items[[sha]]
  }

  got <- stats::setNames(
    fetch_many(unname(need), quiet = quiet, reporter = effective_reporter(quiet)),
    names(need)
  )
  arrived <- function(sha) {
    if (inherits(got[[sha]], "condition")) stop(got[[sha]])
    got[[sha]]
  }

  for (i in todo) {
    out[[i]] <- tryCatch({
      id <- ids[[i]]
      record <- records[[i]]
      url_used <- NA_character_
      placed <- switch(
        route[i],
        store = place(id, record),
        whole = {
          from <- arrived(shas[i])
          url_used <- from$url
          promote(id, record, from$path)
        },
        parts = {
          # No single location served these bytes. What produced them is the
          # part series the entry records.
          for (sha in intersect(unique(part_digests(record)), names(got))) {
            admit(arrived(sha)$path, sha)
          }
          promote(id, record, combine_parts(id, record))
        }
      )
      finish(requests[[i]], placed, url_used)
    }, error = function(e) e)
  }

  done <- todo[!vapply(out[todo], inherits, logical(1), what = "condition")]
  for (package in unique(vapply(ids[done], function(id) id$package, character(1)))) {
    gc_opportunistic(package)
  }
  out
}

request_processor <- function(request) {
  if (isTRUE(request$processed)) request$res$record$processor else NULL
}

# The path a request is answered with when the cache already holds it, checked
# against the declaration in force, and NULL when it does not.
cached_path <- function(request) {
  proc <- request_processor(request)
  entry <- get_entry(request$res$id, if (is.null(proc)) NULL else proc$id)
  if (is.null(entry) || !path_exists(entry$path)) return(NULL)
  validate_cached(entry, request$res$record, force = request$verify)$path
}

# The bytes are in the store and named in the version slot. What remains is
# the processor, where one was asked for, and the record of what was done.
finish <- function(request, placed, url_used) {
  res <- request$res
  proc <- request_processor(request)
  final <- if (is.null(proc)) placed$path else apply_processor(res$id, proc, placed$path)
  put_entry(new_entry(res$id, res$record, final, res$record$sha256,
                      source = res$source, digest = res$digest,
                      created = res$created, url_used = url_used,
                      processor_id = if (is.null(proc)) NULL else proc$id,
                      link = placed$link))
  final
}

path_exists <- function(p) !is.null(p) && (file.exists(p) || dir.exists(p))

# The processed result gets its own slot and its own provenance, so getaca
# always knows which derived tree the returned path refers to and which raw
# artefact produced it.
#
# `rename` is the seam it is in move_file(): promotion of the staging tree can
# fail, and what happens then is a decision worth testing without needing a
# filesystem that refuses the rename.
apply_processor <- function(id, proc, raw, rename = file.rename) {
  out <- cache_proc_dir(id, proc$id)
  staging <- paste0(out, ".staging-", Sys.getpid())
  remove_path(staging)
  dir.create(staging, recursive = TRUE, showWarnings = FALSE)

  # A processor reading the raw view with file.copy() carries the store's
  # read-only mode into its output, so the staging tree is removed the same way
  # the cache is.
  result <- tryCatch(proc$fn(raw, staging), error = function(e) {
    remove_path(staging)
    stop(sprintf("getaca: processor '%s' failed for %s:\n  %s",
                 proc$id, format(id), conditionMessage(e)), call. = FALSE)
  })

  if (file.exists(out) || dir.exists(out)) remove_path(out)
  if (!isTRUE(rename(staging, out))) {
    remove_path(staging)
    stop(sprintf("getaca: could not promote the processed result for %s", format(id)),
         call. = FALSE)
  }
  reroot(result, staging, out, proc$id, id)
}

# A processor works in a staging directory that is renamed once it succeeds, so
# the paths it returned have to follow. Prefix surgery on the string, not a
# pattern: a cache path is full of characters a regular expression would read
# as syntax.
reroot <- function(path, from, to, processor_id, id) {
  outside <- !startsWith(path, from)
  if (any(outside)) {
    stop(sprintf(
      "getaca: processor '%s' returned a path outside its output directory for %s:\n  %s",
      processor_id, format(id), path[outside][1]
    ), call. = FALSE)
  }
  paste0(to, substring(path, nchar(from) + 1L))
}

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
#' state and which policy resolved it, the exact version, declared and observed
#' checksums, which mirror served it, when it was fetched and when it was last
#' fully verified, its license and DOI, any processor applied, which getaca
#' retrieved it, and the local path. Suitable for a reproducibility appendix or
#' a bug report.
#'
#' The registry state appears as a [registry_digest()], so the declaration that
#' resolved the resource can be identified exactly rather than by a number
#' someone kept in step by hand.
#'
#' @inheritParams getaca
#' @return A `getaca_entry`, or `NULL` when the resource is not cached.
#'   Printing one shows the full record. `as.data.frame()` gives the same
#'   record as one row, for a report or for binding several together, with the
#'   columns `package`, `name`, `version`, `processor`, `parts`, `link`, `size`,
#'   `sha256`, `license`, `doi`, `source`, `registry_digest`,
#'   `registry_created`, `url`, `getaca_version`, `fetched_at`, `verified_at`,
#'   `checked_at`, `accessed_at`, `pinned` and `path`. `format()` gives the
#'   identity as `package/name@version`.
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
#' @return A data frame, one row per resource version. `parts` is how many
#'   pieces the artefact is composed from, and `0` where it is served whole, so
#'   what a version update costs to fetch is visible. `current` marks the
#'   version a bare request for that name resolves to, so a channel head is
#'   visible rather than implied. `declared` is `TRUE` when the registry in
#'   force names that version, `FALSE` when it does not, and `NA` when no
#'   registry could be read for the package; `current` is `NA` in that same
#'   case. `cached` says whether a local copy is recorded; the provenance
#'   columns are `NA` for declared resources that are not cached. `doi` is what
#'   the artefact is cited as, where the declaration states one. `link` says
#'   how the slot reaches its bytes, so two packages sharing one copy in the
#'   store are visible as such.
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
  keys <- vapply(entries, function(e) version_key(e$id), character(1))
  is_current <- current_marker(reg)

  rows <- list()
  declared_keys <- character()
  if (!is.null(reg)) {
    for (rec in reg$resources) {
      key <- version_key(rec)
      declared_keys <- c(declared_keys, key)
      hits <- entries[keys == key]
      if (length(hits)) {
        for (e in hits) rows[[length(rows) + 1L]] <- entry_row(e, TRUE, is_current(key))
      } else {
        rows[[length(rows) + 1L]] <- declared_row(package, rec, is_current(key))
      }
    }
  }

  # Cached under a version the registry no longer names, or under a package
  # whose registry could not be read at all. Those are different claims.
  for (e in entries[!keys %in% declared_keys]) {
    rows[[length(rows) + 1L]] <- entry_row(e, if (is.null(reg)) NA else FALSE,
                                           is_current(version_key(e$id)))
  }

  if (!length(rows)) return(NULL)
  do.call(rbind, rows)
}

# Asks the resolver rather than reading `current` directly, so the column says
# what a bare request actually returns for every name, including the ones whose
# single declared version needs no head.
current_marker <- function(reg) {
  if (is.null(reg)) return(function(key) NA)
  names_declared <- unique(vapply(reg$resources, function(r) r$name, character(1)))
  heads <- vapply(names_declared, function(n) {
    version_key(select_record(reg, n))
  }, character(1), USE.NAMES = FALSE)
  function(key) key %in% heads
}

entry_row <- function(e, declared, current) {
  data.frame(
    package = e$package,
    name = e$id$name,
    version = e$id$version,
    current = current,
    processor = e$processor_id %||% NA_character_,
    parts = length(e$parts),
    link = e$link %||% NA_character_,
    declared = declared,
    cached = TRUE,
    size = e$size,
    license = e$license %||% NA_character_,
    doi = e$doi %||% NA_character_,
    source = e$source,
    registry_digest = e$registry_digest %||% NA_character_,
    verified_at = e$verified_at,
    accessed_at = e$accessed_at,
    pinned = isTRUE(e$pinned),
    path = e$path,
    stringsAsFactors = FALSE
  )
}

declared_row <- function(package, rec, current) {
  data.frame(
    package = package,
    name = rec$name,
    version = rec$version,
    current = current,
    processor = if (is.null(rec$processor)) NA_character_ else rec$processor$id,
    parts = length(rec$parts),
    link = NA_character_,
    declared = TRUE,
    cached = FALSE,
    size = as.numeric(rec$size),
    license = rec$license %||% NA_character_,
    doi = rec$doi %||% NA_character_,
    source = NA_character_,
    registry_digest = NA_character_,
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
    current = logical(), processor = character(), parts = integer(),
    link = character(), declared = logical(), cached = logical(),
    size = numeric(), license = character(), doi = character(),
    source = character(), registry_digest = character(),
    verified_at = na_time(0L), accessed_at = na_time(0L),
    pinned = logical(), path = character(), stringsAsFactors = FALSE
  )
}

list_cached_packages <- function() {
  root <- getaca_cache_dir()
  if (!dir.exists(root)) return(character())
  d <- list.dirs(root, full.names = FALSE, recursive = FALSE)
  d[!startsWith(d, ".") & !d %in% CACHE_RESERVED]
}

# Directories the cache owns. Everything else below the root is named after a
# declaring package.
CACHE_RESERVED <- "blobs"

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
#' @details
#' The resources of one call are transferred together, up to
#' `getaca.connections` at a time, and a file two of them name is moved once.
#' One that cannot be retrieved does not stop the others: everything that could
#' be had is cached before the first failure is raised.
#'
#' @return A character vector of paths named by resource, invisibly.
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
  requests <- lapply(names, function(n) {
    list(res = resolve_resource(n, registry = reg), processed = TRUE, verify = FALSE)
  })
  out <- retrieve(requests, quiet = quiet)
  # Everything that could be retrieved has been, and stays cached. The first
  # resource that could not is the one reported.
  failed <- Filter(function(x) inherits(x, "condition"), out)
  if (length(failed)) stop(failed[[1]])
  invisible(stats::setNames(unlist(out), names))
}
