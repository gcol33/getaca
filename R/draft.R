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
#' registry_draft("10.5281/zenodo.17844561", package = "yourpkg")
#' registry_draft(c(backbone = "https://example.org/backbone.parquet"),
#'                package = "yourpkg", version = "2026.1")
#' ```
#'
#' Every file is hashed from its own bytes. Checksums an archive reports are not
#' used: they are md5 at all three archives supported here, and they arrive from
#' the host that serves the bytes, so they say nothing the transfer itself has
#' not already said.
#'
#' This is an authoring tool. Nothing in the retrieval path calls it, and a
#' drafted registry names ordinary `https://` locations, so an archive is
#' consulted when the registry is written and never when a user fetches.
#'
#' @section Where the bytes come from:
#' A checksum can only come from the bytes, but they need not be transferred to
#' get one, and where they are they need not be written down.
#'
#' \describe{
#'   \item{retrieved}{The default. The file is fetched once and hashed as it
#'     arrives, so nothing is written and a location of any size costs no disk.
#'     `keep = TRUE` writes it to the cache instead, where a later [getaca()]
#'     call for the drafted resource finds it already there.}
#'   \item{`local =`}{A copy already on this machine, which is the usual case
#'     for a file you have just published: it is hashed where it lies and
#'     nothing is transferred. The record still names the location, since that
#'     is where a user will fetch from.}
#'   \item{`sha256 =`}{A checksum you already hold from somewhere that is not
#'     the serving host. Taken as declared, and nothing is retrieved at all.}
#' }
#'
#' Giving both `local =` and `sha256 =` for one location hashes the local copy
#' and holds it to the checksum, which is how a published file is confirmed to
#' be the one that was uploaded.
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
#' @param local Paths to copies already on this machine, hashed in place
#'   instead of retrieving. One per location: named after the locations they
#'   belong to, or one for each in order. A location holding several files
#'   cannot take one.
#' @param sha256 Checksums to declare as given, retrieving nothing. Named or
#'   positional on the same terms as `local`, and combinable with it, in which
#'   case the local copy is hashed and held to the checksum.
#' @param keep Keep the retrieved bytes in the cache, so that a later [getaca()]
#'   call for the drafted resource finds them already there instead of
#'   transferring them a second time. Without it a retrieved file is hashed as
#'   it arrives and never written down. A location answered from `sha256 =`
#'   alone transfers nothing, so there is nothing for this to keep.
#' @param quiet Suppress transfer progress.
#' @param ... Passed to [registry()], for `remote`, `policy`, `keys` and `auth`.
#'
#' @return A `getaca_registry`.
#' @seealso [registry_write()] to ship it, [registry_sign()] to sign it.
#' @export
#'
#' @examples
#' \dontrun{
#' reg <- registry_draft("10.5281/zenodo.17844561", package = "yourpkg")
#' registry_write(reg, "inst/getaca/registry.rds")
#'
#' # The file you just uploaded, hashed from the copy you uploaded it from.
#' registry_draft(c(backbone = "https://example.org/backbone.parquet"),
#'                package = "yourpkg", version = "2026.1",
#'                local = c(backbone = "~/data/backbone.parquet"))
#' }
registry_draft <- function(x, package, version = NULL, source = "auto",
                           local = NULL, sha256 = NULL,
                           keep = FALSE, quiet = FALSE, ...) {
  stopifnot(is_string(package))
  registry(package = package,
           resources = draft_resources(x, package = package, version = version,
                                       source = source, local = local,
                                       sha256 = sha256, keep = keep,
                                       quiet = quiet),
           ...)
}

