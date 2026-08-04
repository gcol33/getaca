# Canned responses, shaped after what the three archives actually return, so
# what is exercised here is the reading rather than the requesting.

zenodo_body <- function(id = "17844561", keys = c("alpha.csv", "beta.csv")) {
  list(
    id = as.integer(id),
    doi = paste0("10.5281/zenodo.", id),
    metadata = list(license = list(id = "cc-by-4.0")),
    files = lapply(keys, function(k) {
      list(key = k, size = 8L, checksum = "md5:0",
           links = list(self = sprintf("https://zenodo.org/api/records/%s/files/%s/content", id, k)))
    })
  )
}

figshare_body <- function(version = 1L, doi = "10.6084/m9.figshare.14763051.v1") {
  list(
    version = version,
    doi = doi,
    license = list(name = "CC BY 4.0"),
    files = list(list(
      name = "tiny-data.txt", size = 59L,
      download_url = "https://ndownloader.figshare.com/files/28369770",
      computed_md5 = "70e2afd3fd7e336ae478b1e740a5f08e"
    ))
  )
}

dataverse_body <- function(minor = 0L) {
  list(status = "OK", data = list(latestVersion = list(
    versionNumber = 1L, versionMinorNumber = minor,
    license = list(name = "CC BY 4.0"),
    files = list(list(dataFile = list(
      id = 7133L, filename = "store.zip", filesize = 780L,
      persistentId = "doi:10.11588/DATA/TKCFEF/AUYGU0"
    )))
  )))
}

serves_api <- function(responses) {
  function(url) responses[[url]]
}

# Bytes per URL, so a draft over several files hashes several distinct things.
# A NULL destination asks for the digest rather than the file, which is the
# shape a draft that is not keeping the bytes uses.
serves_bytes <- function(map) {
  function(url, dest, progress = NULL) {
    if (is.null(map[[url]])) {
      return(list(success = FALSE, reason = "HTTP 404", http = 404L))
    }
    bytes <- charToRaw(map[[url]])
    if (!is.null(progress)) progress(length(bytes))
    if (is.null(dest)) {
      return(list(success = TRUE, reason = NA_character_, http = 200L,
                  sha256 = getaca:::sha256_bytes(bytes),
                  bytes = length(bytes)))
    }
    writeBin(bytes, dest)
    list(success = TRUE, reason = NA_character_, http = 200L)
  }
}

refuses_resolution <- function(doi) NULL


test_that("a location is dispatched on the string alone wherever it can be", {
  pick <- function(x) {
    got <- getaca:::choose_handler(x, "auto", refuses_resolution)
    if (is.null(got)) NA_character_ else got$name
  }

  expect_identical(pick("10.5281/zenodo.17844561"), "zenodo")
  expect_identical(pick("https://zenodo.org/records/17844561"), "zenodo")
  expect_identical(pick("https://zenodo.org/record/17844561"), "zenodo")
  expect_identical(pick("10.6084/m9.figshare.14763051.v1"), "figshare")
  expect_identical(
    pick("https://figshare.com/articles/dataset/Test_data/14763051"), "figshare")
  expect_identical(
    pick("https://heidata.uni-heidelberg.de/dataset.xhtml?persistentId=doi:10.11588/data/TKCFEF"),
    "dataverse")
  expect_identical(pick("https://example.org/data.csv"), "url")
})

test_that("a plain URL is the last handler tried, so an archive keeps its own", {
  handlers <- names(getaca:::source_handlers())
  expect_identical(handlers[length(handlers)], "url")
})

test_that("a DOI no prefix identifies is placed by resolving it once", {
  resolves <- function(doi) "https://zenodo.org/records/99"
  got <- getaca:::choose_handler("10.9999/unknown.1", "auto", resolves)
  expect_identical(got$name, "zenodo")
  expect_identical(got$target, "https://zenodo.org/records/99")
})

