# Cache layout

Everything is scoped by declaring package, then resource name, then
version. Two packages that happen to declare the same resource name
never share a slot, and a version can never be silently overwritten by
another.

## Details

    <cache>/
      .locks/                        per-resource locks
      .tmp/                          in-flight downloads, never visible as cache
      <package>/
        index.rds                    provenance for this package only
        <name>/<version>/
          raw/<file>                 verified bytes as served
          proc-<processor-id>/       processed result, own provenance
