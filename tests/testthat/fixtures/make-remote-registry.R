# Builds the registry that test-network.R fetches over https.
#
# The file is committed and served by raw.githubusercontent, so the remote
# registry path is exercised against a real transfer of a real registry rather
# than a stub. Regenerate from the package root with:
#
#   Rscript tests/testthat/fixtures/make-remote-registry.R
#
# It declares one version more than the bundled registry the test builds, so a
# successful fetch is visible in what resolves. Changing that changes what
# test-network.R expects.

pkgload::load_all(quiet = TRUE)

fixture <- registry(
  package = "getacademo",
  resources = list(
    resource("demo", "1.0",
             urls = "https://example.org/demo-1.0.csv",
             sha256 = strrep("a", 64),
             license = "CC-BY-4.0"),
    resource("demo", "2.0",
             urls = "https://example.org/demo-2.0.csv",
             sha256 = strrep("b", 64),
             license = "CC-BY-4.0")
  ),
  revision = 2L
)

path <- "tests/testthat/fixtures/remote-registry.rds"
registry_write(fixture, path)
cat("wrote ", path, " (", file.info(path)$size, " bytes)\n", sep = "")
