## Donor deconvolution in multiplexed scRNA-seq.

#' Donor deconvolution of scRNA-seq data
#'
#' @param cell_data either character(1), path to a VCF file containing variant
#' data for cells, or a list containing A and D matrices
#' @param donor_data either character(1), path to a VCF file containing genotype
#' data for donors, or a matrix for donor genotypes, matched to cell data
#' @param n_donor integer(1), number of donors to infer if not given genotypes
#' @param check_doublet logical(1), should the function check for doublet cells?
#' @param n_vars_threshold integer(1), if the number of variants with coverage
#' in a cell is below this threshold, then the cell will be given an
#' "unassigned" donor ID (default: 10)
#' @param s_threshold numeric(1), threshold for posterior probability of
#' donor assignment (must be in [0, 1]); if best posterior probability for a
#' donor is greater then the threshold, then the cell is assigned to that donor
#' (as long as the cell is not determined to be a doublet) and if below the
#' threshold, then the cell's donor ID is "unassigned"
#' @param d_threshold numeric(1), threshold for summarised posterior probability
#' of doublet detection (must be in [0, 1]);
#' @param verbose logical(1), should the function output verbose information
#' while running?
#' @param ... arguments passed to \code{donor_id_VB}
#'
#' @details This function reads in all elements of the provided VCF file(s) into
#' memory, so we highly recommend filtering VCFs to the minimal appropriate set
#' of variants (e.g. with the bcftools software) before applying them to this
#' function.
#'
#' @return a list with elements: \code{logLik}, log-likelihood of the fitted
#' model; \code{theta}, ; \code{GT}, a matrix of inferred genotypes for each
#' donor; \code{GT_doublet}, a matrix of inferred genotypes for each possible
#' doublet (pairwise combinations of donors); \code{prob}, a matrix of posterior
#' probabilities of donor identities for each cell; \code{prob_doublet}, a
#' matrix of posterior probabilities for each possible doublet for each cell;
#' \code{A}, a variant x cell matrix of observed read counts supporting the
#' alternative allele; \code{D}, a variant x cell matrix of observed read depth;
#' \code{assigned}, a data.frame reporting the cell-donor assignments with
#' columns "cell" (cell identifier), "donor_id" (inferred donor, or "doublet" or
#' "unassigned"), "prob_max" (the maximum posterior probability across donors),
#' "prob_doublet" (the probability that the cell is a doublet), "n_vars" (the
#' number of variants with non-zero read depth used for assignment).
#'
#' @author Davis McCarthy and Yuanhua Huang
#'
#' @export
#'
#' @examples
#' ids <- donor_id(system.file("extdata", "cells.donorid.vcf.gz", package = "cardelino"),
#'                 system.file("extdata", "donors.donorid.vcf.gz", package = "cardelino"))
#' table(ids$assigned$donor_id)
#'
donor_id <- function(cell_data, donor_data = NULL, n_donor=NULL, 
                     check_doublet = TRUE,
                     n_vars_threshold = 10, s_threshold = 0.9,
                     d_threshold = 0.9, verbose = FALSE, ...) {
    if (typeof(cell_data) == "character") {
        in_data <- load_cellSNP_vcf(cell_data)
    } else {
        in_data <- cell_data
    }
    if (is.null(donor_data)) {
        in_data[["GT_donors"]] <- NULL
    } else{
        if (typeof(donor_data) == "character") {
            in_data[["GT_donors"]] <- load_GT_vcf(donor_data)
        } else {
            in_data[["GT_donors"]] <- donor_data
        }
    }
    
    if (verbose) {
        message("Donor ID using ", nrow(in_data$A), " variants")
    }
    out <- donor_id_VB(in_data$A, in_data$D, GT = in_data$GT_donors,
                       K = n_donor, check_doublet = check_doublet,
                       verbose = verbose, ...)

    ## output data
    out$A <- in_data$A
    out$D <- in_data$D
    # out$GT <- in_data$GT_cells #out has GT output

    ## assign data frame
    n_vars <- Matrix::colSums(out$D)
    assigned <- assign_cells_to_clones(out$prob, threshold = s_threshold)
    colnames(assigned) <- c("cell", "donor_id", "prob_max")
    if (check_doublet) {
        assigned$prob_doublet <- matrixStats::rowSums2(out$prob_doublet)
        assigned$donor_id[assigned$prob_doublet > (1 - s_threshold)] <- "doublet"
    } else {
        assigned$prob_doublet <- NA
    }
    assigned$n_vars <- n_vars
    assigned$donor_id[n_vars < n_vars_threshold] <- "unassigned"
    assigned$donor_id[assigned$prob_doublet < d_threshold & 
                      rowSums(out$prob) < s_threshold] <- "unassigned"

    out$assigned <- assigned
    out
}


