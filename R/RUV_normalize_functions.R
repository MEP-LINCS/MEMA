#RUV Normalization functions for processing MEMAs

#'Apply RUV and Loess Normalization to the signals in a MEMA dataset
#'@param dt A datatable with data and metadata to be normalzed. There must be CellLine, Barcode, Well, Ligand, Drug and ECMp metadata columns
#'@param k  The number of factors to be removed in the RUV normalization
#' @export
normRUVLoessResiduals <- function(dt, k){
  setkey(dt,CellLine,Barcode,Well,Ligand,Drug,Drug1Conc,ECMp)
  #Transform signals to be on additive scale
  #log transform all intensity and areaShape values
  log2Names <- grep("_Center_|_Eccentricity|_Orientation",grep("SpotCellCount|Intensity|AreaShape",colnames(dt), value=TRUE, ignore.case = TRUE), value=TRUE, invert=TRUE)
  dtLog <- dt[,lapply(.SD,boundedLog2),.SDcols=log2Names]
  setnames(dtLog,colnames(dtLog),paste0(colnames(dtLog),"Log2"))
  #logit transform proportion values
  logitNames <- grep("_Center_|_Orientation",grep("_Eccentricity|Proportion",colnames(dt), value=TRUE, ignore.case = TRUE), value=TRUE, invert=TRUE)
  dtLogit <- dt[,lapply(.SD,boundedLogit),.SDcols=logitNames]
  setnames(dtLogit,colnames(dtLogit),paste0(colnames(dtLogit),"Logit"))
  signalNames <- c(colnames(dtLog),colnames(dtLogit))
  dt <-  cbind(dt[,grep("^CellLine$|Barcode|^Well$|^Spot$|^PrintSpot$|ArrayRow|ArrayColumn|^ECMp$|^Ligand$|^Drug$|^Drug1Conc$",colnames(dt),value=TRUE),with=FALSE],dtLog,dtLogit)
  #Add residuals from subtracting the biological medians from each value
  residuals <- dt[,lapply(.SD,calcResidual), by="CellLine,Barcode,Well,Ligand,Drug,Drug1Conc,ECMp", .SDcols=signalNames]
  #Add within array location metadata
  residuals$Spot <- as.integer(dt$Spot)
  residuals$PrintSpot <- as.integer(dt$PrintSpot)
  residuals$ArrayRow <- dt$ArrayRow
  residuals$ArrayColumn <- dt$ArrayColumn
  #Create a signal type
  dt$SignalType <- "Signal"
  residuals$SignalType <- "Residual"
  srDT <- rbind(dt,residuals)
  
  #Add to carry metadata into matrices
  srDT$BWLDDc <- paste(srDT$Barcode, srDT$Well, srDT$Ligand,  srDT$Drug,  srDT$Drug1Conc, sep="_") 
  
  #Create the M matrix which denotes replicates
  M <- createRUVM(srDT, replicateCols=c("CellLine","Ligand","Drug","Drug1Conc"))
  
  #Add BW 
  srDT$BW <- paste(srDT$Barcode, srDT$Well, sep="_") 
  #Make a list of matrices that hold signal and residual values
  srmList <- lapply(signalNames, function(signalName, dt){
    srm <- signalResidualMatrix(dt[,.SD, .SDcols=c("BW", "PrintSpot", "SignalType", signalName)])
    return(srm)
  },dt=srDT)
  names(srmList) <- signalNames
  
  #Make a list of matrices of RUV normalized signal values
  srmRUVList <- lapply(names(srmList), function(srmName, srmList, M, k){
    Y <- srmList[[srmName]]
    #Hardcode in identification of residuals as the controls
    resStart <- ncol(Y)/2+1
    cIdx=resStart:ncol(Y)
    nY <- try(RUVArrayWithResiduals(k, Y, M, cIdx, srmName), silent = TRUE) #Normalize the spot level data
    if(!is.data.table(nY)) return(NULL)
    nY$SignalName <- paste0(srmName,"RUV")
    setnames(nY,srmName,paste0(srmName,"RUV"))
    #nY[[srmName]] <- as.vector(Y[,1:(resStart-1)]) #Add back in the raw signal (may not be needed)
    return(nY)
  }, srmList=srmList, M=M, k=k)
  
  #Remove NULL elements that were due to data that failed normalization
  srmRUVList <- srmRUVList[!sapply(srmRUVList,FUN = is.null)]
  #Reannotate with ECMp, Drug, ArrayRow and ArrayColumn as needed for loess normalization
  ECMpDT <- unique(srDT[,list(Well,PrintSpot,Spot,ECMp,Drug, ArrayRow,ArrayColumn)])
  srmERUVList <- lapply(srmRUVList, function(dt,ECMpDT){
    dt$Well <- gsub(".*_","",dt$BW)
    setkey(dt,Well,PrintSpot)
    setkey(ECMpDT,Well,PrintSpot)
    dtECMpDT <- merge(dt,ECMpDT)
    return(dtECMpDT)
  },ECMpDT=ECMpDT)
  
  #Add Loess normalized values for each RUV normalized signal
  RUVLoessList <- lapply(srmERUVList, function(dt){
    dtRUVLoess <- loessNormArray(dt)
  })
  
  #Combine the normalized signals and metadata
  signalDT <- Reduce(merge,RUVLoessList)
  
  #Backtransform from log2 and logit values
  #log transform all intensity and areaShape values
  log2Names <- grep("Log2",colnames(signalDT), value=TRUE)
  btLog2 <- function(x){
    x[x<0] <- 0
    2^x
  }
  dtLog <- signalDT[,lapply(.SD,btLog2),.SDcols=log2Names]
  logitNames <- grep("Logit",colnames(signalDT), value=TRUE)
  dtLogit <- signalDT[,lapply(.SD,plogis),.SDcols=logitNames]
  signalDT <- cbind(signalDT[,.(BW,PrintSpot)],dtLog,dtLogit)
  #Label as Norm instead of RUVLoess
  setnames(signalDT,
           grep("Log2RUVLoess|LogitRUVLoess",colnames(signalDT),value=TRUE),
           gsub("Log2RUVLoess|LogitRUVLoess","Norm", grep("Log2RUVLoess|LogitRUVLoess",colnames(signalDT),value=TRUE)))
  
  return(signalDT)
}

