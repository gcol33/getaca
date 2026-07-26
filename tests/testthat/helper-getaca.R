# Every test runs against its own cache, so nothing touches the real
# R_user_dir and tests never depend on each other's leftovers.
local_cache <- function(env = parent.frame()) {
  dir <- withr::local_tempdir(.local_envir = env)
  withr::local_options(list(getaca.cache = dir), .local_envir = env)
  withr::local_envvar(list(GETACA_CACHE = ""), .local_envir = env)
  dir
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

# Seed the cache as though a successful retrieval had happened.
seed_cache <- function(reg, file, name = "res") {
  rec <- reg$resources[[name]]
  id <- getaca::resource_id(reg$package, rec$name, rec$version)
  raw <- getaca:::cache_raw_dir(id)
  dir.create(raw, recursive = TRUE, showWarnings = FALSE)
  final <- file.path(raw, basename(file$path))
  file.copy(file$path, final, overwrite = TRUE)
  entry <- getaca:::new_entry(id, rec, final, rec$sha256,
                              source = "bundled", revision = 1L,
                              url_used = rec$urls[1])
  getaca:::put_entry(entry)
  list(id = id, path = final, entry = entry)
}
