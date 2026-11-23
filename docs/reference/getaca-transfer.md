# Transfer and promotion

Bytes land in `.tmp/`, are sized, hashed, and only then moved into the
cache. An interrupted transfer can never appear as a valid cached
resource, and a failed transfer never touches a copy that was already
good.

## Details

The temporary file is named after the declared checksum, so an
interrupted download resumes on the next attempt rather than starting
over. That matters when the resource is measured in gigabytes.

getaca drives the transfer itself, over the curl multi interface, rather
than handing a URL to a function that returns when it is done. What that
buys is the response status before the first byte is written, and a
count of the bytes as they arrive. The first decides where they go; the
second is what
[getaca-progress](https://gillescolling.com/getaca/reference/getaca-progress.md)
reports.

## When a transfer is given up on

A transfer is given up on for standing still, never for taking long. A
connection that takes longer than `getaca.connect_seconds`, 30 by
default, to open, or that delivers nothing for `getaca.stall_seconds`,
60 by default, is dropped. One that keeps delivering runs for as long as
the file takes. `getaca.timeout` limits a whole transfer, in seconds,
and is off unless set.

A connection that dropped after delivering bytes is resumed on the same
mirror, for as long as each attempt gets further. A mirror that answers
that it is busy (HTTP 408, 429, 500, 502, 503 or 504) is asked again
after a wait that doubles from two seconds, or after the interval its
`Retry-After` header names, and never after more than a minute. Attempts
that move nothing are counted against `getaca.retries`, 3 by default,
after which the next mirror is tried. A mirror that never answered, or
answered that the file is not there, is not asked twice.

## Several files at once

The parts of a series, and the resources of one
[`getaca_prefetch()`](https://gillescolling.com/getaca/reference/getaca_prefetch.md)
call, share up to `getaca.connections` connections, 4 by default. A file
two of them name is transferred once.

Each setting is also read from an environment variable,
`GETACA_STALL_SECONDS` for `getaca.stall_seconds` and so on, when the
option is unset.