#' Calculate the residuals from the median of a vector of numeric values
#' @export
calcResidual <- function(x){
  mel <- as.numeric(median(x, na.rm=TRUE))
  return(x-mel)
}

#' Apply RUV normalization on a signal and its residuals
#' 
#' Assumes there are signal values in the first half of each row
#' and residuals in the second half
RUVArrayWithResiduals <- function(k, Y, M, cIdx, signalName, verboseDisplay=FALSE){
  YRUVIII <- RUVIII(Y, M, cIdx, k)
  nY <- YRUVIII[["newY"]]
  #Remove residuals
  nY <- nY[,1:(ncol(nY)/2)]
  #melt matrix to have Spot and Ligand columns
  nYm <- melt(nY, varnames=c("BW","PrintSpot"), value.name=signalName)
  nYm$BW <- as.character(nYm$BW)
  if(verboseDisplay){
    return(list(nYm=data.table(nYm), fullAlpha=YRUVIII[["fullalpha"]], W=RUVIII[["W"]]))
  }
  return(data.table(nYm))
}


#' Generate a matrix of signals and residuals
#' 
#' This function reorganizes a data.table into a matrix suitable for
#' RUV normalization.
#' 
#'@param dt a data.table with columns named BW and PrintSpot followed by one signal column 
#'@return A numeric matrix with BW rows and two sets of columns. The second
#'set of columns are the residuals from the medians of each column and have
#'"_Rel" appended to their names.
signalResidualMatrix <- function(dt){
  signalName <- colnames(dt)[ncol(dt)]
  if(grepl("Logit", signalName)){
    fill <- log2(.01/(1-.01))
  } else if(grepl("Log", signalName)){
    fill <- log2(.001)
  } else {
    fill <- 0
  }
  
  dts <- data.table(dcast(dt[dt$SignalType=="Signal",], BW~PrintSpot, value.var=signalName, fill=fill, na.rm=TRUE))
  dtr <- data.table(dcast(dt[dt$SignalType=="Residual",], BW~PrintSpot, value.var=signalName, fill=fill, na.rm=TRUE))
  rowNames <- dts$BW
  dts <- dts[,BW := NULL]
  dtr <- dtr[,BW:=NULL]
  setnames(dtr,colnames(dtr),paste0(colnames(dtr),"_Rel"))
  dtsr <- cbind(dts,dtr)
  srm <- matrix(unlist(dtsr),nrow=nrow(dtsr))
  rownames(srm) <- rowNames
  colnames(srm) <- colnames(dtsr)
  return(srm)
}

