% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/gating.R
\name{localMinima}
\alias{localMinima}
\title{Find a local minima appropriate for classiying a vector of numbers}
\usage{
localMinima(x, probs = c(0.2, 0.8))
}
\arguments{
\item{x}{A vector of values}

\item{probs}{Probabilities that limit where to look for the minimum}
}
\value{
The minimum value between the probs
}
\description{
Find a local minima appropriate for classiying a vector of numbers
}