test_that("a self-hosted instance is what is left once the known hosts decline", {
  resolves <- function(doi) {
    "https://heidata.uni-heidelberg.de/dataset.xhtml?persistentId=doi:10.11588/data/TKCFEF"
  }
  got <- getaca:::choose_handler("10.11588/data/TKCFEF", "auto", resolves)
  expect_identical(got$name, "dataverse")
})

test_that("a DOI that resolves nowhere is not guessed at", {
  expect_null(getaca:::choose_handler("10.9999/nowhere", "auto", refuses_resolution))
  expect_null(getaca:::choose_handler("not a location", "auto", refuses_resolution))
})

test_that("source= overrides the detection, and an unknown one says so", {
  got <- getaca:::choose_handler("https://zenodo.org/records/1", "url",
                                 refuses_resolution)
  expect_identical(got$name, "url")
  expect_error(
    getaca:::choose_handler("https://example.org/x", "dryad", refuses_resolution),
    "unknown source"
  )
})


test_that("a Zenodo record yields derivable locations, its id and its licence", {
  api <- serves_api(list("https://zenodo.org/api/records/17844561" = zenodo_body()))
  spec <- getaca:::zenodo_files("10.5281/zenodo.17844561", api)

  expect_identical(spec$version, "17844561")
  expect_identical(spec$license, "cc-by-4.0")
  expect_length(spec$files, 2L)
  expect_identical(spec$files[[1]]$urls,
                   "https://zenodo.org/records/17844561/files/alpha.csv")
  expect_identical(spec$files[[1]]$doi, "10.5281/zenodo.17844561")
  expect_identical(spec$files[[1]]$size, 8L)
})

test_that("a Zenodo file name that is not URL-safe is encoded in the location", {
  api <- serves_api(list(
    "https://zenodo.org/api/records/5" = zenodo_body("5", keys = "two words.csv")
  ))
  spec <- getaca:::zenodo_files("https://zenodo.org/records/5", api)
  expect_identical(spec$files[[1]]$urls,
                   "https://zenodo.org/records/5/files/two%20words.csv")
  expect_identical(spec$files[[1]]$file, "two words.csv")
})

test_that("a Zenodo response naming files the other way is still read", {
  body <- zenodo_body("7", keys = "only.csv")
  body$files[[1]] <- list(filename = "only.csv", size = 3L)
  api <- serves_api(list("https://zenodo.org/api/records/7" = body))
  spec <- getaca:::zenodo_files("10.5281/zenodo.7", api)
  expect_identical(spec$files[[1]]$file, "only.csv")
})

test_that("an unreachable archive yields nothing rather than a partial answer", {
  expect_null(getaca:::zenodo_files("10.5281/zenodo.1", function(url) NULL))
  expect_null(getaca:::zenodo_files("https://zenodo.org/records/nope",
                                    function(url) stop("never called")))
})


test_that("a versioned figshare DOI asks for that version", {
  api <- serves_api(list(
    "https://api.figshare.com/v2/articles?doi=10.6084%2Fm9.figshare.14763051.v1" =
      list(list(id = 14763051L)),
    "https://api.figshare.com/v2/articles/14763051/versions/1" = figshare_body()
  ))
  spec <- getaca:::figshare_files("10.6084/m9.figshare.14763051.v1", api)

  expect_identical(spec$version, "1")
  expect_identical(spec$license, "CC BY 4.0")
  expect_identical(spec$files[[1]]$urls,
                   "https://ndownloader.figshare.com/files/28369770")
  expect_identical(spec$files[[1]]$doi, "10.6084/m9.figshare.14763051.v1")
})

test_that("an unversioned figshare DOI records the version it was served", {
  api <- serves_api(list(
    "https://api.figshare.com/v2/articles?doi=10.6084%2Fm9.figshare.14763051" =
      list(list(id = 14763051L)),
    "https://api.figshare.com/v2/articles/14763051" =
      figshare_body(version = 4L, doi = "10.6084/m9.figshare.14763051.v4")
  ))
  spec <- getaca:::figshare_files("10.6084/m9.figshare.14763051", api)
  expect_identical(spec$version, "4")
  expect_identical(spec$files[[1]]$doi, "10.6084/m9.figshare.14763051.v4")
})

