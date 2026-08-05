# Migrating an Existing Downloader

Most packages that depend on external data already have a downloader. It
grew one function at a time, it works, and it is two hundred lines
nobody enjoys maintaining. This article converts one, keeping the
package’s own API intact so users notice nothing.

The example is a plausible starting point rather than any particular
package: a table of URLs, a cache directory, a
[`file.exists()`](https://rdrr.io/r/base/files.html) check, and an
ad-hoc version string.

## What is being replaced

``` r

# R/download.R, before
BACKBONE_URLS <- c(
  backbone = "https://host.example/backbone.zip",
  grid     = "https://host.example/grid.zip"
)

backbone_dir <- function() {
  d <- tools::R_user_dir("yourpkg", "cache")
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
  d
}

backbone_path <- function(name) {
  file.path(backbone_dir(), paste0(name, ".zip"))
}

install_backbone <- function(name = "backbone", force = FALSE) {
  dest <- backbone_path(name)
  if (file.exists(dest) && !force) return(invisible(dest))

  url <- BACKBONE_URLS[[name]]
  if (is.null(url)) stop("Unknown dataset: ", name)

  tmp <- tempfile()
  ok <- tryCatch({
    utils::download.file(url, tmp, mode = "wb", quiet = TRUE)
    TRUE
  }, error = function(e) FALSE)
  if (!ok) stop("Could not download ", name, ". Check your connection.")

  file.rename(tmp, dest)
  invisible(dest)
}

backbone_available <- function(name = "backbone") {
  file.exists(backbone_path(name))
}
```

Read it for what it promises rather than what it does.
`install_backbone()` promises a usable file at a path. It delivers a
path to whatever arrived, which is a weaker thing: a proxy’s HTML error
page, a transfer that ended at 60%, and a file the publisher recut last
week all reach the caller as a success and fail somewhere in the parser.

Five gaps, in the order they bite:

1.  **No checksum.** Nothing distinguishes the right bytes from wrong
    ones.

2.  **No version.** `backbone.zip` is whichever release happened to be
    current when a given machine first ran the call, so two machines
    running identical code can hold different data with nothing
    recording it.

3.  **One URL.** An outage is a support issue.

4.  **No check-time behaviour.** Every test, example and vignette that
    touches the data needs its own guard, written by hand.

5.  **No retention policy**, which is what CRAN asks about when a
    package writes under `R_user_dir()`.

What is left after those five is plumbing `getaca` already owns: the
cache directory, the temporary file, the rename, the existence test.

## Step 1: turn the URL table into records

The declaration is mostly information the old code held implicitly. The
URL table becomes records, the implicit “whatever is current” becomes a
version label, and the checksum is the one genuinely new field.

A checksum has to come from the bytes, so
[`registry_draft()`](https://gillescolling.com/getaca/reference/registry_draft.md)
retrieves each location once and hashes it locally. The old table is the
argument, near enough unchanged:

``` r

# data-raw/registry.R
reg <- registry_draft(
  c(backbone = "https://host.example/backbone-2026-06.zip",
    grid     = "https://host.example/grid-2026-06.zip"),
  package = "yourpkg",
  version = "2026-06"
)
```

What comes back is a registry holding a record per entry, each carrying
the size and the SHA-256 of the file as served. That is not always the
file you built: a host that recompresses on upload, or serves a
re-zipped copy, changes the digest your users receive. Hashing what
arrives is what makes the record describe their download rather than
your build.

Where the data are deposited rather than served from a plain URL, the
identifier is the location, and the archive supplies the licence, the
version and a DOI along with the files:

``` r

registry_draft("10.5281/zenodo.1234567", package = "yourpkg")
```

Drafting a large record costs no disk: the file is hashed as it arrives
and never written down. Pass `keep = TRUE` to write it to the cache
instead, so your first real call finds it already there.

Hashing the copy you built is a different claim, and `local =` makes it:

``` r

registry_draft(c(backbone = "https://zenodo.org/records/1234567/files/backbone.zip"),
               package = "yourpkg", version = "2026-06",
               local   = c(backbone = "~/build/backbone-2026-06.zip"),
               sha256  = c(backbone = "9f9f..."))
```

With both, the local copy is hashed and held to the checksum, which is
how a deposit is confirmed to be the file that was uploaded.

A draft is a starting point, and two fields it cannot know are worth
adding by hand: a second location, and a line of description for anyone
reading the catalogue.

``` r

backbone <- resource(
  name    = "backbone",
  version = "2026-06",
  urls    = c("https://zenodo.invalid/records/1234567/files/backbone-2026-06.zip",
              "https://releases.invalid/backbone/2026.06/backbone.zip"),
  sha256  = strrep("9f", 32),
  size    = 797e6,
  license = "CC-BY-4.0",
  description = "Reference backbone, June 2026"
)
format(backbone)
#> [1] "backbone@2026-06  9f9f9f9f9f9f  [CC-BY-4.0]"
```

The version label is the decision worth pausing on. Whatever the old
code called “the current one” now needs a name that will still be right
in two years. Upstream’s own release identifier is the default answer,
and a label that records both identities is better when you are shipping
something you built from upstream:

``` r

format(resource(
  name    = "backbone",
  version = "source-2026-06_build-3",
  urls    = "https://host.invalid/backbone-db-3.zip",
  sha256  = strrep("ab", 32),
  license = "CC-BY-4.0",
  upstream = list(source_release = "2026-06", build = "3")
))
#> [1] "backbone@source-2026-06_build-3  abababababab  [CC-BY-4.0]"
```

## Step 2: assemble and ship the registry

Every entry in the old table becomes a record, and the records become
one registry scoped to your package:

``` r

grid <- resource(
  name    = "grid",
  version = "2026-06",
  urls    = "https://zenodo.invalid/records/1234567/files/grid-2026-06.zip",
  sha256  = strrep("ab", 32),
  size    = 41e6,
  license = "CC-BY-4.0",
  description = "Reference grid, June 2026"
)

reg <- registry(package = "yourpkg", resources = list(backbone, grid))
reg
#> <getaca registry> yourpkg  (policy "bundled")
#>   digest: sha256:deabc8953e49
#>   - backbone@2026-06  9f9f9f9f9f9f  [CC-BY-4.0]
#>   - grid@2026-06  abababababab  [CC-BY-4.0]
```

Generate it rather than hand-maintaining it, from a script that stays
out of the built package:

``` r

# data-raw/registry.R
source("data-raw/records.R")   # returns a list of resource()s
registry_write(
  registry(package = "yourpkg", resources = records),
  "inst/getaca/registry.rds"
)
```

    # .Rbuildignore
    ^data-raw$

Nothing else is needed to make the package discoverable. `getaca` finds
the file with
[`system.file()`](https://rdrr.io/r/base/system.file.html), so there is
no registration call, no `.onLoad()` hook, and no load-order question.

Two lines of `DESCRIPTION` change. `getaca` goes in `Imports`, since the
declaration is useless without it; it brings `curl`, with nothing
beneath it, and one C file that a source install compiles. And the
`Description` field is where a reviewer, and a user on a metered
connection, read that this package downloads data on first use:

    Imports: getaca
    Description: ... The backbone is downloaded on first use and cached under
        tools::R_user_dir(), and can be fetched ahead of time with
        install_backbone().

## Step 3: rewrite the front door

The package’s own API stays. Users keep calling `install_backbone()`;
what changes is the two hundred lines behind it.

``` r

# R/download.R, after
install_backbone <- function(name = "backbone", force = FALSE) {
  invisible(getaca::getaca(name, package = "yourpkg", verify = force))
}

backbone_path <- function(name = "backbone") {
  getaca::getaca(name, package = "yourpkg")
}

backbone_available <- function(name = "backbone") {
  getaca::getaca_available(name, package = "yourpkg")
}
```

`force` changes meaning, and for the better. It used to mean “download
it again”. It now means “re-verify what you have”, which handles the
case the old flag was usually reached for: a user who suspects the
cached copy is wrong. A copy that is genuinely damaged raises
`getaca_error_cache_corrupt` and names the repair, and a copy that is
fine is confirmed rather than re-downloaded.

The mapping for the rest of the old surface:

| Before | After |
|----|----|
| `backbone_dir()` | [`getaca_cache_dir()`](https://gillescolling.com/getaca/reference/getaca_cache_dir.md), or nothing; the path is not the interface |
| `backbone_path(name)` | `getaca(name, package = )` |
| `file.exists(backbone_path(name))` | `getaca_available(name, package = )` |
| `install_backbone(name)` | `getaca(name, package = )` or [`getaca_prefetch()`](https://gillescolling.com/getaca/reference/getaca_prefetch.md) |
| `BACKBONE_URLS` | `urls` on each [`resource()`](https://gillescolling.com/getaca/reference/resource.md) |
| a hand-rolled [`unlink()`](https://rdrr.io/r/base/unlink.html) cleaner | [`getaca_clean()`](https://gillescolling.com/getaca/reference/getaca-gc.md) and the automatic sweeps |
| nothing | [`getaca_info()`](https://gillescolling.com/getaca/reference/getaca_info.md), [`getaca_catalogue()`](https://gillescolling.com/getaca/reference/getaca_catalogue.md) |

The unknown-name branch goes too.
[`getaca()`](https://gillescolling.com/getaca/reference/getaca.md)
raises `getaca_error_invalid_registry` for a name the registry does not
declare, and the message lists what is on offer, which is what the old
`stop("Unknown dataset: ", name)` was reaching for.

## Step 4: replace the guards

Every place the old code checked
[`file.exists()`](https://rdrr.io/r/base/files.html) before doing
something expensive becomes one of the three helpers.

In tests:

``` r

# before
test_that("the backbone parses", {
  skip_if(!backbone_available("backbone"), "backbone not installed")
  expect_s3_class(read_backbone(backbone_path("backbone")), "backbone")
})

# after
test_that("the backbone parses", {
  getaca_skip_if_unavailable("backbone", package = "yourpkg")
  expect_s3_class(read_backbone(getaca("backbone", package = "yourpkg")),
                  "backbone")
})
```

The skip reason is the difference. The old one says the file is not
installed; the new one names the resource, the declaring package, and
the call that would fetch it, which is what someone reading a CI log
from another project needs.

In examples:

``` r

#' @examples
#' path <- getaca_optional("backbone", package = "yourpkg")
#' if (!is.null(path)) summarise_backbone(path)
```

See
[`vignette("checks")`](https://gillescolling.com/getaca/articles/checks.md)
for the vignette cases and the CI workflow.

## Step 5: retire the version guesswork

The old code had no version, so it had no way to answer “which release
is this”. After the migration, provenance is a call:

``` r

getaca_info("backbone", package = "yourpkg")
#> <getaca cache entry> yourpkg/backbone@2026-06
#>   ...
#>   built from  source_release: 2026-06
#>   resolved by bundled registry sha256:1c4d7a90f2be (published 2026-07-20)
#>   source url  https://zenodo.invalid/records/1234567/files/backbone-2026-06.zip
#>   fetched     2026-07-26 11:02:13
#>   verified    2026-07-26 11:09:44 (full re-hash)
```

Across the whole table the same question has a data frame for an answer,
which is the report to ask a user for instead of a directory listing:

``` r

getaca_catalogue(registry = reg)[, c("name", "version", "declared", "cached")]
#>       name version declared cached
#> 1 backbone 2026-06     TRUE  FALSE
#> 2     grid 2026-06     TRUE  FALSE
```

That is worth surfacing in your own output rather than leaving to users
who know to look. A result object that records the resolved version, and
a citation helper that reads it, turn the migration into a visible
improvement rather than an internal one.

``` r

analyse <- function(x) {
  info <- getaca::getaca_info("backbone", package = "yourpkg")
  out  <- do_the_work(x, getaca::getaca("backbone", package = "yourpkg"))
  attr(out, "backbone_version") <- info$id$version
  attr(out, "backbone_sha256")  <- info$observed_sha256
  out
}
```

## Handling users who already have the old cache

The two layouts differ, so existing users re-download on first use after
upgrading. Importing a loose file into the cache is deliberately
unsupported: a copy with no recorded version cannot be shown to be any
particular release, so adopting it would carry forward exactly the
uncertainty the migration removes.

What remains is deciding what happens to the old directory. Two answers.

**Leave it, and say so in `NEWS.md`.** Users who want the disk back
delete the directory themselves, and anyone with a script that still
reads the old path keeps working until they update it. For a cache
measured in megabytes this is the whole job.

**Notice it, and say so once.** The right answer when the old cache was
large, since leaving gigabytes of superseded bytes on disk costs the
user something for nothing. A flag in a package environment keeps it to
one message per session:

``` r

.legacy_checked <- new.env(parent = emptyenv())

retire_legacy_cache <- function() {
  if (isTRUE(.legacy_checked$done)) return(invisible(NULL))
  .legacy_checked$done <- TRUE

  old <- tools::R_user_dir("yourpkg", "cache")
  files <- list.files(old, pattern = "[.]zip$", full.names = TRUE)
  if (!length(files)) return(invisible(NULL))

  message("yourpkg now stores its data through getaca, with a recorded ",
          "version and checksum.\n",
          "The previous downloads at ", old, " are no longer used.\n",
          "Remove them with: unlink(\"", old, "\", recursive = TRUE)")
  invisible(NULL)
}
```

It tells rather than deletes, and that is the part worth keeping.
Deleting a user’s files on package upgrade is a decision worth making
explicitly, in a function they call, rather than as a side effect of
loading a namespace.

## The migration, as a checklist

every entry in the old URL table has a record, with a checksum computed
from the file as served

`size`, `license` and a version label that will still be right in two
years on each record

`inst/getaca/registry.rds` written by a `data-raw/` script, with
`^data-raw$` in `.Rbuildignore`

the old front door still exists, and calls
[`getaca()`](https://gillescolling.com/getaca/reference/getaca.md)

every [`file.exists()`](https://rdrr.io/r/base/files.html) guard
replaced by
[`getaca_available()`](https://gillescolling.com/getaca/reference/getaca-checks.md),
[`getaca_optional()`](https://gillescolling.com/getaca/reference/getaca-checks.md)
or
[`getaca_skip_if_unavailable()`](https://gillescolling.com/getaca/reference/getaca-checks.md)

the download function, the cache-path helpers and the cleanup code
deleted rather than left unused

`getaca` in `Imports`, and `Description` saying data are downloaded on
first use

[`devtools::check()`](https://devtools.r-lib.org/reference/check.html)
passes against an empty `GETACA_CACHE` with `NOT_CRAN` unset

`NEWS.md` says what happened to the old cache directory

## What the migration bought

Counting the parts that were not there before:

- a checksum, so wrong bytes are an error at the boundary rather than a
  parse failure later

- a version, so two machines can be compared and a result can name its
  input

- mirrors, so one host’s outage is a slower call

- resumable transfers, so an interrupted four-gigabyte download
  continues

- locking, so two sessions do not both fetch it

- a retention policy, which is what CRAN asks for when a package writes
  under `R_user_dir()`

- eleven classed conditions in place of one
  [`stop()`](https://rdrr.io/r/base/stop.html) with a guessed cause

- provenance, and a catalogue covering declared and cached in one table

And the parts that went: the download function, the cache-path helpers,
the availability check, the cleanup code, and the guard logic in every
test.

## Where to go next

- [`vignette("declaring")`](https://gillescolling.com/getaca/articles/declaring.md)
  for the full authoring guide and the pre-ship checklist

- [`vignette("checks")`](https://gillescolling.com/getaca/articles/checks.md)
  for the CI workflow and the empty-cache check

- [`vignette("alternatives")`](https://gillescolling.com/getaca/articles/alternatives.md)
  for whether `getaca` is the right target at all
