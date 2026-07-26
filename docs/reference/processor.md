# Declare a post-download processor

A processor turns one verified path into another path: unpacking an
archive, or preparing a package-specific layout. It carries an `id` so
the processed result gets its own cache slot and its own provenance,
rather than being confused with the raw artefact it came from.

## Usage

``` r
processor(id, fn)
```

## Arguments

- id:

  Short stable identifier for this transformation, for example `"unzip"`
  or `"unzip-v2"`. Changing the transformation means changing the id,
  which invalidates previously processed copies.

- fn:

  A function `(input, output_dir)` returning a path inside `output_dir`.

## Value

An object of class `getaca_processor`.

## Details

getaca knows nothing about file formats. It never reads data.

## Examples

``` r
unzipper <- processor("unzip", function(input, output_dir) {
  utils::unzip(input, exdir = output_dir)
  output_dir
})
```
