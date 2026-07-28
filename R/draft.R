#' Draft a registry from where the data is
#'
#' Takes locations, returns a [registry()] with every checksum filled in. What
#' it saves is the part of authoring that cannot be done by hand: a SHA-256 has
#' to be computed from the bytes, which means retrieving them.
#'
#' A location is a plain URL, or an identifier for a data archive that holds
#' several files. Which one it is, and which archive, is read off the string, so
#' one call covers both:
#'
#' ```r
#' registry_draft("10.5281/zenodo.17844561", package = "mypackage")
#' registry_draft(c(wfo = "https://example.org/wfo.parquet"),
#'                package = "mypackage", version = "2026.1")
#' ```
#'
#' Every file is downloaded once and hashed locally. Checksums an archive
#' reports are not used: they are md5 at all three archives supported here, and
#' they arrive from the host that serves the bytes, so they say nothing the
#' transfer itself has not already said.
#'
#' This is an authoring tool. Nothing in the retrieval path calls it, and a
#' drafted registry names ordinary `https://` locations, so an archive is
#' consulted when the registry is written and never when a user fetches.
#'
#' @section Archives:
#' \describe{
#'   \item{Zenodo}{`"10.5281/zenodo.17844561"` or a
#'     `https://zenodo.org/records/...` URL. Version defaults to the record id,
#'     which Zenodo mints afresh for each version.}
#'   \item{figshare}{`"10.6084/m9.figshare.14763051.v1"` or a
#'     `https://figshare.com/articles/...` URL. A DOI without a `.vN` suffix
#'     resolves to whatever figshare currently calls latest, and the version it
#'     served is what the draft records.}
#'   \item{Dataverse}{A dataset DOI, or a
#'     `https://<host>/dataset.xhtml?persistentId=...` URL. Instances are
#'     self-hosted under their own DOI prefixes, so a bare DOI is resolved
#'     through `doi.org` to find which host to ask. The other two are
#'     recognised from the string alone and cost no such lookup.}
#' }
#'
#' @section What to edit afterwards:
#' A draft is a starting point. Resources are named after their files, which is
#' rarely the name you want a user to type, and `description` is left empty.
#' Both are ordinary arguments of [resource()]; edit the call, or edit the
#' returned registry, and write it with [registry_write()].
#'
#' @param x Locations. A character vector, where each element is one location,
#'   or a list, where each element is a character vector of mirrors for one
#'   resource. Names, if any, name the resources.
#' @param package Declaring package name.
#' @param version Version label for every resource drafted. Optional where the
#'   archive supplies one, required for a plain URL.
#' @param source Which handler to use: `"auto"`, or one of `"zenodo"`,
#'   `"figshare"`, `"dataverse"`, `"url"` to override the detection.
#' @param keep Keep the downloaded bytes in the cache, so that a later
#'   [getaca()] call for the drafted resource finds them already there instead
#'   of transferring them a second time.
#' @param quiet Suppress transfer progress.
#' @param ... Passed to [registry()], for `remote`, `policy`, `keys` and `auth`.
#'
#' @return A `getaca_registry`.
#' @seealso [registry_write()] to ship it, [registry_sign()] to sign it.
#' @export
#'
#' @examples
#' \dontrun{
#' reg <- registry_draft("10.5281/zenodo.17844561", package = "mypackage")
#' registry_write(reg, "inst/getaca/registry.rds")
#' }
registry_draft <- function(x, package, version = NULL, source = "auto",
                           keep = FALSE, quiet = FALSE, ...) {
  stopifnot(is_string(package))
  registry(package = package,
           resources = draft_resources(x, package = package, version = version,
                                       source = source, keep = keep,
                                       quiet = quiet),
           ...)
}

# The three seams, on the internal rather than on the exported verb: which
# archive a string names and what its response means are the parts worth
# testing, and neither needs a network to exercise.
draft_resources <- function(x, package, version = NULL, source = "auto",
                            keep = FALSE, quiet = FALSE,
                            api = api_get, resolve = doi_target,
                            transport = try_one) {
  locations <- as_locations(x)
  rep <- effective_reporter(quiet)

  records <- list()
  for (i in seq_along(locations)) {
    records <- c(records, draft_location(
      loc = locations[[i]], given_name = names(locations)[i],
      package = package, version = version, source = source, keep = keep,
      rep = rep, api = api, resolve = resolve, transport = transport
    ))
  }

  names <- vapply(records, function(r) r$name, character(1))
  if (anyDuplicated(names)) {
    stop(sprintf(
      "getaca: two files draft to the resource name %s.\nName them explicitly, as registry_draft(c(one = \"...\", two = \"...\"), ...).",
      paste(sprintf("'%s'", unique(names[duplicated(names)])), collapse = ", ")
    ), call. = FALSE)
  }
  records
}

