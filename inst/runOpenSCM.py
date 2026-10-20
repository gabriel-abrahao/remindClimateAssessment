# %%
import argparse
import datetime as dt
import logging
import os

import pymagicc
from openscm_runner.run import run as openscm_run
import scmdata
import pyam
from climate_assessment.climate.wg3 import clean_wg3_scenarios

import json
from pathlib import Path


class EnvironmentError(Exception):
    pass


# Make sure MAGICC env vars are set
for env_var in ["MAGICC_EXECUTABLE_7", "MAGICC_WORKER_ROOT_DIR", "MAGICC_WORKER_NUMBER"]:
    if os.environ.get(env_var, "") == "":
        raise EnvironmentError(f"{env_var} does not exist")
    # Optional debug prints
    print(f"Found '{env_var}' = '{os.environ.get(env_var)}' ")

# Parse arguments
parser = argparse.ArgumentParser(
    description="Runs MAGICC for given a harmonized and infilled emissions file created by climate-assessment."
)
parser.add_argument("scens_file", type=str, help="an integer for the accumulator")
parser.add_argument(
    "--climatetempdir",
    default=os.getcwd(),
    help="Temporary folder for climate assessment files",
)
parser.add_argument("--endyear", default=2100, help="Final year for MAGICC runs")
# TODO: Unnecessary
parser.add_argument(
    "--scenario-batch-size",
    default=1,
    help="Last year in which climate assessment variables are reported",
)
parser.add_argument(
    "--probabilistic-file",
    required=True,
    help="Required, JSON file with the MAGICC parameter sets. Number of sets must match --num-cfgs",
)
# TODO: Unnecessary
parser.add_argument(
    "--num-cfgs",
    default=1,
    help="Number of parameter sets must match --probabilistic-file",
)

args = parser.parse_args()

# Emission data and probabilistic parameters
scenario_fn = Path(args.scens_file)          # Harmonized and infilled emissions scenario
prob_file_fn = Path(args.probabilistic_file) # JSON with parameter sets

assert all(path.exists() for path in [scenario_fn, prob_file_fn])

# Final year for MAGICC run
endyear = int(args.endyear)

# Clean the harmonized and infilled scenario, fixing some variable names required
scenario_df = clean_wg3_scenarios(pyam.IamDataFrame(scenario_fn))

# Extrapolate emissions data to endyear
scenarios = scmdata.ScmRun(scenario_df)
scenarios = scenarios.interpolate(
    [dt.datetime(y, 1, 1) for y in range(scenarios["year"].min(), endyear + 1)],
    extrapolation_type="constant",
)
# Save extrapolated Emissions
scenarios_extrapolated_fn = scenario_fn.with_stem(f"{scenario_fn.stem}_extrapolated")
(
    scenarios
    .to_iamdataframe()
    .swap_time_for_year()
    .to_csv(scenarios_extrapolated_fn)
)

# Read parameter sets, can also be multiple
with prob_file_fn.open() as fh:
    parsets = json.load(fh)
parsets = [cfg["nml_allcfgs"] for cfg in parsets["configurations"]]

# Combine run cfgs
common_cfg = {
    "endyear": endyear,
    "out_dynamic_vars": [
        "Surface Air Temperature Change",
        "Effective Radiative Forcing|Anthropogenic",
        "Net Atmosphere to Land Flux|CO2",
        "Atmospheric Concentrations|CO2",
    ],
    "out_ascii_binary": "BINARY",
    "out_binary_format": 2,
}

# Merge iteration parset with common cfg. Note: we use a single config
run_cfgs = [{**common_cfg, **parset} for parset in parsets]

# Convert to 
output_variables = [
    pymagicc.definitions.convert_magicc7_to_openscm_variables(magiccvarname).replace(
        "DAT_", ""
    )
    for magiccvarname in common_cfg["out_dynamic_vars"]
]

# Run the cliamte emulator
res = openscm_run(
    climate_models_cfgs={"MAGICC7": run_cfgs},
    output_variables=output_variables,
    scenarios=scenarios,
)

# Write output
climate_assessment_fn = scenario_fn.with_name(f"{scenario_fn.stem}_IAMC_climateassessment.xlsx")
(
    res.filter(region="World")
    .to_iamdataframe()
    .swap_time_for_year()
    .to_excel(climate_assessment_fn)
)