#' RUV normalization function
#' 
#' Based on method and code from Johann Gagnon-Bartsch. This function is written by Johann Gagnon-Bartsch and will become
#'part of the ruv package.
#' @param Y The matrix of values to be normalized
#' @param M A amtrix that describes the organization of the replicates in the Y matrix
#' @param ctl An integer vector denoted which columns in the Y matrix are controls
#' @param k The number of factors to remove
#' @param average Logical to determine if averages should be returned
#' @param fullalpha 
#' @return A list with the normalized Y values and the fullalpha matrix
RUVIII = function(Y, M, ctl, k=NULL, eta=NULL, average=FALSE, fullalpha=NULL)
{
  Y = RUV1(Y,eta,ctl)
  if (is.null(k))
  {
    ycyctinv = solve(Y[,ctl]%*%t(Y[,ctl]))
    newY = (M%*%solve(t(M)%*%ycyctinv%*%M)%*%(t(M)%*%ycyctinv)) %*% Y
    fullalpha=NULL
  }
  else if (k == 0) newY = Y
  else
  {
    m = nrow(Y)
    Y0 = residop(Y,M)
    fullalpha = t(svd(Y0%*%t(Y0))$u[,1:(m-ncol(M)),drop=FALSE])%*%Y
    k<-min(k,nrow(fullalpha))
    alpha = fullalpha[1:k,,drop=FALSE]
    ac = alpha[,ctl,drop=FALSE]
    W = Y[,ctl]%*%t(ac)%*%solve(ac%*%t(ac))
    newY = Y - W%*%alpha
  }
  if (average) newY = ((1/apply(M,2,sum))*t(M)) %*% newY
  return(list(newY = newY, fullalpha=fullalpha, W=W))
}


#' Create an M matrix for the RUV normalization
#' 
#' Each row is for a unit to be normalized and
#' each column is a unique replicate type
#' Each row will have a 1 to indicate the replicate type
#' all other values will be 0
#' @param dt The datatable to be normalized that has columns Barcode, Well and 
#' those in the replicateCols parameter.
#' @param replicateCols A character vector of column names in dt that define a replicate well.
#' @return A matrix suitable for defining the dataset structure in RUV normalization
#' @export
createRUVM <- function(dt,replicateCols=c("CellLine","Ligand","Drug"))
{
  #Add a column that defines what makes a well a replicate
  dt$ReplicateID <- do.call(paste, c(dt[,replicateCols, with=FALSE], sep="_"))
  #Add a similar column that binds in the barcode and well locations
  dt$UnitID <- do.call(paste, c(dt[,c("Barcode","Well",replicateCols), with=FALSE], sep="_"))
  #Set up the M Matrix to denote replicate ligand wells
  nrUnits <- length(unique(dt$UnitID[dt$SignalType=="Signal"]))
  nrReplicateIDs <- length(unique(dt$ReplicateID[dt$SignalType=="Signal"]))
  M <-matrix(0, nrow = nrUnits, ncol = nrReplicateIDs)
  rownames(M) <- unique(dt$UnitID[dt$SignalType=="Signal"])
  colnames(M) <- unique(dt$ReplicateID[dt$SignalType=="Signal"])
  rownames(M) <- gsub("[|]","pipe",rownames(M))
  colnames(M) <- gsub("[|]","pipe",colnames(M))
  #Indicate the replicate ligands
  for(replicate in colnames(M)){
    #Put a 1 in the rownames that contain the column name
    M[grepl(replicate,rownames(M),fixed=TRUE),colnames(M)==replicate] <- 1
  }
  rownames(M) <- gsub("pipe","|",rownames(M))
  colnames(M) <- gsub("pipe","|",colnames(M))
  return(M)
}

#' Loess normalize an array using the spatial residuals
loessNorm <- function(Value,Residual,ArrayRow,ArrayColumn){
  dt <-data.table(Value=Value,Residual=Residual,ArrayRow=ArrayRow,ArrayColumn=ArrayColumn)
  lm <- loess(Residual~ArrayRow+ArrayColumn, dt, span=.7)
  dt$ResidualLoess<-predict(lm)
  dt <- dt[,ValueLoess := Value-ResidualLoess]
  return(ValueLoess = dt$ValueLoess)
}

