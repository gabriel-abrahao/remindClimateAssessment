#' Append Climate Assessment Data to MIF File
#'
#' This function appends climate assessment data to a MIF (Model Intercomparison Framework) file.
#' It removes data from old MAGICC7 runs to avoid duplication and then writes the updated data back to the MIF file.
#'
#' @param qf `quitte` data frame containing the climate assessment data to be appended
#' @param mif File path to the MIF to which the data will be appended
#' @return The function returns the result of writing the updated data to the MIF file.
#' @importFrom quitte as.quitte write.mif
#' @importFrom dplyr filter
#' @importFrom readr write_lines
#' @importFrom rlang .data
#' @export
appendClimateAssessmentToMif <- function(qf, mif) {
  as.quitte(mif) %>%
    # remove data from old MAGICC7 runs to avoid duplicated
    filter(
      ! grepl("(AR6|SCI) climate diagnostics.*MAGICC7", .data$variable),
      ! grepl("^MAGICC7 (AR6|SCI)", .data$variable)
    ) %>%
    rbind(qf) %>%
    write.mif(mif)
  return(qf)
}
