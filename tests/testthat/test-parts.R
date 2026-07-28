# A base and the deltas issued against it, as real files with real checksums, so
# composition is exercised rather than stubbed. Concatenation is the default
# combiner, so a series composes to the pieces run together.
series <- function(dir, pieces) {
  files <- lapply(names(pieces), function(nm) {
    path <- file.path(dir, nm)
    writeBin(charToRaw(pieces[[nm]]), path)
    list(url = paste0("https://parts.invalid/", nm), path = path,
         sha256 = getaca:::sha256_file(path),
         size = unname(file.info(path)$size))
  })
  stats::setNames(files, names(pieces))
}

as_parts <- function(files) {
  unname(lapply(files, function(f) {
    getaca::part(f$url, sha256 = f$sha256, size = f$size)
  }))
}

# What the declaration has to name: the artefact, not any one piece of it.
composed_of <- function(files, dir, name = "composed.bin") {
  path <- file.path(dir, name)
  bytes <- unlist(lapply(files, function(f) {
    readBin(f$path, "raw", n = f$size)
  }), use.names = FALSE)
  writeBin(bytes, path)
  list(path = path, sha256 = getaca:::sha256_file(path),
       size = unname(file.info(path)$size))
}

# Serves whichever piece the URL names, and records what it was asked for, so a
# part already in the store is visibly not fetched a second time.
serves_parts <- function(files) {
  asked <- character()
  fn <- function(url, dest, progress = NULL) {
    hit <- Filter(function(f) identical(f$url, url), files)
    if (!length(hit)) return(list(success = FALSE, reason = "HTTP 404"))
    asked <<- c(asked, url)
    file.copy(hit[[1]]$path, dest, overwrite = TRUE)
    list(success = TRUE, reason = NA_character_)
  }
  list(fn = fn, requested = function() asked)
}

binary_piece <- function(dir, name, bytes) {
  path <- file.path(dir, name)
  writeBin(bytes, path)
  list(url = paste0("https://parts.invalid/", name), path = path,
       sha256 = getaca:::sha256_file(path),
       size = unname(file.info(path)$size))
}

payload <- function(dir, name, bytes) {
  path <- file.path(dir, name)
  writeBin(bytes, path)
  list(path = path, sha256 = getaca:::sha256_file(path),
       size = unname(file.info(path)$size))
}

# A minimal but real patch format, so the base-and-deltas shape is exercised as
# itself rather than as concatenation wearing its name. Each delta says how much
# of the artefact so far to keep, and what follows it.
delta_bytes <- function(keep, tail) {
  c(charToRaw(sprintf("%08d", keep)), charToRaw(tail))
}

patcher <- function() {
  getaca::combiner("keep-append", function(parts, output) {
    read_all <- function(p) readBin(p, "raw", n = unname(file.info(p)$size))
    current <- read_all(parts[1])
    for (d in parts[-1]) {
      raw <- read_all(d)
      keep <- as.integer(rawToChar(raw[seq_len(8)]))
      current <- c(utils::head(current, keep), raw[-seq_len(8)])
    }
    writeBin(current, output)
  })
}

parts_registry <- function(files, composed, version = "1", ...,
                           package = "demopkg") {
  getaca::registry(package, list(
    getaca::resource("db", version, sha256 = composed$sha256, file = "db.bin",
                     size = composed$size, parts = as_parts(files), ...)
  ))
}

# A base, one delta against it, and a second delta after that: the shape the
# whole feature is for.
three_part_fixture <- function(env = parent.frame()) {
  dir <- withr::local_tempdir(.local_envir = env)
  files <- series(dir, list(base = "BASEBASEBASE", d1 = "-delta-one", d2 = "-delta-two"))
  list(dir = dir, files = files, composed = composed_of(files, dir))
}


# Declaration ------------------------------------------------------------

test_that("a part needs a real checksum and a secure transport", {
  expect_error(part("https://e.org/f", sha256 = "abc"),
               class = "getaca_error_invalid_registry")
  expect_error(part("http://e.org/f", sha256 = strrep("a", 64)),
               class = "getaca_error_invalid_registry")
  expect_error(part(character(), sha256 = strrep("a", 64)),
               class = "getaca_error_invalid_registry")
  expect_s3_class(part("https://e.org/f", sha256 = strrep("A", 64)), "getaca_part")
  expect_equal(part("https://e.org/f", sha256 = strrep("A", 64))$sha256, strrep("a", 64))
})