#' Loess normalize values within an array
#'@export
loessNormArray <- function(dt){
  #Identify the Signal name
  signalName <- unique(dt$SignalName)
  setnames(dt,signalName,"Value")
  #Get the median of the replicates within the array
  dt <- dt[,mel := median(Value), by=c("BW","ECMp","Drug")]
  #Get the residuals from the spot median
  dt <- dt[,Residual := Value-mel]
  #Subtract the loess model of each array's residuals from the signal
  dt <- dt[, ValueLoess:= loessNorm(Value,Residual,ArrayRow,ArrayColumn), by="BW"]
  setnames(dt,"ValueLoess", paste0(signalName,"Loess"))
  BW <- "BW"
  PrintSpot <- "PrintSpot"
  dt <- dt[,c(paste0(signalName,"Loess"),BW,PrintSpot), with=FALSE]
  setkey(dt,BW,PrintSpot)
  return(dt)
}

# #Create and test generating the RUV M matrix
# #' Create an M matrix for the RUV normalization
# #' 
# #' The M matrix holds the structure of the dataset in RUV normalization.
# #' There is one row for each unit to be normalized and
# #' one column for each unique unit type
# #' Each row will have one 1 to indicate the unit type
# #' all other values will be 0
# #' @param dt The datatable to be normalized. There must be a SignalType column 
# #' where a value of "Signal" denotes which rows should be included in the M matrix.
# #' @param unitID The column name that identifies the names of the units to be normalized.
# #' For example, this may have the value BW as the barcode and well can be combined to 
# #' create unique identifiers for a unit of data.
# #' @param uniqueID The column name that uniquely identifies the replicates. For example,
# #' this may have a value of Ligand or LigandDrug depending on the experiment.
# #' @return A datatable with values of 1 and 0 that captures the structure of dt.
# #' @export
# createRUVMGeneral <- function(dt, unitID="BWL", uniqueID="Ligand")
# {
#   if(!unitID %in% colnames(dt))stop(paste("The data.table to be normalized must have a", unitID, "column"))
#   if(!uniqueID %in% colnames(dt))stop(paste("The data.table to be normalized must have a",uniqueID,"column"))
#   if(!"SignalType" %in% colnames(dt))stop("The data.table to be normalized must have a SignalType column")
#   #Create a dataframe with each row a unique unit name and a 2nd column with values that classify the unit
#   Mdf <- data.table(UnitID=unique(dt[[unitID]]),stringsAsFactors = FALSE)
#   tmp <- merge(Mdf,dt, by.x="UnitID",by.y=unitID)
#   t2 <- tmp[,]
#   ##Debug here....
#   #Replace any pipe symbols in the ligand names
#   dt[[uniqueID]] <- gsub("[/|]","pipe",dt[[uniqueID]])
#   dt[[unitID]] <- gsub("[/|]","pipe",dt[[unitID]])
#   #Set up the M Matrix to denote replicate ligand wells
#   nrUnits <- length(unique(dt[[unitID]][dt$SignalType=="Signal"]))
#   nrUniqueIDs <- length(unique(dt[[uniqueID]][dt$SignalType=="Signal"]))
#   M <-matrix(0, nrow = nrUnits, ncol = nrUniqueIDs)
#   rownames(M) <- unique(dt[[unitID]][dt$SignalType=="Signal"])
#   colnames(M) <- unique(dt[[uniqueID]][dt$SignalType=="Signal"])
#   #Indicate the replicate ligands
#   for(uID in rownames(M)){
#     #For each row, put a 1 in column that matches it's uniqueID value
#     M[uID,dt[[uniqueID]][dt[[unitID]]==uID]==colnames(M)] <- 1
#   }
#   #Replace any pipe symbols in the ligand names
#   colnames(M) <- gsub("pipe","|",colnames(M))
#   rownames(M) <- gsub("pipe","|",rownames(M))
#   return(M)
# }
# 



