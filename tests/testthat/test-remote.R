# Consulting a remote registry is a decision about which declaration to trust.
# A fake fetch writes a chosen registry to the destination, so every branch of
# that decision is exercised without a network.
fake_fetch <- function(reg = NULL, ok = TRUE, corrupt = FALSE, calls = NULL) {
  function(url, dest) {
    if (!is.null(calls)) calls$n <- calls$n + 1L
    if (!ok) return(FALSE)
    if (corrupt) {
      writeBin(charToRaw("this is not a registry"), dest)
      return(TRUE)
    }
    registry_write(reg, dest)
    TRUE
  }
}

with_remote <- function(resources, ...) {
  registry("demopkg", resources, remote = "https://registry.invalid/demopkg.rds", ...)
}

one_resource <- function(sha = strrep("a", 64), version = "1.0") {
  resource("res", version, urls = "https://example.invalid/res.csv", sha256 = sha)
}

# The remote state a bundled registry is behind: a second version published,
# and the channel head moved onto it.
ahead_registry <- function() {
  with_remote(list(one_resource(), one_resource(strrep("b", 64), "2.0")),
              current = c(res = "2.0"))
}

test_that("a reachable remote registry supersedes the bundled one", {
  local_registries()
  bundled <- with_remote(list(one_resource()))
  ahead <- ahead_registry()

  got <- getaca:::remote_channel(bundled, fetch = fake_fetch(ahead))
  expect_equal(registry_digest(got), registry_digest(ahead))
  expect_length(got$resources, 2L)
})

test_that("the remote channel is what makes a new version resolvable", {
  local_registries()
  bundled <- with_remote(list(one_resource()))
  ahead <- ahead_registry()

  testthat::local_mocked_bindings(fetch_registry = fake_fetch(ahead), .package = "getaca")
  expect_equal(resolve_resource("res", registry = bundled)$id$version, "1.0")

  under_current <- resolve_resource("res", registry = bundled, policy = "current")
  expect_equal(under_current$id$version, "2.0")
  expect_equal(under_current$source, "current")
  # Provenance names the state that chose the record, which under this policy
  # is the remote one rather than the registry the call was handed.
  expect_equal(under_current$digest, registry_digest(ahead))
})

test_that("an unreachable remote falls back to bundled rather than failing", {
  local_registries()
  bundled <- with_remote(list(one_resource()))

  expect_message(
    got <- getaca:::remote_channel(bundled, fetch = fake_fetch(ok = FALSE)),
    "could not reach the remote registry"
  )
  expect_equal(registry_digest(got), registry_digest(bundled))
  expect_length(got$resources, 1L)
})

test_that("an unreadable remote falls back to bundled rather than failing", {
  local_registries()
  bundled <- with_remote(list(one_resource()))

  expect_message(
    got <- getaca:::remote_channel(bundled, fetch = fake_fetch(corrupt = TRUE)),
    "unreadable"
  )
  expect_length(got$resources, 1L)
})

test_that("a remote declaring a different package is refused", {
  local_registries()
  bundled <- with_remote(list(one_resource()))
  wrong <- registry("otherpkg", list(one_resource()))

  expect_error(
    getaca:::remote_channel(bundled, fetch = fake_fetch(wrong)),
    class = "getaca_error_invalid_registry"
  )
  expect_error(
    getaca:::remote_channel(bundled, fetch = fake_fetch(wrong)),
    "declares package 'otherpkg'"
  )
})

test_that("a remote redefining a published version is refused over the wire", {
  local_registries()
  bundled <- with_remote(list(one_resource(strrep("a", 64))))
  rewritten <- with_remote(list(one_resource(strrep("b", 64))))

  expect_error(
    getaca:::remote_channel(bundled, fetch = fake_fetch(rewritten)),
    class = "getaca_error_invalid_registry"
  )
  expect_error(
    getaca:::remote_channel(bundled, fetch = fake_fetch(rewritten)),
    "res@1.0"
  )
})

test_that("a registry with no remote never reaches for one", {
  local_registries()
  plain <- registry("demopkg", list(one_resource()))
  exploding <- function(url, dest) stop("should not have been called")
  expect_equal(registry_digest(getaca:::remote_channel(plain, fetch = exploding)),
               registry_digest(plain))
})

test_that("a remote registry is fetched once per session", {
  local_registries()
  calls <- new.env(parent = emptyenv())
  calls$n <- 0L
  bundled <- with_remote(list(one_resource()))
  fetch <- fake_fetch(ahead_registry(), calls = calls)

  getaca:::remote_channel(bundled, fetch = fetch)
  getaca:::remote_channel(bundled, fetch = fetch)
  expect_equal(calls$n, 1L)

  getaca_refresh()
  getaca:::remote_channel(bundled, fetch = fetch)
  expect_equal(calls$n, 2L)
})

