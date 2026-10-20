# %%
"""
Harmonizes and infills a REMIND emissions file with the AR6 workflow of gcages
(pre-processing, harmonization, infilling). Replacement for climate-assessment's `ca-harmonize-infill`.

Input:  <emissions_file>, IAMC csv as written by REMIND, and the AR6 infilling database csv
Output: <outdir>/<emissions_file stem>_harmonized_infilled.csv, input for runClimateGcages.py
Called from the R package remindClimateAssessment, together with runClimateGcages.py.
"""
import argparse
from pathlib import Path

import climate_assessment
import gcages
import openscm_units
import pandas as pd
import pandas_openscm
import pint
from gcages.ar6 import AR6Harmoniser, AR6Infiller, AR6PreProcessor, get_ar6_full_historical_emissions
from gcages.renaming import SupportedNamingConventions, rename_variables

pint.set_application_registry(openscm_units.unit_registry)
pandas_openscm.register_pandas_accessors()

# Parse arguments
parser = argparse.ArgumentParser(
    description="Harmonizes and infills a REMIND emissions file with the AR6 workflow of gcages."
)
parser.add_argument("emissions_file", type=str, help="Emissions file in IAMC format, as written by REMIND")
parser.add_argument("outdir", type=str, help="Folder for the output <emissions_file stem>_harmonized_infilled.csv")
parser.add_argument(
    "--infilling-database",
    required=True,
    help="Required, AR6 infilling database csv (all emissions except CFCs)",
)
parser.add_argument(
    "--infilling-database-cfcs",
    default=None,
    help="AR6 infilling database csv for CFCs, default: see data files below",
)
parser.add_argument(
    "--history-file",
    default=None,
    help="AR6 historical emissions csv for harmonization, default: see data files below",
)
parser.add_argument(
    "--naming-convention",
    default="gcages",
    choices=["gcages", "ar6_wg3"],
    help="Variable naming of the output. gcages: e.g. Emissions|CO2|Fossil. ar6_wg3: AR6 names, "
    "e.g. Emissions|CO2|Energy and Industrial Processes (no climate-assessment prefixes)",
)

args = parser.parse_args()

# Find the default data files. Lookup order: command line option > file shipped inside the gcages package >
# copy shipped with climate-assessment. The installed gcages (0.14.1a1) only ships databases/emissions_variables.csv,
# i.e. neither file below, so for now the climate-assessment copies are used. They are byte-identical to the files in
# the gcages repo (tests/regression/ar6/ar6-workflow-inputs); gcages checks the sha256 hash of both when loading them.
gcages_dir = Path(gcages.__file__).parent
ca_dir = Path(climate_assessment.__file__).parent
history_candidates = [
    gcages_dir / "databases" / "history_ar6.csv",
    ca_dir / "harmonization" / "history_ar6.csv",
]
cfcs_candidates = [
    gcages_dir / "databases" / "infilling_db_ar6_cfcs.csv",
    ca_dir / "infilling" / "cmip6-ssps-workflow-emissions.csv",
]


def find_file(option, candidates, name):
    # The option if given, else the first existing default candidate
    for fn in [Path(option)] if option else candidates:
        if fn.exists():
            return fn
    raise FileNotFoundError(f"No {name} found, looked in {[str(c) for c in candidates]}. Use the command line option")


emissions_fn = Path(args.emissions_file)
outdir = Path(args.outdir)
infilling_db_fn = Path(args.infilling_database)
infilling_db_cfcs_fn = find_file(args.infilling_database_cfcs, cfcs_candidates, "CFC infilling database")
history_fn = find_file(args.history_file, history_candidates, "AR6 historical emissions")

assert all(path.exists() for path in [emissions_fn, outdir, infilling_db_fn])

# Read the REMIND emissions (IAMC wide format) into the layout gcages expects
emissions = pd.read_csv(emissions_fn)
emissions = emissions.rename(columns={c: c.lower() for c in emissions.columns[:5]})
emissions = emissions.set_index(["model", "scenario", "region", "variable", "unit"])
emissions.columns = emissions.columns.astype(int)
emissions = emissions.dropna(axis="columns", how="all")

# Pre-process: keep the variables understood by the AR6 workflow, aggregate, and switch to gcages variable names
pre_processor = AR6PreProcessor.from_ar6_config(run_checks=True, progress=False, n_processes=None)
pre_processed = pre_processor(emissions)

# Harmonize to the AR6 historical emissions
harmoniser = AR6Harmoniser.from_ar6_config(
    ar6_historical_emissions_file=history_fn, run_checks=True, progress=False, n_processes=1
)
harmonised = harmoniser(pre_processed)

# Infill the missing variables from the AR6 database
infiller = AR6Infiller.from_ar6_config(
    ar6_infilling_db_file=infilling_db_fn,
    ar6_infilling_db_cfcs_file=infilling_db_cfcs_fn,
    historical_emissions=get_ar6_full_historical_emissions(infilling_db_cfcs_fn),
    harmonisation_year=harmoniser.harmonisation_year,
    run_checks=True,
    progress=False,
    n_processes=None,
)
infilled = infiller(harmonised)

# Combine harmonized and infilled variables, these scenarios are ready to run a simple climate model
complete = pd.concat([harmonised, infilled])
if args.naming_convention != "gcages":
    complete = rename_variables(
        complete,
        from_convention=SupportedNamingConventions.GCAGES,
        to_convention=SupportedNamingConventions(args.naming_convention),
        index_level="variable",
    )

# Write output
out_fn = outdir / f"{emissions_fn.stem}_harmonized_infilled.csv"
out = complete.reset_index()
out = out.rename(columns={c: c.capitalize() for c in out.columns if isinstance(c, str)})
out.to_csv(out_fn, index=False)
print(f"Wrote {out_fn}")
