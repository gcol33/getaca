# Transfer and promotion

Bytes land in `.tmp/`, are sized, hashed, and only then moved into the
cache. An interrupted transfer can never appear as a valid cached
resource, and a failed transfer never touches a copy that was already
good.

## Details

The temporary file is named after the declared checksum, so an
interrupted download resumes on the next attempt rather than starting
over. That matters when the resource is measured in gigabytes.
