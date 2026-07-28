# A mirror that refuses to serve. `http` is what the mirror loop classifies on,
# so a stand-in has to carry it the way the real transport does.
refuses <- function(status = 401L) {
  function(url, dest, progress = NULL, auth = NULL) {
    list(success = FALSE, reason = paste("HTTP", status), http = status)
  }
}

# Serves the file only when a credential arrives, which is what an archive
# behind a token does.
serves_to_credential <- function(file, status = 401L) {
  function(url, dest, progress = NULL, auth = NULL) {
    if (is.null(auth)) {
      return(list(success = FALSE, reason = paste("HTTP", status), http = status))
    }
    file.copy(file$path, dest, overwrite = TRUE)
    list(success = TRUE, reason = NA_character_, http = 200L)
  }
}

authed_registry <- function(sha, urls, ..., register = NULL) {
  getaca::registry(
    package = "demopkg",
    auth = list(getaca::auth_host("data.example.invalid",
                                  getaca::bearer("GETACA_TEST_TOKEN"),
                                  register = register)),
    resources = list(getaca::resource("res", "1.0", urls = urls, sha256 = sha, ...))
  )
}

test_that("a scheme names environment variables and refuses a credential", {
  expect_s3_class(bearer("EXAMPLE_TOKEN"), "getaca_auth_scheme")
  expect_equal(unname(bearer("EXAMPLE_TOKEN")$variables), "EXAMPLE_TOKEN")
  expect_equal(unname(basic("U", "P")$variables), c("U", "P"))

  # The failure mode worth catching on the author's machine: pasting the token
  # itself where the variable name goes.
  expect_error(bearer("ghp_R2d2NotAVariableName!"), class = "getaca_error_invalid_registry")
  expect_error(basic("EXAMPLE_USER", "hunter2!"), class = "getaca_error_invalid_registry")
})

test_that("an auth host is a bare host with a real scheme", {
  expect_s3_class(auth_host("data.example.org", bearer("T")), "getaca_auth_host")

  expect_error(auth_host("https://data.example.org", bearer("T")),
               class = "getaca_error_invalid_registry")
  expect_error(auth_host("data.example.org/files", bearer("T")),
               class = "getaca_error_invalid_registry")
  expect_error(auth_host("data.example.org", "bearer"),
               class = "getaca_error_invalid_registry")
  expect_error(auth_host("data.example.org", bearer("T"), register = "http://x.org"),
               class = "getaca_error_invalid_registry")
})

test_that("a registry takes auth declarations and refuses a duplicated host", {
  reg <- authed_registry(strrep("a", 64), "https://data.example.invalid/res-1.0.csv")
  expect_length(reg$auth, 1L)

  expect_error(
    getaca::registry("demopkg",
      auth = list(auth_host("data.example.org", bearer("A")),
                  auth_host("data.example.org", bearer("B"))),
      resources = list(resource("res", "1.0", urls = "https://example.invalid/x",
                                sha256 = strrep("a", 64)))),
    class = "getaca_error_invalid_registry"
  )
  expect_error(
    getaca::registry("demopkg", auth = list("data.example.org"),
      resources = list(resource("res", "1.0", urls = "https://example.invalid/x",
                                sha256 = strrep("a", 64)))),
    class = "getaca_error_invalid_registry"
  )
})

test_that("the host a URL addresses is what a credential is matched on", {
  expect_equal(getaca:::url_host("https://data.example.org/files/x.csv"),
               "data.example.org")
  expect_equal(getaca:::url_host("https://DATA.Example.ORG/x"), "data.example.org")
  expect_equal(getaca:::url_host("https://data.example.org:8443/x"),
               "data.example.org")
  expect_equal(getaca:::url_host("https://data.example.org"), "data.example.org")

  # Userinfo is where a URL can be dressed as a host it does not reach. What
  # follows the last `@` is the host the request goes to, and the credential
  # follows the request.
  expect_equal(getaca:::url_host("https://data.example.org@attacker.invalid/x"),
               "attacker.invalid")
  expect_equal(getaca:::url_host("https://user:pw@data.example.org/x"),
               "data.example.org")
})

test_that("a credential reaches its own host and no other", {
  auth <- list(auth_host("data.example.org", bearer("GETACA_TEST_TOKEN")))
  withr::local_envvar(list(GETACA_TEST_TOKEN = "s3cret"))

  expect_null(getaca:::credential_secret("https://other.example.org/x", auth))
  expect_null(getaca:::credential_demand("https://other.example.org/x", auth))
  # No wildcard, so a subdomain is a different host rather than a covered one.
  expect_null(getaca:::credential_secret("https://sub.data.example.org/x", auth))
  expect_null(getaca:::credential_secret("https://data.example.org.evil.invalid/x", auth))

  got <- getaca:::credential_secret("https://data.example.org/x", auth)
  expect_equal(got, list(scheme = "bearer", header = "Bearer s3cret"))
})

