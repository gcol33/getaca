# Graphical abstract: SHA-256 digests as 16 x 16 bit matrices. The digest the
# registry declares sits in the middle; a copy of the file with one changed
# byte and an intact copy arrive from the left, and the intact one comes back
# as a path in the cache.
# Run from the package root, with a network: Rscript data-raw/hero.R

pkgload::load_all(".", quiet = TRUE)

fixture <- "tests/testthat/fixtures/sample.zip"
declared <- unname(tools::sha256sum(fixture))

# The real call, for the path it returns.
cache <- file.path(tempdir(), "getaca-hero")
options(getaca.cache = cache)
Sys.setenv(NOT_CRAN = "true")
url <- paste0("https://raw.githubusercontent.com/gcol33/getaca/v0.1.6/", fixture)
sample_zip <- resource("sample", "0.1.6", urls = url, sha256 = declared)
reg <- registry(package = "mypkg", resources = list(sample_zip))
path <- getaca("sample", registry = reg)
stopifnot(unname(tools::sha256sum(path)) == declared)
shown <- sub(normalizePath(cache, winslash = "/"), "<cache>",
             normalizePath(path, winslash = "/"), fixed = TRUE)
parts <- strsplit(shown, "/", fixed = TRUE)[[1]]
stopifnot(parts[1] == "<cache>", length(parts) == 6)
path_lines <- c(paste0(paste(parts[1:3], collapse = "/"), "/"),
                paste(parts[4:6], collapse = "/"))

# A copy with one byte changed, as a damaged mirror would serve it.
bytes <- readBin(fixture, "raw", n = file.size(fixture))
bytes[200] <- xor(bytes[200], as.raw(1))
damaged_file <- tempfile()
writeBin(bytes, damaged_file)
damaged <- unname(tools::sha256sum(damaged_file))

bits <- function(digest) {
  b <- strtoi(substring(digest, seq(1, 63, by = 2), seq(2, 64, by = 2)), 16L)
  matrix(as.integer(vapply(b, function(x) rev(as.integer(intToBits(x))[1:8]),
                           integer(8))), ncol = 16, byrow = TRUE)
}
declared_bits <- bits(declared)
damaged_bits <- bits(damaged)
differing <- sum(declared_bits != damaged_bits)

blue <- "#2E6F9E"
red <- "#B5342B"
green <- "#3F7A3D"
ink <- "#5C6166"
frame <- "#2B3A4A"
agree <- "#C3CCD6"
sans <- "'Segoe UI', Helvetica, Arial, sans-serif"
mono <- "Consolas, 'SFMono-Regular', Menlo, monospace"

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

# A digest on a white plate; `layers` maps a fill colour to the cells it paints.
plate <- function(x, y, cell, layers, pad = 7, stroke = 3) {
  side <- 16 * cell
  paste0(
    sprintf('<rect x="%s" y="%s" width="%s" height="%s" rx="8" fill="#FFFFFF" stroke="%s" stroke-width="%s"/>',
            x - pad, y - pad, side + 2 * pad, side + 2 * pad, frame, stroke),
    paste(vapply(names(layers), function(fill) sprintf(
      '<path fill="%s" d="%s"/>', fill, cells_path(layers[[fill]], x, y, cell)),
      character(1)), collapse = ""))
}

W <- 900
H <- 380

small <- 9
big <- 13
left_x <- 26
top_y <- 30
bottom_y <- H - 30 - 16 * small
centre_x <- W / 2 - 16 * big / 2 - 20
centre_y <- H / 2 - 16 * big / 2 + 14
arrow_from <- left_x + 16 * small + 16
plate_left <- centre_x - 7
plate_right <- centre_x + 16 * big + 7
row_top <- top_y + 8 * small + 10
row_bottom <- bottom_y + 8 * small - 10
label_x <- arrow_from + 2
tick_x <- 752
tick_y <- centre_y + 8 * big - 22

text <- function(x, y, label, family, size, fill, anchor = "middle") sprintf(
  '<text x="%s" y="%s" text-anchor="%s" font-family="%s" font-size="%s" font-weight="bold" fill="%s">%s</text>',
  x, y, anchor, family, size, fill, label)
arrow <- function(x0, x1, y, colour, marker) sprintf(
  '<line x1="%s" y1="%s" x2="%s" y2="%s" stroke="%s" stroke-width="3" marker-end="url(#%s)"/>',
  x0, y, x1, y, colour, marker)
escape <- function(x) gsub("<", "&lt;", gsub(">", "&gt;", x, fixed = TRUE), fixed = TRUE)

alt <- sprintf(paste(
  "SHA-256 digests drawn as 16 by 16 bit matrices. The digest a registry",
  "declares for sample.zip is in the middle. The copy from mirror 1 has one",
  "changed byte, %d of its 256 digest bits differ, drawn red, and it is",
  "refused. The copy from mirror 2 matches bit for bit and getaca() returns",
  "its path, %s."), differing, shown)

cross_x <- plate_left - 22
svg <- paste0(
  '<svg xmlns="http://www.w3.org/2000/svg" ',
  sprintf('viewBox="0 0 %d %d" width="%d" height="%d" role="img" aria-label="%s">',
          W, H, W, H, escape(alt)),
  '<defs>',
  sprintf('<marker id="head" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="6" markerHeight="6" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="%s"/></marker>', ink),
  '</defs>',
  sprintf('<rect width="%d" height="%d" fill="#FFFFFF"/>', W, H),
  plate(left_x, top_y, small,
        setNames(list(damaged_bits == 1 & declared_bits == 1,
                      damaged_bits != declared_bits), c(agree, red))),
  plate(left_x, bottom_y, small, setNames(list(declared_bits == 1), blue)),
  plate(centre_x, centre_y, big, setNames(list(declared_bits == 1), blue),
        pad = 9, stroke = 4),
  text(label_x, row_top - 14, "mirror 1", sans, 23, red, "start"),
  sprintf('<line x1="%s" y1="%s" x2="%s" y2="%s" stroke="%s" stroke-width="3"/>',
          arrow_from, row_top, cross_x - 16, row_top, ink),
  sprintf('<path d="M%s %sl18 18m0 -18l-18 18" stroke="%s" stroke-width="5" stroke-linecap="round" fill="none"/>',
          cross_x - 9, row_top - 9, red),
  text(label_x, row_bottom - 14, "mirror 2", sans, 23, blue, "start"),
  arrow(arrow_from, plate_left - 6, row_bottom, ink, "head"),
  text((plate_left + plate_right) / 2, centre_y - 26, "sha256", mono, 30, ink),
  text((plate_right + tick_x - 30) / 2, tick_y - 14, "getaca()", mono, 25, ink),
  arrow(plate_right + 12, tick_x - 44, tick_y, ink, "head"),
  sprintf('<circle cx="%s" cy="%s" r="30" fill="%s"/>', tick_x, tick_y, green),
  sprintf('<path d="M%s %sl11 12l19 -24" stroke="#FFFFFF" stroke-width="7" stroke-linecap="round" stroke-linejoin="round" fill="none"/>',
          tick_x - 15, tick_y + 1),
  text(tick_x, tick_y + 76, escape(path_lines[1]), mono, 23, ink),
  text(tick_x, tick_y + 106, escape(path_lines[2]), mono, 23, ink),
  '</svg>')

stopifnot(!grepl("Inf|NaN", svg))
writeLines(svg, "man/figures/getaca-hero.svg", useBytes = TRUE)
cat(alt, "\n")
