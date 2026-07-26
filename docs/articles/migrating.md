# Migrating an Existing Downloader

Most packages that depend on external data already have a downloader. It
grew one function at a time, it works, and it is two hundred lines
nobody enjoys maintaining. This article converts one, keeping the
package’s own API intact so users notice nothing.

The example is a plausible starting point rather than any particular
package: a cache directory, a URL, a
[`file.exists()`](https://rdrr.io/r/base/files.html) check, and an
ad-hoc version string.

## What is being replaced

``` r

# R/download.R, before
backbone_dir <- function() {
  d <- tools::R_user_dir("taxify", "cache")
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
  d
}

backbone_path <- function(name) {
  file.path(backbone_dir(), paste0(name, ".vtr"))
}

install_backbone <- function(name = "wfo", force = FALSE) {
  dest <- backbone_path(name)
  if (file.exists(dest) && !force) return(invisible(dest))

  url <- BACKBONE_URLS[[name]]
  if (is.null(url)) stop("Unknown backbone: ", name)

  tmp <- tempfile()
  ok <- tryCatch({
    utils::download.file(url, tmp, mode = "wb", quiet = TRUE)
    TRUE
  }, error = function(e) FALSE)
  if (!ok) stop("Could not download ", name, ". Check your connection.")

  file.rename(tmp, dest)
  invisible(dest)
}

backbone_available <- function(name = "wfo") file.exists(backbone_path(name))
```

Read it for what it promises rather than what it does.
`install_backbone()` promises a usable file at a path. It delivers a
path to whatever arrived, which is a weaker thing: a proxy’s HTML error
page, a transfer that ended at 60%, and a file the publisher recut last
week all reach the caller as a success and fail somewhere in the parser.

Four gaps, in the order they bite:

1.  **No checksum.** Nothing distinguishes the right bytes from wrong
    ones.

2.  **No version.** `wfo.vtr` is whichever release happened to be
    current when a given machine first ran the call, so two machines
    running identical code can hold different data with nothing
    recording it.

3.  **One URL.** An outage is a support issue.

4.  **No check-time behaviour.** Every test, example and vignette that
    touches a backbone needs its own guard, written by hand.

There is also no retention policy, which is the part CRAN asks about
when a package writes under `R_user_dir()`.

## Step 1: write down what you already ship

The migration starts with a declaration, and the declaration is mostly
information the old code held implicitly. The URL table becomes records;
the implicit “whatever is current” becomes a version label; the checksum
is the one genuinely new field.

Compute it from the file as served, which is not always the file you
built:

``` r

tmp <- tempfile()
curl::curl_download("https://host.example/wfo-2026-06.vtr", tmp)
digest::digest(tmp, algo = "sha256", file = TRUE)
#> [1] "9f2c8d1e..."
```

Then declare it:

``` r

wfo <- resource(
  name    = "wfo",
  version = "2026-06",
  urls    = c("https://zenodo.invalid/records/1234567/files/wfo-2026-06.vtr",
              "https://github.invalid/gcol33/taxifydb/releases/download/wfo-2026.06/wfo.vtr"),
  sha256  = strrep("9f", 32),
  size    = 797e6,
  license = "CC-BY-4.0",
  description = "World Flora Online backbone, June 2026"
)
format(wfo)
#> [1] "wfo@2026-06  9f9f9f9f9f9f  [CC-BY-4.0]"
```

The version label is the decision worth pausing on. Whatever the old
code called “the current one” now needs a name that will still be right
in two years. Upstream’s own release identifier is the default answer,
and a label that records both identities is better when you are shipping
something you built from upstream:

``` r

format(resource(
  name    = "wfo",
  version = "source-2026-06_build-3",
  urls    = "https://host.invalid/wfo-db-3.vtr",
  sha256  = strrep("ab", 32),
  license = "CC-BY-4.0",
  upstream = list(wfo_release = "2026-06", taxifydb_build = "3")
))
#> [1] "wfo@source-2026-06_build-3  abababababab  [CC-BY-4.0]"
```

## Step 2: assemble and ship the registry

``` r

reg <- registry(
  package  = "taxify",
  resources = list(wfo)
)
reg
#> <getaca registry> taxify  (policy "bundled")
#>   digest: sha256:0c5824f54c6f
#>   - wfo@2026-06  9f9f9f9f9f9f  [CC-BY-4.0]
```

Generate it rather than hand-maintaining it, from a script that stays
out of the built package:

``` r

# data-raw/registry.R
source("data-raw/backbone-records.R")   # returns a list of resource()s
registry_write(
  registry(package = "taxify", resources = records),
  "inst/getaca/registry.rds"
)
```

    # .Rbuildignore
    ^data-raw$

Nothing else is needed to make the package discoverable. `getaca` finds
the file with
[`system.file()`](https://rdrr.io/r/base/system.file.html), so there is
no registration call, no `.onLoad()` hook, and no load-order question.

Add `getaca` to `Imports`. It brings `curl`, with nothing beneath it,
and an R \>= 4.6.0 floor for
[`tools::sha256sum()`](https://rdrr.io/r/tools/sha256sum.html).

## Step 3: rewrite the front door

The package’s own API stays. Users keep calling `install_backbone()`;
what changes is the two hundred lines behind it.

``` r

# R/download.R, after
install_backbone <- function(name = "wfo", force = FALSE) {
  invisible(getaca::getaca(name, package = "taxify", verify = force))
}

backbone_path <- function(name = "wfo") {
  getaca::getaca(name, package = "taxify")
}

backbone_available <- function(name = "wfo") {
  getaca::getaca_available(name, package = "taxify")
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

## Step 4: replace the guards

Every place the old code checked
[`file.exists()`](https://rdrr.io/r/base/files.html) before doing
something expensive becomes one of the three helpers.

In tests:

``` r

# before
test_that("the backbone parses", {
  skip_if(!backbone_available("wfo"), "backbone not installed")
  expect_s3_class(read_backbone(backbone_path("wfo")), "backbone")
})

# after
test_that("the backbone parses", {
  getaca_skip_if_unavailable("wfo", package = "taxify")
  expect_s3_class(read_backbone(getaca("wfo", package = "taxify")), "backbone")
})
```

The skip reason is the difference. The old one says the backbone is not
installed; the new one names the resource, the declaring package, and
the call that would fetch it, which is what someone reading a CI log
from another project needs.

In examples:

``` r

#' @examples
#' path <- getaca_optional("wfo", package = "taxify")
#' if (!is.null(path)) summarise_backbone(path)
```

See
[`vignette("checks")`](https://gillescolling.com/getaca/articles/checks.md)
for the vignette cases and the CI workflow.

## Step 5: retire the version guesswork

The old code had no version, so it had no way to answer “which release
is this”. After the migration, provenance is a call:

``` r

getaca_info("wfo", package = "taxify")
#> <getaca cache entry> taxify/wfo@2026-06
#>   ...
#>   built from  wfo_release: 2026-06
#>   resolved by bundled registry sha256:1c4d7a90f2be (published 2026-07-20)
#>   source url  https://zenodo.invalid/records/1234567/files/wfo-2026-06.vtr
#>   fetched     2026-07-26 11:02:13
#>   verified    2026-07-26 11:09:44 (full re-hash)
```

That is worth surfacing in your own output rather than leaving to users
who know to look. A result object that records the resolved version, and
a citation helper that reads it, turn the migration into a visible
improvement rather than an internal one.

``` r

match_names <- function(x, backbone = "wfo") {
  info <- getaca::getaca_info(backbone, package = "taxify")
  out <- do_the_matching(x, getaca::getaca(backbone, package = "taxify"))
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

**Say so and leave it.** A line in `NEWS.md` and a one-time message
covers it. Users who want the disk back delete the directory themselves,
and anyone with a script that still reads the old path keeps working
until they update it.

**Remove it, once, after telling the user.** The right answer when the
old cache was large, since leaving gigabytes of superseded bytes on disk
costs the user something for nothing.

``` r

.legacy_checked <- new.env(parent = emptyenv())

retire_legacy_cache <- function() {
  if (isTRUE(.legacy_checked$done)) return(invisible(NULL))
  .legacy_checked$done <- TRUE

  old <- tools::R_user_dir("taxify", "cache")
  files <- list.files(old, pattern = "[.]vtr$", full.names = TRUE)
  if (!length(files)) return(invisible(NULL))

  message("taxify now stores backbones through getaca, with a recorded ",
          "version and checksum.\n",
          "The previous downloads at ", old, " are no longer used.\n",
          "Remove them with: unlink(\"", old, "\", recursive = TRUE)")
  invisible(NULL)
}
```

Telling rather than deleting is the safer half of that pattern, and it
is what the code above does. Deleting a user’s files on package upgrade
is a decision worth making explicitly, in a function they call, rather
than as a side effect of loading a namespace.

Whichever you choose, run it once per session rather than on every call.
A flag in a package environment, as above, is enough.

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

- seven classed conditions in place of one
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
