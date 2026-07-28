# The zip is committed, since nothing in base R writes one. Everything else is
# built here, so what the tests extract is what this file packed.
sample_zip <- function() testthat::test_path("fixtures", "sample.zip")

sample_tar <- function(dir, compression = "gzip", ext = "tar.gz") {
  tree <- file.path(dir, "tree")
  dir.create(file.path(tree, "tables"), recursive = TRUE)
  write_bytes(file.path(tree, "names.csv"), "id,name\n1,Fagus sylvatica\n")
  write_bytes(file.path(tree, "tables", "synonyms.csv"), "id,synonym\n1,Fagus silvatica\n")
  write_bytes(file.path(tree, "tables", "ranks.csv"), "id,rank\n1,species\n")

  out <- file.path(dir, paste0("sample.", ext))
  owd <- setwd(tree)
  on.exit(setwd(owd))
  utils::tar(out, files = c("names.csv", "tables"),
             compression = compression, tar = "internal")
  out
}

write_bytes <- function(path, text) {
  con <- file(path, open = "wb")
  on.exit(close(con))
  writeBin(charToRaw(text), con)
}

compressed_file <- function(dir, name, text, opener) {
  path <- file.path(dir, name)
  con <- opener(path, "wb")
  on.exit(close(con))
  writeBin(charToRaw(text), con)
  path
}

# The output directory belongs to the test, not to this call: a processor
# returns paths into it, and they have to survive the return.
run <- function(proc, input) {
  out <- withr::local_tempdir(.local_envir = parent.frame())
  proc$fn(input, out)
}


# ---- identity ---------------------------------------------------------------

test_that("the id says what the processor will do", {
  expect_equal(unpack()$id, "unpack")
  expect_equal(unpack("zip")$id, "unpack-zip")
  expect_equal(unpack("tar")$id, "unpack-tar")
  expect_equal(unpack("gzip")$id, "unpack-gzip")
  expect_s3_class(unpack(), "getaca_processor")
})

test_that("naming members gives the result a different slot", {
  all <- unpack("zip")$id
  some <- unpack("zip", members = "tables")$id
  other <- unpack("zip", members = "names.csv")$id

  expect_false(identical(all, some))
  expect_false(identical(some, other))
  expect_match(some, "^unpack-zip-[0-9a-f]{8}$")
})

test_that("the order members are named in does not reach the result", {
  expect_equal(unpack("zip", members = c("a.csv", "b.csv"))$id,
               unpack("zip", members = c("b.csv", "a.csv"))$id)
  expect_equal(unpack("zip", members = c("a.csv", "a.csv"))$id,
               unpack("zip", members = "a.csv")$id)
})

test_that("the id is a legal processor id", {
  ids <- c(unpack()$id, unpack("bzip2")$id, unpack("tar", members = "x/y")$id)
  expect_true(all(grepl("^[A-Za-z0-9._-]+$", ids)))
})

test_that("an id built here is one processor() would have accepted", {
  expect_no_error(processor(unpack("tar", members = "x")$id, identity))
})


# ---- what the arguments refuse ----------------------------------------------

test_that("members do not apply to a single compressed file", {
  expect_error(unpack("gzip", members = "a.csv"), "single file")
  expect_error(unpack("bzip2", members = "a.csv"), "single file")
  expect_error(unpack("xz", members = "a.csv"), "single file")
})

test_that("members must be names", {
  expect_error(unpack("zip", members = 1L), "character vector")
  expect_error(unpack("zip", members = character()), "character vector")
  expect_error(unpack("zip", members = NA_character_), "character vector")
  expect_error(unpack("zip", members = ""), "character vector")
})

test_that("an unknown format is refused where it is written", {
  expect_error(unpack("rar"), "'arg' should be one of")
})


# ---- reading the format off the name ----------------------------------------

test_that("every documented extension resolves to its format", {
  detect <- function(name) getaca:::detect_format(name)

  expect_equal(detect("backbone.zip"), "zip")
  expect_equal(detect("backbone.tar"), "tar")
  expect_equal(detect("backbone.tar.gz"), "tar")
  expect_equal(detect("backbone.tgz"), "tar")
  expect_equal(detect("backbone.tar.bz2"), "tar")
  expect_equal(detect("backbone.tbz2"), "tar")
  expect_equal(detect("backbone.tar.xz"), "tar")
  expect_equal(detect("backbone.txz"), "tar")
  expect_equal(detect("backbone.csv.gz"), "gzip")
  expect_equal(detect("backbone.csv.bz2"), "bzip2")
  expect_equal(detect("backbone.csv.xz"), "xz")
})

