#' Unpack an archive or a compressed file
#'
#' A stock [processor()] for the transformation almost every declaration of an
#' archive wants: extract it, once, into its own cache slot. `getaca()` then
#' returns the unpacked directory, and `processed = FALSE` still returns the
#' archive it was built from.
#'
#' `format = "auto"` reads the format from the cached file's name: `.zip`;
#' `.tar`, `.tar.gz`, `.tgz`, `.tar.bz2`, `.tbz2`, `.tar.xz` and `.txz`; and
#' the single-file compressions `.gz`, `.bz2` and `.xz`. Name the format
#' instead for an archive whose file name does not carry one.
#'
#' A compressed single file is written under its own name with the compression
#' extension removed, so `backbone-2026-06.csv.gz` unpacks to
#' `backbone-2026-06.csv`. Archives keep the layout they were packed with.
#'
#' The id encodes the settings, because the id is what the cache slot and the
#' registry manifest are keyed on: `unpack()` is `"unpack"`, `unpack("zip")` is
#' `"unpack-zip"`, and naming `members` appends a digest of them. Two records
#' asking for different subsets therefore cannot land in one slot.
#'
#' @param format One of `"auto"`, `"zip"`, `"tar"`, `"gzip"`, `"bzip2"` or
#'   `"xz"`. `"tar"` covers the compressed tarballs; `"gzip"`, `"bzip2"` and
#'   `"xz"` are for a single compressed file.
#' @param members Optional character vector of paths inside the archive to
#'   extract, instead of all of it. A name that ends a directory extracts
#'   everything under it. A name matching nothing in the archive is an error.
#'   Not applicable to a single compressed file.
#'
#' @return An object of class `getaca_processor`, for `resource(processor = )`.
#' @seealso [processor()] to write your own, [resource()] to attach one.
#' @export
#'
#' @examples
#' unpack()
#' unpack("zip")$id
#' unpack("zip", members = "backbone/names.csv")$id
#'
#' resource("backbone", "2026-06",
#'          urls      = "https://example.org/backbone-2026-06.zip",
#'          sha256    = strrep("9f", 32),
#'          processor = unpack())
unpack <- function(format = c("auto", "zip", "tar", "gzip", "bzip2", "xz"),
                   members = NULL) {
  format <- match.arg(format)
  members <- check_members(members, format)
  processor(unpack_id(format, members), function(input, output_dir) {
    unpack_run(input, output_dir, format, members)
  })
}

check_members <- function(members, format) {
  if (is.null(members)) return(NULL)
  if (!is.character(members) || !length(members) || anyNA(members) ||
      !all(nzchar(members))) {
    stop("getaca: `members` must be a character vector of names inside the archive.",
         call. = FALSE)
  }
  if (format %in% ONE_FILE_FORMATS) {
    stop(sprintf(
      "getaca: `members` does not apply to format '%s', which holds a single file.",
      format), call. = FALSE)
  }
  sort(unique(members))
}

ONE_FILE_FORMATS <- c("gzip", "bzip2", "xz")

# The id keys the processed slot and renders into the registry manifest, so it
# has to separate settings that produce different bytes and to be the same on
# every machine. Member order does not reach the result, so it is sorted away
# before the digest rather than making two spellings of one subset disagree.
unpack_id <- function(format, members) {
  parts <- "unpack"
  if (!identical(format, "auto")) parts <- c(parts, format)
  if (!is.null(members)) {
    digest <- sha256_bytes(charToRaw(paste0(members, collapse = "\n")))
    parts <- c(parts, substr(digest, 1L, 8L))
  }
  paste(parts, collapse = "-")
}

unpack_run <- function(input, output_dir, format, members) {
  format <- if (identical(format, "auto")) detect_format(input) else format
  if (format %in% ONE_FILE_FORMATS) {
    decompress_file(input, output_dir, format)
  } else if (identical(format, "zip")) {
    unpack_zip(input, output_dir, members)
  } else {
    unpack_tar(input, output_dir, members)
  }
}

# A compressed tarball is a tarball: the compression is how it travelled and
# untar() reads it either way, so .tar.gz resolves to "tar" rather than "gzip".
# The bare compressions are therefore only reached by a name that no tar
# extension claimed first.
detect_format <- function(path) {
  name <- tolower(basename(path))
  if (grepl("\\.zip$", name)) return("zip")
  if (grepl("\\.(tar|tgz|tbz|tbz2|txz)$", name)) return("tar")
  if (grepl("\\.tar\\.(gz|bz2|xz)$", name)) return("tar")
  if (grepl("\\.gz$", name))  return("gzip")
  if (grepl("\\.bz2$", name)) return("bzip2")
  if (grepl("\\.xz$", name))  return("xz")
  stop(sprintf(
    paste0("getaca: unpack() cannot tell the format of '%s' from its name.\n",
           "  Name it: unpack(format = \"zip\"), or one of %s."),
    basename(path),
    paste(sprintf("\"%s\"", c("tar", "gzip", "bzip2", "xz")), collapse = ", ")
  ), call. = FALSE)
}

unpack_zip <- function(input, output_dir, members) {
  wanted <- expand_members(utils::unzip(input, list = TRUE)$Name, members, input)
  utils::unzip(input, files = wanted, exdir = output_dir)
  output_dir
}

unpack_tar <- function(input, output_dir, members) {
  wanted <- expand_members(utils::untar(input, list = TRUE), members, input)
  status <- utils::untar(input, files = wanted, exdir = output_dir)
  if (!identical(as.integer(status), 0L)) {
    stop(sprintf("getaca: extracting '%s' failed with status %s.",
                 basename(input), status), call. = FALSE)
  }
  output_dir
}

# A member naming a directory takes everything under it, which is what a caller
# asking for one subtree of a large archive means. A member matching nothing is
# an error rather than an empty result: the alternative is a processed slot that
# looks complete and holds nothing, which no later verification would catch,
# since getaca hashes the archive and never reads what came out of it.
expand_members <- function(available, members, input) {
  if (is.null(members)) return(NULL)
  hits <- lapply(members, function(member) {
    prefix <- sub("/+$", "", member)
    available[available == member |
                startsWith(available, paste0(prefix, "/"))]
  })
  empty <- members[lengths(hits) == 0L]
  if (length(empty)) {
    stop(sprintf("getaca: '%s' names nothing in '%s'.",
                 empty[1], basename(input)), call. = FALSE)
  }
  unique(unlist(hits, use.names = FALSE))
}

# Streamed rather than read whole: these are the files that are too big to ship
# in a package, and a decompressed copy of one need never be in memory at once.
decompress_file <- function(input, output_dir, format) {
  opener <- switch(format, gzip = gzfile, bzip2 = bzfile, xz = xzfile)
  output <- file.path(output_dir, decompressed_name(input))

  from <- opener(input, "rb")
  on.exit(close(from), add = TRUE)
  to <- file(output, "wb")
  on.exit(close(to), add = TRUE)

  repeat {
    chunk <- readBin(from, "raw", 1024L * 1024L)
    if (!length(chunk)) break
    writeBin(chunk, to)
  }
  output
}

decompressed_name <- function(input) {
  name <- basename(input)
  sub("\\.(gz|bz2|xz)$", "", name, ignore.case = TRUE)
}