test_that("a record names locations for the whole file or the parts, not both", {
  p <- part("https://e.org/f", sha256 = strrep("b", 64))
  expect_error(
    resource("res", "1.0", urls = "https://e.org/f", sha256 = strrep("a", 64),
             parts = list(p), file = "res.bin"),
    class = "getaca_error_invalid_registry"
  )
  expect_error(
    resource("res", "1.0", sha256 = strrep("a", 64)),
    class = "getaca_error_invalid_registry"
  )
})

test_that("a composed record must name the file it composes to", {
  p <- part("https://e.org/f", sha256 = strrep("b", 64))
  expect_error(
    resource("res", "1.0", sha256 = strrep("a", 64), parts = list(p)),
    "must also declare `file`"
  )
  rec <- resource("res", "1.0", sha256 = strrep("a", 64), parts = list(p),
                  file = "res.bin")
  expect_equal(rec$file, "res.bin")
})

test_that("a declared file name cannot reach outside the slot", {
  p <- part("https://e.org/f", sha256 = strrep("b", 64))
  expect_error(
    resource("res", "1.0", sha256 = strrep("a", 64), parts = list(p),
             file = "../escape"),
    class = "getaca_error_invalid_registry"
  )
  expect_error(
    resource("res", "1.0", sha256 = strrep("a", 64), parts = list(p),
             file = "sub/dir.bin"),
    class = "getaca_error_invalid_registry"
  )
})

test_that("a part list is refused unless every element came from part()", {
  expect_error(
    resource("res", "1.0", sha256 = strrep("a", 64), file = "res.bin",
             parts = list(list(urls = "https://e.org/f", sha256 = strrep("b", 64)))),
    class = "getaca_error_invalid_registry"
  )
})

test_that("an empty URL is refused where a URL is what was declared", {
  expect_error(
    resource("res", "1.0", urls = "", sha256 = strrep("a", 64)),
    "at least one URL is required"
  )
})

test_that("a combiner belongs to a record that declares parts", {
  expect_error(
    resource("res", "1.0", urls = "https://e.org/f", sha256 = strrep("a", 64),
             combiner = combiner("x", function(parts, output) NULL)),
    class = "getaca_error_invalid_registry"
  )
  expect_error(
    resource("res", "1.0", sha256 = strrep("a", 64), file = "res.bin",
             parts = list(part("https://e.org/f", sha256 = strrep("b", 64))),
             combiner = function(parts, output) NULL),
    class = "getaca_error_invalid_registry"
  )
})

test_that("a whole-file record may still name the file it is cached under", {
  rec <- resource("res", "1.0", urls = "https://e.org/download?id=7",
                  sha256 = strrep("a", 64), file = "res.parquet")
  expect_equal(getaca:::record_file_name(rec), "res.parquet")
  plain <- resource("res", "1.0", urls = "https://e.org/res.csv",
                    sha256 = strrep("a", 64))
  expect_equal(getaca:::record_file_name(plain), "res.csv")
})


# Manifest ---------------------------------------------------------------

test_that("parts render in declaration order, with the combiner named", {
  fx <- three_part_fixture()
  reg <- parts_registry(fx$files, fx$composed)
  lines <- unclass(registry_manifest(reg))

  expect_true(any(grepl("^  file db.bin$", lines)))
  expect_equal(sum(grepl("^  part ", lines)), 3L)
  expect_true(any(grepl("^  combiner concat$", lines)))

  shas <- sub("^  part ([0-9a-f]{64}).*$", "\\1", grep("^  part ", lines, value = TRUE))
  expect_equal(shas, vapply(fx$files, function(f) f$sha256, character(1)),
               ignore_attr = TRUE)
})

test_that("a registry declaring no parts renders exactly what it always did", {
  # Byte-for-byte, since a digest recorded in provenance before parts existed
  # has to keep identifying the state that produced it. Adding a field that
  # renders nothing when absent is what makes that true.
  reg <- registry("demopkg", list(
    resource("res", "1.0", urls = "https://example.invalid/res.csv",
             sha256 = strrep("a", 64))
  ))

  expect_equal(
    unclass(registry_manifest(reg)),
    c("getaca-manifest 1",
      "package demopkg",
      "resource res 1.0",
      paste("  sha256", strrep("a", 64)),
      "  url https://example.invalid/res.csv")
  )
})