# The three seams, on the internal rather than on the exported verb: which
# archive a string names and what its response means are the parts worth
# testing, and neither needs a network to exercise.
draft_resources <- function(x, package, version = NULL, source = "auto",
                            local = NULL, sha256 = NULL,
                            keep = FALSE, quiet = FALSE,
                            api = api_get, resolve = doi_target,
                            transport = try_one) {
  locations <- as_locations(x)
  paths <- as_per_location(local, locations, "local")
  declared <- tolower(as_per_location(sha256, locations, "sha256"))
  rep <- effective_reporter(quiet)

  records <- list()
  for (i in seq_along(locations)) {
    records <- c(records, draft_location(
      loc = locations[[i]], given_name = names(locations)[i],
      package = package, version = version, source = source, keep = keep,
      local = paths[i], declared = declared[i],
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
                           local, declared, rep, api, resolve, transport) {
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
  # A checksum, and a copy to take one from, each describe one file, so neither
  # can stand for a location that turned out to be several. There is nothing
  # saying which file it belongs to.
  if (length(spec$files) > 1L && (!is.na(local) || !is.na(declared))) {
    stop(sprintf(
      "getaca: '%s' holds %d files, so `%s` cannot stand for it.\nDraft the files whose checksums you hold as their own locations.",
      loc[1], length(spec$files), if (!is.na(local)) "local" else "sha256"
    ), call. = FALSE)
  }

  lapply(spec$files, function(f) {
    name <- if (!is.na(given_name) && nzchar(given_name)) given_name else draft_name(f$file)
    draft_record(f, name = name, version = as.character(ver),
                 license = spec$license %||% NA_character_,
                 package = package, keep = keep, local = local,
                 declared = declared, rep = rep, transport = transport)
  })
}

# One record, from whichever of the three routes to a checksum this location
# was given. The location is what the record names either way: where the bytes
# were measured is an authoring convenience and says nothing about where a user
# will fetch from.
draft_record <- function(f, name, version, license, package, keep, local,
                         declared, rep, transport) {
  id <- resource_id(package, name, version)
  url <- f$urls[1]

  measured <- if (!is.na(local)) {
    hash_local(local, id, keep)
  } else if (!is.na(declared)) {
    # Nothing measured. The size the archive reports stands, since the checksum
    # is what fixes the identity and a size only ever ends a transfer early.
    list(sha256 = declared, size = as_size(f$size))
  } else {
    hash_transfer(f, id, url, keep, rep, transport)
  }
  if (!is.na(local) && !is.na(declared) &&
      !identical(measured$sha256, declared)) {
    stop(sprintf(
      "getaca: the copy at '%s' is not the file %s declares.\n  declared SHA-256: %s\n  observed SHA-256: %s",
      local, format(id), declared, measured$sha256
    ), call. = FALSE)
  }

  file <- draft_file(f$file)
  resource(
    name = name,
    version = version,
    urls = f$urls,
    sha256 = measured$sha256,
    size = measured$size,
    license = license,
    doi = f$doi,
    # Stated only where the location does not already say it, since a record
    # takes its cached name from the URL when it names nothing else.
    file = if (identical(file, url_basename(url))) NULL else file
  )
}

# A copy the author already has, hashed where it lies. Admission is a move, so
# keeping it means copying into the cache first: the author's own file is not
# getaca's to take, and a draft that relocated it would be unusable twice.
hash_local <- function(path, id, keep) {
  path <- path.expand(path)
  if (!file.exists(path) || dir.exists(path)) {
    stop(sprintf("getaca: no file at '%s' to hash for %s.", path, format(id)),
         call. = FALSE)
  }
  sha <- sha256_file(path)
  if (is.na(sha)) {
    stop(sprintf("getaca: the file at '%s' could not be read.", path),
         call. = FALSE)
  }
  if (isTRUE(keep)) {
    staged <- file.path(cache_tmp_dir(), sprintf("draft-%s", basename(path)))
    unlink(staged)
    if (!isTRUE(file.copy(path, staged, overwrite = TRUE))) {
      stop(sprintf("getaca: could not copy '%s' into the cache to keep it.", path),
           call. = FALSE)
    }
    admit(staged, sha)
  }
  list(sha256 = sha, size = file_size(path))
}

# The bytes are retrieved to be hashed, and where they are not being kept they
# are hashed as they arrive and never written down, so a location of any size
# costs no disk. A draft that keeps them starts from empty, since a partial
# left by an earlier draft of a different file would be resumed onto.
hash_transfer <- function(f, id, url, keep, rep, transport) {
  dest <- if (isTRUE(keep)) {
    file.path(cache_tmp_dir(), sprintf("draft-%s", draft_file(f$file)))
  } else {
    NULL
  }
  if (!is.null(dest)) unlink(dest)

  emit(rep, "begin", id = id, url = url, total = as_size(f$size), offset = 0)
  res <- transport(url, dest, progress = byte_callback(rep, id, as_size(f$size)))
  if (!isTRUE(res$success)) {
    emit(rep, "end", id = id, status = "failed", bytes = 0, reason = res$reason)
    if (!is.null(dest)) unlink(dest)
    stop(sprintf("getaca: could not retrieve %s to hash it.\n  %s: %s",
                 format(id), url, res$reason), call. = FALSE)
  }

  if (is.null(dest)) {
    emit(rep, "end", id = id, status = "ok", bytes = res$bytes %||% 0,
         reason = NA_character_)
    if (!is_string(res$sha256) || !grepl("^[0-9a-f]{64}$", res$sha256)) {
      stop(sprintf("getaca: nothing hashed %s as it arrived.", format(id)),
           call. = FALSE)
    }
    return(list(sha256 = res$sha256, size = as_size(res$bytes)))
  }

  emit(rep, "end", id = id, status = "ok", bytes = bytes_on_disk(dest),
       reason = NA_character_)
  sha <- sha256_file(dest)
  size <- file_size(dest)
  admit(dest, sha)
  list(sha256 = sha, size = size)
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

# An argument qualifying particular locations, lined up with them. Names match
# the names the locations were given, which is what a draft of several files
# with a checksum for one of them needs; without names the entries stand for
# the locations in order.
as_per_location <- function(x, locations, what) {
  n <- length(locations)
  if (is.null(x)) return(rep(NA_character_, n))
  if (!is.character(x) || !length(x) || anyNA(x)) {
    stop(sprintf("getaca: `%s` must be a character vector, one entry per location it applies to.",
                 what), call. = FALSE)
  }

  given <- names(x)
  if (is.null(given) || !all(nzchar(given))) {
    if (length(x) != n) {
      stop(sprintf(
        "getaca: `%s` has %d entries and there are %d locations.\nGive one for each, in order, or name each after the location it belongs to.",
        what, length(x), n), call. = FALSE)
    }
    return(unname(x))
  }

  known <- names(locations)
  unknown <- setdiff(given, known[!is.na(known)])
  if (length(unknown)) {
    stop(sprintf(
      "getaca: `%s` names %s, which is not among the locations being drafted.",
      what, paste(sprintf("'%s'", unknown), collapse = ", ")), call. = FALSE)
  }
  out <- rep(NA_character_, n)
  out[match(given, known)] <- unname(x)
  out
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