#' Variational inference for donor deconvolution with or without genotypes.
#'
#' @param A A matrix of integers. Number of alteration reads in SNP i cell j
#' @param D A matrix of integers. Number of reads depth in SNP i cell j
#' @param GT A matrix of integers for genotypes. The donor-SNP configuration.
#' @param K An integer. The number of donors to infer if not given GT.
#' @param K_extend A float. The extension ratio of donor number in the first run
#' @param n_init A integer. The number of random initializations for EM
#' algorithm, which can be useful to avoid local optima if not given genotypes.
#' Default: 1 if given GT, 5 if not given GT.
#' @param n_proc An integer. The number of processors to use. 
#' @param ... arguments passed to \code{run_VB}
#' @details Users should typically use \code{\link{donor_id}} rather than this
#' lower-level function.
#'
#' @return a list containing
#' \code{logLik}, the log likelihood.
#' \code{theta}, a vector denoting the binomial parameters for each genotype.
#' \code{prob}, a matrix of posterior probability of cell assignment to donors.
#' The summary may less than 1, as there are some probabilities go to doublets.
#' \code{prob_doublet}, a matrix of posterior probability of cell assignment to
#' each inter-donor doublet.
#' \code{GT}, the input GT or a point estimate of genotype of donors. Note,
#' this may be not very accurate, especially for lowly expressed SNPs.
#' \code{GT_doublet}, the pair-wise doublet genotype based on GT.
#'
#' @import stats
#'
#' @export
#'
#' @examples
#' data(example_donor)
#' res <- donor_id_VB(A_clone, D_clone, GT = tree$Z[1:nrow(A_clone),])
#' head(res$prob)
#'
donor_id_VB <- function(A, D, K=NULL, K_extend=1.5, GT=NULL, GT_prior=NULL, 
                        n_init=NULL, n_proc=4, random_seed=NULL, ...) {
    start_time <- Sys.time()
    if (!is.null(random_seed)) {set.seed(random_seed)}
    
    ## Check input data
    if (is.null(GT) && is.null(K)) {
        stop("GT and K cannot both be NULL.")
    }
    if (nrow(A) != nrow(D) || ncol(A) != ncol(D)) {
        stop("A and D must have the same size.")
    }
    if (!is.null(GT)) {
        if (nrow(A) != nrow(GT)) {
            stop("nrow(A) and nrow(GT) must be the same.")
        }
    }
    
    A[is.na(A)] <- 0
    D[is.na(D)] <- 0
    idx <- which(as.matrix((A > 0) & (A != D)))    
    logLik_coeff <- sum(lchoose(c(D[idx]), c(A[idx])), na.rm = TRUE)
    
    A <- Matrix::Matrix(A, sparse = TRUE)
    D <- Matrix::Matrix(D, sparse = TRUE)
    
    if (is.null(K_extend) || K_extend < 1) { 
        K_run1 <- K
    } else {
        K_run1 <- ceiling(K_extend * K)
    }
    
    ## Multiple initializations
    if (is.null(n_init)) {
        if (is.null(GT)) {n_init <- 4}
        else {n_init <- 2}
    }
    cat(paste("run1:", n_init, "random initializations...\n")) 
        
    if (is.null(n_proc) || n_proc == 1) {
        res_VB_list <- list()
        for (ii in seq_len(n_init)) {
            res_VB_list[[ii]] <- 
            run_VB(A, D, K = K_run1, GT = GT, GT_prior = GT_prior, ...)
        }
    } else{
        library(foreach)
        doMC::registerDoMC(n_proc)
        res_VB_list <- foreach::foreach(i = 1:n_init) %dopar% {
            run_VB(A, D, K = K_run1, GT = GT, GT_prior = GT_prior, ...)
        }
    }
    
    ## Only keep the initialization with highest lower bound
    VB_info <- matrix(0, nrow = n_init, ncol = 2)
    colnames(VB_info) <- c("n_iter", "LBound")
    for (ii in seq_len(n_init)) {
        VB_info[ii, 1] <- res_VB_list[[ii]]$n_iter
        VB_info[ii, 2] <- res_VB_list[[ii]]$LBound
    }
    print(t(VB_info))
    
    res_VB_best <- res_VB_list[[which.max(VB_info[, "LBound"])]]
    
    ## for second run if there are extra components
    if (is.null(GT) && K_run1 > K) {
        sum_cell <- colSums(res_VB_best$prob)
        idx_don <- order(sum_cell, decreasing = TRUE)
        cat("Donor size in run1:\n")
        print(t(sum_cell[idx_don]))
        cat("Now, run2:\n")
        if (sum_cell[idx_don[K]] / sum_cell[idx_don[K + 1]] < 2) {
            message(paste("The difference between K_th and K+1_th",
                          "donor is too small.\n Best to run again with",
                          "more initializations to reach the global optima."))
        }
        GT_idx <- c()
        for (ii in idx_don[1:K]) {
            GT_idx <- c(GT_idx, (ii - 1) * nrow(D) + seq_len(nrow(D)))
        }
        GT_prior <- res_VB_best$GT_prob[GT_idx, ]
        
        res_VB_best <- run_VB(A, D, K = K, GT = GT, GT_prior = GT_prior, ...)
    }
    
    cat(paste("Finished in", Sys.time() - start_time, "sec.\n"))
    res_VB_best
}

