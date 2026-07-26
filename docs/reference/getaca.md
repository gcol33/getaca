# Get a declared external resource

The single retrieval verb. Packages declare resources; getaca retrieves
them. Returns an ordinary local path, always: getaca never reads data
and knows nothing about file formats.

## Usage

``` r
getaca(
  name,
  package = NULL,
  registry = NULL,
  version = NULL,
  policy = NULL,
  verify = FALSE,
  processed = TRUE,
  quiet = FALSE
)
```

## Arguments

- name:

  Resource name as declared by `package`.

- package:

  Declaring package. The resource identity is
  `package / name / version`, so two packages declaring the same name
  never collide.

- registry:

  A
  [`registry()`](https://gillescolling.com/getaca/reference/registry.md)
  object, for standalone use without a declaring package.

- version:

  Explicit version, bypassing channel resolution. Use this to hold an
  analysis to one release.

- policy:

  Resolution policy for this call. Defaults to
  [`getaca_policy()`](https://gillescolling.com/getaca/reference/getaca_policy.md).

- verify:

  Force a full re-hash of the cached copy before returning it. Ordinary
  access performs a cheap size check and re-hashes on a schedule.

- processed:

  Apply the declared
  [`processor()`](https://gillescolling.com/getaca/reference/processor.md),
  when there is one, and return the processed path. `FALSE` returns the
  raw artefact.

- quiet:

  Suppress progress reporting.

## Value

A local file or directory path.

## Details

The returned path is guaranteed to be a complete file, verified against
the declared SHA-256, at the requested version, in a cache slot getaca
owns and tracks.

## See also

[`getaca_available()`](https://gillescolling.com/getaca/reference/getaca-checks.md)
to test without downloading,
[`getaca_info()`](https://gillescolling.com/getaca/reference/getaca_info.md)
for provenance,
[`getaca_clean()`](https://gillescolling.com/getaca/reference/getaca-gc.md)
for cache management.

## Examples

``` r
# Resources are declared by the packages that need them:
reg <- registry("demo", list(
  resource("example", "1.0",
           urls = "https://example.org/example-1.0.csv",
           sha256 = strrep("c", 64))
))
reg

# getaca("example", registry = reg)   # would download and verify
```
