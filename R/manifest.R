#' The canonical form a registry hashes to
#'
#' Renders the declaration as a sorted, escaped, line-oriented text form and
#' returns its lines. [registry_digest()] hashes exactly these bytes, so a
#' digest is never a black box: two registries that disagree can be diffed on
#' the text that produced the disagreement.
#'
#' Hashing the R object directly is not an option. A [resource()] may carry a
#' [processor()], which holds a closure, and a closure digests differently
#' across machines and builds because its environment, bytecode and source
#' references travel with it. A registry declaring a processor would appear to
#' change identity on every machine. The manifest reduces a processor to its
#' `id`, which is what the declaration actually promises.
#'
#' @section Format:
#' The first line names the format version, which moves independently of
#' `schema_version` because the two change for different reasons: a new field
#' in the stored form need not change how existing fields are rendered.
#'
#' ```
#' getaca-manifest 1
#' package taxify
#' remote https://taxify.example.org/registry.rds
#' current wfo 2026-09
#' resource wfo 2026-06
#'   sha256 3f9ac2...
#'   size 1048576
#'   license CC-BY-4.0
#'   url https://zenodo.org/record/123/wfo-2026-06.parquet
#'   url https://mirror.example.org/wfo-2026-06.parquet
#'   upstream release 2026-06
#'   processor unzip-v2
#' ```
#'
#' Resources are sorted by `name@version` in the C locale, so the same
#' declaration renders identically wherever it is read. URLs keep declaration
#' order, which is load-bearing: mirrors are tried in the order given. Absent
#' and `NA` fields are omitted rather than rendered as empty, since a key that
#' is present carries a value by construction.
#'
#' @section What is left out:
#' `created` and `policy` are not part of the declaration. `created` says when
#' a state was written and `policy` supplies a default; neither changes which
#' bytes a name resolves to, and including either would mean an unchanged
#' registry took on a new identity for writing it out again. `description` is
#' prose, so a typo fix would invalidate a digest already recorded in
#' provenance.
#'
#' @param registry A [registry()] object.
#'
#' @return A character vector of lines, classed `getaca_manifest`.
#' @seealso [registry_digest()]
#' @export
#'
#' @examples
#' reg <- registry("demo", list(
#'   resource("example", "1.0",
#'            urls = "https://example.org/example-1.0.csv",
#'            sha256 = strrep("c", 64), license = "CC0-1.0")
#' ))
#' registry_manifest(reg)
registry_manifest <- function(registry) {
  stopifnot(inherits(registry, "getaca_registry"))
  lines <- c(
    paste("getaca-manifest", MANIFEST_FORMAT),
    manifest_line("package", registry$package),
    manifest_line("remote", registry$remote),
    manifest_current(registry$current),
    unlist(lapply(manifest_sorted(registry$resources), manifest_resource),
           use.names = FALSE)
  )
  structure(lines, class = "getaca_manifest")
}

MANIFEST_FORMAT <- 1L

#' @export
print.getaca_manifest <- function(x, ...) {
  cat(unclass(x), sep = "\n")
  cat("\n")
  invisible(x)
}