test_that("a figshare URL is read from its trailing segments", {
  expect_identical(
    getaca:::figshare_article("https://figshare.com/articles/dataset/Title/14763051",
                              function(url) stop("never called")),
    list(id = "14763051", version = NULL)
  )
  expect_identical(
    getaca:::figshare_article("https://figshare.com/articles/dataset/Title/14763051/2",
                              function(url) stop("never called")),
    list(id = "14763051", version = "2")
  )
  # A title that is itself a number does not become the article id.
  expect_identical(
    getaca:::figshare_article("https://figshare.com/articles/dataset/2024/14763051",
                              function(url) stop("never called")),
    list(id = "14763051", version = NULL)
  )
  # A link of some other shape says nothing rather than guessing.
  expect_null(
    getaca:::figshare_article("https://figshare.com/articles/14763051",
                              function(url) stop("never called"))
  )
})


test_that("a Dataverse dataset yields its two-part version and per-file DOIs", {
  base <- "https://heidata.uni-heidelberg.de"
  api <- serves_api(stats::setNames(
    list(dataverse_body()),
    sprintf("%s/api/datasets/:persistentId?persistentId=doi:10.11588/data/TKCFEF", base)
  ))
  url <- sprintf("%s/dataset.xhtml?persistentId=doi:10.11588/data/TKCFEF", base)
  spec <- getaca:::dataverse_files(url, NULL, api)

  expect_identical(spec$version, "1.0")
  expect_identical(spec$license, "CC BY 4.0")
  expect_identical(spec$files[[1]]$urls, paste0(base, "/api/access/datafile/7133"))
  expect_identical(spec$files[[1]]$doi, "10.11588/DATA/TKCFEF/AUYGU0")
})

test_that("a host that is not a Dataverse instance yields nothing", {
  api <- serves_api(list())
  url <- "https://example.org/dataset.xhtml?persistentId=doi:10.9999/x"
  expect_null(getaca:::dataverse_files(url, NULL, api))
})


test_that("a draft hashes the bytes it retrieves rather than trusting a report", {
  local_cache()
  api <- serves_api(list("https://zenodo.org/api/records/17844561" = zenodo_body()))
  bytes <- list("alpha", "beta and more")
  names(bytes) <- c("https://zenodo.org/records/17844561/files/alpha.csv",
                    "https://zenodo.org/records/17844561/files/beta.csv")

  records <- getaca:::draft_resources(
    "10.5281/zenodo.17844561", package = "demopkg", quiet = TRUE,
    api = api, resolve = refuses_resolution, transport = serves_bytes(bytes)
  )

  expect_length(records, 2L)
  expect_identical(vapply(records, function(r) r$name, character(1)),
                   c("alpha", "beta"))
  expect_identical(records[[1]]$version, "17844561")
  expect_identical(records[[1]]$sha256,
                   getaca:::sha256_bytes(charToRaw("alpha")))
  # The archive said 8 bytes for both; what is recorded is what arrived.
  expect_identical(records[[2]]$size, 13)
  expect_identical(records[[1]]$license, "cc-by-4.0")
  expect_identical(records[[1]]$doi, "10.5281/zenodo.17844561")
})

test_that("a drafted registry is a registry, and has a digest", {
  local_cache()
  api <- serves_api(list("https://zenodo.org/api/records/17844561" = zenodo_body()))
  bytes <- list("alpha", "beta")
  names(bytes) <- c("https://zenodo.org/records/17844561/files/alpha.csv",
                    "https://zenodo.org/records/17844561/files/beta.csv")

  reg <- getaca::registry(
    package = "demopkg",
    resources = getaca:::draft_resources(
      "10.5281/zenodo.17844561", package = "demopkg", quiet = TRUE,
      api = api, resolve = refuses_resolution, transport = serves_bytes(bytes))
  )
  expect_s3_class(reg, "getaca_registry")
  expect_match(getaca::registry_digest(reg), "^sha256:[0-9a-f]{64}$")
  expect_identical(names(reg$resources), c("alpha", "beta"))
})