test_that("reordering the parts is a different declaration", {
  fx <- three_part_fixture()
  forward <- parts_registry(fx$files, fx$composed)
  reversed <- parts_registry(rev(fx$files), fx$composed)
  expect_false(identical(registry_digest(forward), registry_digest(reversed)))
})


# Composition ------------------------------------------------------------

test_that("a series is fetched, verified and composed into the declared bytes", {
  local_fetchable()
  local_cache()
  fx <- three_part_fixture()
  reg <- parts_registry(fx$files, fx$composed)
  net <- serves_parts(fx$files)
  testthat::local_mocked_bindings(try_one = net$fn, .package = "getaca")

  path <- getaca("db", registry = reg, quiet = TRUE)

  expect_equal(getaca:::sha256_file(path), fx$composed$sha256)
  expect_equal(basename(path), "db.bin")
  expect_length(net$requested(), 3L)
})

test_that("the composed artefact is stored and verified like a downloaded one", {
  local_fetchable()
  local_cache()
  fx <- three_part_fixture()
  reg <- parts_registry(fx$files, fx$composed)
  testthat::local_mocked_bindings(try_one = serves_parts(fx$files)$fn, .package = "getaca")

  getaca("db", registry = reg, quiet = TRUE)
  entry <- getaca_info("db", registry = reg)

  expect_true(getaca:::blob_exists(fx$composed$sha256))
  expect_equal(entry$declared_sha256, fx$composed$sha256)
  expect_true(is.na(entry$url_used))
  expect_equal(entry$combiner_id, "concat")
  expect_equal(entry$parts, vapply(fx$files, function(f) f$sha256, character(1)),
               ignore_attr = TRUE)
  # A full re-hash is of the artefact, which is what the checksum describes.
  expect_silent(getaca("db", registry = reg, verify = TRUE, quiet = TRUE))
})

test_that("each part is stored under its own digest", {
  local_fetchable()
  local_cache()
  fx <- three_part_fixture()
  reg <- parts_registry(fx$files, fx$composed)
  testthat::local_mocked_bindings(try_one = serves_parts(fx$files)$fn, .package = "getaca")

  getaca("db", registry = reg, quiet = TRUE)

  for (f in fx$files) expect_true(getaca:::blob_exists(f$sha256))
  expect_true(all(vapply(fx$files, function(f) f$sha256, character(1)) %in%
                    getaca:::live_blobs()))
})

test_that("a base shared by two versions is transferred once", {
  local_fetchable()
  local_cache()
  dir <- withr::local_tempdir()
  files <- series(dir, list(base = "BASEBASEBASE", d1 = "-delta-one", d2 = "-delta-two"))
  v1 <- composed_of(files[c("base", "d1")], dir, "v1.bin")
  v2 <- composed_of(files, dir, "v2.bin")

  reg <- registry("demopkg", current = c(db = "2"), resources = list(
    resource("db", "1", sha256 = v1$sha256, file = "db.bin",
             parts = as_parts(files[c("base", "d1")])),
    resource("db", "2", sha256 = v2$sha256, file = "db.bin",
             parts = as_parts(files))
  ))
  net <- serves_parts(files)
  testthat::local_mocked_bindings(try_one = net$fn, .package = "getaca")

  getaca("db", registry = reg, version = "1", quiet = TRUE)
  expect_equal(net$requested(), c(files$base$url, files$d1$url))

  path <- getaca("db", registry = reg, version = "2", quiet = TRUE)

  # Publishing a version cost its consumer the delta rather than the whole file.
  expect_equal(net$requested(), c(files$base$url, files$d1$url, files$d2$url))
  expect_equal(getaca:::sha256_file(path), v2$sha256)
})

