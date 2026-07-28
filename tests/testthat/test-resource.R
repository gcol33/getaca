test_that("resource identity is the package/name/version triple", {
  id <- resource_id("taxify", "wfo", "2026-06")
  expect_equal(format(id), "taxify/wfo@2026-06")
  expect_s3_class(id, "getaca_id")
})

test_that("a resource declaration requires a real SHA-256", {
  expect_error(
    resource("res", "1.0", urls = "https://e.org/f", sha256 = "abc"),
    class = "getaca_error_invalid_registry"
  )
  expect_error(
    resource("res", "1.0", urls = "https://e.org/f", sha256 = strrep("Z", 64)),
    class = "getaca_error_invalid_registry"
  )
})

test_that("checksums are stored lowercase whatever the author typed", {
  rec <- resource("res", "1.0", urls = "https://e.org/f", sha256 = strrep("A", 64))
  expect_equal(rec$sha256, strrep("a", 64))
})

test_that("insecure and missing transports are refused", {
  expect_error(
    resource("res", "1.0", urls = "http://e.org/f", sha256 = strrep("a", 64)),
    class = "getaca_error_invalid_registry"
  )
  expect_error(
    resource("res", "1.0", urls = character(), sha256 = strrep("a", 64)),
    class = "getaca_error_invalid_registry"
  )
})

test_that("names and versions must be usable as directory names", {
  expect_error(
    resource("res/../etc", "1.0", urls = "https://e.org/f", sha256 = strrep("a", 64)),
    class = "getaca_error_invalid_registry"
  )
  expect_error(
    resource("res", "1.0/../2.0", urls = "https://e.org/f", sha256 = strrep("a", 64)),
    class = "getaca_error_invalid_registry"
  )
})

test_that("a derived artefact records what it was built from", {
  rec <- resource(
    "wfo-db", "source-2026-06_build-3",
    urls = "https://e.org/f", sha256 = strrep("a", 64),
    upstream = list(wfo_release = "2026-06", taxifydb_build = "3")
  )
  expect_equal(rec$upstream$wfo_release, "2026-06")
  expect_output(print(rec), "built from")
})

test_that("a DOI is stored bare, however it was written down", {
  bare <- resource("res", "1.0", urls = "https://e.org/f", sha256 = strrep("a", 64),
                   doi = "10.5281/zenodo.1234567")
  expect_equal(bare$doi, "10.5281/zenodo.1234567")

  for (written in c("doi:10.5281/zenodo.1234567",
                    "https://doi.org/10.5281/zenodo.1234567",
                    "http://dx.doi.org/10.5281/zenodo.1234567")) {
    rec <- resource("res", "1.0", urls = "https://e.org/f",
                    sha256 = strrep("a", 64), doi = written)
    expect_equal(rec$doi, "10.5281/zenodo.1234567")
  }

  expect_null(resource("res", "1.0", urls = "https://e.org/f",
                       sha256 = strrep("a", 64))$doi)
  expect_output(print(bare), "10.5281/zenodo.1234567", fixed = TRUE)
})

test_that("something that is not a DOI is refused", {
  expect_error(
    resource("res", "1.0", urls = "https://e.org/f", sha256 = strrep("a", 64),
             doi = "zenodo.1234567"),
    class = "getaca_error_invalid_registry"
  )
  expect_error(
    resource("res", "1.0", urls = "https://e.org/f", sha256 = strrep("a", 64),
             doi = "10.5281/zenodo 1234567"),
    class = "getaca_error_invalid_registry"
  )
})

test_that("a DOI is provenance rather than a route", {
  rec <- resource("res", "1.0", urls = "https://e.org/f", sha256 = strrep("a", 64),
                  doi = "10.5281/zenodo.1234567")

  # Nothing downstream may take a DOI for somewhere to fetch from.
  expect_equal(rec$urls, "https://e.org/f")
  expect_equal(getaca:::record_file_name(rec), "f")
})

test_that("a DOI renders in the manifest and an absent one renders nothing", {
  with_doi <- registry("demopkg", list(
    resource("res", "1.0", urls = "https://e.org/f", sha256 = strrep("a", 64),
             doi = "10.5281/zenodo.1234567")
  ))
  without <- registry("demopkg", list(
    resource("res", "1.0", urls = "https://e.org/f", sha256 = strrep("a", 64))
  ))

  expect_true("  doi 10.5281/zenodo.1234567" %in% unclass(registry_manifest(with_doi)))
  expect_false(any(grepl("^  doi ", unclass(registry_manifest(without)))))
  expect_false(identical(registry_digest(with_doi), registry_digest(without)))
})

test_that("a DOI reaches provenance and the catalogue", {
  cache <- local_cache()
  local_fetchable()
  f <- seed_file(cache)
  reg <- demo_registry(f$sha256, doi = "10.5281/zenodo.1234567")
  seeded <- seed_cache(reg, f)

  expect_equal(seeded$entry$doi, "10.5281/zenodo.1234567")
  expect_output(print(seeded$entry), "10.5281/zenodo.1234567", fixed = TRUE)

  out <- getaca_catalogue(registry = reg)
  expect_equal(out$doi, "10.5281/zenodo.1234567")
})

test_that("a processor must come from processor()", {
  expect_error(
    resource("res", "1.0", urls = "https://e.org/f", sha256 = strrep("a", 64),
             processor = function(x, y) x),
    class = "getaca_error_invalid_registry"
  )
  p <- processor("unzip", function(input, output_dir) output_dir)
  expect_s3_class(p, "getaca_processor")
})