#' Variational inference with a single run
#'
#' @param A A matrix of integers. Number of alteration reads in SNP i cell j
#' @param D A matrix of integers. Number of reads depth in SNP i cell j
#' @param K An integer. The number of donors to infer if not given GT.
#' @param GT A matrix of integers for genotypes. The donor-SNP configuration.
#' @param GT_prior A Matrix of genotype prior probability.
#' @param check_doublet logical(1), if TRUE, check doublet, otherwise ignore.
#' @param min_iter A integer. The minimum number of iterations in EM algorithm.
#' @param max_iter A integer. The maximum number of iterations in EM algorithm.
#' The real iteration may finish earlier.
#' @param epsilon_conv A float. The threshold of lower bound increase for
#' detecting convergence.
#' @param verbose logical(1), If TRUE, output verbose information when running.
#'
#' @details Users should typically use \code{\link{donor_id}} rather than this
#' lower-level function.
#'
#' @return a list containing
#' \code{logLik}, the log likelihood.
#' \code{theta}, a vector denoting the binomial parameters for each genotype.
#' \code{prob}, a matrix of posterior probability of cell assignment to donors.
#' The summary may less than 1, as there are some probabilities go to doublets.
#' \code{prob_doublet}, a matrix of posterior probability of cell assignment to
#' each inter-donor doublet.
#' \code{GT}, the input GT or a point estimate of genotype of donors. Note,
#' this may be not very accurate, especially for lowly expressed SNPs.
#' \code{GT_doublet}, the pair-wise doublet genotype based on GT.
run_VB <- function(A, D, K=NULL, GT=NULL, GT_prior=NULL, 
                   theta_prior=NULL, learn_theta=TRUE, 
                   check_doublet=TRUE, doublet_prior=NULL, 
                   check_doublet_iterative=FALSE,
                   binary_GT=FALSE, min_iter=20, max_iter=200, 
                   epsilon_conv=1e-2, verbose=FALSE) {
    ## preprocessing
    N <- nrow(D)    # number of SNPs 
    M <- ncol(D)    # number of cells
    
    B <- D - A
    D_idx <- which(as.matrix(D) != 0) ## index of non-zero elements in D
    A_vec <- as.matrix(A)[D_idx]      ## non-zero element as a vector
    #B_vec <- as.matrix(B)[D_idx]
    D_vec <- as.matrix(D)[D_idx]
    W_vec <- lchoose(D_vec, A_vec)

    ## initializate theta
    gt_singlet <- c(0, 1, 2)
    gt_doublet <- c(0.5, 1.5)
    n_gt <- length(gt_singlet)
    if (is.null(theta_prior)) {        
        theta_prior <- matrix(c(0.3, 3, 29.7, 29.7,  3, 0.3), nrow = 3)
        row.names(theta_prior) <- paste0("GT=", c("0", "1", "2"))
        colnames(theta_prior) <- c("beta_shape1", "beta_shape2")
    }
    theta_shapes <- theta_prior
        
    ## initialize GT
    if (is.null(GT)) {
        update_GT <- TRUE
        if (is.null(GT_prior)) {
            GT_prior <- matrix(1 / length(gt_singlet), nrow = N * K, 
                               ncol = length(gt_singlet))
            GT_prob <- matrix(0, nrow = N * K, ncol = length(gt_singlet))
            for (ii in seq_len(N * K)) {
                GT_prob[ii, ] <- t(rmultinom(1, size = 1, GT_prior[ii, ]))
            }
        } else{
            GT_prob <- GT_prior
            GT_prior[GT_prior > 0.999999] <- 0.999999
            GT_prior[GT_prior < 10^-8] <- 10^-8
            GT_prior <- GT_prior / rowSums(GT_prior)
        }
    } else {
        K <- ncol(GT)   ## number of singlet donors
        update_GT <- FALSE
        GT_prob <- GT_to_prob(GT, gt_singlet)
    }
    
    ## setting Psi, the donor prevalence
    K2 <- K + (K - 1) * K / 2 # singlet and doublet donors
    if (is.null(doublet_prior) || doublet_prior == "uniform") { 
        doublet_prior <- (K2 - K) / K2
    } else if (!is.na(as.numeric(doublet_prior))) {
        doublet_prior <- as.numeric(doublet_prior)
        if (doublet_prior > 1 || doublet_prior < 0) {
            warning("doublet_prior > 1 or <0!\n")
            doublet_prior <- (K2 - K) / K2
        }
    } else {#including auto
        doublet_prior <- ncol(D) / 100000
    }
    Psi <- c(rep((1 - doublet_prior) / K, K),
             rep(doublet_prior / (K2 - K), (K2 - K)))
    
    ## VB iterations
    LB <- rep(0, max_iter)
    logLik <- logLik_new <- 0
    for (it in seq_len(max_iter)) {
        ## update theta
        if (learn_theta && it > max(min_iter - 5, min_iter * 2 / 3) ) {
            theta_shapes <- theta_prior
            for (ig in seq_len(ncol(GT_prob))) {
                GT_prob_ig <- matrix(GT_prob[, ig], nrow = N)
                theta_shapes[ig, 1] <- theta_prior[ig, 1] + sum(S1_gt * GT_prob_ig)
                theta_shapes[ig, 2] <- theta_prior[ig, 2] + sum(S2_gt * GT_prob_ig)
            }
        }
        
        ## update donor ID
        if (check_doublet  && check_doublet_iterative && 
            it > max(min_iter - 5, min_iter * 2 / 3)) {
            GT_both <- get_doublet_GT(GT_prob, K)
            theta_both <- get_doublet_theta(theta_shapes)
            ID_prob_res <- get_ID_prob(A, D, GT_both, theta_both, Psi) 
        } else{
            ID_prob_res <- get_ID_prob(A, D, GT_prob, theta_shapes, Psi) 
        }        
        ID_prob <- ID_prob_res$ID_prob
        logLik_new <- ID_prob_res$logLik
        
        S1_gt <- as.matrix(A %*% ID_prob[, seq_len(K)])
        SS_gt <- as.matrix(D %*% ID_prob[, seq_len(K)])
        S2_gt <- SS_gt - S1_gt
        
        
        logLik_GT <- matrix(0, nrow = length(SS_gt), ncol = n_gt)
        for (ig in seq_len(ncol(logLik_GT))) {
            logLik_GT[, ig] <- (S1_gt * digamma(theta_shapes[ig, 1]) + 
                                S2_gt * digamma(theta_shapes[ig, 2]) - 
                                SS_gt * digamma(sum(theta_shapes[ig, ])))
        }
        
        ## update GT
        if (update_GT) {
            log_GT_post <- logLik_GT + log(GT_prior)
            log_GT_post <- log_GT_post - matrixStats::rowMaxs(log_GT_post)
            GT_prob <- exp(log_GT_post) / rowSums(exp(log_GT_post))
            if (binary_GT) {
                for (ik in seq_len(nrow(logLik_GT))) {
                    idx_max <- which.max(logLik_GT[ik, ])
                    GT_prob[ik, ] <- 0
                    GT_prob[ik, idx_max] <- 1            
                }
            }
        }
                
        # Check convergence
        LB_p <- sum(logLik_GT * GT_prob) + sum(W_vec)
        LB_p_ID <- sum(t(ID_prob) * log(Psi[1:K] / sum(Psi[1:K])))
        LB_q_ID <- sum(ID_prob[, 1:K] * log(ID_prob[, 1:K]), na.rm = TRUE)
        if (update_GT) {
            LB_p_GT <- sum(GT_prob * log(GT_prior))
            LB_q_GT <- sum(GT_prob * log(GT_prob), na.rm = TRUE)
        } else {
            LB_p_GT <- LB_q_GT <- 0
        } 
        if (learn_theta) {
            LB_p_theta <- nega_beta_entropy(theta_shapes, theta_prior)
            LB_q_theta <- nega_beta_entropy(theta_shapes)
        } else{
            LB_p_theta <- LB_q_theta <- 0
        }
        
        # print(c(LB_p_ID, LB_p_GT, LB_p_theta, LB_p,
        #         LB_q_ID, LB_q_GT, LB_q_theta))
        
        LB[it] <- (LB_p_ID + LB_p_GT + LB_p_theta + LB_p -
                   LB_q_ID - LB_q_GT - LB_q_theta)  
        
        if (verbose) { cat("It: ", it, " LB: ", LB[it], 
                           " LB_diff: ", LB[it] - LB[it - 1], "\n")} 
        
        if (it > min_iter) {
            if (is.na(LB[it]) || (LB[it] == -Inf)) { break }
            if (LB[it] < LB[it - 1]) { message("Lower bound decreases!\n")}
            if (it == max_iter) {warning("VB did not converge!\n")}
            if (LB[it] - LB[it - 1] < epsilon_conv) { break }
        }
        
        # print(paste(it, logLik_new + sum(W_vec), LB_p, sum(logLik_ID) + sum(W_vec) ))
        # if (it > min_iter) {
        #     if (abs(logLik_new - logLik) < epsilon_conv) { break }
        # }
        logLik <- logLik_new
    }
       
    ## post doublet check
    if (check_doublet && (!check_doublet_iterative)) {
        GT_both <- get_doublet_GT(GT_prob, K)
        theta_both <- get_doublet_theta(theta_shapes)
        
        ID_prob_res <- ID_prob_res <- get_ID_prob(A, D, GT_both, theta_both, Psi)        
        ID_prob <- ID_prob_res$ID_prob
        logLik <- ID_prob_res$logLik
            
        ## update GT
        if (update_GT) {
            S1_gt <- as.matrix(A %*% ID_prob[, seq_len(K)])
            SS_gt <- as.matrix(D %*% ID_prob[, seq_len(K)])
            S2_gt <- SS_gt - S1_gt
            logLik_GT <- matrix(0, nrow = length(SS_gt), ncol = n_gt)
            for (ig in seq_len(ncol(logLik_GT))) {
                logLik_GT[, ig] <- (S1_gt * digamma(theta_shapes[ig, 1]) + 
                                    S2_gt * digamma(theta_shapes[ig, 2]) - 
                                    SS_gt * digamma(sum(theta_shapes[ig, ])))
            }
            
            log_GT_post <- logLik_GT + log(GT_prior)
            log_GT_post <- log_GT_post - matrixStats::rowMaxs(log_GT_post)
            GT_prob <- exp(log_GT_post) / rowSums(exp(log_GT_post))
            if (binary_GT) {
                for (ik in seq_len(nrow(logLik_GT))) {
                    idx_max <- which.max(logLik_GT[ik, ])
                    GT_prob[ik, ] <- 0
                    GT_prob[ik, idx_max] <- 1            
                }
            }
        }
    }
        
    ## Print log info
    if (verbose && check_doublet) {
        cat(sprintf("Total iterations for doublet: %d; LBound: %.2f\n", 
                    it, logLik))
    } else if (verbose) {
        cat(sprintf("Total iterations: %d; LBound: %.2f\n", 
                    it, logLik))
    }
    
    ## Return values
    donor_names <- paste0("donor", seq_len(K))
    if (check_doublet) {
        combn_idx <- utils::combn(K, 2)
        donor_names <- c(donor_names, paste0(donor_names[combn_idx[1,]], ",",  
                                             donor_names[combn_idx[2,]]))
    }
    row.names(ID_prob) <- colnames(D)
    colnames(ID_prob) <- donor_names
    prob_singlet <- ID_prob[, 1:K, drop = FALSE]
    prob_doublet <- NULL
    if (check_doublet) {
        prob_doublet <- ID_prob[, (K + 1):K2, drop = FALSE]
    }
    
    # if (is.null(colnames(GT))) { 
    #     colnames(GT) <- paste0("donor", seq_len(ncol(GT)))
    # }
    
    return_list <- list("LBound" = LB[it], "LBound_all" = LB[1:it], 
                        "n_iter" = it, "theta" = theta_shapes, 
                        "Psi" = Psi, "GT_prob" = GT_prob, 
                        "prob" = prob_singlet,
                        "prob_doublet" = prob_doublet)
    return_list
}