# #' Normalize the proliferation ratio signal to the collagen 1 values
# #' @param x a dataframe or datatable with columns names ProliferatioRatio
# #' and ShortName. ShortName must include at least one entry of COL1 or COL I.
# #' @return The input dataframe of datatable with a normedProliferation column that has the ProliferationRatio values divided by the median collagen
# #' 1 proliferation value
# #' @export
# normProfToCol1 <- function(x){
#   col1Median <- median(x$ProliferationRatio[x$ShortName %in% c("COL1", "COL I")],na.rm = TRUE)
#   normedProliferation <- x$ProliferationRatio/col1Median
# }

# #' Normalize to a base MEP
# #'
# #' Normalizes one channel of values for all MEPs in a multi-well plate to one
# #' base MEP.
# #'
# #' @param DT A \code{data.table} that includes a numeric value column to be
# #'   normalized, a \code{ECMp} column that has the printed ECM names and a
# #'   \code{Growth.Factors} or \code{Ligand}column that has the growth factor names.
# #' @param value The name of the column of values to be normalized
# #' @param baseECM A regular expression for the name or names of the printed ECM(s) to be normalized against
# #' @param baseGF A regular expression for the name or names of the soluble growth factors to be normalized against
# #' @return A numeric vector of the normalized values
# #'
# #' @section Details: \code{normWellsWithinPlate} normalizes the value column of
# #'   all MEPs by dividing the median value of the replicates of the MEP that
# #'   is the pairing of baseECM  with baseGF.
# #'   @export
# normWellsWithinPlate <- function(DT, value, baseECM, baseGF) {
#   if(!c("ECMp") %in% colnames(DT)) stop(paste("DT must contain a ECMp column."))
#   if(!c(value) %in% colnames(DT)) stop(paste("DT must contain a", value, "column."))
#   if("Ligand" %in% colnames(DT)){
#     valueMedian <- median(unlist(DT[(grepl(baseECM, DT$ECMp)  & grepl(baseGF,DT$Ligand)),value, with=FALSE]), na.rm = TRUE)
#   } else if (c("Growth.Factors") %in% colnames(DT)) {
#     valueMedian <- median(unlist(DT[(grepl(baseECM, DT$ECMp)  & grepl(baseGF,DT$Growth.Factors)),value, with=FALSE]), na.rm = TRUE)
#   } else stop (paste("DT must contain a Growth.Factors or Ligand column."))
#   normedValues <- DT[,value,with=FALSE]/valueMedian
#   return(normedValues)
# }


# #' RZS Normalize a Column of Data
# #'
# #' \code{normRZSWellsWithinPlate} normalizes all elements of DT[[value]] by
# #' subtracting the median of DT[[value]] of all baseECM spots in the
# #' baseL wells, then divides the result by the MAD*1.48 of all baseECM spots in
# #' the baseL wells
# #'@param DT A datatable with value, baseECM and baseL, ECMp and
# #'Ligand columns
# #'@param value A single column name of the value to be normalized
# #'@param baseECM A single character string or a regular expression that selects
# #'the ECM(s) that are used as the base for normalization.
# #'@param baseL A single character string or a regular expression that selects
# #'the ligand used as the base for normalization.
# #'@return a vector of RZS normalized values
# #' @export
# #'
# normRZSWellsWithinPlate <- function(DT, value, baseECM, baseL) {
#   if(!"ECMp" %in% colnames(DT)) stop (paste("DT must contain an ECMp column."))
#   if(!"Ligand" %in% colnames(DT)) stop (paste("DT must contain a Ligand column."))
#   if(!c(value) %in% colnames(DT)) stop(paste("DT must contain a", value, "column."))
#   
#   valueMedian <- median(unlist(DT[(grepl(baseECM, DT$ECMp) & grepl(baseL,DT$Ligand)), value, with=FALSE]), na.rm = TRUE)
#   if (is.na(valueMedian)) stop(paste("Normalization calculated an NA median for",value, baseECM, baseL))
#   
#   valueMAD <- mad(unlist(DT[(grepl(baseECM, DT$ECMp)  & grepl(baseL,DT$Ligand)),value, with=FALSE]), na.rm = TRUE)
#   #Correct for 0 MAD values
#   valueMAD <- valueMAD+.01
#   normedValues <- (DT[,value,with=FALSE]-valueMedian)/valueMAD
#   return(normedValues)
# }

