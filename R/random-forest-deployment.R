# Import the common functions.
source('R/common.R')
source('R/supervised-model-deployment.R')

#' Deploy a production-ready predictive RandomForest model
#'
#' @description This step allows one to
#' \itemize{
#' \item Create a final model on all of your training data
#' \item Automatically save the model
#' \item Run the model against test data to generate predictions
#' \item Push these predictions to SQL Server
#' }
#' @docType class
#' @import caret
#' @import doParallel
#' @importFrom R6 R6Class
#' @import ranger
#' @import RODBC
#' @param type The type of model (either 'regression' or 'classification')
#' @param df Dataframe whose columns are used for calc.
#' @param grainCol The dataframe's column that has IDs pertaining to the grain
#' @param testWindowCol This column dictates the split between model training and
#' test sets. Those rows with zeros in this column indicate the training set
#' while those that have ones indicate the test set
#' @param predictedCol Column that you want to predict.
#' @param impute For training df, set all-column imputation to F or T.
#' This uses mean replacement for numeric columns
#' and most frequent for factorized columns.
#' F leads to removal of rows containing NULLs.
#' @param debug Provides the user extended output to the console, in order
#' to monitor the calculations throughout. Use T or F.
#' @seealso \code{\link{healthcareai}}
#' @examples
#' #### Classification example using diabetes data ####
#' # This example requires you to first create a table in SQL Server
#' # If you prefer to not use SAMD, execute this in SSMS to create output table:
#' # CREATE TABLE dbo.HCRDeployRegressionBASE(
#' #   BindingID float, BindingNM varchar(255), LastLoadDTS datetime2,
#' #   PatientEncounterID int, <--change to match inputID
#' #   PredictedProbNBR decimal(38, 2),
#' #   Factor1TXT varchar(255), Factor2TXT varchar(255), Factor3TXT varchar(255)
#' # )
#'
#' #setwd('C:/Yourscriptlocation/Useforwardslashes') # Uncomment if using csv
#' ptm <- proc.time()
#' library(healthcareai)
#'
#' connection.string <- "driver={SQL Server};
#'                       server=localhost;
#'                       database=SAM;
#'                       trusted_connection=true"
#'
#' # Use this for an example SQL source:
#' # query <- 'SELECT * FROM [SAM].[YourCoolSAM].[SomeTrainingSetTable]'
#' # df <- selectData(connection.string, query)
#'
#' # Can delete these four lines when you set your SQL connection/query
#' csvfile <- system.file("extdata", "HCRDiabetesClinical.csv", package = "healthcareai")
#' # Change csvfile to 'path/to/yourfile'
#' df <- read.csv(file = csvfile, header = TRUE, na.strings = c("NULL", "NA", ""))
#'
#' head(df)
#'
#' # Remove unnecessary columns
#' df$PatientID <- NULL
#'
#' p <- SupervisedModelDeploymentParams$new()
#' p$type <- "classification"
#' p$df <- df
#' p$grainCol <- "PatientEncounterID"
#' p$testWindowCol <- "InTestWindowFLG"
#' p$predictedCol <- "ThirtyDayReadmitFLG"
#' p$impute <- TRUE
#' p$debug <- FALSE
#' p$useSavedModel <- FALSE
#' p$cores <- 1
#' p$sqlConn <- connection.string
#' p$destSchemaTable <- "dbo.HCRDeployClassificationBASE"
#'
#' dL <- RandomForestDeployment$new(p)
#' dL$deploy()
#'
#' print(proc.time() - ptm)
#' @export