test_that("a compressed tarball is a tarball, not a compressed file", {
  expect_equal(getaca:::detect_format("backbone.tar.gz"), "tar")
  expect_equal(getaca:::detect_format("backbone.tar.xz"), "tar")
})

test_that("the format is read off the name whatever case it is written in", {
  expect_equal(getaca:::detect_format("BACKBONE.ZIP"), "zip")
  expect_equal(getaca:::detect_format("Backbone.Tar.Gz"), "tar")
})

test_that("a name carrying no format says so and names the way out", {
  expect_error(getaca:::detect_format("backbone.bin"),
               "cannot tell the format")
  expect_error(getaca:::detect_format("backbone.bin"),
               "unpack(format", fixed = TRUE)
})


# ---- zip --------------------------------------------------------------------

test_that("a zip arrives with its layout intact", {
  out <- run(unpack(), sample_zip())

  expect_true(dir.exists(out))
  expect_setequal(list.files(out, recursive = TRUE),
                  c("names.csv", "tables/synonyms.csv", "tables/ranks.csv"))
  expect_equal(readLines(file.path(out, "names.csv"), warn = FALSE)[2],
               "1,Fagus sylvatica")
})

test_that("naming a member extracts that member alone", {
  out <- run(unpack("zip", members = "names.csv"), sample_zip())
  expect_equal(list.files(out, recursive = TRUE), "names.csv")
})

test_that("naming a directory extracts everything under it", {
  out <- run(unpack("zip", members = "tables"), sample_zip())
  expect_setequal(list.files(out, recursive = TRUE),
                  c("tables/synonyms.csv", "tables/ranks.csv"))
})

test_that("a trailing slash names the same directory", {
  expect_setequal(list.files(run(unpack("zip", members = "tables/"), sample_zip()),
                             recursive = TRUE),
                  list.files(run(unpack("zip", members = "tables"), sample_zip()),
                             recursive = TRUE))
})

test_that("a member that is in no archive is an error, not an empty slot", {
  expect_error(run(unpack("zip", members = "tables/absent.csv"), sample_zip()),
               "names nothing in 'sample.zip'")
})

test_that("a partial name does not silently match a longer one", {
  expect_error(run(unpack("zip", members = "names"), sample_zip()),
               "names nothing")
})


# ---- tar --------------------------------------------------------------------

test_that("a tarball arrives with its layout intact", {
  dir <- withr::local_tempdir()
  out <- run(unpack(), sample_tar(dir))

  expect_setequal(list.files(out, recursive = TRUE),
                  c("names.csv", "tables/synonyms.csv", "tables/ranks.csv"))
})

test_that("every compression a tarball travels under is read", {
  for (case in list(c("gzip", "tar.gz"), c("bzip2", "tar.bz2"),
                    c("xz", "tar.xz"), c("none", "tar"))) {
    dir <- withr::local_tempdir()
    out <- run(unpack(), sample_tar(dir, compression = case[1], ext = case[2]))
    expect_setequal(list.files(out, recursive = TRUE),
                    c("names.csv", "tables/synonyms.csv", "tables/ranks.csv"))
  }
})

test_that("members work the same way in a tarball", {
  dir <- withr::local_tempdir()
  tarball <- sample_tar(dir)

  expect_setequal(list.files(run(unpack("tar", members = "tables"), tarball),
                             recursive = TRUE),
                  c("tables/synonyms.csv", "tables/ranks.csv"))
  expect_error(run(unpack("tar", members = "absent"), tarball), "names nothing")
})


# ---- one compressed file ----------------------------------------------------

test_that("a compressed file arrives decompressed, under its own name", {
  dir <- withr::local_tempdir()
  cases <- list(
    list("backbone.csv.gz", gzfile, "gzip"),
    list("backbone.csv.bz2", bzfile, "bzip2"),
    list("backbone.csv.xz", xzfile, "xz")
  )

  for (case in cases) {
    input <- compressed_file(dir, case[[1]], "id,name\n1,Fagus\n", case[[2]])
    out <- run(unpack(), input)

    expect_equal(basename(out), "backbone.csv")
    expect_equal(readLines(out, warn = FALSE), c("id,name", "1,Fagus"))
  }
})

test_that("naming the compression overrides what the name suggests", {
  dir <- withr::local_tempdir()
  input <- compressed_file(dir, "backbone.bin", "payload\n", gzfile)

  expect_error(run(unpack(), input), "cannot tell the format")
  expect_equal(readLines(run(unpack("gzip"), input), warn = FALSE), "payload")
})

test_that("a decompressed file keeps its name where there is no suffix to drop", {
  dir <- withr::local_tempdir()
  input <- compressed_file(dir, "backbone.bin", "payload\n", gzfile)
  expect_equal(basename(run(unpack("gzip"), input)), "backbone.bin")
})