test_that("an artefact already composed needs none of its parts", {
  local_fetchable()
  local_cache()
  fx <- three_part_fixture()
  reg <- parts_registry(fx$files, fx$composed)
  testthat::local_mocked_bindings(try_one = serves_parts(fx$files)$fn, .package = "getaca")
  getaca("db", registry = reg, quiet = TRUE)

  # A second declaring package finds the composed blob and asks for nothing.
  other <- parts_registry(fx$files, fx$composed, package = "otherpkg")
  testthat::local_mocked_bindings(
    try_one = function(...) stop("the store should have answered this"),
    .package = "getaca"
  )
  path <- getaca("db", registry = other, quiet = TRUE)
  expect_equal(getaca:::sha256_file(path), fx$composed$sha256)
})

test_that("a base and the deltas against it apply in order", {
  local_fetchable()
  local_cache()
  dir <- withr::local_tempdir()
  files <- list(
    base = binary_piece(dir, "base", charToRaw("HELLO-WORLD")),
    d1   = binary_piece(dir, "d1", delta_bytes(5L, "-THERE")),
    d2   = binary_piece(dir, "d2", delta_bytes(11L, "!!"))
  )
  v1 <- payload(dir, "v1.bin", charToRaw("HELLO-THERE"))
  v2 <- payload(dir, "v2.bin", charToRaw("HELLO-THERE!!"))

  reg <- registry("demopkg", current = c(db = "2"), resources = list(
    resource("db", "1", sha256 = v1$sha256, file = "db.bin",
             parts = as_parts(files[c("base", "d1")]), combiner = patcher()),
    resource("db", "2", sha256 = v2$sha256, file = "db.bin",
             parts = as_parts(files), combiner = patcher())
  ))
  net <- serves_parts(files)
  testthat::local_mocked_bindings(try_one = net$fn, .package = "getaca")

  first <- getaca("db", registry = reg, version = "1", quiet = TRUE)
  expect_equal(readBin(first, "raw", n = 11L), charToRaw("HELLO-THERE"))

  second <- getaca("db", registry = reg, version = "2", quiet = TRUE)

  expect_equal(readBin(second, "raw", n = 13L), charToRaw("HELLO-THERE!!"))
  expect_equal(net$requested(),
               c(files$base$url, files$d1$url, files$d2$url))
})

test_that("a version may pick up where the previous artefact left off", {
  local_fetchable()
  local_cache()
  dir <- withr::local_tempdir()
  files <- list(
    base = binary_piece(dir, "base", charToRaw("HELLO-WORLD")),
    d1   = binary_piece(dir, "d1", delta_bytes(5L, "-THERE")),
    d2   = binary_piece(dir, "d2", delta_bytes(11L, "!!"))
  )
  v1 <- payload(dir, "v1.bin", charToRaw("HELLO-THERE"))
  v2 <- payload(dir, "v2.bin", charToRaw("HELLO-THERE!!"))

  # The published artefact of version 1, declared as the first part of version
  # 2. Its digest is the one version 1 already admitted, so a machine holding
  # version 1 finds it in the store and applies a single delta.
  previous <- list(url = "https://parts.invalid/v1.bin", path = v1$path,
                   sha256 = v1$sha256, size = v1$size)

  reg <- registry("demopkg", current = c(db = "2"), resources = list(
    resource("db", "1", sha256 = v1$sha256, file = "db.bin",
             parts = as_parts(files[c("base", "d1")]), combiner = patcher()),
    resource("db", "2", sha256 = v2$sha256, file = "db.bin",
             parts = as_parts(list(previous, files$d2)), combiner = patcher())
  ))
  net <- serves_parts(c(files, list(v1 = previous)))
  testthat::local_mocked_bindings(try_one = net$fn, .package = "getaca")

  getaca("db", registry = reg, version = "1", quiet = TRUE)
  path <- getaca("db", registry = reg, version = "2", quiet = TRUE)

  expect_equal(readBin(path, "raw", n = 13L), charToRaw("HELLO-THERE!!"))
  expect_equal(net$requested(),
               c(files$base$url, files$d1$url, files$d2$url))
})

