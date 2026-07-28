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
