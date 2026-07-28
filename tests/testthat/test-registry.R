test_that("a registry round-trips through its stored form", {
  dir <- withr::local_tempdir()
  reg <- demo_registry(strrep("a", 64))
  path <- registry_write(reg, file.path(dir, "getaca", "registry.rds"))
  back <- registry_read(path)

  expect_true(file.exists(path))
  expect_equal(registry_digest(back), registry_digest(reg))
  expect_equal(back$resources, reg$resources)
})

test_that("writing dates the state, since publishing is what dates it", {
  dir <- withr::local_tempdir()
  reg <- demo_registry(strrep("a", 64))
  stamp <- as.POSIXct("2026-02-03 04:05:06", tz = "UTC")

  expect_null(reg$created)
  back <- registry_read(registry_write(reg, file.path(dir, "registry.rds"),
                                       created = stamp))
  expect_equal(back$created, stamp)
})

test_that("an older stored form still reads, so a new field costs nothing", {
  dir <- withr::local_tempdir()
  path <- file.path(dir, "registry.rds")
  reg <- demo_registry(strrep("a", 64))

  # What an installed package shipped before the field existed: no `created`,
  # and a `revision` this getaca has never heard of.
  older <- reg
  older$created <- NULL
  older$revision <- 3L
  saveRDS(older, path, version = 3)

  back <- registry_read(path)
  expect_null(back$created)
  expect_equal(registry_digest(back), registry_digest(reg))
})

test_that("a stored form from a newer getaca is refused rather than guessed at", {
  dir <- withr::local_tempdir()
  path <- file.path(dir, "registry.rds")
  ahead <- demo_registry(strrep("a", 64))
  ahead$schema_version <- getaca:::REGISTRY_SCHEMA + 1L
  saveRDS(ahead, path, version = 3)

  expect_error(registry_read(path), class = "getaca_error_invalid_registry")
  expect_error(registry_read(path), "newer getaca")
})

test_that("a registry with no usable schema version is refused", {
  dir <- withr::local_tempdir()
  path <- file.path(dir, "registry.rds")
  broken <- demo_registry(strrep("a", 64))
  broken$schema_version <- NULL
  saveRDS(broken, path, version = 3)

  expect_error(registry_read(path), "no usable schema version")
})

test_that("a lone resource needs no list around it", {
  reg <- registry("demopkg",
                  resource("res", "1.0", urls = "https://e.org/f",
                           sha256 = strrep("a", 64)))

  expect_named(reg$resources, "res")
  expect_s3_class(reg$resources[["res"]], "getaca_resource")
})

test_that("a registry has to declare something", {
  expect_error(registry("demopkg", list()), "declares no resources")
})

test_that("a resource has to come from resource()", {
  expect_error(registry("demopkg", list(list(name = "res", version = "1.0"))),
               "must come from resource\\(\\)")
})

test_that("a remote has to be an https URL", {
  make <- function(remote) {
    registry("demopkg", remote = remote,
             resources = list(resource("res", "1.0", urls = "https://e.org/f",
                                       sha256 = strrep("a", 64))))
  }
  expect_error(make("http://registry.invalid/demopkg.rds"), "must be an https URL")
  expect_error(make("registry.invalid/demopkg.rds"), "must be an https URL")
  expect_silent(make("https://registry.invalid/demopkg.rds"))
})

# A key set that is not text cannot be a key set, and a stored form is where
# that arrives: registry() coerces what the author passes, so this is the shape
# a rewritten file takes rather than a mistake made at the keyboard.
test_that("a stored key set that is not text is refused on read", {
  dir <- withr::local_tempdir()
  path <- file.path(dir, "registry.rds")
  broken <- demo_registry(strrep("a", 64))
  broken$keys <- 42
  saveRDS(broken, path, version = 3)

  expect_error(registry_read(path), "must be public keys")
})

test_that("duplicate declarations are refused", {
  expect_error(
    registry("demopkg", list(
      resource("res", "1.0", urls = "https://e.org/f", sha256 = strrep("a", 64)),
      resource("res", "1.0", urls = "https://e.org/g", sha256 = strrep("b", 64))
    )),
    class = "getaca_error_invalid_registry"
  )
})