test_that("an author-supplied combiner is used and recorded", {
  local_fetchable()
  local_cache()
  dir <- withr::local_tempdir()
  files <- series(dir, list(base = "abc", d1 = "def"))
  # Stands in for a delta format: the pieces are combined by something other
  # than running them together, and the result is what the record names.
  target <- file.path(dir, "target.bin")
  writeBin(charToRaw("fedcba"), target)
  composed <- list(path = target, sha256 = getaca:::sha256_file(target),
                   size = unname(file.info(target)$size))

  reverser <- combiner("reverse", function(parts, output) {
    bytes <- unlist(lapply(parts, function(p) {
      readBin(p, "raw", n = file.info(p)$size)
    }), use.names = FALSE)
    writeBin(rev(bytes), output)
  })
  reg <- parts_registry(files, composed, combiner = reverser)
  testthat::local_mocked_bindings(try_one = serves_parts(files)$fn, .package = "getaca")

  path <- getaca("db", registry = reg, quiet = TRUE)

  expect_equal(readBin(path, "raw", n = 6L), charToRaw("fedcba"))
  expect_equal(getaca_info("db", registry = reg)$combiner_id, "reverse")
})


# Failure ----------------------------------------------------------------

test_that("parts that do not compose to the declared bytes blame the declaration", {
  local_fetchable()
  local_cache()
  fx <- three_part_fixture()
  wrong <- fx$composed
  wrong$sha256 <- strrep("e", 64)
  reg <- parts_registry(fx$files, wrong)
  testthat::local_mocked_bindings(try_one = serves_parts(fx$files)$fn, .package = "getaca")

  err <- expect_error(getaca("db", registry = reg, quiet = TRUE),
                      class = "getaca_error_composition")
  expect_equal(err$actor, "author")
  expect_equal(err$parts, 3L)
  expect_equal(err$combiner, "concat")
  expect_match(conditionMessage(err), "not a transfer problem")

  # Nothing that failed to verify is anywhere a reader could reach it.
  expect_false(getaca:::blob_exists(wrong$sha256))
  expect_length(list.files(getaca:::cache_tmp_dir(), pattern = "\\.compose$"), 0L)
})

test_that("a failure names which part of the series it was", {
  local_fetchable()
  local_cache()
  fx <- three_part_fixture()
  reg <- parts_registry(fx$files, fx$composed)
  # The middle piece is served by nobody.
  testthat::local_mocked_bindings(
    try_one = serves_parts(fx$files[c("base", "d2")])$fn, .package = "getaca"
  )

  err <- expect_error(getaca("db", registry = reg, quiet = TRUE),
                      class = "getaca_error_unavailable")
  expect_match(conditionMessage(err), "part 2 of 3", fixed = TRUE)
})

test_that("a part whose bytes moved is reported against the publisher", {
  local_fetchable()
  local_cache()
  fx <- three_part_fixture()
  reg <- parts_registry(fx$files, fx$composed)
  reg$resources[["db"]]$parts[[2]]$sha256 <- strrep("f", 64)
  testthat::local_mocked_bindings(try_one = serves_parts(fx$files)$fn, .package = "getaca")

  err <- expect_error(getaca("db", registry = reg, quiet = TRUE),
                      class = "getaca_error_upstream_changed")
  expect_equal(err$actor, "upstream")
  expect_match(conditionMessage(err), "part 2 of 3", fixed = TRUE)
})

test_that("a damaged part in the store is dropped and fetched again", {
  local_fetchable()
  local_cache()
  dir <- withr::local_tempdir()
  files <- series(dir, list(base = "BASEBASEBASE", d1 = "-one", d2 = "-two"))
  v1 <- composed_of(files[c("base", "d1")], dir, "v1.bin")
  v2 <- composed_of(files[c("base", "d2")], dir, "v2.bin")
  reg <- registry("demopkg", current = c(db = "2"), resources = list(
    resource("db", "1", sha256 = v1$sha256, file = "db.bin",
             parts = as_parts(files[c("base", "d1")])),
    resource("db", "2", sha256 = v2$sha256, file = "db.bin",
             parts = as_parts(files[c("base", "d2")]))
  ))
  net <- serves_parts(files)
  testthat::local_mocked_bindings(try_one = net$fn, .package = "getaca")
  getaca("db", registry = reg, version = "1", quiet = TRUE)

  # Nothing re-verifies a part on a schedule, so composing from a rotted base
  # would otherwise be reported as the declaration failing to produce itself.
  corrupt(getaca:::blob_path(files$base$sha256), "rotted")

  path <- getaca("db", registry = reg, version = "2", quiet = TRUE)

  expect_equal(getaca:::sha256_file(path), v2$sha256)
  expect_equal(sum(net$requested() == files$base$url), 2L)
})

