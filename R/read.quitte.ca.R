#' read.quitte.ca
#'
#' Fast drop-in replacement for `quitte::read.quitte(file)` for the output files of the climate assessment: the xlsx
#' written by the python scripts (sheet 'data', or the first sheet), the same content as csv (comma separated, as
#' written by pandas), the harmonized and infilled emissions csv, and REMIND-style mif files (';' separated).
#'
#' The returned object is identical (`identical()`: values, column types, factor levels and their order, row order,
#' attributes and class) to the one returned by `read.quitte`. The files are read into a wide table with typed
#' columns (xlsx: `readxl`, csv/mif: `data.table::fread`, numbers are converted with `readr::parse_number`, the parser
#' used by `read.quitte`), the factors are built on the wide table and the long table is assembled with `rep()`.
#' This is about 20-30 times faster than `read.quitte` for large files (e.g. 600 climate configurations, 1.1 million
#' rows: ~20 s versus < 1 s).
#'
#' If an assumption of the fast reader is violated, the function falls back to `quitte::read.quitte(file, ...)` after
#' a message. The fast reader requires: a single existing file that is not .rds; no further arguments in `...`; the
#' five columns Model, Scenario, Region, Variable, Unit plus optional extra columns (e.g. Climate_Model, Run_Id) of
#' type character or numeric (csv/mif: extra columns between Unit and the first year); four-digit year columns;
#' no hash or double quote characters in the character columns of csv/mif files; no duplicated rows; parsable
#' numbers; no comment lines in csv/mif files.
#'
#' @md
#' @param file Path of one xlsx, csv or mif file
#' @param variables Optional character vector of variable names. If given, only these variables are kept before the
#'   data is reshaped, which is faster. The result then equals `droplevels(filter(read.quitte(file), variable %in%
#'   variables))`. Defaults to NULL, i.e. no filter
#' @param periods Optional numeric vector of periods. If given, only these periods are kept (xlsx columns of other
#'   periods are not even parsed). Unused factor levels are dropped as for `variables`. Defaults to NULL
#' @param ... Further arguments of `read.quitte` (e.g. `filter.function`). If any is given, the function falls back to
#'   `read.quitte`, and `variables` and `periods` are applied afterwards
#' @return A `quitte` data frame, identical to `read.quitte(file)`
#' @importFrom data.table fread
#' @importFrom quitte read.quitte
#' @importFrom readr parse_number problems
#' @importFrom readxl excel_sheets read_excel
#' @examples
#' \dontrun{
#' qf <- read.quitte.ca(cfg$climateAssessmentFile)
#' tempData <- read.quitte.ca(
#'   cfg$climateAssessmentFile,
#'   variables = "Surface Air Temperature Change",
#'   periods = 2020:2300
#' )
#' }
#' @export
read.quitte.ca <- function(file, variables = NULL, periods = NULL, ...) { # nolint: object_name_linter.
  fallback <- function(reason) {
    message("read.quitte.ca: using quitte::read.quitte (", reason, ")")
    qf <- read.quitte(file, ...)
    if (!is.null(variables) || !is.null(periods)) {
      keep <- rep(TRUE, nrow(qf))
      if (!is.null(variables)) keep <- keep & as.character(qf$variable) %in% variables
      if (!is.null(periods)) keep <- keep & qf$period %in% periods
      qf <- droplevels(qf[keep, ])
    }
    return(qf)
  }
  if (length(list(...)) > 0) {
    return(fallback("additional arguments"))
  }
  if (!is.character(file) || length(file) != 1 || is.na(file) || !file.exists(file)) {
    return(fallback("'file' is not a single existing path"))
  }
  # read.quitte never returns for an empty text file
  if (file.size(file) == 0) {
    stop("File ", file, " is empty")
  }
  qf <- tryCatch(readClimateAssessmentFast(file, variables, periods), error = function(e) conditionMessage(e))
  if (is.character(qf)) {
    return(fallback(qf))
  }
  return(qf)
}

# Names of the default columns, the strings read.quitte reads as NA, and extra column names that would clash with
# the columns of a quitte object
caIdCols <- c("model", "scenario", "region", "variable", "unit")
caNaStrings <- c("UNDF", "NA", "N/A", "n_a")
caReservedCols <- c("value", "period", "year", "data1", "data2", "data3")