test_that("a plain URL keeps its mirrors and needs a version", {
  local_cache()
  urls <- c("https://a.example.org/backbone.parquet",
            "https://b.example.org/backbone.parquet")
  bytes <- list("payload"); names(bytes) <- urls[1]

  records <- getaca:::draft_resources(
    list(backbone = urls), package = "demopkg", version = "2026.1", quiet = TRUE,
    api = function(url) stop("never called"), resolve = refuses_resolution,
    transport = serves_bytes(bytes)
  )
  expect_identical(records[[1]]$name, "backbone")
  expect_identical(records[[1]]$urls, urls)
  expect_identical(records[[1]]$version, "2026.1")

  expect_error(
    getaca:::draft_resources(urls[1], package = "demopkg", quiet = TRUE,
                             api = function(url) NULL, resolve = refuses_resolution,
                             transport = serves_bytes(bytes)),
    "needs one"
  )
})

test_that("a given version overrides the one the archive carries", {
  local_cache()
  api <- serves_api(list(
    "https://zenodo.org/api/records/5" = zenodo_body("5", keys = "only.csv")))
  bytes <- list("x"); names(bytes) <- "https://zenodo.org/records/5/files/only.csv"

  records <- getaca:::draft_resources(
    "10.5281/zenodo.5", package = "demopkg", version = "2026.1", quiet = TRUE,
    api = api, resolve = refuses_resolution, transport = serves_bytes(bytes))
  expect_identical(records[[1]]$version, "2026.1")
})

test_that("a resource is named after its file, without the extension", {
  expect_identical(getaca:::draft_name("backbone-2026.parquet"), "backbone-2026")
  expect_identical(getaca:::draft_name("two words.csv"), "two-words")
  expect_identical(getaca:::draft_name("a/b.csv"), "a-b")
  expect_identical(getaca:::draft_name(".hidden"), "hidden")
  expect_identical(getaca:::draft_file("two words.csv"), "two-words.csv")
})

test_that("file= is stated only where the location does not already say it", {
  local_cache()
  api <- serves_api(list(
    "https://zenodo.org/api/records/5" = zenodo_body("5", keys = c("plain.csv", "two words.csv"))))
  bytes <- list("a", "b")
  names(bytes) <- c("https://zenodo.org/records/5/files/plain.csv",
                    "https://zenodo.org/records/5/files/two%20words.csv")

  records <- getaca:::draft_resources(
    "10.5281/zenodo.5", package = "demopkg", quiet = TRUE,
    api = api, resolve = refuses_resolution, transport = serves_bytes(bytes))

  expect_null(records[[1]]$file)
  expect_identical(records[[2]]$file, "two-words.csv")
})

test_that("two files drafting to one name is refused rather than collapsed", {
  local_cache()
  api <- serves_api(list(
    "https://zenodo.org/api/records/5" = zenodo_body("5", keys = c("data.csv", "data.zip"))))
  bytes <- list("a", "b")
  names(bytes) <- c("https://zenodo.org/records/5/files/data.csv",
                    "https://zenodo.org/records/5/files/data.zip")

  expect_error(
    getaca:::draft_resources("10.5281/zenodo.5", package = "demopkg", quiet = TRUE,
                             api = api, resolve = refuses_resolution,
                             transport = serves_bytes(bytes)),
    "draft to the resource name 'data'"
  )
})

test_that("a name cannot stand for a location holding several files", {
  local_cache()
  api <- serves_api(list("https://zenodo.org/api/records/17844561" = zenodo_body()))
  expect_error(
    getaca:::draft_resources(c(everything = "10.5281/zenodo.17844561"),
                             package = "demopkg", quiet = TRUE, api = api,
                             resolve = refuses_resolution,
                             transport = serves_bytes(list())),
    "holds 2 files"
  )
})

