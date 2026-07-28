# Choose how transfers report progress

Reports or sets the progress style for the current session. The default,
`"auto"`, draws a bar when the session is interactive and reports
nothing when it is not, which keeps a log or a CI transcript clean
without asking.

## Usage

``` r
getaca_progress(progress = NULL)
```

## Arguments

- progress:

  A style name, a
  [`reporter()`](https://gillescolling.com/getaca/reference/reporter.md),
  or `NULL` to query without setting.

## Value

The reporter in effect, invisibly when setting.

## Details

`quiet = TRUE` on an individual
[`getaca()`](https://gillescolling.com/getaca/reference/getaca.md) call
overrides whatever is set here, so one silent call never needs the
session changed and put back.

## Styles

- `"auto"`:

  A bar when interactive, nothing otherwise. The default.

- `"bar"`:

  A single line that redraws in place, with the share transferred, the
  rate and an estimate of what is left. Falls back to bytes and a rate
  where the registry declares no size.

- `"line"`:

  One line when a transfer starts and one when it ends. What a CI log or
  a [`sink()`](https://rdrr.io/r/base/sink.html)ed script wants, where a
  redrawing bar leaves thousands of fragments.

- `"none"`:

  Nothing at all.

## See also

[`reporter()`](https://gillescolling.com/getaca/reference/reporter.md)
to write your own, and
[getaca-progress](https://gillescolling.com/getaca/reference/getaca-progress.md)
for the events one receives.

## Examples

``` r
getaca_progress()

# A reporter of your own: one line per completed transfer, and nothing
# while it runs.
logger <- reporter("log", function(event) {
  if (identical(event$type, "end") && identical(event$status, "ok")) {
    message(format(event$id), " retrieved (", event$bytes, " bytes)")
  }
})
logger

# getaca_progress(logger)
# getaca_progress("line")
```
