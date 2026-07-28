#' Identify a resource
#'
#' A resource is identified by the triple package / name / version, never by
#' name alone. Callers rarely build these by hand; the registry supplies the
#' package and the resolution policy supplies the version.
#'
#' @param package Declaring package name.
#' @param name Resource name, as declared in the registry.
#' @param version Resource version string.
#'
#' @return An object of class `getaca_id`.
#' @export
#'
#' @examples
#' resource_id("yourpkg", "backbone", "2026.1")
resource_id <- function(package, name, version) {
  stopifnot(is_string(package), is_string(name), is_string(version))
  structure(
    list(package = package, name = name, version = version),
    class = "getaca_id"
  )
}

#' @export
format.getaca_id <- function(x, ...) {
  base <- sprintf("%s/%s@%s", x$package, x$name, x$version)
  # The transport reports a failure against whatever it was asked to fetch, and
  # one part of a series is not the resource the caller named. Carrying the
  # label on the id is what lets an unchanged error message say which of several
  # files could not be reached.
  if (is.null(x$part)) base else sprintf("%s (part %s)", base, x$part)
}

part_id <- function(id, index, total) {
  id$part <- sprintf("%d of %d", index, total)
  id
}

#' @export
print.getaca_id <- function(x, ...) {
  cat("<getaca resource> ", format(x), "\n", sep = "")
  invisible(x)
}

#' @export
as.character.getaca_id <- function(x, ...) format(x)

#' Declare an immutable resource record
#'
#' A resource record names one concrete artefact: exact bytes, at one or more
#' locations, under one version label. Once published, a record is immutable.
#' If a publisher reissues the same nominal file with different bytes that is
#' an upstream mutation, not a routine update, and getaca reports it as such.
#'
#' @section Whole files and parts:
#' A record names either locations for the whole file, in `urls`, or the
#' ordered series it is composed from, in `parts`. `sha256` describes the
#' artefact either way, so what a version means does not depend on how it
#' arrives. See [part()].
#'
#' @param name Resource name. Must be usable as a directory name.
#' @param version Version label for these exact bytes, for example `"2026.1"`.
#' @param urls Character vector of download locations, tried in order. All
#'   must be `https://`. Give this or `parts`.
#' @param sha256 Lowercase hex SHA-256 of the artefact. For a record with
#'   `parts`, of the artefact they compose rather than of any one of them.
#' @param size Expected size in bytes, or `NA`. Used to detect truncated
#'   transfers before hashing.
#' @param license License identifier for the data, for example `"CC-BY-4.0"`.
#' @param description One-line human description.
#' @param doi Optional DOI for these bytes, for example
#'   `"10.5281/zenodo.1234567"`. A `https://doi.org/` or `doi:` prefix is
#'   accepted and stripped. This is what the artefact is cited as, and it
#'   travels into provenance; it never routes anything, and the locations to
#'   fetch from stay in `urls`.
#' @param upstream Optional named list identifying what these bytes were built
#'   from, when the artefact is derived rather than an original release. A
#'   prepared database records both its own build identity and the upstream
#'   release it was made from, and both travel into provenance.
#' @param processor Optional [processor()] applied after verification.
#' @param parts Optional list of [part()] records, in the order they are
#'   combined. Give this or `urls`.
#' @param combiner Optional [combiner()] turning the parts into the artefact.
#'   The default concatenates them, which is what a file split for a host with
#'   a size limit needs.
#' @param file Name the artefact is cached under. Defaults to the file name in
#'   the first URL, and is required alongside `parts`, where the URLs name the
#'   pieces rather than the result.
#'
#' @return An object of class `getaca_resource`.
#' @export
#'
#' @examples
#' resource(
#'   name = "backbone",
#'   version = "2026.1",
#'   urls = "https://example.org/backbone-2026.1.parquet",
#'   sha256 = strrep("a", 64),
#'   size = 1048576,
#'   license = "CC-BY-4.0"
#' )
#'
#' # The same artefact, published as a base and the delta issued against it:
#' resource(
#'   name = "backbone",
#'   version = "2026.2",
#'   sha256 = strrep("b", 64),
#'   file = "backbone.parquet",
#'   parts = list(
#'     part("https://example.org/backbone-base.bin", sha256 = strrep("c", 64)),
#'     part("https://example.org/backbone-2026.2.bin", sha256 = strrep("d", 64))
#'   )
#' )
resource <- function(name, version, urls = NULL, sha256,
                     size = NA_real_, license = NA_character_,
                     description = NA_character_, doi = NULL, upstream = NULL,
                     processor = NULL, parts = NULL, combiner = NULL,
                     file = NULL) {
  rec <- structure(
    list(
      name = name,
      version = version,
      urls = as.character(urls),
      sha256 = tolower(sha256),
      size = as_size(size),
      license = license,
      description = description,
      doi = as_doi(doi),
      upstream = upstream,
      processor = processor,
      parts = if (length(parts)) parts else NULL,
      combiner = combiner,
      file = file
    ),
    class = "getaca_resource"
  )
  problems <- validate_resource(rec)
  if (length(problems)) err_invalid_registry(problems)
  rec
}