draft_location <- function(loc, given_name, package, version, source, keep,
                           rep, api, resolve, transport) {
  chosen <- choose_handler(loc, source, resolve)
  if (is.null(chosen)) {
    stop(sprintf(
      "getaca: '%s' is not a location registry_draft() recognises.\nGive an https:// URL, or a DOI from Zenodo, figshare or a Dataverse instance.",
      loc[1]
    ), call. = FALSE)
  }

  spec <- chosen$handler$expand(loc, chosen$target, api)
  # An entry an archive describes too partially to fetch is dropped rather than
  # drafted into a record with a hole in it.
  if (!is.null(spec)) spec$files <- Filter(Negate(is.null), spec$files)
  if (is.null(spec) || !length(spec$files)) {
    stop(sprintf("getaca: nothing could be read for '%s' from %s.",
                 loc[1], chosen$name), call. = FALSE)
  }

  ver <- version %||% spec$version
  if (is.null(ver)) {
    stop(sprintf(
      "getaca: '%s' carries no version of its own, so registry_draft() needs one.\nPass version = \"...\".",
      loc[1]
    ), call. = FALSE)
  }
  # A name identifies one resource, so it can only stand for a location that
  # turned out to be one file. An archive holding several is named per file.
  if (!is.na(given_name) && nzchar(given_name) && length(spec$files) > 1L) {
    stop(sprintf(
      "getaca: '%s' holds %d files, so the name '%s' cannot stand for it.\nDraft it unnamed and rename the resources afterwards.",
      loc[1], length(spec$files), given_name
    ), call. = FALSE)
  }

  lapply(spec$files, function(f) {
    name <- if (!is.na(given_name) && nzchar(given_name)) given_name else draft_name(f$file)
    draft_record(f, name = name, version = as.character(ver),
                 license = spec$license %||% NA_character_,
                 package = package, keep = keep, rep = rep,
                 transport = transport)
  })
}

# The bytes are retrieved to be hashed. A draft always starts from empty, since
# a partial left by an earlier draft of a different file would be resumed onto.
draft_record <- function(f, name, version, license, package, keep, rep,
                         transport) {
  id <- resource_id(package, name, version)
  url <- f$urls[1]
  dest <- file.path(cache_tmp_dir(), sprintf("draft-%s", draft_file(f$file)))
  unlink(dest)

  emit(rep, "begin", id = id, url = url, total = as_size(f$size), offset = 0)
  res <- transport(url, dest, progress = byte_callback(rep, id, as_size(f$size)))
  if (!isTRUE(res$success)) {
    emit(rep, "end", id = id, status = "failed", bytes = 0, reason = res$reason)
    unlink(dest)
    stop(sprintf("getaca: could not retrieve %s to hash it.\n  %s: %s",
                 format(id), url, res$reason), call. = FALSE)
  }
  emit(rep, "end", id = id, status = "ok", bytes = bytes_on_disk(dest),
       reason = NA_character_)

  sha <- sha256_file(dest)
  size <- file_size(dest)
  if (isTRUE(keep)) admit(dest, sha) else unlink(dest)

  file <- draft_file(f$file)
  resource(
    name = name,
    version = version,
    urls = f$urls,
    sha256 = sha,
    size = size,
    license = license,
    doi = f$doi,
    # Stated only where the location does not already say it, since a record
    # takes its cached name from the URL when it names nothing else.
    file = if (identical(file, url_basename(url))) NULL else file
  )
}

# One location per element, and a character vector inside an element is the
# mirrors of one resource.
as_locations <- function(x) {
  if (is.character(x)) x <- as.list(x)
  if (!is.list(x) || !length(x)) {
    stop("getaca: `x` must be a character vector of locations, or a list of them.",
         call. = FALSE)
  }
  x <- lapply(x, function(loc) {
    if (!is.character(loc) || !length(loc) || anyNA(loc)) {
      stop("getaca: every location must be a character vector of one or more URLs.",
           call. = FALSE)
    }
    loc
  })
  if (is.null(names(x))) names(x) <- rep(NA_character_, length(x))
  x
}