RandomForestDeployment <- R6Class("RandomForestDeployment",
  #Inheritance
  inherit = SupervisedModelDeployment,

  #Private members
  private = list(

    # variables
    coefficients = NULL,
    multiplyRes = NULL,
    orderedFactors = NULL,
    predictedValsForUnitTest = NULL,

    # functions
    connectDataSource = function() {
      odbcCloseAll()
      # Convert the connection string into a real connection object.
      self$params$sqlConn <- odbcDriverConnect(self$params$sqlConn)
    },

    closeDataSource = function() {
      odbcCloseAll()
    },

    fitGeneralizedLinearModel = function() {
      if (isTRUE(self$params$debug)) {
        print('generating fitLogit...')
      }

      if (self$params$type == 'classification') {
        private$fitLogit <- glm(
          as.formula(paste(self$params$predictedCol, '.', sep = " ~ ")),
          data = private$dfTrain,
          family = binomial(link = "logit"),
          metric = "ROC",
          control = list(maxit = 10000),
          trControl = trainControl(classProbs = TRUE, summaryFunction = twoClassSummary)
        )

      } else if (self$params$type == 'regression') {
        private$fitLogit <- glm(
          as.formula(paste(self$params$predictedCol, '.', sep = " ~ ")),
          data = private$dfTrain,
          metric = "RMSE",
          control = list(maxit = 10000)
        )
      }
    },

    saveModel = function() {
      if (isTRUE(self$params$debug)) {
        print('Saving model...')
      }

      # Save models if specified
      if (isTRUE(!self$params$useSavedModel)) {

        #NOTE: save(private$fitLogit, ...) does not work!
        fitLogitObj <- private$fitLogit
        fitObj <- private$fit

        save(fitLogitObj, file = "rmodel_var_import.rda")
        save(fitObj, file = "rmodel_probability.rda")
      }

      # This isn't needed if formula interface is used in randomForest
      private$dfTest[[self$params$predictedCol]] <- NULL

      if (isTRUE(self$params$debug)) {
        print('Test set before being used in predict(), after removing y')
        print(str(private$dfTest))
      }
    },

    performPrediction = function() {
      if (self$params$type == 'classification') {
        #  these are probabilities
        predictedValsTemp <- predict(private$fit, data = private$dfTest)
        private$predictedVals <- predictedValsTemp$predictions[, 2]
        private$predictedValsForUnitTest <- private$predictedVals[5] # for unit test

        print('Probability predictions are based on random forest')

        if (isTRUE(self$params$debug)) {
          print(paste0('Rows in prob prediction: ', nrow(private$predictedVals)))
          print('First 10 raw classification probability predictions')
          print(round(private$predictedVals[1:10], 2))
        }

      } else if (self$params$type == 'regression') {
        # this is in-kind prediction
        predictedValsTemp <- predict(private$fit, data = self$dfTest)
        private$predictedVals <- predictedValsTemp$predictions

        if (isTRUE(self$params$debug)) {
          print(paste0(
            'Rows in regression prediction: ',
            length(private$predictedVals)
          ))
          print('First 10 raw regression predictions (with row # first)')
          print(round(private$predictedVals[1:10], 2))
        }
      }
    },

    calculateCoeffcients = function() {
      # Do semi-manual calc to rank cols by order of importance
      coeffTemp <- private$fitLogit$coefficients

      if (isTRUE(self$params$debug)) {
        print('Coefficients for the default logit (for ranking var import)')
        print(coeffTemp)
      }

      private$coefficients <-
        coeffTemp[2:length(coeffTemp)] # drop intercept
    },

    calculateMultiplyRes = function() {
      # Apply multiplication of coeff across each row of test set
      # Remove y (label) so we do multiplication only on X (features)
      private$dfTest[[self$params$predictedCol]] <- NULL

      if (isTRUE(self$params$debug)) {
        print('Test set after removing predicted column')
        print(str(private$dfTest))
      }

      private$multiplyRes <-
        sweep(private$dfTestRaw, 2, private$coefficients, `*`)

      if (isTRUE(self$params$debug)) {
        print('Data frame after multiplying raw vals by coeffs')
        print(private$multiplyRes[1:10, ])
      }
    },

    calculateOrderedFactors = function() {
      # Calculate ordered factors of importance for each row's prediction
      private$orderedFactors <- t(sapply
                                  (1:nrow(private$multiplyRes),
                                  function(i)
                                    colnames(private$multiplyRes[order(private$multiplyRes[i, ],
                                                                        decreasing = TRUE)])))

      if (isTRUE(self$params$debug)) {
        print('Data frame after getting column importance ordered')
        print(private$orderedFactors[1:10, ])
      }
    },

    saveDataIntoDb = function() {
      dtStamp <- as.POSIXlt(Sys.time(), "GMT")

      # Combine grain.col, prediction, and time to be put back into SAM table
      outDf <- data.frame(
        0,                                 # BindingID
        'R',                               # BindingNM
        dtStamp,                           # LastLoadDTS
        private$grainTest,                 # GrainID
        private$predictedVals,             # PredictedProbab
        private$orderedFactors[, 1:3])    # Top 3 Factors

      predictedResultsName = ""
      if (self$params$type == 'classification') {
        predictedResultsName = "PredictedProbNBR"
      } else if (self$params$type == 'regression') {
        predictedResultsName = "PredictedValueNBR"
      }
      colnames(outDf) <- c(
        "BindingID",
        "BindingNM",
        "LastLoadDTS",
        self$params$grainCol,
        predictedResultsName,
        "Factor1TXT",
        "Factor2TXT",
        "Factor3TXT"
      )

      if (isTRUE(self$params$debug)) {
        print('Dataframe going to SQL Server:')
        print(str(outDf))
      }

      # Save df to table in SAM database
      out <- sqlSave(
        channel = self$params$sqlConn,
        dat = outDf,
        tablename = self$params$destSchemaTable,
        append = T,
        rownames = F,
        colnames = F,
        safer = T,
        nastring = NULL,
        verbose = self$params$debug
      )

      # Print success if insert was successful
      if (out == 1) {
        print('SQL Server insert was successful')
      }
    }
  ),

  #Public members
  public = list(
    #Constructor
    #p: new SupervisedModelDeploymentParams class object,
    #   i.e. p = SupervisedModelDeploymentParams$new()
    initialize = function(p) {

      super$initialize(p)

      if (!is.null(p$rfmtry))
        self$params$rfmtry <- p$rfmtry

      if (!is.null(p$trees))
        self$params$trees <- p$trees
    },

    #This would be a user-defined method
    # which gets called by buildFitObject function
    fitRandomForest = function() {

      # Set proper mtry (either based on recc default or specified)
      if (nchar(self$params$rfmtry) == 0 &&
          self$params$type == 'classification') {
        rfMtryTemp <- floor(sqrt(ncol(private$dfTrain)))
      } else if (nchar(self$params$rfmtry) == 0 &&
                 self$params$type == 'regression') {
        rfMtryTemp <- max(floor(ncol(private$dfTrain) / 3), 1)
      } else {
        rfMtryTemp <- self$params$rfmtry
      }

      if (isTRUE(self$params$debug)) {
        print('generating fit for random forest...')
      }

      if (self$params$type == 'classification') {
        private$fit <- ranger(
          as.formula(paste(
            self$params$predictedCol, '.', sep = " ~ "
          )),
          data = private$dfTrain,
          probability = TRUE,
          num.trees = self$params$trees,
          write.forest = TRUE,
          mtry = rfMtryTemp
        )
      } else if (self$params$type == 'regression') {
        private$fit <- ranger(
          as.formula(paste(self$params$predictedCol, '.', sep = " ~ ")),
          data = private$dfTrain,
          num.trees = self$params$trees,
          write.forest = TRUE,
          mtry = rfMtryTemp
        )
      }
    },

    buildFitObject = function() {

      # Get fit object by random forest
      self$fitRandomForest()
    },

    #Override: Build Deploy Model
    buildDeployModel = function() {

      if (isTRUE(self$params$debug)) {
        print('Training data set immediately before training')
        print(str(private$dfTrain))
      }

      # Start default logit (for var importance)
      private$fitGeneralizedLinearModel()

      # Build fit object
      self$buildFitObject()

      print('Details for proability model:')
      print(private$fit)
    },

    #Override: deploy the model
    deploy = function() {

      # Connect to sql via odbc driver
      private$connectDataSource()

      if (isTRUE(self$params$useSavedModel)) {
        load("rmodel_var_import.rda")  # Produces fitLogit object
        private$fitLogit <- fitLogit

        load("rmodel_probability.rda") # Produces fit object (for probability)
        private$fit <- fit
      } else {
        private$registerClustersOnCores()

        # build deploy model
        self$buildDeployModel()
      }

      # Save model
      private$saveModel()

      # Predict
      private$performPrediction()

      # Calculate Coeffcients
      private$calculateCoeffcients()

      # Calculate MultiplyRes
      private$calculateMultiplyRes()

      # Calculate Ordered Factors
      private$calculateOrderedFactors()

      # Save data into db
      private$saveDataIntoDb()

      # Clean up.
      if (isTRUE(!self$params$useSavedModel)) {
        private$stopClustersOnCores()
      }
      private$closeDataSource()
    },

    #Get predicted values
    getPredictedValsForUnitTest = function() {
      return(private$predictedValsForUnitTest)
    }
  )
)