validate_resource <- function(x) {
  p <- character()
  if (!is_string(x$name) || !grepl("^[A-Za-z0-9._-]+$", x$name)) {
    p <- c(p, "`name` must be a single string of [A-Za-z0-9._-]")
  }
  if (!is_string(x$version) || !grepl("^[A-Za-z0-9._-]+$", x$version)) {
    p <- c(p, sprintf("resource '%s': `version` must be a single string of [A-Za-z0-9._-]", x$name))
  }
  p <- c(p, validate_sources(x))
  if (!is_string(x$sha256) || !grepl("^[0-9a-f]{64}$", x$sha256)) {
    p <- c(p, sprintf("resource '%s': `sha256` must be 64 lowercase hex characters", x$name))
  }
  if (!is.null(x$processor) && !inherits(x$processor, "getaca_processor")) {
    p <- c(p, sprintf("resource '%s': `processor` must come from processor()", x$name))
  }
  if (!is.null(x$doi) && !grepl("^10\\.[0-9]{4,9}/[^[:space:]]+$", x$doi)) {
    p <- c(p, sprintf("resource '%s': `doi` must be a DOI such as \"10.5281/zenodo.1234567\"",
                      x$name))
  }
  p
}

# One stored form for the three ways a DOI is written down. A registered DOI
# starts at the `10.` prefix; the resolver in front of it is a way to open one
# in a browser rather than part of the identifier.
as_doi <- function(doi) {
  if (is.null(doi) || !length(doi) || is.na(doi[1])) return(NULL)
  doi <- sub("^https?://(dx\\.)?doi\\.org/", "", as.character(doi)[1])
  sub("^doi:", "", doi)
}

# Where the bytes come from. Declaring both `urls` and `parts` would be two
# routes to one result with different failure characteristics and nothing in the
# declaration to choose between them, so a record names one or the other.
validate_sources <- function(x) {
  p <- character()
  has_urls <- length(x$urls) > 0L
  has_parts <- length(x$parts) > 0L

  if (has_urls && has_parts) {
    return(sprintf(
      "resource '%s': declares both `urls` and `parts`; give locations for the whole file or the parts it is composed from, not both",
      x$name
    ))
  }
  if (!has_urls && !has_parts) {
    return(sprintf("resource '%s': needs either `urls` or `parts`", x$name))
  }

  if (has_urls) {
    if (!all(nzchar(x$urls))) {
      p <- c(p, sprintf("resource '%s': at least one URL is required", x$name))
    } else if (!all(grepl("^https://", x$urls))) {
      p <- c(p, sprintf("resource '%s': all URLs must use https", x$name))
    }
    if (!is.null(x$combiner)) {
      p <- c(p, sprintf(
        "resource '%s': `combiner` describes how `parts` are put together, and this record declares none",
        x$name
      ))
    }
  }

  if (has_parts) {
    if (!all(vapply(x$parts, inherits, logical(1), "getaca_part"))) {
      p <- c(p, sprintf("resource '%s': every element of `parts` must come from part()", x$name))
    }
    if (!is.null(x$combiner) && !inherits(x$combiner, "getaca_combiner")) {
      p <- c(p, sprintf("resource '%s': `combiner` must come from combiner()", x$name))
    }
    # A whole-file record takes its cached name from the first URL. A part's URL
    # names the part, and consumers routinely choose a reader by extension, so
    # the artefact's own name has to be stated rather than guessed at.
    if (is.null(x$file)) {
      p <- c(p, sprintf(
        "resource '%s': a record declaring `parts` must also declare `file`, the name the composed artefact is cached under",
        x$name
      ))
    }
  }

  c(p, validate_file_name(x$file, x$name))
}