# Signals that the fast reader cannot be used. The reason is passed on to the message of the fallback
stopFast <- function(reason) {
  stop(reason, call. = FALSE)
}

# Fast reader behind read.quitte.ca. Returns a quitte data frame, or stops with the reason why the fast reader cannot
# be used.
#' @noRd
readClimateAssessmentFast <- function(file, variables, periods) {
  if (grepl("\\.rds$", file)) {
    stopFast("rds file")
  }
  isXlsx <- grepl("\\.xlsx?$", file)
  # Wide data frame with lower case column names and numeric period columns, and the names of the extra columns
  input <- if (isXlsx) readXlsxWide(file, periods) else readDelimitedWide(file, periods)
  wide <- input$wide
  extras <- input$extras
  periodCols <- names(wide)[grepl("^[0-9]{4}$", names(wide))]
  if (!is.null(periods)) periodCols <- periodCols[as.integer(periodCols) %in% periods]
  if (length(periodCols) == 0 || nrow(wide) == 0) stopFast("no data")

  # Filter before the (expensive) reshaping and number parsing
  if (!is.null(variables)) wide <- wide[wide$variable %in% variables, , drop = FALSE]
  if (nrow(wide) == 0) stopFast("no rows left after filtering")

  checkIdColumns(wide, extras, isXlsx)
  if (anyDuplicated(wide[c("model", "scenario", "region", "variable", extras)]) > 0) stopFast("duplicated rows")
  wide <- parsePeriodColumns(wide, periodCols, isXlsx)
  return(assembleQuitte(wide, extras, periodCols, isXlsx))
}

# Reads the sheet 'data' (or the first sheet) of an xlsx file. Columns of periods that are not needed are skipped.
#' @noRd
readXlsxWide <- function(file, periods) {
  sheets <- excel_sheets(file)
  sheet <- if ("data" %in% sheets) "data" else 1
  header <- tolower(names(suppressMessages(read_excel(file, sheet = sheet, n_max = 0))))
  isYear <- grepl("^[0-9]{4}$", header)
  if (!any(isYear)) stopFast("no period columns")
  if (anyDuplicated(header) || !all(caIdCols %in% header)) stopFast("unexpected columns")
  extras <- setdiff(header[!isYear], caIdCols)
  if (any(extras %in% caReservedCols)) stopFast("reserved extra column names")
  years <- as.integer(header[isYear])
  useCol <- !isYear | is.null(periods) | years[pmax(cumsum(isYear), 1)] %in% periods
  colTypes <- ifelse(isYear, ifelse(useCol, "numeric", "skip"), ifelse(header %in% caIdCols, "text", "guess"))
  # Any readxl warning means: use read.quitte
  wide <- withCallingHandlers(
    read_excel(file, sheet = sheet, col_types = colTypes, guess_max = 21474836, .name_repair = "minimal"),
    warning = function(w) stopFast("warnings while reading the xlsx")
  )
  wide <- as.data.frame(wide)
  names(wide) <- tolower(names(wide))
  return(list(wide = wide, extras = extras))
}

# Reads a csv (comma separated) or mif (';' separated) file with fread, all columns as character
#' @noRd
readDelimitedWide <- function(file, periods) {
  firstLine <- readLines(file, n = 1L, warn = FALSE)
  if (length(firstLine) == 0 || grepl("^#", firstLine) || grepl("[\r\"]", firstLine)) {
    stopFast("comment, quote or carriage return in header")
  }
  sep <- if (grepl(";", firstLine)) ";" else ","
  header <- tolower(strsplit(firstLine, sep, fixed = TRUE)[[1]])
  if (length(header) < 6 || anyDuplicated(header) || !setequal(header[1:5], caIdCols)) stopFast("unexpected header")
  isYear <- grepl("^[0-9]{4}$", header)
  if (!any(isYear)) stopFast("no period columns")
  nId <- min(which(isYear)) - 1L
  if (nId < 5 || !all(isYear[(nId + 1):length(header)])) stopFast("unexpected period columns")
  extras <- header[seq_len(nId)][-(1:5)]
  if (any(extras %in% caReservedCols) || any(grepl("^[a-z]?[0-9]{4}$", extras))) {
    stopFast("reserved or period-like extra columns")
  }
  years <- as.integer(header[isYear])
  selected <- c(seq_len(nId), nId + which(is.null(periods) | years %in% periods))
  # Any fread warning (e.g. stopped early, comment line in the data, ragged lines) means: use read.quitte
  wide <- withCallingHandlers(
    fread(
      file, sep = sep, header = TRUE, select = selected, colClasses = "character", na.strings = NULL, quote = "",
      strip.white = TRUE, showProgress = FALSE, blank.lines.skip = TRUE, fill = FALSE, data.table = FALSE
    ),
    warning = function(w) stopFast("warnings while reading the file")
  )
  names(wide) <- header[selected]
  # read.quitte treats the NA strings as missing in all columns (e.g. a unit "NA" is read as NA)
  for (col in c(caIdCols, extras)) wide[[col]][wide[[col]] %in% caNaStrings] <- NA_character_
  return(list(wide = wide, extras = extras))
}

