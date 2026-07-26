# getaca

*external data your package depends on, pinned to exact bytes*

[![R-CMD-check](https://github.com/gcol33/getaca/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/gcol33/getaca/actions/workflows/R-CMD-check.yaml)
[![Codecov test
coverage](https://codecov.io/gh/gcol33/getaca/graph/badge.svg)](https://app.codecov.io/gh/gcol33/getaca)
[![License:
MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**Depend on gigabytes of external data without breaking reproducibility,
offline use, or `R CMD check`.**

Packages declare resources. `getaca` retrieves them. A declaration names
exact bytes: one SHA-256, one version label, one or more mirrors.
Retrieval resolves that declaration through an explicit policy, verifies
what arrives, records where it came from, and returns an ordinary local
path. There is one engine and many declarations, the way there is one
`renv` and many lockfiles.

``` r

library(getaca)

# what a package ships, at inst/getaca/registry.rds
registry(
  package = "taxify",
  resources = list(
    resource("wfo", "2026-06",
             urls = c("https://primary/wfo-2026-06.zip",
                      "https://mirror/wfo-2026-06.zip"),
             sha256 = "9f2c...",
             size = 4.1e9,
             license = "CC-BY-4.0")
  )
)

# what retrieval looks like, from anywhere
path <- getaca("wfo", package = "taxify")
```

## Pinned, not merely downloaded

[`download.file()`](https://rdrr.io/r/utils/download.file.html) gives
you whatever is at the URL today. `getaca` gives you the bytes the
package was built against, or an error naming who can fix it.

Six failures that look identical to a plain downloader get six different
answers, each classed so callers can branch on the cause:

| Condition | Meaning | Who acts |
|----|----|----|
| `getaca_error_unavailable` | no mirror answered | user |
| `getaca_error_offline` | not cached, network not permitted here | user |
| `getaca_error_incomplete` | transfer ended short | user |
| `getaca_error_upstream_changed` | publisher replaced a published version | upstream |
| `getaca_error_cache_corrupt` | local copy drifted from its own record | user |
| `getaca_error_declaration` | every mirror agrees, the registry disagrees | author |

The last one is the interesting case. When several independent mirrors
return identical bytes and none match the declared checksum, the
registry is the likely error, and `getaca` says so rather than blaming
the network.

Each condition carries an `actor` field, so a declaring package can
catch the ones its users will meet and answer in its own vocabulary:

``` r

install_backbone <- function(name = "wfo") {
  path <- tryCatch(
    getaca(name, package = "taxify"),
    getaca_error_unavailable = function(e) {
      stop("The WFO backbone is not installed and no network is available.\n",
           "Connect, then run: taxify::install_backbone(\"wfo\")", call. = FALSE)
    }
  )
  open_backbone(path)
}
```

## Passing `R CMD check` with a 4 GB dependency

Resolution collapses to `offline` under `R CMD check`, whatever policy
is set. Three helpers cover the three contexts CRAN cares about:

``` r

# in tests
test_that("backbone parses", {
  getaca_skip_if_unavailable("wfo", package = "taxify")
  expect_s3_class(read_backbone(getaca("wfo", package = "taxify")), "backbone")
})

# in examples and vignettes
path <- getaca_optional("wfo", package = "taxify")
if (!is.null(path)) summarise_backbone(path)

# anywhere a plain logical is easier
if (getaca_available("wfo", package = "taxify")) { }
```

Point `GETACA_CACHE` at a pre-seeded directory and a CI job finds
everything already there. The cache is a plain directory tree, so the
usual actions cache it by key:

``` yaml
- uses: actions/cache@v4
  with:
    path: ~/.cache/getaca
    key: getaca-${{ hashFiles('inst/getaca/registry.rds') }}
- run: Rscript -e 'getaca::getaca_prefetch(package = "taxify")'
  env:
    GETACA_CACHE: ~/.cache/getaca
```

Keying the cache on the registry file means a new declaration downloads
once and every later job reuses it.

## Immutable records, mutable channels

Two things that must not be conflated. A **resource record** is
immutable: `taxify / wfo / 2026-06` names exact bytes forever. A
**channel** maps the logical name onto one record, and channels move.

| Policy | Resolves through | Use when |
|----|----|----|
| `bundled` | the registry shipped with the package | default; same install, same bytes |
| `current` | author’s remote registry, falling back to bundled | mirrors need repair, or data releases outpace CRAN |
| `pinned` | a frozen local snapshot | an analysis must keep resolving what it was written against |
| `offline` | cached and bundled information only | no network permitted |

A remote channel may repair a dead mirror and may publish `2026-09`. It
may never redefine what `2026-06` means; `getaca` rejects that as an
invalid registry rather than accepting a silent substitution.

Which record the channel points at is stated in the registry, because
version strings here are labels rather than semantic versions and
`source-2026-06_build-3` has no defensible ordering:

``` r

registry(
  package = "taxify",
  current = c(wfo = "2026-09"),
  resources = list(
    resource("wfo", "2026-06", urls = "...", sha256 = "..."),
    resource("wfo", "2026-09", urls = "...", sha256 = "...")
  )
)
```

A name offering several versions and naming no head is refused as an
invalid registry. That turns the one mistake this design is exposed to,
appending `2026-03` below `2026-09` and moving every user backwards,
into an error at
[`registry()`](https://gillescolling.com/getaca/reference/registry.md)
on the author’s machine.

## A worked case

A taxonomic name matcher resolves species names against reference
backbones. The backbones are published on their own schedule and run to
[797 MB for WFO, 1.9 GB for GBIF, and 2.0 GB for
COL](https://github.com/gcol33/taxify), so the package cannot ship them,
cannot download them during a check run, and cannot afford to fetch
different bytes on Tuesday than it fetched on Monday. That is the case
`getaca` was designed against; what follows is what declaring those
backbones through it looks like.

The declaring package ships a declaration and nothing large:

``` r

# data-raw/registry.R, run at build time
registry_write(
  registry(
    package  = "taxify",
    policy   = "current",
    remote   = "https://gcol33.github.io/taxify/getaca-registry.rds",
    current  = c(wfo = "2026-06"),
    resources = list(
      resource("wfo", "2026-06",
               urls = c("https://zenodo.org/records/1234567/files/wfo-2026-06.vtr",
                        "https://github.com/gcol33/taxifydb/releases/download/wfo-2026.06/wfo.vtr"),
               sha256 = "9f2c...",
               size   = 797e6,
               license = "CC-BY-4.0",
               upstream = list(wfo_release = "2026-06", taxifydb_build = "3"))
    )
  ),
  "inst/getaca/registry.rds"
)
```

Installing the package downloads nothing. The first real call retrieves,
verifies and caches:

``` r

path <- getaca("wfo", package = "taxify")
```

What each part of the declaration buys:

- **two mirrors** mean a Zenodo outage falls through to the GitHub
  release
- **`sha256`** means a truncated or substituted file is an error rather
  than a parse failure three functions later
- **`upstream`** keeps both identities, the WFO release and the build
  that turned it into a queryable file, so provenance answers which one
  moved
- **`policy = "current"`** lets a dead mirror be repaired, or `2026-09`
  published, without a CRAN release
- **`current`** states which of the published versions a bare
  `getaca("wfo")` returns

When WFO publishes `2026-09`, the remote registry adds the record and
moves the head. When WFO replaces `2026-06` in place, the checksum stops
matching, the cached copy is left alone, and the error names the
publisher as the party who changed something.

## What the cached path guarantees

[`getaca()`](https://gillescolling.com/getaca/reference/getaca.md)
returns a path to a complete file, verified against the declared
checksum, at the resolved version, in a slot `getaca` owns.

Bytes land in `.tmp/`, are sized, hashed, and only then moved into the
cache, so an interrupted transfer can never appear as a valid cached
resource and a failed transfer never touches a copy that was already
good. The temporary file is named after the declared checksum, so an
interrupted download resumes on the next attempt. Each mirror gets its
own temporary file, because a partial transfer is resumable only against
the mirror that produced it.

Verification asks three questions and keeps the answers apart:

|  | when | recorded as |
|----|----|----|
| full re-hash | on download, on `verify = TRUE`, and every `getaca.verify_days` | `verified_at` |
| size check | on ordinary access | `checked_at` |
| use | on ordinary access | `accessed_at` |

“Verified” therefore means the bytes were re-hashed then, rather than
that somebody looked at the file at some point.

Locking is in the first version. Two sessions asking for the same 4 GB
file wait on a portable directory mutex, and the second observes the
first’s success instead of downloading again. A lock whose holder died
goes stale and is taken over.

## Provenance, and what is cached

``` r

getaca_info("wfo", package = "taxify")
#> <getaca cache entry> taxify/wfo@2026-06
#>   path        ~/.cache/R/getaca/taxify/wfo/2026-06/raw/wfo-2026-06.vtr
#>   sha256      9f2c8d1e...
#>   size        797,000,000 bytes
#>   license     CC-BY-4.0
#>   built from  wfo_release: 2026-06
#>   built from  taxifydb_build: 3
#>   resolved by current registry, revision 7
#>   source url  https://zenodo.org/records/1234567/files/wfo-2026-06.vtr
#>   fetched     2026-07-26 11:02:13
#>   verified    2026-07-26 11:09:44 (full re-hash)
#>   checked     2026-07-26 15:31:02 (size and mtime)
```

That is a reproducibility appendix, and a bug report that says which
mirror served the bytes and which registry revision chose them.

[`getaca_catalogue()`](https://gillescolling.com/getaca/reference/getaca_catalogue.md)
widens it to a data frame covering both halves, every resource the
installed packages declare and every copy the cache holds:

``` r

getaca_catalogue()[, c("package", "name", "version", "current", "declared", "cached")]
#>   package name version current declared cached
#> 1  taxify  wfo 2026-06    TRUE     TRUE   TRUE
#> 2  taxify  wfo 2026-03   FALSE    FALSE   TRUE
#> 3  taxify  col 2026-06    TRUE     TRUE  FALSE
```

Row 2 is a copy of a version nothing asks for any more, which is what
the retention sweeps reclaim first. Row 3 is work still to do on this
machine.

## Processors

A processor turns one verified path into another: unpacking an archive,
or preparing a package-specific layout. It carries an id, so the
processed result gets its own cache slot and its own provenance.

``` r

resource("wfo", "2026-06",
         urls = "https://example.org/wfo-2026-06.zip",
         sha256 = "9f2c...",
         processor = processor("unzip", function(input, output_dir) {
           utils::unzip(input, exdir = output_dir)
           output_dir
         }))
```

Changing what the transformation does means changing the id, which
invalidates previously processed copies.
`getaca(..., processed = FALSE)` returns the raw artefact. `getaca`
knows nothing about file formats and never reads data.

## Cache management is not optional

CRAN permits
[`tools::R_user_dir()`](https://rdrr.io/r/tools/userdir.html) on
condition that contents are “actively managed (including removing
outdated material)”. `getaca` reads that as a retention policy rather
than a function users might discover, and collects after every
successful retrieval.

Removal runs cheapest and safest first: broken material, abandoned
transfers, superseded versions past their retention window, then
least-recently-used entries only when over the size ceiling. Superseded
and not-recently-used age on separate clocks, so an expensive resource
is never dropped merely for being old. Pinned entries, the version the
bundled registry names, and anything under an active lock are never
touched.

``` r

getaca_clean(dry_run = TRUE)      # what would go, and why
getaca_keep("wfo", package = "taxify")   # exempt this one permanently
options(getaca.max_bytes = 50 * 1024^3)  # raise the ceiling
```

## getaca or a companion data package?

|  | companion data package | `getaca` |
|----|----|----|
| Size | fits a repository | too large to bundle |
| Release cadence | coupled to code releases | independent of them |
| Shape | naturally R objects | any file, any format |
| Granularity | all of it, always | users take what they need |
| License | redistribution permitted | download permitted, redistribution discouraged |

A companion package can itself use `getaca`, but that is rarely the
first recommendation: it moves the complexity rather than removing it.

## Related work

Two established packages solve neighbouring problems, and either may be
the better fit depending on which problem you have.

[**pins**](https://cran.r-project.org/package=pins) publishes “data
sets, models, and other R objects, making it easy to share them across
projects and with your colleagues”, across boards including local
folders, Posit Connect and AWS S3. It is built around the person sharing
an artefact and the board it lives on.

[**BiocFileCache**](https://bioconductor.org/packages/BiocFileCache)
“creates a persistent on-disk cache of files that the user can add,
update, and retrieve”, for resources that are costly to create or
fetched from the web, backed by an SQLite metadata database.

`getaca` is built around a package declaring what it needs: identity is
`package / name / version`, the declaration ships inside the installed
package, and resolution, verification, offline behaviour and retention
are the same for every declaring package because there is one engine.

## Dependencies

`Imports: curl, digest`. Recursive footprint outside base R: **zero
packages**. `curl` has no dependencies; `digest` has none beyond
`utils`. YAML and JSON registries, testthat helpers and vignettes live
in `Suggests` and are gated at call time.

[`tools::sha256sum()`](https://rdrr.io/r/tools/sha256sum.html) would
remove `digest` entirely, but it arrived in R 4.6.0 and this package
supports R 4.0.

## What’s in the box

- **[`getaca()`](https://gillescolling.com/getaca/reference/getaca.md)**
  retrieve a declared resource, return a local path
- **[`resource()`](https://gillescolling.com/getaca/reference/resource.md)**
  declare one immutable record
- **[`registry()`](https://gillescolling.com/getaca/reference/registry.md)**
  collect a package’s declarations and name the channel head
- **[`registry_write()`](https://gillescolling.com/getaca/reference/registry_write.md)**
  ship them at `inst/getaca/registry.rds`
- **[`as_registry()`](https://gillescolling.com/getaca/reference/as_registry.md)**
  build one from a YAML or JSON authoring file
- **[`processor()`](https://gillescolling.com/getaca/reference/processor.md)**
  declare a post-verification transformation
- **[`getaca_info()`](https://gillescolling.com/getaca/reference/getaca_info.md)**
  full provenance for a cached resource
- **[`getaca_catalogue()`](https://gillescolling.com/getaca/reference/getaca_catalogue.md)**
  what is declared, what is current, what is cached
- **[`getaca_refresh()`](https://gillescolling.com/getaca/reference/getaca_refresh.md)**
  forget cached registry state within a session
- **[`getaca_prefetch()`](https://gillescolling.com/getaca/reference/getaca_prefetch.md)**
  warm a cache before going offline
- **[`getaca_pin()`](https://gillescolling.com/getaca/reference/getaca_pin.md)**
  freeze current resolution into a pin file
- **[`getaca_keep()`](https://gillescolling.com/getaca/reference/getaca_keep.md)**
  exempt a resource from collection
- **[`getaca_clean()`](https://gillescolling.com/getaca/reference/getaca-gc.md)**
  run the retention sweeps by hand
- **[`getaca_available()`](https://gillescolling.com/getaca/reference/getaca-checks.md)**,
  **[`getaca_optional()`](https://gillescolling.com/getaca/reference/getaca-checks.md)**,
  **[`getaca_skip_if_unavailable()`](https://gillescolling.com/getaca/reference/getaca-checks.md)**
  check-safe access
- **[`getaca_policy()`](https://gillescolling.com/getaca/reference/getaca_policy.md)**,
  **[`getaca_cache_dir()`](https://gillescolling.com/getaca/reference/getaca_cache_dir.md)**
  settings

## Installation

``` r

install.packages("pak")
pak::pak("gcol33/getaca")
```

## Documentation

- [Quick
  start](https://gillescolling.com/getaca/articles/quickstart.html)
- [Declaring
  resources](https://gillescolling.com/getaca/articles/declaring.html)
- [Policies and
  channels](https://gillescolling.com/getaca/articles/policies.html)
- [Surviving R CMD check and
  CI](https://gillescolling.com/getaca/articles/checks.html)
- [The cache](https://gillescolling.com/getaca/articles/cache.html)
- [Handling
  failures](https://gillescolling.com/getaca/articles/failures.html)
- [Migrating an existing
  downloader](https://gillescolling.com/getaca/articles/migrating.html)
- [Choosing between getaca and the
  alternatives](https://gillescolling.com/getaca/articles/alternatives.html)
- [Function
  reference](https://gillescolling.com/getaca/reference/index.html)

## Support

> “Software is like sex: it’s better when it’s free.” — Linus Torvalds

I’m a PhD student who builds R packages in my free time because I
believe good tools should be free and open. I started these projects for
my own work and figured others might find them useful too.

If this package saved you some time, buying me a coffee is a nice way to
say thanks. It helps with my coffee addiction.

[![Buy Me A
Coffee](https://img.shields.io/badge/-Buy%20me%20a%20coffee-FFDD00?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/gcol33)

## License

MIT (see the LICENSE.md file)

## Citation

``` bibtex
@software{getaca,
  author = {Colling, Gilles},
  title = {getaca: Reproducible External Data Dependencies for R Packages},
  year = {2026},
  url = {https://github.com/gcol33/getaca}
}
```