test_that("a file larger than one read arrives whole", {
  dir <- withr::local_tempdir()
  text <- paste(rep("Fagus sylvatica", 200000L), collapse = ",")
  input <- compressed_file(dir, "big.txt.gz", text, gzfile)

  out <- run(unpack(), input)
  expect_equal(file.size(out), nchar(text))
  expect_equal(getaca:::sha256_file(out),
               getaca:::sha256_bytes(charToRaw(text)))
})


# ---- through a retrieval ----------------------------------------------------

serves_archive <- function(file) {
  function(url, dest, progress = NULL) {
    file.copy(file, dest, overwrite = TRUE)
    list(success = TRUE, reason = NA_character_)
  }
}

archive_registry <- function(proc = unpack()) {
  registry("demopkg", list(
    resource("backbone", "2026-06",
             urls = "https://a.invalid/backbone-2026-06.zip",
             sha256 = getaca:::sha256_file(sample_zip()),
             processor = proc)
  ))
}

test_that("a declared archive is returned unpacked", {
  local_fetchable()
  local_cache()
  reg <- archive_registry()
  testthat::local_mocked_bindings(try_one = serves_archive(sample_zip()),
                                  .package = "getaca")

  path <- getaca("backbone", registry = reg, quiet = TRUE)

  expect_true(dir.exists(path))
  expect_match(path, "proc-unpack", fixed = TRUE)
  expect_setequal(list.files(path, recursive = TRUE),
                  c("names.csv", "tables/synonyms.csv", "tables/ranks.csv"))
})

test_that("the archive it was built from stays reachable", {
  local_fetchable()
  local_cache()
  reg <- archive_registry()
  testthat::local_mocked_bindings(try_one = serves_archive(sample_zip()),
                                  .package = "getaca")

  unpacked <- getaca("backbone", registry = reg, quiet = TRUE)
  archive <- getaca("backbone", registry = reg, processed = FALSE, quiet = TRUE)

  expect_true(dir.exists(unpacked))
  expect_false(dir.exists(archive))
  expect_equal(getaca:::sha256_file(archive), getaca:::sha256_file(sample_zip()))
})

test_that("the id it records is the id it was declared with", {
  local_fetchable()
  local_cache()
  reg <- archive_registry(unpack("zip", members = "tables"))
  testthat::local_mocked_bindings(try_one = serves_archive(sample_zip()),
                                  .package = "getaca")

  path <- getaca("backbone", registry = reg, quiet = TRUE)
  info <- getaca_info("backbone", registry = reg)

  expect_equal(info$processor_id, unpack("zip", members = "tables")$id)
  expect_setequal(list.files(path, recursive = TRUE),
                  c("tables/synonyms.csv", "tables/ranks.csv"))
})

test_that("two subsets of one archive do not share a slot", {
  local_fetchable()
  local_cache()
  serve <- serves_archive(sample_zip())
  testthat::local_mocked_bindings(try_one = serve, .package = "getaca")

  names_only <- getaca("backbone", registry = archive_registry(
    unpack("zip", members = "names.csv")), quiet = TRUE)
  tables_only <- getaca("backbone", registry = archive_registry(
    unpack("zip", members = "tables")), quiet = TRUE)

  expect_false(identical(names_only, tables_only))
  expect_equal(list.files(names_only, recursive = TRUE), "names.csv")
  expect_setequal(list.files(tables_only, recursive = TRUE),
                  c("tables/synonyms.csv", "tables/ranks.csv"))
})

test_that("a processor that fails leaves no slot behind", {
  local_fetchable()
  local_cache()
  reg <- archive_registry(unpack("zip", members = "absent.csv"))
  testthat::local_mocked_bindings(try_one = serves_archive(sample_zip()),
                                  .package = "getaca")

  expect_error(getaca("backbone", registry = reg, quiet = TRUE), "names nothing")
  expect_length(list.files(getaca_cache_dir(), pattern = "^proc-",
                           recursive = TRUE, include.dirs = TRUE), 0L)
})


# ---- what the registry records ----------------------------------------------

test_that("the manifest carries the id, so a subset changes the digest", {
  all <- registry_digest(archive_registry(unpack("zip")))
  some <- registry_digest(archive_registry(unpack("zip", members = "tables")))

  expect_false(identical(all, some))
})

test_that("a stock processor digests the same on every machine", {
  expect_equal(registry_digest(archive_registry(unpack())),
               registry_digest(archive_registry(unpack())))
  expect_match(registry_manifest(archive_registry(unpack())),
               "processor unpack", fixed = TRUE, all = FALSE)
})