test_that("a location that cannot be retrieved fails the draft and leaves nothing", {
  local_cache()
  expect_error(
    getaca:::draft_resources("https://example.org/gone.csv", package = "demopkg",
                             version = "1", quiet = TRUE,
                             api = function(url) NULL, resolve = refuses_resolution,
                             transport = serves_bytes(list())),
    "could not retrieve"
  )
  expect_length(list.files(getaca:::cache_tmp_dir()), 0L)
})

test_that("a drafted registry is one getaca can act on", {
  local_cache()
  local_fetchable()
  api <- serves_api(list(
    "https://zenodo.org/api/records/5" = zenodo_body("5", keys = "only.csv")))
  bytes <- list("payload bytes")
  names(bytes) <- "https://zenodo.org/records/5/files/only.csv"

  reg <- getaca::registry(
    package = "demopkg",
    resources = getaca:::draft_resources(
      "10.5281/zenodo.5", package = "demopkg", quiet = TRUE,
      api = api, resolve = refuses_resolution, transport = serves_bytes(bytes)))
  rec <- reg$resources[[1]]

  # The draft named the location it hashed, so a fetch over that location
  # returns the bytes it recorded. This is the whole round trip: the archive
  # describes the files, the draft declares them, and the declaration retrieves.
  testthat::local_mocked_bindings(try_one = serves_bytes(bytes),
                                  .package = "getaca")
  path <- getaca::getaca(rec$name, registry = reg, quiet = TRUE)
  expect_identical(getaca:::sha256_file(path), rec$sha256)
})

test_that("keep= puts the drafted bytes where a later fetch will find them", {
  local_cache()
  local_fetchable()
  bytes <- list("payload"); names(bytes) <- "https://example.org/f.csv"

  reg <- getaca::registry(
    package = "demopkg",
    resources = getaca:::draft_resources(
      "https://example.org/f.csv", package = "demopkg", version = "1",
      keep = TRUE, quiet = TRUE, api = function(url) NULL,
      resolve = refuses_resolution, transport = serves_bytes(bytes)))
  rec <- reg$resources[[1]]

  expect_true(file.exists(getaca:::blob_path(rec$sha256)))
  expect_length(list.files(getaca:::cache_tmp_dir()), 0L)

  # Already in the store under its own digest, so retrieval is a link and no
  # transport is reached at all.
  testthat::local_mocked_bindings(
    try_one = function(...) stop("the store should have answered this"),
    .package = "getaca"
  )
  path <- getaca::getaca(rec$name, registry = reg, quiet = TRUE)
  expect_identical(getaca:::sha256_file(path), rec$sha256)
})

test_that("without keep=, the bytes are hashed as they arrive and never written", {
  local_cache()
  bytes <- list("payload"); names(bytes) <- "https://example.org/f.csv"
  serve <- serves_bytes(bytes)
  asked <- list()

  records <- getaca:::draft_resources(
    "https://example.org/f.csv", package = "demopkg", version = "1",
    quiet = TRUE, api = function(url) NULL, resolve = refuses_resolution,
    transport = function(url, dest, progress = NULL) {
      asked <<- c(asked, list(dest))
      serve(url, dest, progress = progress)
    })

  # No destination at all, which is what makes a location of any size cost no
  # disk to draft.
  expect_length(asked, 1L)
  expect_null(asked[[1]])
  expect_identical(records[[1]]$sha256,
                   getaca:::sha256_bytes(charToRaw("payload")))
  expect_identical(records[[1]]$size, 7)
  expect_false(file.exists(getaca:::blob_path(records[[1]]$sha256)))
  expect_length(list.files(getaca:::cache_tmp_dir()), 0L)
})

test_that("several locations of different kinds draft in one call", {
  local_cache()
  api <- serves_api(list(
    "https://zenodo.org/api/records/5" = zenodo_body("5", keys = "only.csv")))
  bytes <- list("a", "b")
  names(bytes) <- c("https://zenodo.org/records/5/files/only.csv",
                    "https://example.org/extra.csv")

  records <- getaca:::draft_resources(
    c("10.5281/zenodo.5", extra = "https://example.org/extra.csv"),
    package = "demopkg", version = "2026.1", quiet = TRUE,
    api = api, resolve = refuses_resolution, transport = serves_bytes(bytes))

  expect_identical(vapply(records, function(r) r$name, character(1)),
                   c("only", "extra"))
  expect_identical(records[[1]]$license, "cc-by-4.0")
  expect_true(is.na(records[[2]]$license))
})