# Checks the assumptions on the non-numeric columns
#' @noRd
checkIdColumns <- function(wide, extras, isXlsx) {
  if (!isXlsx) {
    for (col in c(caIdCols, extras)) {
      if (any(grepl("[#\"]", unique(wide[[col]])))) stopFast(paste("unusual values in column", col))
    }
    return(invisible(NULL))
  }
  # read.quitte lets readxl guess the type of all columns, numeric-looking ids would be factorised numerically
  for (col in caIdCols) {
    uniqueVals <- unique(wide[[col]])
    uniqueVals <- uniqueVals[!is.na(uniqueVals)]
    if (length(uniqueVals) > 0 && all(grepl("^[-+]?[0-9.eE+-]+$", uniqueVals))) stopFast(paste("numeric-looking", col))
  }
  for (col in extras) {
    if (!(is.character(wide[[col]]) || (is.numeric(wide[[col]]) && !inherits(wide[[col]], "POSIXt")))) {
      stopFast(paste("unsupported type of column", col))
    }
  }
  return(invisible(NULL))
}

# Numbers of csv/mif files with the parser of read.quitte (the parser of data.table differs in the last digit). The
# numbers of xlsx files are numeric already
#' @noRd
parsePeriodColumns <- function(wide, periodCols, isXlsx) {
  if (isXlsx) {
    if (!all(vapply(wide[periodCols], is.numeric, logical(1)))) stopFast("non-numeric period column")
    return(wide)
  }
  for (col in periodCols) {
    raw <- wide[[col]]
    parsed <- parse_number(raw, na = caNaStrings)
    if (nrow(problems(parsed)) > 0) stopFast("parsing problems")
    if (any(is.na(parsed) & !(raw %in% c(caNaStrings, "")))) stopFast("unparsable values")
    wide[[col]] <- parsed
  }
  return(wide)
}

# One column of the long table, with each value repeated for all periods. Character columns become factors with
# sorted levels, or with the order of appearance if keepOrder is TRUE
#' @noRd
longColumn <- function(x, nPeriods, keepOrder) {
  if (!is.character(x)) {
    return(rep(x, each = nPeriods))
  }
  levs <- if (keepOrder) unique(x[!is.na(x)]) else levels(factor(unique(x)))
  out <- rep(match(x, levs), each = nPeriods)
  levels(out) <- levs
  class(out) <- "factor"
  return(out)
}

# Long format, row by row: all periods of the first row, then of the second row, ...
#' @noRd
assembleQuitte <- function(wide, extras, periodCols, isXlsx) {
  nPeriods <- length(periodCols)
  # In csv/mif files `read.quitte` keeps the order of appearance for scenarios
  ids <- lapply(caIdCols, function(col) longColumn(wide[[col]], nPeriods, col == "scenario" && !isXlsx))
  names(ids) <- caIdCols
  extraCols <- lapply(extras, function(col) longColumn(wide[[col]], nPeriods, FALSE))
  names(extraCols) <- extras
  period <- rep(as.integer(periodCols), times = nrow(wide))
  value <- as.vector(t(as.matrix(wide[periodCols])))
  # as.quitte (xlsx) puts the extra columns behind the period, read.quitte for csv/mif keeps them in front of it
  out <- if (isXlsx) {
    c(ids, list(period = period), extraCols, list(value = value))
  } else {
    c(ids, extraCols, list(period = period, value = value))
  }
  attr(out, "row.names") <- c(NA_integer_, -length(value))
  class(out) <- c("quitte", "tbl_df", "tbl", "data.frame")
  return(out)
}
