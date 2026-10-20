"""Run climate-assessment's command line tools with newer aneris / openscm-runner.

The pinned climate-assessment targets aneris 0.3.1 and openscm-runner 0.12.1, but gcages needs aneris>=0.4.2 (and
with it openscm-runner 0.13, scmdata 0.19). Those releases changed two things climate-assessment relies on; this
script shims them at runtime and then hands over to the unmodified CLI:

  * aneris.convenience.harmonise_all: keyword `harmonisation_year` became `year`, and the returned index is
    clean, whereas climate-assessment drops the redundant half of a duplicated index afterwards.
  * openscm_runner.run: no longer exposes the `run` function at package level (it is the submodule now).

Usage: python caCompat.py {harmonize-infill|run-climate} <the usual arguments of ca-harmonize-infill / ca-run-climate>
"""
import inspect
import sys
from multiprocessing import freeze_support

import pandas as pd


def patchAneris():
    import aneris.convenience as convenience

    original = convenience.harmonise_all
    if "year" not in inspect.signature(original).parameters:
        return  # old aneris, nothing to do

    def harmonise_all(scenarios, history, harmonisation_year=None, overrides=None, **kwargs):
        result = original(scenarios, history, year=harmonisation_year, overrides=overrides, **kwargs)
        # climate-assessment's drop_broken_stuff keeps only the first half of the index levels, so duplicate them
        idx = result.index
        arrays = [idx.get_level_values(i) for i in range(idx.nlevels)]
        names = list(idx.names)
        result = result.copy()
        result.index = pd.MultiIndex.from_arrays(arrays * 2, names=names + [f"{n}_dup" for n in names])
        return result

    convenience.harmonise_all = harmonise_all


def patchOpenscmRunner():
    import openscm_runner
    import openscm_runner.run

    if not callable(openscm_runner.run):
        openscm_runner.run = openscm_runner.run.run


if __name__ == "__main__":
    freeze_support()
    commands = {"harmonize-infill": "harmonize_and_infill", "run-climate": "clim_cli"}
    if len(sys.argv) < 2 or sys.argv[1] not in commands:
        sys.exit(__doc__)
    patchAneris()
    patchOpenscmRunner()
    import climate_assessment.cli

    sys.argv = [f"ca-{sys.argv[1]}"] + sys.argv[2:]
    getattr(climate_assessment.cli, commands[sys.argv[0][3:]])()
