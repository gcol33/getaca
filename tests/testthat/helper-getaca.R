# Every test runs against its own cache, so nothing touches the real
# R_user_dir and tests never depend on each other's leftovers.
local_cache <- function(env = parent.frame()) {
  dir <- withr::local_tempdir(.local_envir = env)
  withr::local_options(list(getaca.cache = dir), .local_envir = env)
  withr::local_envvar(list(GETACA_CACHE = ""), .local_envir = env)
  dir
}

# Registry lookups and remote fetches are cached for the session, so any test
# that exercises either starts and finishes with a clean slate.
local_registries <- function(env = parent.frame()) {
  getaca::getaca_refresh()
  withr::defer(getaca::getaca_refresh(), envir = env)
}

# Skips unless this is a run where reaching the network is both allowed and
# possible, and releases the check clamp for the duration. The host tested is
# the one the fixtures are served from, so an outage there skips rather than
# reporting a transport bug that is not there.
online_only <- function(env = parent.frame()) {
  testthat::skip_on_cran()
  testthat::skip_if_offline("raw.githubusercontent.com")
  withr::local_envvar(list(NOT_CRAN = "true"), .local_envir = env)
}

# A real file with a real checksum, so verification is exercised rather than
# stubbed.
seed_file <- function(dir, contents = "backbone", name = "res.csv") {
  path <- file.path(dir, name)
  writeBin(charToRaw(contents), path)
  list(path = path, sha256 = getaca:::sha256_file(path))
}

demo_registry <- function(sha, urls = "https://example.invalid/res-1.0.csv",
                          package = "demopkg", version = "1.0", ...) {
  getaca::registry(
    package = package,
    resources = list(
      getaca::resource("res", version, urls = urls, sha256 = sha, ...)
    )
  )
}

# Serves a known file as though it had been downloaded, so a retrieval can be
# exercised end to end without a network.
serves_file <- function(file) {
  function(url, dest, quiet = FALSE) {
    file.copy(file$path, dest, overwrite = TRUE)
    list(success = TRUE, reason = NA_character_)
  }
}

# Seed the cache as though a successful retrieval had happened: through the
# store, so a seeded entry is shaped like a fetched one.
seed_cache <- function(reg, file, name = "res", link = getaca:::link_file) {
  rec <- reg$resources[[name]]
  id <- getaca::resource_id(reg$package, rec$name, rec$version)
  staged <- file.path(getaca:::cache_tmp_dir(), basename(file$path))
  file.copy(file$path, staged, overwrite = TRUE)
  getaca:::admit(staged, rec$sha256)
  placed <- getaca:::place(id, rec, link = link)
  entry <- getaca:::new_entry(id, rec, placed$path, rec$sha256,
                              source = "bundled",
                              digest = getaca::registry_digest(reg),
                              url_used = rec$urls[1], link = placed$link)
  getaca:::put_entry(entry)
  list(id = id, path = placed$path, entry = entry)
}

# What a FAT volume or a network mount leaves: both link calls refuse, and the
# view is an independent copy of the blob rather than another name for it.
copies_only <- function(from, to) {
  if (isTRUE(file.copy(from, to, overwrite = TRUE))) "copy" else NA_character_
}

# A view is a name for shared bytes only where the filesystem allows a link.
# Where it does not, a view is a full copy and occupies its own space, so the
# assertions about sharing do not apply.
skip_unless_linked <- function(entry) {
  if (identical(entry$link, "copy")) {
    testthat::skip("the filesystem refused links, so a view is a full copy")
  }
}

# A package declares resources by shipping inst/getaca/registry.rds and nothing
# else. This builds that layout on a temporary library so discovery is exercised
# the way it actually happens, which is also what the superseded sweep needs:
# what a version is superseded by is whatever the installed registry now names.
install_declaring_package <- function(name, reg, env = parent.frame()) {
  lib <- withr::local_tempdir(.local_envir = env)
  dir.create(file.path(lib, name, "getaca"), recursive = TRUE)
  writeLines(c(paste0("Package: ", name), "Version: 0.0.1"),
             file.path(lib, name, "DESCRIPTION"))
  getaca::registry_write(reg, file.path(lib, name, "getaca", "registry.rds"))
  withr::local_libpaths(lib, action = "prefix", .local_envir = env)
  lib
}

# The store is read-only, so damaging a cached file takes the same step bit rot
# or a determined user would.
corrupt <- function(path, contents) {
  Sys.chmod(path, "0666")
  writeBin(charToRaw(contents), path)
  path
}