test_that("a name offering several versions must say which one is current", {
  expect_error(
    registry("demopkg", list(
      resource("res", "2026-09", urls = "https://e.org/a", sha256 = strrep("a", 64)),
      resource("res", "2026-03", urls = "https://e.org/b", sha256 = strrep("b", 64))
    )),
    class = "getaca_error_invalid_registry"
  )
  expect_error(
    registry("demopkg", list(
      resource("res", "2026-09", urls = "https://e.org/a", sha256 = strrep("a", 64)),
      resource("res", "2026-03", urls = "https://e.org/b", sha256 = strrep("b", 64))
    )),
    "names no current one"
  )
})

test_that("one version per name needs no channel head", {
  reg <- registry("demopkg", list(
    resource("one", "1.0", urls = "https://e.org/a", sha256 = strrep("a", 64)),
    resource("two", "9.9", urls = "https://e.org/b", sha256 = strrep("b", 64))
  ))
  expect_null(reg$current)
  expect_equal(getaca:::select_record(reg, "two")$version, "9.9")
})

test_that("a channel head must name a declared resource and a declared version", {
  expect_error(
    registry("demopkg", current = c(nope = "1.0"), resources = list(
      resource("res", "1.0", urls = "https://e.org/a", sha256 = strrep("a", 64))
    )),
    "does not declare"
  )
  expect_error(
    registry("demopkg", current = c(res = "7.0"), resources = list(
      resource("res", "1.0", urls = "https://e.org/a", sha256 = strrep("a", 64))
    )),
    "not declared \\(has: 1.0\\)"
  )
})

test_that("an unnamed channel head is refused rather than silently ignored", {
  expect_error(
    registry("demopkg", current = "1.0", resources = list(
      resource("res", "1.0", urls = "https://e.org/a", sha256 = strrep("a", 64))
    )),
    "must name one version per resource"
  )
})

test_that("a channel head naming one resource twice is refused", {
  expect_error(
    registry("demopkg", current = c(res = "1.0", res = "2.0"), resources = list(
      resource("res", "1.0", urls = "https://e.org/a", sha256 = strrep("a", 64)),
      resource("res", "2.0", urls = "https://e.org/b", sha256 = strrep("b", 64))
    )),
    "names resource 'res' more than once"
  )
})

# A YAML or JSON authoring file arrives as a list, so the same channel head has
# to be accepted in that shape as in the named vector the R constructor takes.
test_that("a channel head may arrive as a list", {
  reg <- registry("demopkg", current = list(res = "2.0"), resources = list(
    resource("res", "1.0", urls = "https://e.org/a", sha256 = strrep("a", 64)),
    resource("res", "2.0", urls = "https://e.org/b", sha256 = strrep("b", 64))
  ))

  expect_equal(reg$current, c(res = "2.0"))
  expect_equal(resolve_resource("res", registry = reg)$id$version, "2.0")
})

test_that("a channel head survives the stored form", {
  dir <- withr::local_tempdir()
  reg <- registry("demopkg", current = c(res = "1.0"), resources = list(
    resource("res", "1.0", urls = "https://e.org/a", sha256 = strrep("a", 64)),
    resource("res", "2.0", urls = "https://e.org/b", sha256 = strrep("b", 64))
  ))
  path <- registry_write(reg, file.path(dir, "registry.rds"))
  expect_equal(registry_read(path)$current, c(res = "1.0"))
})

test_that("a stored registry that lost its channel head is refused on read", {
  dir <- withr::local_tempdir()
  reg <- registry("demopkg", current = c(res = "2.0"), resources = list(
    resource("res", "1.0", urls = "https://e.org/a", sha256 = strrep("a", 64)),
    resource("res", "2.0", urls = "https://e.org/b", sha256 = strrep("b", 64))
  ))
  reg$current <- NULL
  path <- file.path(dir, "registry.rds")
  saveRDS(reg, path, version = 3)

  expect_error(registry_read(path), class = "getaca_error_invalid_registry")
})

test_that("two packages may declare the same resource name without colliding", {
  a <- demo_registry(strrep("a", 64), package = "pkgA")
  b <- demo_registry(strrep("b", 64), package = "pkgB")
  ida <- resolve_resource("res", registry = a)$id
  idb <- resolve_resource("res", registry = b)$id
  expect_false(identical(format(ida), format(idb)))
  expect_false(identical(getaca:::cache_version_dir(ida),
                         getaca:::cache_version_dir(idb)))
})

test_that("an unknown resource name names what is on offer", {
  reg <- demo_registry(strrep("a", 64))
  expect_error(
    resolve_resource("nope", registry = reg),
    class = "getaca_error_invalid_registry"
  )
  expect_error(resolve_resource("nope", registry = reg), "res")
})