# Detection is a property of the string wherever it can be. Zenodo and figshare
# register their own DOI prefixes, so those are decided offline; a Dataverse
# instance is self-hosted under its own prefix and can only be found by asking
# the resolver which host the DOI belongs to.
choose_handler <- function(loc, source, resolve) {
  handlers <- source_handlers()
  if (!identical(source, "auto")) {
    if (!source %in% names(handlers)) {
      stop(sprintf("getaca: unknown source '%s'; one of %s, or \"auto\".",
                   source, paste(sprintf("\"%s\"", names(handlers)), collapse = ", ")),
           call. = FALSE)
    }
    return(list(name = source, handler = handlers[[source]], target = NULL))
  }

  for (nm in names(handlers)) {
    if (isTRUE(handlers[[nm]]$match(loc[1]))) {
      return(list(name = nm, handler = handlers[[nm]], target = NULL))
    }
  }
  if (!grepl("^10\\.[0-9]{4,9}/", loc[1])) return(NULL)

  target <- resolve(loc[1])
  if (is.null(target)) return(NULL)
  for (nm in names(handlers)) {
    if (isTRUE(handlers[[nm]]$match(target)) ||
        identical(url_host(target), handlers[[nm]]$host)) {
      return(list(name = nm, handler = handlers[[nm]], target = target))
    }
  }
  # Every Dataverse instance answers the same dataset endpoint, so asking it is
  # what identifies one. A host that is not one answers with something else and
  # the handler returns nothing.
  list(name = "dataverse", handler = handlers$dataverse, target = target)
}

# Order is the dispatch: a plain URL matches anything with a scheme, so it is
# tried last and stands for whatever the archives did not claim.
source_handlers <- function() {
  list(
    zenodo = list(
      host = "zenodo.org",
      match = function(x) {
        grepl("^10\\.5281/zenodo\\.[0-9]+$", x) ||
          grepl("^https://zenodo\\.org/records?/[0-9]+", x)
      },
      expand = function(loc, target, api) zenodo_files(loc, api)
    ),
    figshare = list(
      host = "figshare.com",
      match = function(x) {
        grepl("^10\\.6084/m9\\.figshare\\.[0-9]+", x) ||
          grepl("^https://figshare\\.com/articles/", x)
      },
      expand = function(loc, target, api) figshare_files(loc, api)
    ),
    dataverse = list(
      host = NULL,
      match = function(x) grepl("/dataset\\.xhtml\\?.*persistentId=", x),
      expand = function(loc, target, api) dataverse_files(loc, target, api)
    ),
    url = list(
      host = NULL,
      match = function(x) grepl("^https://", x),
      expand = function(loc, target, api) url_files(loc)
    )
  )
}

url_files <- function(loc) {
  list(
    version = NULL,
    license = NA_character_,
    files = list(list(file = url_basename(loc[1]), urls = loc,
                      size = NA_real_, doi = NULL))
  )
}

# Zenodo mints a record id per version, so the id both identifies the archive
# and dates it. The download location is derived rather than taken from the
# response, since the links the API reports have not been stable across its own
# migrations while this form has.
zenodo_files <- function(loc, api) {
  id <- sub("^10\\.5281/zenodo\\.", "", loc[1])
  id <- sub("^https://zenodo\\.org/records?/([0-9]+).*$", "\\1", id)
  if (!grepl("^[0-9]+$", id)) return(NULL)

  rec <- api(sprintf("https://zenodo.org/api/records/%s", id))
  if (is.null(rec) || !length(rec$files)) return(NULL)
  rid <- as.character(rec$id %||% id)

  list(
    version = rid,
    license = rec$metadata$license$id %||% NA_character_,
    files = lapply(rec$files, function(f) {
      key <- f$key %||% f$filename
      if (is.null(key)) return(NULL)
      list(
        file = key,
        urls = sprintf("https://zenodo.org/records/%s/files/%s", rid,
                       utils::URLencode(key, reserved = TRUE)),
        size = f$size %||% NA_real_,
        doi = rec$doi %||% sprintf("10.5281/zenodo.%s", rid)
      )
    })
  )
}

# figshare numbers a file per version of an article, and the download location
# carries that number, so it names one set of bytes even where the DOI does not.
figshare_files <- function(loc, api) {
  ident <- figshare_article(loc, api)
  if (is.null(ident)) return(NULL)

  url <- if (is.null(ident$version)) {
    sprintf("https://api.figshare.com/v2/articles/%s", ident$id)
  } else {
    sprintf("https://api.figshare.com/v2/articles/%s/versions/%s",
            ident$id, ident$version)
  }
  art <- api(url)
  if (is.null(art) || !length(art$files)) return(NULL)

  list(
    version = as.character(art$version %||% ident$version %||% "1"),
    license = art$license$name %||% NA_character_,
    files = lapply(art$files, function(f) {
      if (is.null(f$name) || is.null(f$download_url)) return(NULL)
      list(file = f$name, urls = f$download_url,
           size = f$size %||% NA_real_, doi = as_doi(art$doi))
    })
  )
}

