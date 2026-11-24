# A SHA-256 digest as a 16 x 16 bit matrix, and the SVG path that paints
# selected cells of one. Shared by data-raw/hero.R and data-raw/logo.R.

bits <- function(digest) {
  b <- strtoi(substring(digest, seq(1, 63, by = 2), seq(2, 64, by = 2)), 16L)
  matrix(as.integer(vapply(b, function(x) rev(as.integer(intToBits(x))[1:8]),
                           integer(8))), ncol = 16, byrow = TRUE)
}

# One closed subpath per horizontal run of cells selected by `mask`.
cells_path <- function(mask, x0, y0, cell) {
  out <- character()
  for (i in seq_len(nrow(mask))) {
    runs <- rle(as.integer(mask[i, ]))
    ends <- cumsum(runs$lengths)
    starts <- ends - runs$lengths
    for (k in which(runs$values == 1L)) {
      out <- c(out, sprintf("M%s %sh%sv%sh-%sz", x0 + starts[k] * cell,
                            y0 + (i - 1) * cell, runs$lengths[k] * cell, cell,
                            runs$lengths[k] * cell))
    }
  }
  paste(out, collapse = "")
}
