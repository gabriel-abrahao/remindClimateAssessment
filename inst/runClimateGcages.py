# %%
"""
Runs MAGICC with the AR6 or SCI (June 2026) runner of gcages for a harmonized and infilled emissions file, and
post-processes the output into percentiles and exceedance probabilities.
Replacement for climate-assessment's `ca-run-climate`.

Input:  <scens_file>, output of runHarmInfGcages.py (gcages variable names), and a JSON file with MAGICC parameter sets
Output: <outdir>/<scens_file stem>_IAMC_climateassessment.xlsx (percentiles and metadata)
        <outdir>/<scens_file stem>_full_exceedance_probabilities.xlsx
Called from the R package remindClimateAssessment, after runHarmInfGcages.py.
Needs the env vars MAGICC_EXECUTABLE_7, MAGICC_WORKER_ROOT_DIR and MAGICC_WORKER_NUMBER.
"""
import argparse
import datetime as dt
import os
from pathlib import Path

import pandas as pd
import pyam
import scmdata

# TEMPORARY: the post-processing is still the one of climate-assessment (percentiles, exceedance probabilities,
# metadata). The plan is to replace it by the AR6PostProcessor of gcages plus percentiles calculated in R.
from climate_assessment.climate.magicc7 import get_magicc7_configurations
from climate_assessment.climate.post_process import post_process
from gcages.ar6 import AR6SCMRunner
from gcages.ar6.scm_running import DEFAULT_OUTPUT_VARIABLES
from gcages.cmip7_scenariomip.scm_running import SCM_OUTPUT_VARIABLES_DEFAULT
from gcages.sci_june_2026 import SCIJune2026PostProcessor, SCIJune2026SCMRunner


class EnvironmentError(Exception):
    pass


# Make sure MAGICC env vars are set
for env_var in ["MAGICC_EXECUTABLE_7", "MAGICC_WORKER_ROOT_DIR", "MAGICC_WORKER_NUMBER"]:
    if os.environ.get(env_var, "") == "":
        raise EnvironmentError(f"{env_var} does not exist")
    print(f"Found '{env_var}' = '{os.environ.get(env_var)}' ")

# Parse arguments, same as climate-assessment's ca-run-climate
parser = argparse.ArgumentParser(
    description="Runs MAGICC with gcages for a harmonized and infilled emissions file and post-processes the output."
)
parser.add_argument("scens_file", type=str, help="Harmonized and infilled emissions file, with gcages variable names")
parser.add_argument("--setup", default="AR6", choices=["AR6", "SCI"], help="Workflow to use, with its MAGICC version and post-processing")
parser.add_argument("outdir", type=str, help="Folder for the output files")
parser.add_argument("--num-cfgs", default=600, type=int, help="Number of parameter sets to use from the probabilistic file")
parser.add_argument("--scenario-batch-size", default=20, type=int, help="Number of scenarios run and post-processed at once")
parser.add_argument("--probabilistic-file", required=True, help="Required, JSON file with the MAGICC parameter sets")
parser.add_argument("--model-version", default="v7.5.3", help="AR6 only: expected MAGICC version")
parser.add_argument("--history-file", default=None, help="SCI only, required: historical emissions csv, to complete the emissions before 2023")
parser.add_argument("--magicc-extra-config", default=None, help="Optional JSON with extra MAGICC configuration")
# Not supported, but accepted as the R scripts pass them (drop-in compatibility with ca-run-climate)
parser.add_argument("--output-variables-file", default=None)
parser.add_argument("--variable-definitions-file", default=None)

args = parser.parse_args()
if args.output_variables_file or args.variable_definitions_file:
    raise NotImplementedError("--output-variables-file and --variable-definitions-file are not supported yet")

scenario_fn = Path(args.scens_file)
outdir = Path(args.outdir)
prob_file_fn = Path(args.probabilistic_file)
assert all(path.exists() for path in [scenario_fn, prob_file_fn, outdir])

# Prefix of all output variable names
prefix = f"{args.setup} climate diagnostics"

# AR6: extend scenarios to 2110 by constant extrapolation. This avoids MAGICC's end year effects, by running it a bit
# beyond the last year of interest (2100). The SCI runner takes care of that itself
scenarios = scmdata.ScmRun(pyam.IamDataFrame(scenario_fn))
if args.setup == "AR6":
    scenarios = scenarios.interpolate(
        [dt.datetime(y, 1, 1) for y in range(scenarios["year"].min(), 2110 + 1)],
        extrapolation_type="constant",
    )
scenarios = scenarios.timeseries(time_axis="year")

if args.setup == "AR6":
    # MAGICC configurations, one per parameter set
    magicc_cfgs, _ = get_magicc7_configurations(
        magicc_version=args.model_version,
        magicc_probabilistic_file=str(prob_file_fn),
        magicc_extra_config=args.magicc_extra_config,
        num_cfgs=args.num_cfgs,
        co2_and_non_co2_warming=False,
    )

    # Output variables: besides the gcages defaults, climate-assessment also reports the effective radiative forcing
    # of the individual F-gases, which the gcages defaults only have as aggregates
    f_gases = ["CF4", "C2F6", "C6F14", "SF6", "HFC23", "HFC32", "HFC4310mee", "HFC125", "HFC134a", "HFC143a",
               "HFC227ea", "HFC245fa", "CFC11", "CFC12", "HCFC22"]
    output_variables = DEFAULT_OUTPUT_VARIABLES + tuple(
        f"Effective Radiative Forcing|{gas}"
        for gas in f_gases
        if f"Effective Radiative Forcing|{gas}" not in DEFAULT_OUTPUT_VARIABLES
    )

    # Climate emulator: gcages AR6 runner with our own MAGICC configs. run_checks=False as the input checks are
    # already done by the previous harmonization and infilling step.
    # n_processes is taken from MAGICC_WORKER_NUMBER because run_scms overwrites that env var with n_processes
    scm_runner = AR6SCMRunner(
        climate_models_cfgs={"MAGICC7": magicc_cfgs},
        output_variables=output_variables,
        force_interpolate_to_yearly=True,
        run_checks=False,
        progress=False,
        n_processes=int(os.environ["MAGICC_WORKER_NUMBER"]),
    )