figshare_article <- function(loc, api) {
  if (grepl("^https://figshare\\.com/articles/", loc[1])) {
    # A figshare article link is type/slug/id, and a versioned one appends the
    # version. How many segments there are is what tells the two apart: a slug
    # may itself be a number, so the trailing pair alone does not say which of
    # them is the article. A link of any other shape is left to the DOI.
    path <- sub("[?#].*$", "", sub("/+$", "", loc[1]))
    segs <- strsplit(sub("^https://figshare\\.com/articles/", "", path), "/")[[1]]
    if (length(segs) == 3L && grepl("^[0-9]+$", segs[3])) {
      return(list(id = segs[3], version = NULL))
    }
    if (length(segs) == 4L && all(grepl("^[0-9]+$", segs[3:4]))) {
      return(list(id = segs[3], version = segs[4]))
    }
    return(NULL)
  }

  doi <- as_doi(loc[1])
  found <- api(sprintf("https://api.figshare.com/v2/articles?doi=%s",
                       utils::URLencode(doi, reserved = TRUE)))
  if (!length(found) || is.null(found[[1]]$id)) return(NULL)
  suffix <- sub("^.*\\.", "", doi)
  list(
    id = as.character(found[[1]]$id),
    version = if (grepl("^v[0-9]+$", suffix)) sub("^v", "", suffix) else NULL
  )
}

# A Dataverse dataset carries a two-part version number, and its files may carry
# DOIs of their own, which name the bytes more exactly than the dataset's does.
dataverse_files <- function(loc, target, api) {
  where <- dataverse_target(loc, target)
  if (is.null(where)) return(NULL)

  ds <- api(sprintf("%s/api/datasets/:persistentId?persistentId=doi:%s",
                    where$base, where$doi))
  if (is.null(ds) || !identical(ds$status, "OK")) return(NULL)
  v <- ds$data$latestVersion
  if (is.null(v) || !length(v$files)) return(NULL)

  list(
    version = sprintf("%s.%s", v$versionNumber %||% 1L, v$versionMinorNumber %||% 0L),
    license = v$license$name %||% NA_character_,
    files = lapply(v$files, function(f) {
      df <- f$dataFile
      if (is.null(df$filename) || is.null(df$id)) return(NULL)
      list(
        file = df$filename,
        urls = sprintf("%s/api/access/datafile/%s", where$base, df$id),
        size = df$filesize %||% NA_real_,
        doi = as_doi(df$persistentId %||% where$doi)
      )
    })
  )
}

dataverse_target <- function(loc, target) {
  url <- if (grepl("/dataset\\.xhtml\\?.*persistentId=", loc[1])) loc[1] else target
  if (is.null(url) || !grepl("persistentId=", url)) return(NULL)
  doi <- sub("^.*persistentId=", "", url)
  doi <- sub("&.*$", "", doi)
  doi <- as_doi(utils::URLdecode(doi))
  if (is.null(doi) || !grepl("^10\\.", doi)) return(NULL)
  list(base = sub("^(https://[^/]+).*$", "\\1", url), doi = doi)
}

# A resource name has to be typed by a user, so the extension comes off; a file
# name has to survive as a path, so only the characters a cache slot allows do.
draft_name <- function(file) {
  base <- gsub("[^A-Za-z0-9._-]+", "-", tools::file_path_sans_ext(file))
  base <- gsub("^[-.]+|-+$", "", base)
  if (nzchar(base)) base else "resource"
}

draft_file <- function(file) {
  out <- gsub("[^A-Za-z0-9._-]+", "-", file)
  if (nzchar(out) && !out %in% c(".", "..")) out else "resource.bin"
}

# JSON over the same handle every other request uses, so timeout, redirect and
# user-agent settings are the package's rather than this file's.
api_get <- function(url) {
  need_suggested("jsonlite", "drafting a registry from a data archive")
  h <- new_handle_for(url)
  curl::handle_setheaders(h, Accept = "application/json")
  res <- tryCatch(curl::curl_fetch_memory(url, handle = h), error = function(e) NULL)
  if (is.null(res) || res$status_code >= 400) return(NULL)
  txt <- rawToChar(res$content)
  Encoding(txt) <- "UTF-8"
  tryCatch(jsonlite::fromJSON(txt, simplifyVector = FALSE), error = function(e) NULL)
}

# Which host holds a DOI, without retrieving what it holds.
doi_target <- function(doi) {
  url <- paste0("https://doi.org/", doi)
  h <- new_handle_for(url)
  curl::handle_setopt(h, nobody = TRUE)
  res <- tryCatch(curl::curl_fetch_memory(url, handle = h), error = function(e) NULL)
  if (is.null(res) || res$status_code >= 400) return(NULL)
  res$url
}
