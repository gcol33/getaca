# The content-addressed store

Bytes live once, under their own digest. A version slot holds a *view*:
a second name for the blob, carrying the readable file name the
declaration implies. Two packages declaring the same file therefore
store it once and, because the acquisition lock keys on the digest,
download it once.

## Details

    <cache>/blobs/sha256/<aa>/<sha256>

The store keeps no metadata. A blob's name is its digest, which is the
only fact about a blob worth recording; liveness is derived from the
package indexes and integrity by hashing. There is no reference count to
drift out of step with the indexes it would be summarising.
