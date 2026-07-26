# Resolve a name to an immutable resource record

Separates the two things that must not be conflated: an immutable
resource record, and the mutable channel that maps a logical name onto
one. This function walks the channel; everything downstream deals only
in records.

## Usage

``` r
resolve_resource(
  name,
  package = NULL,
  registry = NULL,
  policy = NULL,
  version = NULL
)
```

## Arguments

- name:

  Resource name.

- package:

  Declaring package. Ignored when `registry` is supplied.

- registry:

  A
  [`registry()`](https://gillescolling.com/getaca/reference/registry.md)
  object, for standalone use.

- policy:

  Resolution policy, defaulting to
  [`getaca_policy()`](https://gillescolling.com/getaca/reference/getaca_policy.md).

- version:

  Optional explicit version, bypassing channel resolution.

## Value

A list with `id`, `record`, `policy`, `source` and `revision`. `policy`
is the one actually in force, after the argument, the session setting,
the registry default and the check clamp have been resolved.