validate_file_name <- function(file, name) {
  if (is.null(file)) return(character())
  if (!is_string(file) || !grepl("^[A-Za-z0-9._-]+$", file) ||
      file %in% c(".", "..")) {
    return(sprintf(
      "resource '%s': `file` must be a single file name of [A-Za-z0-9._-], with no directory part",
      name
    ))
  }
  character()
}

#' @export
format.getaca_resource <- function(x, ...) {
  sprintf("%s@%s  %s  [%s]", x$name, x$version,
          substr(x$sha256, 1, 12), x$license)
}

#' @export
print.getaca_resource <- function(x, ...) {
  cat("<getaca resource record>\n")
  cat("  name      ", x$name, "\n", sep = "")
  cat("  version   ", x$version, "\n", sep = "")
  cat("  sha256    ", x$sha256, "\n", sep = "")
  cat("  size      ", if (is.na(x$size)) "unknown" else format(x$size, big.mark = ","), "\n", sep = "")
  cat("  license   ", x$license, "\n", sep = "")
  if (!is.null(x$doi)) cat("  doi       ", x$doi, "\n", sep = "")
  if (!is.null(x$file)) cat("  file      ", x$file, "\n", sep = "")
  if (length(x$urls)) {
    cat("  urls      ", paste(x$urls, collapse = "\n             "), "\n", sep = "")
  }
  if (length(x$parts)) {
    cat("  composed  ", length(x$parts), " parts via '", combiner_id(x$combiner),
        "'\n", sep = "")
    for (prt in x$parts) cat("    ", format(prt), "\n", sep = "")
  }
  if (!is.null(x$upstream)) {
    cat("  built from\n")
    for (nm in names(x$upstream)) {
      cat("    ", nm, ": ", as.character(x$upstream[[nm]]), "\n", sep = "")
    }
  }
  if (!is.null(x$processor)) cat("  processor ", x$processor$id, "\n", sep = "")
  invisible(x)
}

#' Declare one part of a resource
#'
#' A part names bytes that are a piece of an artefact rather than the artefact:
#' a chunk of a file split for a host with an upload limit, or a base release
#' and a delta issued against it. Parts are retrieved and verified individually
#' and then combined, in declaration order, into the file [resource()] names.
#'
#' Each part carries its own checksum and is stored under it, so a base shared
#' by every version of a resource is transferred once and kept once however many
#' versions declare it. Publishing a new version then costs its consumers the
#' delta rather than the whole file.
#'
#' Parts describe how the bytes arrive. A declaration may re-split an artefact,
#' add mirrors for a piece or drop one, the same way it may repair a mirror
#' list, because what a version means is fixed by the resource's own `sha256`
#' and checked against it after composition.
#'
#' @param urls Character vector of download locations for this part, tried in
#'   order. All must be `https://`.
#' @param sha256 Lowercase hex SHA-256 of this part as served.
#' @param size Expected size in bytes, or `NA`. Used to detect a truncated
#'   transfer before hashing.
#'
#' @return An object of class `getaca_part`.
#' @seealso [resource()], and [combiner()] for parts that are not simply
#'   concatenated.
#' @export
#'
#' @examples
#' part("https://example.org/backbone-base.bin", sha256 = strrep("c", 64),
#'      size = 1048576)
part <- function(urls, sha256, size = NA_real_) {
  prt <- structure(
    list(
      urls = as.character(urls),
      sha256 = tolower(sha256),
      size = if (is.na(size)) NA_real_ else as.numeric(size)
    ),
    class = "getaca_part"
  )
  problems <- validate_part(prt)
  if (length(problems)) err_invalid_registry(problems)
  prt
}

