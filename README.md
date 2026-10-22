# REMIND integration of IIASA's `climate-assessment` package

R package **remindClimateAssessment**, version **0.2.0.9001**

   [![R build status](https://github.com/pik-piam/remindClimateAssessment/workflows/check/badge.svg)](https://github.com/pik-piam/remindClimateAssessment/actions) [![codecov](https://codecov.io/gh/pik-piam/remindClimateAssessment/branch/master/graph/badge.svg)](https://app.codecov.io/gh/pik-piam/remindClimateAssessment) [![r-universe](https://pik-piam.r-universe.dev/badges/remindClimateAssessment)](https://pik-piam.r-universe.dev/builds)

## Purpose and Functionality

The REMIND integration of IIASA's `climate-assessment` provides a standardized interface to simple climate models such as MAGICC7.


## Installation

For installation of the most recent package version an additional repository has to be added in R:

```r
options(repos = c(CRAN = "@CRAN@", pik = "https://rse.pik-potsdam.de/r/packages"))
```
The additional repository can be made available permanently by adding the line above to a file called `.Rprofile` stored in the home folder of your system (`Sys.glob("~")` in R returns the home directory).

After that the most recent version of the package can be installed using `install.packages`:

```r
install.packages("remindClimateAssessment")
```

Package updates can be installed using `update.packages` (make sure that the additional repository has been added before running that command):

```r
update.packages()
```

## Questions / Problems

In case of questions / problems please contact Tonn Rüter <tonn.rueter@pik-potsdam.de>.

## Citation

To cite package **remindClimateAssessment** in publications use:

Rüter T (2026). "remindClimateAssessment: REMIND integration of IIASA's `climate-assessment` package." Version: 0.2.0.9001, <https://github.com/pik-piam/remindClimateAssessment>.

A BibTeX entry for LaTeX users is

 ```latex
@Misc{,
  title = {remindClimateAssessment: REMIND integration of IIASA's `climate-assessment` package},
  author = {Tonn Rüter},
  date = {2026-10-21},
  year = {2026},
  url = {https://github.com/pik-piam/remindClimateAssessment},
  note = {Version: 0.2.0.9001},
}
```