# Negative entropy value for beta distribution
nega_beta_entropy <- function(theta_shapes, theta_prior=NULL) {
    if (is.null(theta_prior)) {theta_prior <- theta_shapes}
    out_val <- 0
    for (ii in seq_len(nrow(theta_shapes))) {
        out_val <- (out_val - lbeta(theta_prior[ii, 1], theta_prior[ii, 2]) +
                    (theta_prior[ii, 1] - 1) * digamma(theta_shapes[ii, 1]) +
                    (theta_prior[ii, 2] - 1) * digamma(theta_shapes[ii, 2]) -
                    (sum(theta_prior[ii, ]) - 2) * digamma(sum(theta_shapes[ii, ])))
    }
    out_val
}

# Internal function to update cell assignement probability
#' @return A list containing \code{logLik} and \code{ID_prob}
get_ID_prob <- function(A, D, GT_prob, theta_shapes, Psi) {    
    M <- ncol(A)
    N <- nrow(A)
    K <- nrow(GT_prob) / N
    logLik_ID <- matrix(0, nrow = M, ncol = K)
    for (ig in seq_len(ncol(GT_prob))) {
        S1 <- Matrix::t(A) %*% matrix(GT_prob[, ig], nrow = N)
        SS <- Matrix::t(D) %*% matrix(GT_prob[, ig], nrow = N)
        S2 <- SS - S1
        logLik_ID <- logLik_ID + as.matrix(S1 * digamma(theta_shapes[ig, 1]) + 
                                           S2 * digamma(theta_shapes[ig, 2]) - 
                                           SS * digamma(sum(theta_shapes[ig, ])))
    }    
    logLik_ID <- t(t(logLik_ID) + log(Psi[1:K]/sum(Psi[1:K])))
    logLik_ID_amplify <- logLik_ID - matrixStats::rowMaxs(logLik_ID)
    ID_prob <- exp(logLik_ID_amplify) / rowSums(exp(logLik_ID_amplify))
    
    logLik_vec <- rep(NA, nrow(logLik_ID))
    for (i in seq_len(nrow(logLik_ID))) {
        logLik_vec[i] <- matrixStats::logSumExp(logLik_ID[i,], na.rm = TRUE)
    }
    logLik_val <- sum(logLik_vec, na.rm = TRUE)
        
    list("logLik" = logLik_val, "ID_prob" = ID_prob)
}