test_that("basic authentication carries both variables or neither", {
  auth <- list(auth_host("data.example.org", basic("GETACA_TEST_USER",
                                                   "GETACA_TEST_PASSWORD")))
  url <- "https://data.example.org/x"

  withr::with_envvar(list(GETACA_TEST_USER = "ada", GETACA_TEST_PASSWORD = ""), {
    expect_null(getaca:::credential_secret(url, auth))
    expect_equal(getaca:::credential_demand(url, auth)$missing, "GETACA_TEST_PASSWORD")
  })

  withr::with_envvar(list(GETACA_TEST_USER = "ada", GETACA_TEST_PASSWORD = "pw"), {
    expect_equal(getaca:::credential_secret(url, auth),
                 list(scheme = "basic", userpwd = "ada:pw"))
    expect_length(getaca:::credential_demand(url, auth)$missing, 0L)
  })
})

test_that("what a URL demands is answered without reading the credential", {
  auth <- list(auth_host("data.example.org", bearer("GETACA_TEST_TOKEN"),
                         register = "https://data.example.org/register"))
  withr::local_envvar(list(GETACA_TEST_TOKEN = "s3cret"))

  d <- getaca:::credential_demand("https://data.example.org/x", auth)

  expect_equal(d$host, "data.example.org")
  expect_equal(d$scheme, "bearer")
  expect_equal(d$variables, "GETACA_TEST_TOKEN")
  expect_length(d$missing, 0L)
  expect_equal(d$register, "https://data.example.org/register")
  # The whole point of the split: the value is nowhere in what a message is
  # built from.
  expect_false(any(grepl("s3cret", unlist(d), fixed = TRUE)))
})

test_that("a handle takes either scheme", {
  # libcurl attaching the header, and withholding it across hosts, is its own
  # documented behaviour and is exercised only by a real request. What is
  # decided here is that both schemes reach a handle without error.
  expect_s3_class(
    getaca:::transfer_handle("https://data.example.org/x", 0,
                             list(scheme = "bearer", header = "Bearer s3cret")),
    "curl_handle"
  )
  expect_s3_class(
    getaca:::transfer_handle("https://data.example.org/x", 0,
                             list(scheme = "basic", userpwd = "ada:pw")),
    "curl_handle"
  )
  expect_s3_class(getaca:::transfer_handle("https://data.example.org/x", 0, NULL),
                  "curl_handle")
})

test_that("a refusal everywhere is a credential problem, not an outage", {
  cache <- local_cache()
  local_fetchable()
  withr::local_envvar(list(GETACA_TEST_TOKEN = ""))

  reg <- authed_registry(strrep("a", 64), "https://data.example.invalid/res-1.0.csv",
                         register = "https://data.example.invalid/register")
  id <- getaca::resource_id("demopkg", "res", "1.0")

  err <- expect_error(
    getaca:::fetch_to_temp(id, reg$resources[["res"]], quiet = TRUE,
                           transport = refuses(401L), auth = reg$auth),
    class = "getaca_error_credentials"
  )
  expect_equal(err$actor, "user")
  expect_match(conditionMessage(err), "GETACA_TEST_TOKEN")
  expect_match(conditionMessage(err), "not set")
  expect_match(conditionMessage(err), "data.example.invalid/register", fixed = TRUE)
})

test_that("a credential that is set and still refused says so", {
  cache <- local_cache()
  local_fetchable()
  withr::local_envvar(list(GETACA_TEST_TOKEN = "s3cret"))

  reg <- authed_registry(strrep("a", 64), "https://data.example.invalid/res-1.0.csv")
  id <- getaca::resource_id("demopkg", "res", "1.0")

  err <- expect_error(
    getaca:::fetch_to_temp(id, reg$resources[["res"]], quiet = TRUE,
                           transport = refuses(403L), auth = reg$auth),
    class = "getaca_error_credentials"
  )
  expect_match(conditionMessage(err), "set, and refused")
  # A message travels into logs and bug reports, so the credential must not.
  expect_false(grepl("s3cret", conditionMessage(err), fixed = TRUE))
})

test_that("a refusal from a host with no declaration names the author", {
  cache <- local_cache()
  local_fetchable()

  reg <- demo_registry(strrep("a", 64), "https://public.example.invalid/res-1.0.csv")
  id <- getaca::resource_id("demopkg", "res", "1.0")

  err <- expect_error(
    getaca:::fetch_to_temp(id, reg$resources[["res"]], quiet = TRUE,
                           transport = refuses(403L), auth = NULL),
    class = "getaca_error_credentials"
  )

  # No variable exists to be set, so the message must not ask for one and the
  # actor is whoever declared the location.
  expect_equal(err$actor, "author")
  expect_match(conditionMessage(err), "names no credential")
  expect_false(grepl("set the variables named above", conditionMessage(err), fixed = TRUE))
  expect_match(conditionMessage(err), "report it to the declaring package")
})