refuses_transport <- function(url, dest, progress = NULL) {
  stop("nothing should have been retrieved")
}


test_that("local= hashes the copy on this machine and retrieves nothing", {
  local_cache()
  dir <- withr::local_tempdir()
  path <- file.path(dir, "backbone.parquet")
  writeBin(charToRaw("payload bytes"), path)

  records <- getaca:::draft_resources(
    c(backbone = "https://example.org/backbone.parquet"),
    package = "demopkg", version = "2026.1", local = path, quiet = TRUE,
    api = function(url) NULL, resolve = refuses_resolution,
    transport = refuses_transport)

  expect_identical(records[[1]]$sha256,
                   getaca:::sha256_bytes(charToRaw("payload bytes")))
  expect_identical(records[[1]]$size, 13)
  # The record names where a user fetches from, not where the author measured.
  expect_identical(records[[1]]$urls, "https://example.org/backbone.parquet")
})

test_that("sha256= is taken as declared and nothing is retrieved", {
  local_cache()
  sha <- getaca:::sha256_bytes(charToRaw("payload"))

  records <- getaca:::draft_resources(
    "https://example.org/f.csv", package = "demopkg", version = "1",
    sha256 = sha, quiet = TRUE, api = function(url) NULL,
    resolve = refuses_resolution, transport = refuses_transport)

  expect_identical(records[[1]]$sha256, sha)
  # A plain URL reports no size, and nothing measured one.
  expect_true(is.na(records[[1]]$size))
})

test_that("sha256= takes the size the archive reported", {
  local_cache()
  api <- serves_api(list(
    "https://zenodo.org/api/records/5" = zenodo_body("5", keys = "only.csv")))

  records <- getaca:::draft_resources(
    "10.5281/zenodo.5", package = "demopkg", sha256 = strrep("a", 64),
    quiet = TRUE, api = api, resolve = refuses_resolution,
    transport = refuses_transport)

  expect_identical(records[[1]]$sha256, strrep("a", 64))
  expect_identical(records[[1]]$size, 8)
})

test_that("both together hold the local copy to the checksum", {
  local_cache()
  dir <- withr::local_tempdir()
  path <- file.path(dir, "f.csv")
  writeBin(charToRaw("payload"), path)

  records <- getaca:::draft_resources(
    "https://example.org/f.csv", package = "demopkg", version = "1",
    local = path, sha256 = getaca:::sha256_bytes(charToRaw("payload")),
    quiet = TRUE, api = function(url) NULL, resolve = refuses_resolution,
    transport = refuses_transport)
  expect_identical(records[[1]]$sha256,
                   getaca:::sha256_bytes(charToRaw("payload")))

  expect_error(
    getaca:::draft_resources(
      "https://example.org/f.csv", package = "demopkg", version = "1",
      local = path, sha256 = strrep("a", 64), quiet = TRUE,
      api = function(url) NULL, resolve = refuses_resolution,
      transport = refuses_transport),
    "is not the file"
  )
})

test_that("a checksum given in upper case is the same checksum", {
  local_cache()
  sha <- getaca:::sha256_bytes(charToRaw("payload"))

  records <- getaca:::draft_resources(
    "https://example.org/f.csv", package = "demopkg", version = "1",
    sha256 = toupper(sha), quiet = TRUE, api = function(url) NULL,
    resolve = refuses_resolution, transport = refuses_transport)
  expect_identical(records[[1]]$sha256, sha)
})

test_that("a local path that is not a readable file says so", {
  local_cache()
  expect_error(
    getaca:::draft_resources(
      "https://example.org/f.csv", package = "demopkg", version = "1",
      local = file.path(tempdir(), "absent-9d21f0"), quiet = TRUE,
      api = function(url) NULL, resolve = refuses_resolution,
      transport = refuses_transport),
    "no file at"
  )
})

