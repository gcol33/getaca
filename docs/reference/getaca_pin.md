# Freeze current resolution into a pin file

Records, for each named package, the registry state currently in effect.
Under the `"pinned"` policy those records are what resolution uses, so
an analysis keeps resolving the versions it was written against.

## Usage

``` r
getaca_pin(packages, path = pin_file())
```

## Arguments

- packages:

  Character vector of package names.

- path:

  Where to write the pin file.

## Value

`path`, invisibly.
