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
             licence = "CC-BY-4.0")
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
everything already there.

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

## What’s in the box

- **[`getaca()`](https://gillescolling.com/getaca/reference/getaca.md)**
  retrieve a declared resource, return a local path
- **[`resource()`](https://gillescolling.com/getaca/reference/resource.md)**
  declare one immutable record
- **[`registry()`](https://gillescolling.com/getaca/reference/registry.md)**
  collect a package’s declarations
- **[`registry_write()`](https://gillescolling.com/getaca/reference/registry_write.md)**
  ship them at `inst/getaca/registry.rds`
- **[`processor()`](https://gillescolling.com/getaca/reference/processor.md)**
  declare a post-verification transformation
- **[`getaca_info()`](https://gillescolling.com/getaca/reference/getaca_info.md)**
  full provenance for a cached resource
- **[`getaca_catalogue()`](https://gillescolling.com/getaca/reference/getaca_catalogue.md)**
  what is declared, what is cached
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

Locking is in the first version, not a later refinement. Two sessions
asking for the same 4 GB file wait on a portable directory mutex; the
second observes the first’s success instead of downloading again.

## getaca or a companion data package?

|  | companion data package | `getaca` |
|----|----|----|
| Size | fits a repository | too large to bundle |
| Release cadence | coupled to code releases | independent of them |
| Shape | naturally R objects | any file, any format |
| Granularity | all of it, always | users take what they need |
| Licence | redistribution permitted | download permitted, redistribution discouraged |

A companion package can itself use `getaca`, but that is rarely the
first recommendation: it moves the complexity rather than removing it.

## Dependencies

`Imports: curl, digest`. Recursive footprint outside base R: **zero
packages**. `curl` has no dependencies; `digest` has none beyond
`utils`. YAML and JSON registries, testthat helpers and vignettes live
in `Suggests` and are gated at call time.

[`tools::sha256sum()`](https://rdrr.io/r/tools/sha256sum.html) would
remove `digest` entirely, but it arrived in R 4.6.0 and this package
supports R 4.0.

## Installation

``` r

install.packages("pak")
pak::pak("gcol33/getaca")
```

## Documentation

- [Quick
  Start](https://gillescolling.com/getaca/articles/quickstart.html)
- [Declaring
  Resources](https://gillescolling.com/getaca/articles/declaring.html)
- [Function
  Reference](https://gillescolling.com/getaca/reference/index.html)

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
