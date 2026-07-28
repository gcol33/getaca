# Declare how parts are combined

A combiner turns the verified
[`part()`](https://gillescolling.com/getaca/reference/part.md)s of a
resource, in declaration order, into the single artefact the resource
names. Concatenation is the default and needs no declaration; a combiner
is what a delta format calls for, since applying a patch is knowledge
about a file format and getaca has none.

## Usage

``` r
combiner(id, fn)
```

## Arguments

- id:

  Short stable identifier for this transformation, for example
  `"bsdiff"`.

- fn:

  A function `(parts, output)`, where `parts` is a character vector of
  verified local paths in declaration order and `output` is the file to
  write. The return value is ignored.

## Value

An object of class `getaca_combiner`.

## Details

The result is held to the resource's own SHA-256 like any other bytes,
so a combiner cannot produce something other than what the declaration
promises. That is also why the manifest records a combiner by `id`
alone: the checksum says the result is right, and the identifier only
says what to run.

## See also

[`part()`](https://gillescolling.com/getaca/reference/part.md)

## Examples

``` r
combiner("bsdiff", function(parts, output) {
  # apply parts[-1] to parts[1], writing the result to output
  file.copy(parts[1], output)
})
```