test_that("a failed fetch is not cached, so the next call tries again", {
  local_registries()
  calls <- new.env(parent = emptyenv())
  calls$n <- 0L
  bundled <- with_remote(list(one_resource()))
  fetch <- fake_fetch(ok = FALSE, calls = calls)

  suppressMessages({
    getaca:::remote_channel(bundled, fetch = fetch)
    getaca:::remote_channel(bundled, fetch = fetch)
  })
  expect_equal(calls$n, 2L)
})

# --------------------------------------------------------------- signed remotes

# Serves a registry and its detached signature from one fake host, so a
# downgrade can be staged by withholding just the signature.
signed_host <- function(reg, key, created = as.POSIXct("2026-06-01", tz = "UTC"),
                        expires = as.POSIXct("2026-12-31", tz = "UTC"),
                        sign = TRUE, serve_signature = TRUE,
                        env = parent.frame()) {
  dir <- withr::local_tempdir(.local_envir = env)
  path <- file.path(dir, "registry.rds")
  registry_write(reg, path, created = created)
  if (sign) registry_sign(path, key = key$path, expires = expires)

  function(url, dest) {
    wants_signature <- grepl("\\.sig$", url)
    if (wants_signature && !serve_signature) return(FALSE)
    src <- if (wants_signature) paste0(path, ".sig") else path
    if (!file.exists(src)) return(FALSE)
    file.copy(src, dest, overwrite = TRUE)
    TRUE
  }
}

remote_key <- function(env = parent.frame()) {
  path <- withr::local_tempfile(.local_envir = env)
  list(path = path, public = registry_keygen(path))
}

test_that("a signed remote registry is accepted", {
  local_registries()
  key <- remote_key()
  bundled <- with_remote(list(one_resource()), keys = key$public)
  ahead <- with_remote(list(one_resource(), one_resource(strrep("b", 64), "2.0")),
                       current = c(res = "2.0"), keys = key$public)

  got <- getaca:::remote_channel(bundled, fetch = signed_host(ahead, key))
  expect_equal(registry_digest(got), registry_digest(ahead))
  expect_length(got$resources, 2L)
})

test_that("a package declaring no keys never asks for a signature", {
  local_registries()
  asked <- new.env(parent = emptyenv())
  asked$sig <- FALSE
  bundled <- with_remote(list(one_resource()))
  ahead <- ahead_registry()

  inner <- fake_fetch(ahead)
  fetch <- function(url, dest) {
    if (grepl("\\.sig$", url)) asked$sig <- TRUE
    inner(url, dest)
  }

  got <- getaca:::remote_channel(bundled, fetch = fetch)
  expect_equal(registry_digest(got), registry_digest(ahead))
  expect_false(asked$sig)
})

test_that("a registry that arrives without its signature is refused", {
  local_registries()
  key <- remote_key()
  bundled <- with_remote(list(one_resource()), keys = key$public)
  ahead <- with_remote(list(one_resource(), one_resource(strrep("b", 64), "2.0")),
                       current = c(res = "2.0"), keys = key$public)

  # The registry is served and the signature is withheld, which is the shape a
  # downgrade takes when one host serves both.
  fetch <- signed_host(ahead, key, serve_signature = FALSE)
  expect_error(getaca:::remote_channel(bundled, fetch = fetch),
               class = "getaca_error_signature")
  expect_error(getaca:::remote_channel(bundled, fetch = fetch),
               "no signature could be fetched")
})

test_that("an unreachable host still falls back, signed or not", {
  local_registries()
  key <- remote_key()
  bundled <- with_remote(list(one_resource()), keys = key$public)

  # Nothing arrives at all, which is an availability failure rather than an
  # integrity one, and is the one case that keeps its soft fallback.
  expect_message(
    got <- getaca:::remote_channel(bundled, fetch = fake_fetch(ok = FALSE)),
    "could not reach the remote registry"
  )
  expect_equal(registry_digest(got), registry_digest(bundled))
})