test_that("a mixed set of failures keeps the broader condition", {
  cache <- local_cache()
  local_fetchable()

  reg <- authed_registry(strrep("a", 64),
                         c("https://data.example.invalid/res-1.0.csv",
                           "https://mirror.example.invalid/res-1.0.csv"))
  id <- getaca::resource_id("demopkg", "res", "1.0")
  mixed <- function(url, dest, progress = NULL, auth = NULL) {
    if (grepl("^https://data\\.", url)) {
      list(success = FALSE, reason = "HTTP 401", http = 401L)
    } else {
      list(success = FALSE, reason = "HTTP 503", http = 503L)
    }
  }

  expect_error(
    getaca:::fetch_to_temp(id, reg$resources[["res"]], quiet = TRUE,
                           transport = mixed, auth = reg$auth),
    class = "getaca_error_unavailable"
  )
})

test_that("a public mirror still answers when the private one refuses", {
  cache <- local_cache()
  local_fetchable()
  withr::local_envvar(list(GETACA_TEST_TOKEN = "s3cret"))
  f <- seed_file(cache)

  reg <- authed_registry(f$sha256,
                         c("https://data.example.invalid/res-1.0.csv",
                           "https://public.example.invalid/res-1.0.csv"))
  id <- getaca::resource_id("demopkg", "res", "1.0")
  # The credential is presented to the host that declares one and rejected;
  # the mirror that needs none is reached in its turn.
  either <- function(url, dest, progress = NULL, auth = NULL) {
    if (!is.null(auth)) {
      return(list(success = FALSE, reason = "HTTP 403", http = 403L))
    }
    file.copy(f$path, dest, overwrite = TRUE)
    list(success = TRUE, reason = NA_character_, http = 200L)
  }

  got <- getaca:::fetch_to_temp(id, reg$resources[["res"]], quiet = TRUE,
                                transport = either, auth = reg$auth)

  expect_equal(got$url, "https://public.example.invalid/res-1.0.csv")
  expect_equal(got$sha256, f$sha256)
})

test_that("a declared credential is carried into the transfer", {
  cache <- local_cache()
  local_fetchable()
  local_registries()
  withr::local_envvar(list(GETACA_TEST_TOKEN = "s3cret"))
  f <- seed_file(cache)

  reg <- authed_registry(f$sha256, "https://data.example.invalid/res-1.0.csv")
  id <- getaca::resource_id("demopkg", "res", "1.0")

  got <- getaca:::fetch_to_temp(id, reg$resources[["res"]], quiet = TRUE,
                                transport = serves_to_credential(f),
                                auth = reg$auth)

  expect_equal(got$sha256, f$sha256)
})

test_that("a part is matched by the same host rule as a whole file", {
  cache <- local_cache()
  local_fetchable()
  withr::local_envvar(list(GETACA_TEST_TOKEN = "s3cret"))

  a <- seed_file(cache, "front", "a.bin")
  b <- seed_file(cache, "back", "b.bin")
  whole <- seed_file(cache, "frontback", "whole.bin")

  reg <- getaca::registry(
    package = "demopkg",
    auth = list(getaca::auth_host("data.example.invalid",
                                  getaca::bearer("GETACA_TEST_TOKEN"))),
    resources = list(getaca::resource(
      "res", "1.0", sha256 = whole$sha256, file = "whole.bin",
      parts = list(
        getaca::part("https://data.example.invalid/a.bin", sha256 = a$sha256),
        getaca::part("https://data.example.invalid/b.bin", sha256 = b$sha256)
      )
    ))
  )
  id <- getaca::resource_id("demopkg", "res", "1.0")
  serves_parts <- function(url, dest, progress = NULL, auth = NULL) {
    if (is.null(auth)) return(list(success = FALSE, reason = "HTTP 401", http = 401L))
    file.copy(if (grepl("a\\.bin$", url)) a$path else b$path, dest, overwrite = TRUE)
    list(success = TRUE, reason = NA_character_, http = 200L)
  }

  out <- getaca:::compose_parts(id, reg$resources[["res"]], quiet = TRUE,
                                transport = serves_parts, auth = reg$auth)

  expect_equal(getaca:::sha256_file(out), whole$sha256)
})

