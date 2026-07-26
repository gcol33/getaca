test_that("a registry round-trips through its stored form", {
  dir <- withr::local_tempdir()
  reg <- demo_registry(strrep("a", 64))
  path <- registry_write(reg, file.path(dir, "getaca", "registry.rds"))
  expect_true(file.exists(path))
  expect_equal(registry_read(path), reg)
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

# A package declares resources by shipping inst/getaca/registry.rds and nothing
# else. These build that layout on a temporary library so discovery is tested
# the way it actually happens.
install_declaring_package <- function(name, reg, env = parent.frame()) {
  lib <- withr::local_tempdir(.local_envir = env)
  dir.create(file.path(lib, name, "getaca"), recursive = TRUE)
  writeLines(c(paste0("Package: ", name), "Version: 0.0.1"),
             file.path(lib, name, "DESCRIPTION"))
  registry_write(reg, file.path(lib, name, "getaca", "registry.rds"))
  withr::local_libpaths(lib, action = "prefix", .local_envir = env)
  lib
}

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
  local_registries()
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir(), contents = "payload")
  install_declaring_package("declaringpkg",
                            demo_registry(f$sha256, package = "declaringpkg"))
  testthat::local_mocked_bindings(
    try_one = function(url, dest, quiet = FALSE) {
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
