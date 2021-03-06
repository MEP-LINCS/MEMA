% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/QA_functions.R
\name{QASpotLevelData}
\alias{QASpotLevelData}
\title{Add QA flags to the spot level data}
\usage{
QASpotLevelData(dt, lowSpotCellCountThreshold = 5,
  lowRegionCellCountThreshold = 0.4, lowWellQAThreshold = 0.7)
}
\arguments{
\item{dt}{A datatable to be QA'd}

\item{lowSpotCellCountThreshold}{Threshold for spots with not enough cells}

\item{lowRegionCellCountThreshold}{Threshold for loess regions with not enough cells}

\item{lowWellQAThreshold}{Threshold for low quality wells}
}
\value{
The same datatable with the QA columns
}
\description{
Add QA flags to the spot level data
}
