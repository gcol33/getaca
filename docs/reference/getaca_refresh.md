# Forget cached registry state

Registries are read once per session: the one a package ships is cached
after the first
[`system.file()`](https://rdrr.io/r/base/system.file.html) lookup, and a
remote registry is cached after the first fetch. Call this after
installing a new version of a declaring package, or to make the
`"current"` policy consult the remote again within the same session.

## Usage

``` r
getaca_refresh()
```

## Value

`NULL`, invisibly.

## Details

Cached *resources* are untouched. This forgets declarations, not data.

## Examples

``` r
getaca_refresh()
```