test_that("a forged registry served with a valid signature is refused", {
  local_registries()
  key <- remote_key()
  bundled <- with_remote(list(one_resource()), keys = key$public)
  genuine <- with_remote(list(one_resource(), one_resource(strrep("b", 64), "2.0")),
                         current = c(res = "2.0"), keys = key$public)

  dir <- withr::local_tempdir()
  good <- file.path(dir, "registry.rds")
  registry_write(genuine, good, created = as.POSIXct("2026-06-01", tz = "UTC"))
  registry_sign(good, key = key$path)

  forged <- with_remote(list(one_resource(),
                             one_resource(strrep("c", 64), "2.0")),
                        current = c(res = "2.0"), keys = key$public)
  bad <- file.path(dir, "forged.rds")
  registry_write(forged, bad, created = as.POSIXct("2026-06-01", tz = "UTC"))

  # The genuine signature, over a registry it does not describe.
  fetch <- function(url, dest) {
    src <- if (grepl("\\.sig$", url)) paste0(good, ".sig") else bad
    file.copy(src, dest, overwrite = TRUE)
    TRUE
  }
  expect_error(getaca:::remote_channel(bundled, fetch = fetch),
               class = "getaca_error_signature")
  expect_error(getaca:::remote_channel(bundled, fetch = fetch),
               "signature covers")
})

test_that("a registry signed by an untrusted key is refused", {
  local_registries()
  key <- remote_key()
  attacker <- remote_key()
  bundled <- with_remote(list(one_resource()), keys = key$public)
  # Self-consistent: the fetched registry nominates the key that signed it.
  ahead <- with_remote(list(one_resource(), one_resource(strrep("b", 64), "2.0")),
                       current = c(res = "2.0"), keys = attacker$public)

  fetch <- signed_host(ahead, attacker)
  expect_error(getaca:::remote_channel(bundled, fetch = fetch),
               class = "getaca_error_signature")
  expect_error(getaca:::remote_channel(bundled, fetch = fetch),
               "does not list as a signing key")
})

test_that("an expired signature is refused", {
  local_registries()
  key <- remote_key()
  bundled <- with_remote(list(one_resource()), keys = key$public)
  ahead <- with_remote(list(one_resource(), one_resource(strrep("b", 64), "2.0")),
                       current = c(res = "2.0"), keys = key$public)

  fetch <- signed_host(ahead, key,
                       created = as.POSIXct("2020-01-01", tz = "UTC"),
                       expires = as.POSIXct("2020-04-01", tz = "UTC"))
  expect_error(getaca:::remote_channel(bundled, fetch = fetch),
               class = "getaca_error_signature")
  expect_error(getaca:::remote_channel(bundled, fetch = fetch), "expired on")
})

test_that("a signed but superseded registry is refused as a rollback", {
  local_registries()
  key <- remote_key()
  bundled <- with_remote(list(one_resource()), keys = key$public)
  # What the installed package was built from, which is what a replayed older
  # state has to beat.
  bundled$created <- as.POSIXct("2026-06-01", tz = "UTC")

  old <- with_remote(list(one_resource(), one_resource(strrep("b", 64), "2.0")),
                     current = c(res = "2.0"), keys = key$public)
  fetch <- signed_host(old, key, created = as.POSIXct("2026-01-01", tz = "UTC"))

  expect_error(getaca:::remote_channel(bundled, fetch = fetch),
               class = "getaca_error_signature")
  expect_error(getaca:::remote_channel(bundled, fetch = fetch),
               "older than the declaration already installed")
})

test_that("a signature does not excuse a redefined version", {
  local_registries()
  key <- remote_key()
  bundled <- with_remote(list(one_resource(strrep("a", 64))), keys = key$public)
  rewritten <- with_remote(list(one_resource(strrep("b", 64))), keys = key$public)

  fetch <- signed_host(rewritten, key)
  expect_error(getaca:::remote_channel(bundled, fetch = fetch),
               class = "getaca_error_invalid_registry")
  expect_error(getaca:::remote_channel(bundled, fetch = fetch), "res@1.0")
})

test_that("pinning under the current policy freezes the remote state", {
  local_registries()
  # The policy is the point of this test, so the check clamp is released and
  # the environment is neutralised rather than inherited.
  withr::local_envvar(list(NOT_CRAN = "true", GETACA_POLICY = "", GETACA_OFFLINE = ""))
  withr::local_options(list(getaca.policy = NULL))
  dir <- withr::local_tempdir()
  pins <- file.path(dir, "getaca.pins.rds")
  ahead <- ahead_registry()

  testthat::local_mocked_bindings(fetch_registry = fake_fetch(ahead), .package = "getaca")
  testthat::local_mocked_bindings(
    registry_for = function(package) with_remote(list(one_resource()), policy = "current"),
    .package = "getaca"
  )

  getaca_pin("demopkg", path = pins)
  frozen <- readRDS(pins)
  expect_equal(registry_digest(frozen$demopkg), registry_digest(ahead))
  expect_length(frozen$demopkg$resources, 2L)
})