test_that("a combiner that raises is reported as the combiner failing", {
  local_fetchable()
  local_cache()
  fx <- three_part_fixture()
  breaks <- combiner("broken", function(parts, output) stop("no such format"))
  reg <- parts_registry(fx$files, fx$composed, combiner = breaks)
  testthat::local_mocked_bindings(try_one = serves_parts(fx$files)$fn, .package = "getaca")

  expect_error(getaca("db", registry = reg, quiet = TRUE),
               "combiner 'broken' failed")
})

test_that("a combiner that writes nothing is reported rather than hashed", {
  local_fetchable()
  local_cache()
  fx <- three_part_fixture()
  silent <- combiner("silent", function(parts, output) invisible(NULL))
  reg <- parts_registry(fx$files, fx$composed, combiner = silent)
  testthat::local_mocked_bindings(try_one = serves_parts(fx$files)$fn, .package = "getaca")

  expect_error(getaca("db", registry = reg, quiet = TRUE),
               "combiner 'silent' wrote nothing")
})


# Retention --------------------------------------------------------------

test_that("a part stays live while any composed version still holds it", {
  local_fetchable()
  local_cache()
  dir <- withr::local_tempdir()
  files <- series(dir, list(base = "BASEBASEBASE", d1 = "-one", d2 = "-two"))
  v1 <- composed_of(files[c("base", "d1")], dir, "v1.bin")
  v2 <- composed_of(files[c("base", "d2")], dir, "v2.bin")
  reg <- registry("demopkg", current = c(db = "2"), resources = list(
    resource("db", "1", sha256 = v1$sha256, file = "db.bin",
             parts = as_parts(files[c("base", "d1")])),
    resource("db", "2", sha256 = v2$sha256, file = "db.bin",
             parts = as_parts(files[c("base", "d2")]))
  ))
  testthat::local_mocked_bindings(try_one = serves_parts(files)$fn, .package = "getaca")
  getaca("db", registry = reg, version = "1", quiet = TRUE)
  getaca("db", registry = reg, version = "2", quiet = TRUE)

  getaca:::drop_cached(getaca_info("db", registry = reg, version = "1"))
  getaca_clean(what = "unreferenced")

  expect_true(getaca:::blob_exists(files$base$sha256))
  expect_false(getaca:::blob_exists(files$d1$sha256))

  getaca:::drop_cached(getaca_info("db", registry = reg, version = "2"))
  getaca_clean(what = "unreferenced")

  expect_false(getaca:::blob_exists(files$base$sha256))
})

test_that("the catalogue says how many pieces a version arrives in", {
  local_fetchable()
  local_cache()
  fx <- three_part_fixture()
  reg <- parts_registry(fx$files, fx$composed)

  declared <- getaca_catalogue(registry = reg)
  expect_equal(declared$parts, 3L)

  plain <- getaca_catalogue(registry = demo_registry(strrep("a", 64)))
  expect_equal(plain$parts, 0L)
})


# Authoring formats ------------------------------------------------------

test_that("parts are expressible in an authoring format", {
  reg <- as_registry(list(
    db = list(
      version = "1",
      sha256 = strrep("a", 64),
      file = "db.bin",
      parts = list(
        list(url = "https://e.org/base.bin", sha256 = strrep("b", 64), size = 12),
        list(url = "https://e.org/d1.bin", sha256 = strrep("c", 64))
      )
    )
  ), package = "demopkg")

  rec <- reg$resources[["db"]]
  expect_length(rec$parts, 2L)
  expect_equal(rec$parts[[1]]$sha256, strrep("b", 64))
  expect_true(is.na(rec$parts[[2]]$size))
  expect_equal(rec$file, "db.bin")
})

test_that("an authoring format cannot name a combiner it cannot carry", {
  spec <- list(db = list(
    version = "1", sha256 = strrep("a", 64), file = "db.bin",
    combiner = "bsdiff",
    parts = list(list(url = "https://e.org/base.bin", sha256 = strrep("b", 64)))
  ))
  expect_error(as_registry(spec, package = "demopkg"),
               class = "getaca_error_invalid_registry")

  spec$db$combiner <- "concat"
  expect_s3_class(as_registry(spec, package = "demopkg"), "getaca_registry")
})