validate_part <- function(x) {
  p <- character()
  if (!length(x$urls) || !all(nzchar(x$urls))) {
    p <- c(p, "part: at least one URL is required")
  } else if (!all(grepl("^https://", x$urls))) {
    p <- c(p, "part: all URLs must use https")
  }
  if (!is_string(x$sha256) || !grepl("^[0-9a-f]{64}$", x$sha256)) {
    p <- c(p, "part: `sha256` must be 64 lowercase hex characters")
  }
  p
}

#' @export
format.getaca_part <- function(x, ...) {
  sprintf("%s  %s  %s", substr(x$sha256, 1, 12),
          if (is.na(x$size)) "unknown size" else format(x$size, big.mark = ","),
          x$urls[1])
}

#' @export
print.getaca_part <- function(x, ...) {
  cat("<getaca part> ", format(x), "\n", sep = "")
  invisible(x)
}

#' Declare how parts are combined
#'
#' A combiner turns the verified [part()]s of a resource, in declaration order,
#' into the single artefact the resource names. Concatenation is the default and
#' needs no declaration; a combiner is what a delta format calls for, since
#' applying a patch is knowledge about a file format and getaca has none.
#'
#' The result is held to the resource's own SHA-256 like any other bytes, so a
#' combiner cannot produce something other than what the declaration promises.
#' That is also why the manifest records a combiner by `id` alone: the checksum
#' says the result is right, and the identifier only says what to run.
#'
#' @param id Short stable identifier for this transformation, for example
#'   `"bsdiff"`.
#' @param fn A function `(parts, output)`, where `parts` is a character vector
#'   of verified local paths in declaration order and `output` is the file to
#'   write. The return value is ignored.
#'
#' @return An object of class `getaca_combiner`.
#' @seealso [part()]
#' @export
#'
#' @examples
#' combiner("bsdiff", function(parts, output) {
#'   # apply parts[-1] to parts[1], writing the result to output
#'   file.copy(parts[1], output)
#' })
combiner <- function(id, fn) {
  stopifnot(is_string(id), grepl("^[A-Za-z0-9._-]+$", id), is.function(fn))
  structure(list(id = id, fn = fn), class = "getaca_combiner")
}

#' @export
print.getaca_combiner <- function(x, ...) {
  cat("<getaca combiner> ", x$id, "\n", sep = "")
  invisible(x)
}

#' Declare a post-download processor
#'
#' A processor turns one verified path into another path: unpacking an
#' archive, or preparing a package-specific layout. It carries an `id` so the
#' processed result gets its own cache slot and its own provenance, rather
#' than being confused with the raw artefact it came from.
#'
#' getaca knows nothing about file formats. It never reads data.
#'
#' @param id Short stable identifier for this transformation, for example
#'   `"unzip"` or `"unzip-v2"`. Changing the transformation means changing
#'   the id, which invalidates previously processed copies.
#' @param fn A function `(input, output_dir)` returning a path inside
#'   `output_dir`.
#'
#' @return An object of class `getaca_processor`.
#' @export
#'
#' @examples
#' unzipper <- processor("unzip", function(input, output_dir) {
#'   utils::unzip(input, exdir = output_dir)
#'   output_dir
#' })
processor <- function(id, fn) {
  stopifnot(is_string(id), grepl("^[A-Za-z0-9._-]+$", id), is.function(fn))
  structure(list(id = id, fn = fn), class = "getaca_processor")
}

is_string <- function(x) is.character(x) && length(x) == 1L && !is.na(x)

# A declaration may omit a size, and an authoring format may hand over an empty
# one. Both say the same thing: there is nothing to hold a transfer to before it
# is hashed.
as_size <- function(size) {
  if (!length(size) || is.na(size)) NA_real_ else as.numeric(size)
}