#' Content identity of a registry
#'
#' The digest of a registry's [registry_manifest()]. This is what identifies a
#' declaration state: it is derived from the declaration rather than asserted
#' alongside it, so it cannot be typed wrong, cannot go stale, and cannot claim
#' that two different states are the same one. Provenance records it for every
#' retrieved resource, so a cached file can always be traced to the exact
#' declaration that resolved it.
#'
#' The value is self-describing, as in `"sha256:3f9ac2..."`, so the algorithm
#' can change later without changing the shape of anything that stores one.
#'
#' A digest says whether two registries are the same. It does not say which is
#' newer; `created` answers that. It also carries no authenticity: a digest
#' travelling inside the file it describes is rewritten by anyone who rewrites
#' the file. What stops a remote registry from redefining published bytes is
#' the per-resource checksum comparison in [resolve_resource()], which names the
#' offending resource rather than reporting that something, somewhere, moved.
#'
#' @param registry A [registry()] object.
#'
#' @return A single string: an algorithm name, a colon, and lowercase hex.
#' @seealso [registry_manifest()] for the exact bytes hashed.
#' @export
#'
#' @examples
#' reg <- registry("demo", list(
#'   resource("example", "1.0",
#'            urls = "https://example.org/example-1.0.csv",
#'            sha256 = strrep("c", 64))
#' ))
#' registry_digest(reg)
registry_digest <- function(registry) {
  text <- paste0(paste(unclass(registry_manifest(registry)), collapse = "\n"), "\n")
  # Hash the UTF-8 bytes explicitly. A string carrying a non-ASCII license or
  # upstream field would otherwise hash to whatever the session's native
  # encoding made of it, which differs between platforms.
  bytes <- charToRaw(enc2utf8(text))
  paste0("sha256:", unname(tools::sha256sum(bytes = bytes)))
}

# Enough hex to identify a state at a glance, matching what a resource record
# shows. The full value stays in provenance.
short_digest <- function(digest, n = 12L) {
  if (is.null(digest) || is.na(digest)) return(NA_character_)
  parts <- strsplit(digest, ":", fixed = TRUE)[[1]]
  if (length(parts) != 2L) return(substr(digest, 1L, n))
  paste0(parts[1], ":", substr(parts[2], 1L, n))
}

manifest_resource <- function(r) {
  c(
    paste("resource", manifest_escape(r$name), manifest_escape(r$version)),
    manifest_line("sha256", r$sha256, indent = TRUE),
    manifest_line("size", manifest_size(r$size), indent = TRUE),
    manifest_line("license", r$license, indent = TRUE),
    manifest_line("url", r$urls, indent = TRUE),
    manifest_upstream(r$upstream),
    manifest_line("processor", r$processor$id, indent = TRUE)
  )
}

manifest_upstream <- function(upstream) {
  if (!length(upstream)) return(character())
  nms <- names(upstream)
  if (is.null(nms)) return(character())
  nms <- nms[manifest_order(nms)]
  vapply(nms, function(nm) {
    paste("  upstream", manifest_escape(nm),
          manifest_escape(as.character(upstream[[nm]])[1]))
  }, character(1), USE.NAMES = FALSE)
}

manifest_current <- function(current) {
  if (!length(current)) return(character())
  nms <- names(current)[manifest_order(names(current))]
  vapply(nms, function(nm) {
    paste("current", manifest_escape(nm), manifest_escape(unname(current[[nm]])))
  }, character(1), USE.NAMES = FALSE)
}

# One line per value, absent values contributing nothing.
manifest_line <- function(key, value, indent = FALSE) {
  if (is.null(value) || !length(value)) return(character())
  value <- value[!is.na(value)]
  if (!length(value)) return(character())
  paste0(if (indent) "  ", key, " ", manifest_escape(as.character(value)))
}

manifest_size <- function(size) {
  if (is.null(size) || !length(size) || is.na(size)) return(NA_character_)
  sprintf("%.0f", as.numeric(size))
}

# Radix ordering is the C locale wherever it runs. The default method consults
# the collation locale, which would make a registry's identity depend on the
# machine that read it.
manifest_order <- function(x) order(x, method = "radix")

manifest_sorted <- function(resources) {
  keys <- vapply(resources, function(r) paste0(r$name, "@", r$version), character(1))
  unname(resources[manifest_order(keys)])
}

# One escape rule for every position, so field boundaries are unambiguous
# without the reader having to know which fields may contain a space. The
# backslash has to go first or it would double the escapes introduced after it.
manifest_escape <- function(x) {
  x <- gsub("\\", "\\\\", x, fixed = TRUE)
  x <- gsub(" ", "\\s", x, fixed = TRUE)
  x <- gsub("\t", "\\t", x, fixed = TRUE)
  x <- gsub("\r", "\\r", x, fixed = TRUE)
  gsub("\n", "\\n", x, fixed = TRUE)
}
