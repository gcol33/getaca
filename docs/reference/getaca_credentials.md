# Which credentials a package expects

Reports the environment variables a package's declaration reads, and
whether each is set in this session. Answers "do I have what I need"
before a fetch rather than during one, without touching the network.

## Usage

``` r
getaca_credentials(package = NULL, registry = NULL)
```

## Arguments

- package:

  Declaring package. Ignored when `registry` is supplied.

- registry:

  A
  [`registry()`](https://gillescolling.com/getaca/reference/registry.md)
  object, for standalone use.

## Value

A data frame with one row per declared variable: `package`, `host`,
`scheme`, `variable`, `set` and `register`. Empty when nothing is
declared.

## Details

Values are never read or shown. `set` says only that the variable holds
something.

## See also

[getaca-auth](https://gillescolling.com/getaca/reference/getaca-auth.md)

## Examples

``` r
reg <- registry("demo",
  auth = list(auth_host("data.example.org", bearer("EXAMPLE_TOKEN"))),
  resources = list(
    resource("example", "1.0",
             urls = "https://data.example.org/example-1.0.csv",
             sha256 = strrep("c", 64))
  ))
getaca_credentials(registry = reg)
```