# #' Normalize selected values in a dataset on a plate basis
# #' 
# #' A wrapper function for \code{normRZSWellsWithinPlate} that selects the
# #' \code{_CP_|_QI_|_PA_|SpotCellCount|Lineage} columns of dt if they exist and 
# #' normalizes them on a plate basis
# #' @param dt A data.table with a \code{Barcode} column numeric values to be RZS normalized 
# #'  using all ECM proteins in the FBS well
# #' @return A datatable with the normalized values
# #' @export
# normRZSDataset <- function(dt){
#   parmNormedList <- lapply(grep("_CP_|_QI_|_PA_|SpotCellCount|Lineage",colnames(dt),value = TRUE), function(parm){
#     dt <- dt[,paste0(parm,"_RZSNorm") := normRZSWellsWithinPlate(.SD, value=parm, baseECM = ".*",baseL = "FBS"), by="Barcode"]
#     return(dt)
#   })
#   return(parmNormedList[[length(parmNormedList)]])
# }

# #'Apply RUV and Loess Normalization to the signals in a dataset
# #' @export
# normRUVLoessResidualsDisplay <- function(dt, k){
#   setkey(dt,Barcode,Well,Ligand,ECMp)
#   metadataNames <- "Barcode|Well|^Spot$|^PrintSpot$|ArrayRow|ArrayColumn|^ECMp$|^Ligand$"
#   signalNames <- grep(metadataNames,colnames(dt),invert=TRUE, value=TRUE)
#   
#   #Add residuals from subtracting the biological medians from each value
#   residuals <- dt[,lapply(.SD,calcResidual), by="Barcode,Well,Ligand,ECMp", .SDcols=signalNames]
#   #Add within array location metadata
#   residuals$Spot <- as.integer(dt$Spot)
#   residuals$PrintSpot <- as.integer(dt$PrintSpot)
#   residuals$ArrayRow <- dt$ArrayRow
#   residuals$ArrayColumn <- dt$ArrayColumn
#   #Create a signal type
#   dt$SignalType <- "Signal"
#   residuals$SignalType <- "Residual"
#   srDT <- rbind(dt,residuals)
#   
#   #Add to carry metadata into matrices
#   srDT$BWL <- paste(srDT$Barcode, srDT$Well, srDT$Ligand, sep="_") 
# 
#   #Set up the M Matrix to denote replicates
#   nrControlWells <- sum(grepl("FBS",unique(srDT$BWL[srDT$SignalType=="Signal"])))
#   nrLigandWells <- length(unique(srDT$BWL[srDT$SignalType=="Signal"]))-nrControlWells
#   M <-matrix(0, nrow = length(unique(srDT$BWL[srDT$SignalType=="Signal"])), ncol = nrLigandWells+1)
#   rownames(M) <- unique(srDT$BWL[srDT$SignalType=="Signal"])
#   #Indicate the control wells in the last column
#   Mc <- M[grepl("FBS",rownames(M)),]
#   Mc[,ncol(Mc)] <-1L
#   #Subset to the ligand wells and mark as non-replicate
#   Ml <- M[!grepl("FBS",rownames(M)),]
#   for(i in 1:nrLigandWells) {
#     Ml[i,i] <- 1
#   }
#   #Add the replicate wells and restore the row order
#   M <- rbind(Mc,Ml)
#   M <- M[order(rownames(M)),]
#   
#   srmList <- lapply(signalNames, function(signalName, dt){
#     srm <- signalResidualMatrix(dt[,.SD, .SDcols=c("BWL", "PrintSpot", "SignalType", signalName)])
#     return(srm)
#   },dt=srDT)
#   names(srmList) <- signalNames
#   
#   srmRUVList <- lapply(names(srmList), function(srmName, srmList, M, k){
#     Y <- srmList[[srmName]]
#     #Hardcode in identification of residuals as the controls
#     resStart <- ncol(Y)/2+1
#     cIdx=resStart:ncol(Y)
#     nY <- RUVIIIArrayWithResiduals(k, Y, M, cIdx, srmName, verboseDisplay = TRUE)[["nYm"]] #Normalize the spot level data
#     nY$k <- k
#     nY$SignalName <- paste0(srmName,"RUV")
#     setnames(nY,srmName,paste0(srmName,"RUV"))
#     nY[[srmName]] <- as.vector(Y[,1:(resStart-1)])
#     return(nY)
#   }, srmList=srmList, M=M, k=k)
#   
#   #Reannotate with ECMp, MEP, ArrayRow and ArrayColumn
#   ECMpDT <- unique(srDT[,list(Well,PrintSpot,Spot,ECMp,ArrayRow,ArrayColumn)])
#   
#   srmERUVList <- lapply(srmRUVList, function(dt,ECMpDT){
#     setkey(dt,Well,PrintSpot)
#     setkey(ECMpDT,Well,PrintSpot)
#     dtECMpDT <- merge(dt,ECMpDT)
#     dtECMpDT$MEP <- paste(dtECMpDT$ECMp,dtECMpDT$Ligand,sep="_")
#     return(dtECMpDT)
#   },ECMpDT=ECMpDT)
#   
#   
#   #Add Loess normalized values for each RUV normalized signal
#   RUVLoessList <- lapply(srmERUVList, function(dt){
#     dtRUVLoess <- loessNormArray(dt)
#   })
#   
#   #Add Loess normalized values for each Raw signal
#   RUVLoessList <- lapply(srmERUVList, function(dt){
#     dt$SignalName <- sub("RUV","",dt$SignalName)
#     dtLoess <- loessNormArray(dt)
#   })
#   
#   #Combine the normalized signal into one data.table
#   #with one set of metadata
#   signalDT <- do.call(cbind,lapply(RUVLoessList, function(dt){
#     sdt <- dt[,grep("_CP_|_PA_|Cells|Reference",colnames(dt)), with=FALSE]
#   }))
#   
#   signalMetadataDT <- cbind(RUVLoessList[[1]][,grep("_CP_|_PA_|Cells|Reference",colnames(RUVLoessList[[1]]), invert=TRUE), with=FALSE], signalDT)
#   signalMetadataDT <- signalMetadataDT[,SignalName := NULL]
#   signalMetadataDT <- signalMetadataDT[,mel := NULL]
#   signalMetadataDT <- signalMetadataDT[,Residual := NULL]
#   return(signalMetadataDT)
# }