test_that("credentials come from the bundled registry, never from a remote one", {
  cache <- local_cache()
  local_registries()
  withr::local_envvar(list(GETACA_POLICY = "current", NOT_CRAN = "true"))

  bundled <- getaca::registry(
    package = "demopkg",
    remote = "https://registry.example.invalid/registry.rds",
    policy = "current",
    auth = list(getaca::auth_host("data.example.invalid",
                                  getaca::bearer("GETACA_TEST_TOKEN"))),
    resources = list(getaca::resource("res", "1.0",
                                      urls = "https://data.example.invalid/res-1.0.csv",
                                      sha256 = strrep("a", 64)))
  )
  # A remote declaration that would send the same credential somewhere else.
  hostile <- getaca::registry(
    package = "demopkg",
    remote = "https://registry.example.invalid/registry.rds",
    policy = "current",
    auth = list(getaca::auth_host("attacker.invalid",
                                  getaca::bearer("GETACA_TEST_TOKEN"))),
    resources = list(getaca::resource("res", "2.0",
                                      urls = "https://attacker.invalid/res-2.0.csv",
                                      sha256 = strrep("b", 64)))
  )
  path <- file.path(cache, "remote.rds")
  getaca::registry_write(hostile, path)

  channel <- getaca:::remote_channel(bundled, fetch = function(url, dest) {
    file.copy(path, dest, overwrite = TRUE)
  })
  expect_equal(channel$resources[[1]]$version, "2.0")

  res <- getaca::resolve_resource("res", registry = bundled, policy = "current")

  # The remote chose the record, and the bundled declaration still decides
  # where a credential may be sent.
  expect_equal(res$record$version, "2.0")
  expect_equal(vapply(res$auth, function(a) a$host, character(1)),
               "data.example.invalid")
  expect_null(getaca:::credential_secret("https://attacker.invalid/res-2.0.csv",
                                         res$auth))
})

test_that("getaca_credentials reports what is declared and what is set", {
  local_registries()

  reg <- authed_registry(strrep("a", 64), "https://data.example.invalid/res-1.0.csv",
                         register = "https://data.example.invalid/register")

  withr::with_envvar(list(GETACA_TEST_TOKEN = ""), {
    out <- getaca_credentials(registry = reg)
    expect_equal(nrow(out), 1L)
    expect_equal(out$host, "data.example.invalid")
    expect_equal(out$scheme, "bearer")
    expect_equal(out$variable, "GETACA_TEST_TOKEN")
    expect_false(out$set)
    expect_equal(out$register, "https://data.example.invalid/register")
  })

  withr::with_envvar(list(GETACA_TEST_TOKEN = "s3cret"), {
    out <- getaca_credentials(registry = reg)
    expect_true(out$set)
    # A report of what is set is not a report of what it is set to.
    expect_false(any(grepl("s3cret", unlist(lapply(out, as.character)), fixed = TRUE)))
  })
})

test_that("getaca_credentials keeps its columns when nothing is declared", {
  reg <- demo_registry(strrep("a", 64))

  out <- getaca_credentials(registry = reg)

  expect_equal(nrow(out), 0L)
  expect_setequal(names(out),
                  c("package", "host", "scheme", "variable", "set", "register"))
})

test_that("auth renders in the manifest, sorted by host, values absent", {
  reg <- getaca::registry(
    package = "demopkg",
    auth = list(
      getaca::auth_host("zeta.example.org", getaca::basic("Z_USER", "Z_PASSWORD")),
      getaca::auth_host("alpha.example.org", getaca::bearer("A_TOKEN"),
                        register = "https://alpha.example.org/register")
    ),
    resources = list(getaca::resource("res", "1.0",
                                      urls = "https://alpha.example.org/res-1.0.csv",
                                      sha256 = strrep("a", 64)))
  )

  lines <- unclass(getaca::registry_manifest(reg))
  auth_lines <- grep("^auth |^  register ", lines, value = TRUE)

  expect_equal(auth_lines, c(
    "auth alpha.example.org bearer A_TOKEN",
    "  register https://alpha.example.org/register",
    "auth zeta.example.org basic Z_USER Z_PASSWORD"
  ))
})

test_that("a registry declaring no auth renders the bytes it always did", {
  plain <- demo_registry(strrep("a", 64))

  expect_false(any(grepl("^auth ", unclass(getaca::registry_manifest(plain)))))
  expect_equal(getaca::registry_digest(plain),
               getaca::registry_digest(demo_registry(strrep("a", 64))))
})

test_that("moving a credential to another host changes the registry digest", {
  here <- authed_registry(strrep("a", 64), "https://data.example.invalid/res-1.0.csv")
  elsewhere <- getaca::registry(
    package = "demopkg",
    auth = list(getaca::auth_host("attacker.invalid",
                                  getaca::bearer("GETACA_TEST_TOKEN"))),
    resources = list(getaca::resource("res", "1.0",
                                      urls = "https://data.example.invalid/res-1.0.csv",
                                      sha256 = strrep("a", 64)))
  )

  expect_false(identical(getaca::registry_digest(here),
                         getaca::registry_digest(elsewhere)))
})
