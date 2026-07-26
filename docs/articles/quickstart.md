# Quick Start

A package that needs a four-gigabyte taxonomic backbone cannot ship it,
cannot download it during `R CMD check`, and cannot afford to fetch a
different version on Tuesday than it fetched on Monday. `getaca` is the
layer that makes those three constraints compatible.

There is one engine and many declarations. Packages say what they need;
`getaca` gets it.

## Declaring what you need

A resource record names exact bytes. Not a URL, not a dataset in the
abstract: one checksum, one version label, and the places those bytes
can be found.

``` r

wfo <- resource(
  name    = "wfo",
  version = "2026-06",
  urls    = c("https://primary.invalid/wfo-2026-06.zip",
              "https://mirror.invalid/wfo-2026-06.zip"),
  sha256  = strrep("9f", 32),
  size    = 4.1e9,
  licence = "CC-BY-4.0"
)

wfo
#> <getaca resource record>
#>   name      wfo
#>   version   2026-06
#>   sha256    9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f
#>   size      4.1e+09
#>   licence   CC-BY-4.0
#>   urls      https://primary.invalid/wfo-2026-06.zip
#>              https://mirror.invalid/wfo-2026-06.zip
```

Records live in a registry, which is scoped to the declaring package:

``` r

reg <- registry(package = "taxify", resources = list(wfo))
reg
#> <getaca registry> taxify  (revision 1, policy "bundled")
#>   - wfo@2026-06  9f9f9f9f9f9f  [CC-BY-4.0]
```

Ship it where `getaca` looks for it, and there is nothing to register
and no load hook to write:

``` r

registry_write(reg, "inst/getaca/registry.rds")
```

## Getting it

``` r

path <- getaca("wfo", package = "taxify")
```

That path points to a complete file, verified against the declared
checksum, at the requested version, in a cache slot `getaca` owns. What
happens on the way there depends on what is already true:

- cached and intact, the path comes back immediately after a size check

- cached but past the re-verification interval, the bytes are re-hashed
  first

- absent, the mirrors are tried in order, into a temporary file, which
  is hashed before it is moved into place

An interrupted transfer resumes rather than restarting, and can never be
mistaken for a finished resource.

## Identity is a triple

`"wfo"` is not a global name. It resolves to `taxify / wfo / 2026-06`,
and another package may declare its own `"wfo"` without collision.

``` r

format(resource_id("taxify", "wfo", "2026-06"))
#> [1] "taxify/wfo@2026-06"
```

## Surviving R CMD check

Resolution collapses to `offline` under check, whatever policy is set,
so a check run never reaches the network. Three helpers cover the three
places that matters.

In tests, skip cleanly and say what is missing:

``` r

test_that("the backbone parses", {
  getaca_skip_if_unavailable("wfo", package = "taxify")
  expect_s3_class(read_backbone(getaca("wfo", package = "taxify")), "backbone")
})
```

In examples and vignettes, degrade to a message rather than an error:

``` r

path <- getaca_optional("wfo", package = "taxify")
if (!is.null(path)) summarise_backbone(path)
```

And where a plain logical reads better:

``` r

getaca_available("wfo", registry = reg)
#> [1] FALSE
```

To prepare a machine that will later be offline, or a CI job that should
find everything already present:

``` r

getaca_prefetch("wfo", package = "taxify")
```

Setting `GETACA_CACHE` points any session at a cache that has already
been seeded.

## Knowing where a file came from

``` r

getaca_info("wfo", package = "taxify")
#> <getaca cache entry> taxify/wfo@2026-06
#>   path        ~/.cache/R/getaca/taxify/wfo/2026-06/raw/wfo-2026-06.zip
#>   sha256      9f9f9f...
#>   size        4,100,000,000 bytes
#>   licence     CC-BY-4.0
#>   resolved by bundled registry, revision 1
#>   source url  https://primary.invalid/wfo-2026-06.zip
#>   fetched     2026-07-26 11:02:13
#>   verified    2026-07-26 11:09:44 (full re-hash)
#>   checked     2026-07-26 15:31:02 (size and mtime)
```

Four timestamps, kept apart on purpose. “Verified” means the bytes were
re-hashed then, not that somebody looked at the file at some point.

[`getaca_catalogue()`](https://gillescolling.com/getaca/reference/getaca_catalogue.md)
gives the same information for everything cached, as a data frame
suitable for a reproducibility appendix.

## Where things are stored

``` r

getaca_cache_dir()
#> [1] "C:\\Users\\Gilles Colling\\AppData\\Local/R/cache/R/getaca"
```

`tools::R_user_dir("getaca", "cache")` by default, which is what CRAN
policy permits, on the condition that contents are actively managed.
`getaca` treats that as a retention policy rather than a function users
might find, and sweeps after every successful retrieval. See
[`?"getaca-gc"`](https://gillescolling.com/getaca/reference/getaca-gc.md)
for the removal order and what is never touched.