else:
    # The SCI runner sets up its own MAGICC (v7.6.0a3) configs from the parameter sets, with its default output
    # variables. It completes the emissions before 2023 with the history. Only the first num_cfgs sets are used
    scm_runner = SCIJune2026SCMRunner.from_cmip7_scenariomip_config(
        magicc_exe_path=Path(os.environ["MAGICC_EXECUTABLE_7"]),
        magicc_prob_distribution_path=prob_file_fn,
        output_variables=SCM_OUTPUT_VARIABLES_DEFAULT,
        historical_emissions_path=Path(args.history_file),
        run_checks=False,
        progress=False,
        n_processes=int(os.environ["MAGICC_WORKER_NUMBER"]),
    )
    scm_runner.climate_models_cfgs["MAGICC7"] = scm_runner.climate_models_cfgs["MAGICC7"][: args.num_cfgs]
    sci_post_processor = SCIJune2026PostProcessor.from_cmip7_scenariomip_config()

# Run and post-process in batches of scenarios
mod_scen = scenarios.index.droplevel(scenarios.index.names.difference(["model", "scenario"]))
unique_mod_scen = mod_scen.unique()
batch_size = args.scenario_batch_size
percentiles, metas = [], []
for i in range(0, len(unique_mod_scen), batch_size):
    print(f"Running scenarios {i + 1}-{min(i + batch_size, len(unique_mod_scen))} of {len(unique_mod_scen)}")
    if args.setup == "AR6":
        res = scmdata.ScmRun(scm_runner(scenarios[mod_scen.isin(unique_mod_scen[i : i + batch_size])]))
        _, res_percentiles, meta_table = post_process(
            res,
            str(outdir),
            test_run=False,
            save_raw_output=False,
            co2_and_non_co2_warming=False,
            historical_warming=0.85,
            historical_warming_reference_period="1850-1900",
            historical_warming_evaluation_period="1995-2014",
            year_filter_first=1995,
            year_filter_last=2101,
        )
        ts = res_percentiles.timeseries()
        ts.columns = ts.columns.map(lambda x: x.year)
        percentiles.append(ts.reset_index().rename(columns=lambda c: str(c).title()))
        metas.append(meta_table.reset_index())
    else:
        res = scm_runner(scenarios[mod_scen.isin(unique_mod_scen[i : i + batch_size])])
        post = sci_post_processor(res)
        # Percentiles over the runs of all variables, including the temperature in line with the assessment
        runs = pd.concat([res, post.timeseries_run_id]).loc[:, 1995:2100]
        keep_levels = [level for level in runs.index.names if level != "run_id"]
        quantiles = runs.groupby(level=keep_levels).quantile(list(sci_post_processor.percentiles_to_calculate))
        quantiles = quantiles.rename_axis(index=[*keep_levels, "quantile"]).reset_index()
        quantiles["variable"] = (
            quantiles["variable"] + "|" + quantiles["climate_model"] + "|" + (quantiles["quantile"] * 100).round(1).astype(str) + "th Percentile"
        )
        # Exceedance probabilities over time, named like in AR6
        exceedance = post.timeseries_exceedance_probabilities.loc[:, 1995:2100].reset_index()
        exceedance["variable"] = "Exceedance Probability " + exceedance["threshold"].astype(str) + "C|" + exceedance["climate_model"]
        drop_cols = ["climate_model", "quantile", "threshold", "threshold_unit"]
        percentiles.append(
            pd.concat([quantiles, exceedance]).drop(columns=drop_cols, errors="ignore").rename(columns=lambda c: str(c).title())
        )
        # Scenario metadata: exceedance probabilities, peak and end of century warming quantiles, categories
        def wide(series, name):
            frame = series.rename("value").reset_index()
            frame["name"] = name(frame)
            return frame.pivot(index=["model", "scenario"], columns="name", values="value")
        metas.append(
            pd.concat(
                [
                    wide(post.metadata_exceedance_probabilities, lambda f: "Exceedance Probability " + f["threshold"].astype(str) + "C (" + f["climate_model"] + ")"),
                    wide(post.metadata_quantile, lambda f: "p" + (f["quantile"] * 100).round(1).astype(str) + " " + f["metric"].astype(str) + " warming (" + f["climate_model"] + ")"),
                    wide(post.metadata_categories, lambda f: f["metric"] + " (" + f["climate_model"] + ")"),
                ],
                axis=1,
            ).reset_index()
        )

# Write exceedance probabilities and metadata
key_string = scenario_fn.stem
meta = pd.concat(metas, ignore_index=True)
meta["exclude"] = ""
meta.to_excel(outdir / f"{key_string}_full_exceedance_probabilities.xlsx")

# Write percentiles with the prefix and the metadata
full_output = pyam.IamDataFrame(pd.concat(percentiles)).data
full_output["variable"] = prefix + "|" + full_output["variable"].astype(str)
full_output = pyam.IamDataFrame(full_output)
meta_mod_scen = meta.set_index(["model", "scenario"])
for c in meta_mod_scen:
    if c != "exclude":
        full_output.set_meta(meta_mod_scen[c])
full_output.to_excel(outdir / f"{key_string}_IAMC_climateassessment.xlsx")
print("COMPLETE")
