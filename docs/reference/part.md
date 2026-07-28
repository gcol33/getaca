# Declare one part of a resource

A part names bytes that are a piece of an artefact rather than the
artefact: a chunk of a file split for a host with an upload limit, or a
base release and a delta issued against it. Parts are retrieved and
verified individually and then combined, in declaration order, into the
file
[`resource()`](https://gillescolling.com/getaca/reference/resource.md)
names.

## Usage

``` r
part(urls, sha256, size = NA_real_)
```

## Arguments

- urls:

  Character vector of download locations for this part, tried in order.
  All must be `https://`.

- sha256:

  Lowercase hex SHA-256 of this part as served.

- size:

  Expected size in bytes, or `NA`. Used to detect a truncated transfer
  before hashing.

## Value

An object of class `getaca_part`.

## Details

Each part carries its own checksum and is stored under it, so a base
shared by every version of a resource is transferred once and kept once
however many versions declare it. Publishing a new version then costs
its consumers the delta rather than the whole file.

Parts describe how the bytes arrive. A declaration may re-split an
artefact, add mirrors for a piece or drop one, the same way it may
repair a mirror list, because what a version means is fixed by the
resource's own `sha256` and checked against it after composition.

## See also

[`resource()`](https://gillescolling.com/getaca/reference/resource.md),
and
[`combiner()`](https://gillescolling.com/getaca/reference/combiner.md)
for parts that are not simply concatenated.

## Examples

``` r
part("https://example.org/wfo-base.bin", sha256 = strrep("c", 64),
     size = 1048576)
```