# #' Apply the RUV algortihm 
# normRUVDataset <- function(dt, k){
#   #browser()
#   #Setup data with plate as the unit
#   #There are 694 negative controls and all plates are replicates
#   
#   setkey(dt, Barcode,Well,Spot)     #Sort the data
#   metadataNames <- "Barcode|Well|^Spot$"
#   signalNames <- grep(metadataNames,colnames(dt),invert=TRUE, value=TRUE)
#   
#   dt$WS <- paste(dt$Well, dt$Spot,sep="_") #Add to carry metadata to matrix
#   
#   nYL <- lapply(signalNames, function(signal, dt, M){
#     #Create appropriate fill for missing values for each signal
#     if(grepl("EdU|Proportion|Ecc", signal)){
#       fill <- log2(.01/(1-.01))
#     } else if(grepl("Log", signal)){
#       fill <- log2(.001)
#     } else {
#       fill <- 0
#     }
#     
#     #Cast into barcode rows and well spot columns
#     dtc <- dcast(dt, Barcode~WS, value.var=signal, fill=fill)
#     #Remove the Barcode column and use it as rownames in the matrix
#     barcodes <-dtc$Barcode
#     dtc <- dtc[,Barcode := NULL]
#     Y <- matrix(unlist(dtc), nrow=nrow(dtc), dimnames=list(barcodes, colnames(dtc)))
#     k<-min(k, nrow(Y)-1)
#     cIdx <- which(grepl("A03",colnames(Y)))
#     nY <- RUVIII(Y, M, cIdx, k)[["newY"]]
#     #melt matrix to have ECMp and Ligand columns
#     nYm <- melt(nY, varnames=c("Barcode","WS"),  as.is=TRUE)
#     nYm <- data.table(nYm)
#     
#     #Add the name of the signal and convert back to well and spot
#     nYm$Signal <- paste0(signal,"_Norm")
#     return(nYm)
#     
#   }, dt=dt, M=matrix(1,nrow=length(unique(dt$Barcode)))
#   # ,mc.cores = detectCores())
#   )
#   
#   nYdtmelt <- rbindlist(nYL)
#   nY <- dcast(nYdtmelt, Barcode+WS~Signal, value.var="value")
#   nY$Well <- gsub("_.*","",nY$WS)
#   nY$Spot <- as.integer(gsub(".*_","",nY$WS))
#   nY <- nY[,WS:=NULL]
#   return(nY)
# }
