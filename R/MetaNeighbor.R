#' Runs MetaNeighbor
#'
#' For each gene set of interest, the function builds a network of rank
#' correlations between all cells. Next,It builds a network of rank correlations
#' between all cells for a gene set. Next, the neighbor voting predictor
#' produces a weighted matrix of predicted labels by performing matrix
#' multiplication between the network and the binary vector indicating cell type
#' membership, then dividing each element by the null predictor (i.e., node
#' degree). That is, each cell is given a score equal to the fraction of its
#' neighbors (including itself), which are part of a given cell type. For
#' cross-validation, we permute through all possible combinations of
#' leave-one-dataset-out cross-validation, and we report how well we can recover
#' cells of the same type as area under the receiver operator characteristic
#' curve (AUROC). This is repeated for all folds of cross-validation, and the
#' mean AUROC across folds is reported. Calls
#' \code{\link{neighborVoting}}.
#'
#' @param dat A SummarizedExperiment object containing gene-by-sample
#' expression matrix.
#' @param i default value 1; non-zero index value of assay containing the matrix
#' data
#' @param experiment_labels A numerical vector that indicates the source of each
#' sample.
#' @param celltype_labels A matrix that indicates the cell type of each sample.
#' @param genesets Gene sets of interest provided as a list of vectors.
#' @param bplot default true, beanplot is generated
#' @return A matrix of AUROC scores representing the mean for each gene set
#' tested for each celltype is returned directly (see \code{\link{neighborVoting}}).
#'
#' @seealso \code{\link{neighborVoting}}
#' @examples
#' data("mn_data")
#' data("GOmouse")
#' library(SummarizedExperiment)
#' AUROC_scores = MetaNeighbor(dat = mn_data,
#'                             experiment_labels = as.numeric(factor(mn_data$study_id)),
#'                             celltype_labels = metadata(colData(mn_data))[["cell_labels"]],
#'                             genesets = GOmouse,
#'                             bplot = TRUE)
#' @export
#'

MetaNeighbor <-function(dat, i = 1, experiment_labels, celltype_labels, genesets, bplot = TRUE, fast_version = FALSE) {

    dat <- SummarizedExperiment::assay(dat, i = i)

    #check length of experiment_labels equal # of samples
    if(length(experiment_labels) != length(colnames(dat))){
        stop('experiment_labels length does not match number of samples')
    }

    #check length of celltype_labels equal # of samples
    if(length(rownames(celltype_labels)) != length(colnames(dat))){
        stop('celltype_labels length does not match number of samples')
    }

    #check obj contains more than 1 unique study_id
    if(length(unique(experiment_labels)) < 2){
        stop('Found only 1 unique experiment_label. Please use data from more than 1 study!')
    }

    #check genesets matches more than 1 genes in gene_matrix
    genes_in_geneset <- as.character(unlist(genesets))
    genes_in_matrix <- rownames(dat)
    if(length(intersect(genes_in_geneset,genes_in_matrix)) < 1)
        stop('No matching genes between genesets and gene_matrix')

    ROCs              <- vector(mode = "list", length = length(genesets))
    names(ROCs)       <- names(genesets)
    nv_mat            <- matrix(data = 0,
                                ncol = dim(celltype_labels)[2],
                                nrow = length(genesets))
    rownames(nv_mat)  <- names(genesets)
    colnames(nv_mat)  <- colnames(celltype_labels)

    for(l in seq_along(genesets)){
        print(names(genesets)[l])
        geneset     <- genesets[[l]]
        m           <- match(rownames(dat), geneset)
        dat_sub     <- dat[!is.na(m),]
        if (fast_version) {
          ROCs[[l]] <- score_low_mem(dat_sub, experiment_labels, celltype_labels)
        } else {
          ROCs[[l]] <- score_default(dat_sub, experiment_labels, celltype_labels)
        }
    }

    for(i in seq_along(ROCs)){
        nv_mat[i,] <- round(rowMeans(ROCs[[i]][[1]], na.rm = TRUE),3)
    }

    if(bplot){
        Celltype = rep(colnames(nv_mat),each=dim(nv_mat)[1])
        ROCValues = unlist(lapply(seq_len(dim(nv_mat)[2]), function(i) nv_mat[,i]))
        beanplot::beanplot(ROCValues ~ Celltype,
                           border="NA",
                           col="gray",
                           ylab="AUROC",
                           what=c(0,1,1,1),
                           frame.plot = FALSE)
    }

    return(nv_mat)
}

# Compute ROCs according to the default procedure
score_default <- function(dat_sub, experiment_labels, celltype_labels) {
  dat_sub     <- stats::cor(dat_sub, method = "s")
  dat_sub     <- as.matrix(dat_sub)
  rank_dat    <- dat_sub
  rank_dat[]  <- rank(dat_sub, ties.method = "average", na.last = "keep")
  rank_dat[is.na(rank_dat)] <- 0
  rank_dat    <- rank_dat/max(rank_dat)
  return(neighborVoting(experiment_labels,
                        celltype_labels,
                        rank_dat,
                        means = FALSE))
}

# Compute ROCs using the approximate low memory version
score_low_mem <- function(dat_sub, study_id, celltype_labels, skip_network = TRUE) {
  # remove cells that have zero expressed genes
  nonzero_cells <- Matrix::colSums(dat_sub) > 0
  dat_sub <- dat_sub[, nonzero_cells]
  study_id <- study_id[nonzero_cells]
  celltype_labels <- as.matrix(celltype_labels[nonzero_cells,])

  dat_sub <- normalize_cols(dat_sub)

  unique_study_ids <- unique(study_id)
  aurocs <- c()
  for (study in unique_study_ids) {
    votes <- compute_votes(candidates = dat_sub[, study_id == study],
                           voters = dat_sub[, study_id != study],
                           voter_id = celltype_labels[study_id != study,],
                           skip_network)
    all_aurocs <- compute_aurocs(
      votes, candidate_id = celltype_labels[study_id == study,, drop = FALSE]
    )
    aurocs <- cbind(aurocs, diag(all_aurocs))
  }
  colnames(aurocs) <- unique_study_ids
  return(list(aurocs))
}

# Compute neighbor voting for a given set of candidates and voters
compute_votes <- function(candidates, voters, voter_id, skip_network) {
  if (skip_network) {
    return(compute_votes_without_network(candidates, voters, voter_id))
  } else {
    network <- build_network(candidates, voters)
    votes <- compute_votes_from_network(network)
    rm(network); gc()
    return(votes)
  }
}