#' Generate theta parameters for doublet genotype
#' @param theta_shapes A 3-by-2 matrix of beta paramters for genotype 0, 1, 2
#' @return a 5-by-2 matrix of beta paramters for genotype 0, 1, 2, 0.5, 1.5
get_doublet_theta <- function(theta_shapes) {
    theta_shapes2 <- matrix(0, nrow = 2, ncol = 2)
    row.names(theta_shapes2) <- paste0("GT=", c("0_1", "1_2"))
    
    for (ii in seq_len(2)) {
        theta_input <- theta_shapes[ii:(ii + 1), ]
        
        theta_mean <- mean(theta_input[1:2, 1] / rowSums(theta_input[1:2,]))
        shape_sum <- sqrt(sum(theta_input[1, ]) * sum(theta_input[2, ]))
        theta_shapes2[ii, 1] <- theta_mean * shape_sum
        theta_shapes2[ii, 2] <- (1 - theta_mean) * shape_sum
    }
    rbind(theta_shapes, theta_shapes2)
}

#' Generate genotype probability for doublets
#' @param GT_prob A matrix of genotype for singlets
#' @param K An integer for number of donors
#' @return \code{GT_both}, a matrix of genotype probability for both singlet
#' and doublet donors
get_doublet_GT <- function(GT_prob, K) {
    N <- nrow(GT_prob) / K
    cb_idx <- utils::combn(K, 2) ## column wise
    
    GT_prob2 <- matrix(0, nrow = N * ncol(cb_idx), 5)
    for (ik in seq_len(ncol(cb_idx))) {
        idx1 = seq_len(N) + (cb_idx[1, ik] - 1) * N
        idx2 = seq_len(N) + (cb_idx[2, ik] - 1) * N
        idx3 = seq_len(N) + (ik - 1) * N
        
        GT_prob2[idx3, 1] <- (GT_prob[idx1, 1] * GT_prob[idx2, 1])
        GT_prob2[idx3, 2] <- (GT_prob[idx1, 2] * GT_prob[idx2, 2] +
                              GT_prob[idx1, 1] * GT_prob[idx2, 3] +
                              GT_prob[idx1, 3] * GT_prob[idx2, 1])
        GT_prob2[idx3, 3] <- (GT_prob[idx1, 3] * GT_prob[idx2, 3])
        GT_prob2[idx3, 4] <- (GT_prob[idx1, 1] * GT_prob[idx2, 2] +
                              GT_prob[idx1, 2] * GT_prob[idx2, 1])
        GT_prob2[idx3, 5] <- (GT_prob[idx1, 2] * GT_prob[idx2, 3] +
                              GT_prob[idx1, 3] * GT_prob[idx2, 2])
    }
    GT_prob2 <- GT_prob2 / rowSums(GT_prob2)
    
    GT_zero <- matrix(0, nrow = nrow(GT_prob), 
                      ncol = (ncol(GT_prob2) - ncol(GT_prob)))
    GT_both <- rbind(cbind(GT_prob, GT_zero), GT_prob2)
    GT_both
}

# Convert genotype matrix to genotype probability matrix
#' @param GT A matrix of genotype
#' @param gt_singlet A list of singlet genotyoe
GT_to_prob <- function(GT, gt_singlet=c(0, 1, 2)) {
  GT_prob <- matrix(0, nrow = length(GT), ncol = length(gt_singlet))
  colnames(GT_prob) <- paste0("GT=", gt_singlet)
  for (ig in seq_len(length(gt_singlet))) {
    GT_prob[which(GT == gt_singlet[ig]), ig] <- 1
  }
  
  GT_prob
}