test_that("keep= with local= copies into the store and leaves the original", {
  local_cache()
  local_fetchable()
  dir <- withr::local_tempdir()
  path <- file.path(dir, "f.csv")
  writeBin(charToRaw("payload"), path)

  reg <- getaca::registry(
    package = "demopkg",
    resources = getaca:::draft_resources(
      "https://example.org/f.csv", package = "demopkg", version = "1",
      local = path, keep = TRUE, quiet = TRUE, api = function(url) NULL,
      resolve = refuses_resolution, transport = refuses_transport))
  rec <- reg$resources[[1]]

  # Admission is a move, so the author's own file has to survive it.
  expect_true(file.exists(path))
  expect_true(file.exists(getaca:::blob_path(rec$sha256)))
  expect_length(list.files(getaca:::cache_tmp_dir()), 0L)

  testthat::local_mocked_bindings(
    try_one = function(...) stop("the store should have answered this"),
    .package = "getaca"
  )
  expect_identical(
    getaca:::sha256_file(getaca::getaca(rec$name, registry = reg, quiet = TRUE)),
    rec$sha256)
})

test_that("a per-location argument is matched by name or by position", {
  locations <- getaca:::as_locations(c(a = "https://x/1", b = "https://x/2"))

  expect_identical(getaca:::as_per_location(NULL, locations, "local"),
                   c(NA_character_, NA_character_))
  expect_identical(getaca:::as_per_location(c(b = "two"), locations, "local"),
                   c(NA_character_, "two"))
  expect_identical(getaca:::as_per_location(c("one", "two"), locations, "local"),
                   c("one", "two"))
  expect_error(getaca:::as_per_location("one", locations, "local"),
               "1 entries and there are 2 locations")
  expect_error(getaca:::as_per_location(c(c = "x"), locations, "sha256"),
               "not among the locations")
  expect_error(getaca:::as_per_location(1L, locations, "local"),
               "character vector")
})

test_that("a checksum cannot stand for a location holding several files", {
  local_cache()
  api <- serves_api(list("https://zenodo.org/api/records/17844561" = zenodo_body()))
  expect_error(
    getaca:::draft_resources("10.5281/zenodo.17844561", package = "demopkg",
                             sha256 = strrep("a", 64), quiet = TRUE, api = api,
                             resolve = refuses_resolution,
                             transport = refuses_transport),
    "`sha256` cannot stand for it"
  )
  expect_error(
    getaca:::draft_resources("10.5281/zenodo.17844561", package = "demopkg",
                             local = tempfile(), quiet = TRUE, api = api,
                             resolve = refuses_resolution,
                             transport = refuses_transport),
    "`local` cannot stand for it"
  )
})

test_that("routes mix within one call", {
  local_cache()
  dir <- withr::local_tempdir()
  path <- file.path(dir, "b.csv")
  writeBin(charToRaw("bee"), path)
  bytes <- list("aye"); names(bytes) <- "https://example.org/a.csv"

  records <- getaca:::draft_resources(
    c(a = "https://example.org/a.csv", b = "https://example.org/b.csv",
      c = "https://example.org/c.csv"),
    package = "demopkg", version = "1", local = c(b = path),
    sha256 = c(c = strrep("c", 64)), quiet = TRUE,
    api = function(url) NULL, resolve = refuses_resolution,
    transport = serves_bytes(bytes))

  expect_identical(records[[1]]$sha256, getaca:::sha256_bytes(charToRaw("aye")))
  expect_identical(records[[2]]$sha256, getaca:::sha256_bytes(charToRaw("bee")))
  expect_identical(records[[3]]$sha256, strrep("c", 64))
})

test_that("x must be locations", {
  expect_error(getaca:::as_locations(character()), "character vector")
  expect_error(getaca:::as_locations(list(1L)), "one or more URLs")
  expect_error(getaca:::as_locations(list(NA_character_)), "one or more URLs")
})
