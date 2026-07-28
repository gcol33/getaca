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

  Report nothing for this call, whatever
  [`getaca_progress()`](https://gillescolling.com/getaca/reference/getaca_progress.md)
  is set to.

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
# Resources are declared by the packages that need them. This one is a zip
# its host would not take whole, uploaded in two pieces and unpacked on
# arrival:
unzipper <- processor("unzip", function(input, output_dir) {
  utils::unzip(input, exdir = output_dir)
  output_dir
})

atlas <- resource("atlas", "1.0",
                  sha256 = strrep("c", 64),
                  size = 1572864,
                  file = "atlas.zip",
                  license = "CC-BY-4.0",
                  parts = list(
                    part("https://example.org/atlas-1.0.zip.001",
                         sha256 = strrep("a", 64), size = 1048576),
                    part("https://example.org/atlas-1.0.zip.002",
                         sha256 = strrep("b", 64), size = 524288)
                  ),
                  processor = unzipper)
atlas

reg <- registry("demo", list(atlas))

# Each piece is fetched and verified on its own, the two are concatenated,
# and the zip is held to the resource's own sha256 before the processor
# sees it. The returned path is the unpacked directory:
# getaca("atlas", registry = reg)

# The raw zip, without unpacking:
# getaca("atlas", registry = reg, processed = FALSE)
```
