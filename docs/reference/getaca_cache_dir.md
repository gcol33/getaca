# Where getaca stores things

Uses `tools::R_user_dir("getaca", "cache")` as CRAN policy requires,
unless overridden by the `getaca.cache` option or the `GETACA_CACHE`
environment variable. Setting `GETACA_CACHE` is the supported way to
point a CI job or a check run at a pre-seeded cache.

## Usage

``` r
getaca_cache_dir()
```

## Value

A directory path. Not created as a side effect of asking.

## Examples

``` r
getaca_cache_dir()
```