test_that("YAML authoring produces the same model as the R constructor", {
  skip_if_not_installed("yaml")
  dir <- withr::local_tempdir()
  path <- file.path(dir, "registry.yml")
  writeLines(c(
    "res:",
    "  version: '1.0'",
    "  urls:",
    "    - https://example.invalid/res-1.0.csv",
    paste0("  sha256: '", strrep("a", 64), "'"),
    "  license: CC-BY-4.0"
  ), path)

  reg <- as_registry(path, package = "demopkg")
  expect_equal(reg$resources$res$sha256, strrep("a", 64))
  expect_equal(reg$resources$res$license, "CC-BY-4.0")
  expect_equal(reg$resources$res$urls, "https://example.invalid/res-1.0.csv")
})

test_that("either spelling of license is accepted from an authoring format", {
  skip_if_not_installed("yaml")
  dir <- withr::local_tempdir()
  path <- file.path(dir, "registry.yml")
  writeLines(c(
    "res:",
    "  version: '1.0'",
    "  url: https://example.invalid/res-1.0.csv",
    paste0("  sha256: '", strrep("a", 64), "'"),
    "  licence: CC-BY-4.0"
  ), path)

  expect_equal(as_registry(path, package = "demopkg")$resources$res$license,
               "CC-BY-4.0")
})

test_that("JSON authoring produces the same model as YAML", {
  skip_if_not_installed("jsonlite")
  dir <- withr::local_tempdir()
  path <- file.path(dir, "registry.json")
  writeLines(jsonlite::toJSON(list(res = list(
    version = "1.0",
    urls = "https://example.invalid/res-1.0.csv",
    sha256 = strrep("a", 64),
    license = "CC-BY-4.0"
  )), auto_unbox = TRUE), path)

  reg <- as_registry(path, package = "demopkg")
  expect_equal(reg$resources$res$sha256, strrep("a", 64))
  expect_equal(reg$resources$res$license, "CC-BY-4.0")
})

test_that("an authoring format getaca does not read is named", {
  dir <- withr::local_tempdir()
  path <- file.path(dir, "registry.toml")
  writeLines("res = 1", path)
  expect_error(as_registry(path, package = "demopkg"), "Unsupported registry format")
})

test_that("a registry is discovered from the conventional path, with no registration", {
  local_registries()
  install_declaring_package("declaringpkg",
                            demo_registry(strrep("a", 64), package = "declaringpkg"))

  reg <- registry_for("declaringpkg")

  expect_s3_class(reg, "getaca_registry")
  expect_equal(reg$package, "declaringpkg")
})

test_that("a package shipping no registry resolves to NULL rather than failing", {
  local_registries()
  expect_null(registry_for("stats"))
})

test_that("a registry naming a package other than its host is refused", {
  local_registries()
  install_declaring_package("declaringpkg",
                            demo_registry(strrep("a", 64), package = "someoneelse"))

  expect_error(registry_for("declaringpkg"),
               class = "getaca_error_invalid_registry")
  expect_error(registry_for("declaringpkg"), "declares package 'someoneelse'")
})

test_that("a discovered registry is read once per session", {
  local_registries()
  lib <- install_declaring_package("declaringpkg",
                                   demo_registry(strrep("a", 64), package = "declaringpkg"))

  first <- registry_for("declaringpkg")
  unlink(file.path(lib, "declaringpkg", "getaca", "registry.rds"))
  expect_equal(registry_for("declaringpkg"), first)

  getaca_refresh()
  expect_null(registry_for("declaringpkg"))
})

test_that("retrieval reaches a declaring package by name alone", {
  local_fetchable()
  local_registries()
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir(), contents = "payload")
  install_declaring_package("declaringpkg",
                            demo_registry(f$sha256, package = "declaringpkg"))
  testthat::local_mocked_bindings(
    try_one = function(url, dest, progress = NULL) {
      file.copy(f$path, dest, overwrite = TRUE)
      list(success = TRUE, reason = NA_character_)
    },
    .package = "getaca"
  )

  path <- getaca("res", package = "declaringpkg", quiet = TRUE)

  expect_true(file.exists(path))
  expect_equal(getaca:::sha256_file(path), f$sha256)
  expect_equal(getaca_info("res", package = "declaringpkg")$package, "declaringpkg")
})
