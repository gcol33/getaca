# Unpack an archive or a compressed file

A stock
[`processor()`](https://gillescolling.com/getaca/reference/processor.md)
for the transformation almost every declaration of an archive wants:
extract it, once, into its own cache slot.
[`getaca()`](https://gillescolling.com/getaca/reference/getaca.md) then
returns the unpacked directory, and `processed = FALSE` still returns
the archive it was built from.

## Usage

``` r
unpack(format = c("auto", "zip", "tar", "gzip", "bzip2", "xz"), members = NULL)
```

## Arguments

- format:

  One of `"auto"`, `"zip"`, `"tar"`, `"gzip"`, `"bzip2"` or `"xz"`.
  `"tar"` covers the compressed tarballs; `"gzip"`, `"bzip2"` and `"xz"`
  are for a single compressed file.

- members:

  Optional character vector of paths inside the archive to extract,
  instead of all of it. A name that ends a directory extracts everything
  under it. A name matching nothing in the archive is an error. Not
  applicable to a single compressed file.

## Value

An object of class `getaca_processor`, for `resource(processor = )`.

## Details

`format = "auto"` reads the format from the cached file's name: `.zip`;
`.tar`, `.tar.gz`, `.tgz`, `.tar.bz2`, `.tbz2`, `.tar.xz` and `.txz`;
and the single-file compressions `.gz`, `.bz2` and `.xz`. Name the
format instead for an archive whose file name does not carry one.

A compressed single file is written under its own name with the
compression extension removed, so `backbone-2026-06.csv.gz` unpacks to
`backbone-2026-06.csv`. Archives keep the layout they were packed with.

The id encodes the settings, because the id is what the cache slot and
the registry manifest are keyed on: `unpack()` is `"unpack"`,
`unpack("zip")` is `"unpack-zip"`, and naming `members` appends a digest
of them. Two records asking for different subsets therefore cannot land
in one slot.

## See also

[`processor()`](https://gillescolling.com/getaca/reference/processor.md)
to write your own,
[`resource()`](https://gillescolling.com/getaca/reference/resource.md)
to attach one.

## Examples

``` r
unpack()
unpack("zip")$id
unpack("zip", members = "backbone/names.csv")$id

resource("backbone", "2026-06",
         urls      = "https://example.org/backbone-2026-06.zip",
         sha256    = strrep("9f", 32),
         processor = unpack())
```
