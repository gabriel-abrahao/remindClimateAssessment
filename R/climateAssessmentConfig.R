#' Configure Climate Assessment
#'
#' Collects all necessary files and directories to set up climate assessment run from a REMIND output directory
#'
#' @param outputDir A REMIND output directory
#' @param mode Determines which probabiliy files is used. Must be either "report", "iteration" or "impulse"
#'
#' @return A list containing the configuration settings for the climate assessment
# nolint start
#' @examples
#' \dontrun{
#' climateAssessmentConfig("<outputDir>", "iteration") # yields
#' list(
#'   outputDir  = "/p/tmp/tonnru/remind/output/h_cpol_KLW_d50_2025-02-06_18.10.48",
#'   scenario   = "h_cpol_KLW_d50",
#'   condaEnv   = "/p/projects/rd3mod/python/environments/scm_magicc7_hpc",
#'   isArchived = FALSE,
#'   logFile    = "<outputDir>/log_climate.txt",
#'   workersDir = "<outputDir>/climate-assessment-data/workers",
#'   climateDir = "<outputDir>/climate-assessment-data",
#'   archiveDir = "",
#'   magiccBin  = "<Depending on your installation>",
#'   variablesFile = "<Depending on piamInterfaces>",
#'   infillingDatabase = "<Depending on your REMIND default.cfg>",
#'   probabilisticFile = "<Depending on your REMIND default.cfg>",
#'   nSets             = "<Depending on your REMIND probabilisticFile>",
#'   ...
#' )
#' }
# nolint end
#' @importFrom yaml read_yaml
#' @importFrom piamenv condaPackageVersion
#' @export
climateAssessmentConfig <- function(outputDir, mode) {
  if (!(mode %in% c("report", "iteration", "impulse")) || file.exists(mode))
    stop("'mode' must be either 'report', 'iteration', 'impulse', or valid path")
  runConfig <- read_yaml(file.path(outputDir, "cfg.txt"))
  cfg <- list(
    mode       = mode,
    outputDir  = normalizePath(outputDir, mustWork = TRUE),
    scenario   = lucode2::getScenNames(outputDir),
    condaEnv   = normalizePath(runConfig$pythonPath, mustWork = TRUE),
    isArchived = isTRUE(runConfig$climate_assessment_archive),
    logFile    = normalizePath(file.path(outputDir, "log_climate.txt"), mustWork = FALSE),
    reportsDir = normalizePath(file.path(outputDir, "reporting"), mustWork = FALSE),
    climateDir = normalizePath(file.path(outputDir, "climate-assessment-data"), mustWork = FALSE),
    workersDir = normalizePath(file.path(outputDir, "climate-assessment-data", "workers"), mustWork = FALSE),
    archiveDir = if (!isTRUE(runConfig$archiveClimateAssessmentData)) {
      normalizePath(file.path(outputDir, "climate-assessment-data", "archive"), mustWork = FALSE)
    } else {
      normalizePath(file.path(runConfig$archiveClimateAssessmentData, mustWork = FALSE))
    },
    magiccBin  = normalizePath(file.path(runConfig$climate_assessment_magicc_bin), mustWork = TRUE),
    variablesFile = normalizePath(
      file.path(system.file(package = "piamInterfaces"), "iiasaTemplates", "climate_assessment_variables.yaml"),
      mustWork = TRUE
    ),
    infillingDatabase = normalizePath(runConfig$climate_assessment_infiller_db, mustWork = TRUE),
    probabilisticFile = if (mode == "report") {
      normalizePath(runConfig$climate_assessment_magicc_prob_file_reporting, mustWork = TRUE)
    } else if (mode %in% c("iteration", "impulse")) {
      normalizePath(runConfig$climate_assessment_magicc_prob_file_iteration, mustWork = TRUE)
    } else {
      normalizePath(mode, mustWork = TRUE)
    }
  )
  # Query the MAGICC binary for its version. `getMagiccVersion`` stops hard if it cannot establish a proper
  # version string, thereby failing the config build and everything downstream
  cfg$magiccVersion <- getMagiccVersion(cfg$magiccBin)
  # Query the deployed climate-assessment package for its version
  cfg$climateAssessmentVersion <- condaPackageVersion("climate_assessment", cfg$condaEnv)
  # Some more file needed to run climate assessment
  cfg$parameterSets <- read_yaml(cfg$probabilisticFile)
  cfg$nSets         <- length(cfg$parameterSets$configurations)
  # Optional overrides that broaden the set of reported climate variables. Each defaults to NULL, in which case
  # matching climate-assessment CLI flag is omitted and the built-in default is used.
  # To report sea-level-rise variables produced by an SLR-capable MAGICC:
  #   climate_assessment_magicc_extra_config       -> MAGICC out_dynamic_vars (JSON, --magicc-extra-config)
  #   climate_assessment_output_variables_file     -> requested emulator variables (JSON, --output-variables-file)
  #   climate_assessment_variable_definitions_file -> post-processing name/unit table (CSV, --variable-definitions-file)
  # Treat both an absent key (NULL) and an empty string as "not set" -> use built-in default
  isSet <- function(x) !is.null(x) && length(x) == 1 && nzchar(x)
  cfg$magiccExtraConfig <- if (isSet(runConfig$climate_assessment_magicc_extra_config)) {
    normalizePath(runConfig$climate_assessment_magicc_extra_config, mustWork = TRUE)
  } else {
    NULL
  }
  cfg$outputVariablesFile <- if (isSet(runConfig$climate_assessment_output_variables_file)) {
    normalizePath(runConfig$climate_assessment_output_variables_file, mustWork = TRUE)
  } else {
    NULL
  }
  cfg$variableDefinitionsFile <- if (isSet(runConfig$climate_assessment_variable_definitions_file)) {
    normalizePath(runConfig$climate_assessment_variable_definitions_file, mustWork = TRUE)
  } else {
    NULL
  }
  # Setup of the climate assessment, "AR6" or "SCI". The files that only belong to one of them are optional. Arguments
  # that select the setup in the python scripts, for the harmonization/infilling and for running the climate emulator
  cfg$setup <- if (isSet(runConfig$climate_assessment_setup)) runConfig$climate_assessment_setup else "AR6"
  optionalFileArg <- function(flag, entry) {
    if (isSet(runConfig[[entry]])) paste(flag, normalizePath(runConfig[[entry]], mustWork = TRUE))
  }
  historyFileArg <- optionalFileArg("--history-file", "climate_assessment_history_file")
  cfg$harmInfArgs <- paste(c(
    "--setup", cfg$setup, historyFileArg,
    optionalFileArg("--aneris-overrides-file", "climate_assessment_aneris_overrides_file"),
    optionalFileArg("--infilling-database-cfcs", "climate_assessment_infiller_db_cfcs")
  ), collapse = " ")
  cfg$climateArgs <- paste(c("--setup", cfg$setup, historyFileArg), collapse = " ")
  # Climate assessment files have a different prefix when depending on mode (i.e. run type)
  assessmentFilesPrefix <- if (mode == "report") {
    "ar6_climate_assessment_"
  } else if (mode == "iteration") {
    "ar6_iteration_"
  }else {
    # Must be impulse
    "ar6_emissions_impulse_"
  }
  # Emissions file is the output of the harmnonization and infilling step
  cfg$remindEmissionsFile  <- normalizePath(
    file.path(cfg$climateDir, paste0(assessmentFilesPrefix, cfg$scenario, ".csv")),
    mustWork = FALSE
  )
  # Keep the emission impulse file as a separate entity to distringuish against the remind emissions file, since the
  # it is based on the harmonized and infilled emissions file from a previous climate assessment iteration run and thus
  # conceptually different, however ...
  cfg$emissionsImpulseFile <- if (mode == "impulse") {
    normalizePath(
      # ... still append the '_harmonized_infilled' suffix here to highlight its origin. Note that climate assessment
      # impulse do not feature the harm/inf step and directly go to emulation step
      file.path(cfg$climateDir, paste0(assessmentFilesPrefix, cfg$scenario, "_harmonized_infilled.csv")),
      mustWork = FALSE
    )
  } else {
    NULL
  }
  # Climate assessment generated harmonization and infilling file
  cfg$harmInfEmissionsFile <- if (mode == "report") {
    normalizePath(
      file.path(cfg$climateDir, paste0(assessmentFilesPrefix, cfg$scenario, "_harmonized_infilled.csv")),
      mustWork = FALSE
    )
  } else {
    # When running climate assessment in impulse mode the harmonized and infilled emissions file from a previous
    # iteration run is used. Use the assessmentFilesPrefix from iteration run config here
    normalizePath(
      file.path(cfg$climateDir, paste0("ar6_iteration_", cfg$scenario, "_harmonized_infilled.csv")),
      mustWork = FALSE
    )
  }
  # Climate assessment generated output file
  cfg$climateAssessmentFile <- normalizePath(
    file.path(
      cfg$climateDir, paste0(assessmentFilesPrefix, cfg$scenario, "_harmonized_infilled_IAMC_climateassessment.xlsx")
    ),
    mustWork = FALSE
  )
  # Climate assessment generates files with `_excluded_scenarios_` in the file name in case certain checks did not pass
  # Error checking idiom could look like any(file.exists(cfg$excludedScenarioFiles))
  cfg$excludedScenarioFiles <- c(
    # From ca docs: Writing out scenarios with no confidence due to reporting completeness issues
    "No Confidence" = normalizePath(
      file.path(cfg$climateDir, paste0(assessmentFilesPrefix, cfg$scenario, "_excluded_scenarios_noconfidence.csv")),
      mustWork = FALSE
    ),
    # No Emissions|CO2 or Emissions|CO2|Energy and Industrial Processes found in reporting file
    "No CO2 reported" = normalizePath(
      file.path(
        cfg$climateDir, paste0(assessmentFilesPrefix, cfg$scenario, "_excluded_scenarios_noCO2orCO2EnIPreported.csv")
      ),
      mustWork = FALSE
    ),
    # Check against historical data failed
    "Too far from historical" = normalizePath(
      file.path(
        cfg$climateDir, paste0(assessmentFilesPrefix, cfg$scenario, "_excluded_scenarios_toofarfromhistorical.csv")
      ),
      mustWork = FALSE
    ),
    # Exclude all scenarios with negative non-CO2 values
    "Unexpected Negatives" = normalizePath(
      file.path(
        cfg$climateDir, paste0(assessmentFilesPrefix, cfg$scenario, "_excluded_scenarios_unexpectednegatives.csv")
      ),
      mustWork = FALSE
    )
  )
  return(cfg)
}
