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
#' resource_id("taxify", "wfo", "2026.1")
resource_id <- function(package, name, version) {
  stopifnot(is_string(package), is_string(name), is_string(version))
  structure(
    list(package = package, name = name, version = version),
    class = "getaca_id"
  )
}

#' @export
format.getaca_id <- function(x, ...) {
  sprintf("%s/%s@%s", x$package, x$name, x$version)
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
#' @param name Resource name. Must be usable as a directory name.
#' @param version Version label for these exact bytes, for example `"2026.1"`.
#' @param urls Character vector of download locations, tried in order. All
#'   must be `https://`.
#' @param sha256 Lowercase hex SHA-256 of the file as served.
#' @param size Expected size in bytes, or `NA`. Used to detect truncated
#'   transfers before hashing.
#' @param license License identifier for the data, for example `"CC-BY-4.0"`.
#' @param description One-line human description.
#' @param upstream Optional named list identifying what these bytes were built
#'   from, when the artefact is derived rather than an original release. A
#'   prepared database records both its own build identity and the upstream
#'   release it was made from, and both travel into provenance.
#' @param processor Optional [processor()] applied after verification.
#'
#' @return An object of class `getaca_resource`.
#' @export
#'
#' @examples
#' resource(
#'   name = "wfo",
#'   version = "2026.1",
#'   urls = "https://example.org/wfo-2026.1.parquet",
#'   sha256 = strrep("a", 64),
#'   size = 1048576,
#'   license = "CC-BY-4.0"
#' )
resource <- function(name, version, urls, sha256,
                     size = NA_real_, license = NA_character_,
                     description = NA_character_, upstream = NULL,
                     processor = NULL) {
  rec <- structure(
    list(
      name = name,
      version = version,
      urls = as.character(urls),
      sha256 = tolower(sha256),
      size = if (is.na(size)) NA_real_ else as.numeric(size),
      license = license,
      description = description,
      upstream = upstream,
      processor = processor
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
  if (!length(x$urls) || !all(nzchar(x$urls))) {
    p <- c(p, sprintf("resource '%s': at least one URL is required", x$name))
  } else if (!all(grepl("^https://", x$urls))) {
    p <- c(p, sprintf("resource '%s': all URLs must use https", x$name))
  }
  if (!is_string(x$sha256) || !grepl("^[0-9a-f]{64}$", x$sha256)) {
    p <- c(p, sprintf("resource '%s': `sha256` must be 64 lowercase hex characters", x$name))
  }
  if (!is.null(x$processor) && !inherits(x$processor, "getaca_processor")) {
    p <- c(p, sprintf("resource '%s': `processor` must come from processor()", x$name))
  }
  p
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
  cat("  urls      ", paste(x$urls, collapse = "\n             "), "\n", sep = "")
  if (!is.null(x$upstream)) {
    cat("  built from\n")
    for (nm in names(x$upstream)) {
      cat("    ", nm, ": ", as.character(x$upstream[[nm]]), "\n", sep = "")
    }
  }
  if (!is.null(x$processor)) cat("  processor ", x$processor$id, "\n", sep = "")
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
