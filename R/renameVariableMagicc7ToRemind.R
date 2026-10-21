#' renameVariableMagicc7ToRemind
#'
#' Substitutes parts of MAGICC7 variable names to create REMIND compatible variable names
#'
#' @md
#' @param varName Variable to be renamed
#' @return Renamed variable
#'
#' @author Tonn Rüter
#' @export
renameVariableMagicc7ToRemind <- function(varName) {
  varName <- gsub("|MAGICCv7[^|]*", "", varName)
  varName <- gsub("AR6 climate diagnostics|", "MAGICC7 AR6|", varName, fixed = TRUE)
  varName <- gsub("SCI climate diagnostics|", "MAGICC7 SCI|", varName, fixed = TRUE)
  return(varName)
}
