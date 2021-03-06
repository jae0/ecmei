
stmv__twostep = function( p, dat, pa, nu=NULL, phi=NULL, varObs=varObs, varSpatial=varSpatial, ... ) {

  #\\ twostep modelling time first as a simple ts and then spatial or spatio-temporal interpolation
  #\\ nu is the bessel smooth param

  # step 1 -- timeseries modelling
  # use all available data in 'dat' to get a time trend .. and assume it applies to the prediction area of interest 'pa'
     # some methods require a uniform (temporal with associated covariates) prediction grid based upon all dat locations

  if (0) {
    varObs = S[Si, i_sdObs]^2
    varSpatial = S[Si, i_sdSpatial]^2
    sloc = Sloc[Si,]
    eps = 1e-9
  }

  vnt = c( p$stmv_variables$LOCS, p$stmv_variables$Y)
  pa = data.table(pa)

  px = dat # only the static parts .. time has to be a uniform grid so reconstruct below

  ids = array_map( "xy->1", px[, c("plon", "plat")], gridparams=p$gridparams ) # 100X faster than paste / merge
  todrop = which(duplicated( ids) )
  if (length(todrop>0)) px = px[-todrop,]
  ids = todrop=NULL

  # static vars .. don't need to look up
  tokeep = c(p$stmv_variables$LOCS )
  if (exists("weights", dat) ) tokeep = c(tokeep, "weights")
  if (p$nloccov > 0) {
    for (ci in 1:p$nloccov) {
      vn = p$stmv_variables$local_cov[ci]
      pu = stmv_attach( p$storage_backend, p$ptr$Pcov[[vn]] )
      nts = ncol(pu)
      if ( nts==1 ) tokeep = c(tokeep, vn )
    }
  }
  px = px[ , ..tokeep ]
  px_n = nrow(px)
  nts = vn = NULL

  # add temporal grid
  if ( exists("TIME", p$stmv_variables) ) {
    px = cbind( px[ rep.int(1:px_n, p$nt), ],
                    rep.int(p$prediction_ts, rep(px_n, p$nt )) )
    names(px)[ ncol(px) ] = p$stmv_variables$TIME
    px = cbind( px, stmv_timecovars ( vars=p$stmv_variables$local_all, ti=px[[ p$stmv_variables$TIME ]]  ) )
  }

  if (p$nloccov > 0) {
    # add time-varying covars .. not necessary except when covars are modelled locally
    for (ci in 1:p$nloccov) {
      vn = p$stmv_variables$local_cov[ci]
      pu = stmv_attach( p$storage_backend, p$ptr$Pcov[[vn]] )
      nts = ncol(pu)
      if ( nts== 1) {
        # static vars are retained in the previous step
      } else if ( nts == p$ny )  {
        px$iy = px$yr - p$yrs[1] + 1 #yr index
        px[,vn] = pu[ cbind(px$i, px$iy) ]
       } else if ( nts == p$nt) {
        px$it = p$nw*(px$tiyr - p$yrs[1] - p$tres/2) + 1 #ts index
        px[,vn] = pu[ cbind(px$i, px$it) ]
      }
    } # end for loop
    nts = vn = NULL
  } # end if
  rownames(px) = NULL


  # print( "starting gam-timeseries mod/pred")
  ts_preds = NULL

  p$stmv_local_modelformula = p$stmv_local_modelformula_time

  if (p$stmv_twostep_time == "inla" ) ts_preds = stmv__inla_ts( p, dat, px )  #TODO
  if (p$stmv_twostep_time == "inla_ar1" ) ts_preds = stmv__inla_ar1( p, dat, px ) #TODO
  if (p$stmv_twostep_time == "glm" ) ts_preds = stmv__glm( p, dat, px )
  if (p$stmv_twostep_time == "gam" ) ts_preds = stmv__gam( p, dat, px )
  if (p$stmv_twostep_time == "bayesx" ) ts_preds = stmv__bayesx( p, dat, px )

  if (is.null( ts_preds)) return(NULL)

#  if (ss$r.sq < p$stmv_rsquared_threshold ) return(NULL)  # smooth/flat surfaces are ok ..
  # temporal r-squared test
  if (exists("stmv_rsquared_threshold", p)) {
    if ( exists("stmv_stats", ts_preds)) {
      if ( exists("rsquared", ts_preds$stmv_stats) ) {
        # ts_preds_rsquared = ts_preds$stmv_stats$rsquared  # store for now until return call
        if (!is.finite(ts_preds$stmv_stats$rsquared) ) return(NULL)
        if (ts_preds$stmv_stats$rsquared < p$stmv_rsquared_threshold ) return(NULL)
      }
    }
  }

  # range checks
  rY = range( dat[[ p$stmv_variables$Y ]], na.rm=TRUE)
  toosmall = which( ts_preds$predictions$mean < rY[1] )
  toolarge = which( ts_preds$predictions$mean > rY[2] )
  if (length(toosmall) > 0) ts_preds$predictions$mean[toosmall] =  rY[1]
  if (length(toolarge) > 0) ts_preds$predictions$mean[toolarge] =  rY[2]

  pxts = ts_preds$predictions
  rownames(pxts) = NULL
  ts_preds = NULL

  names(pxts)[which(names(pxts)=="mean")] = p$stmv_variables$Y
  names(pxts)[which(names(pxts)=="sd")] = paste(p$stmv_variables$Y, "sd", sep=".")

  if(0){
      # debugging plots
      for (ti in 1:p$nt){
        xi = which( pxts[ , p$stmv_variables$TIME ] == p$prediction_ts[ti] )
        mbas = MBA::mba.surf( pxts[xi, ..vnt ], 300, 300, extend=TRUE)$xyz.est
        image(mbas)
      }
  }


  # step 2 :: spatial modelling .. essentially a time-space separable solution

  if (!exists( "stmv_twostep_space", p)) p$stmv_twostep_space="krige" # default

  out = NULL
  if ( p$stmv_twostep_space == "krige" ) {
    out = stmv__krige( p, dat=pxts, pa=pa, nu=nu, phi=phi, varObs=varObs, varSpatial=varSpatial )
  }

  if ( p$stmv_twostep_space == "gstat" ) {
    out = stmv__gstat( p, dat=pxts, pa=pa, nu=nu, phi=phi, varObs=varObs, varSpatial=varSpatial )
  }

  if ( p$stmv_twostep_space == "inla_spde" ) {
    out = stmv__inla_space_spde( p, dat=pxts, pa=pa, nu=nu, phi=phi, varObs=varObs, varSpatial=varSpatial ) #TODO
  }

  if ( p$stmv_twostep_space == "inla_car" ) {
    out = stmv__inla_space_car( p, dat=pxts, pa=pa, nu=nu, phi=phi, varObs=varObs, varSpatial=varSpatial ) #TODO
  }

  if (p$stmv_twostep_space %in% c("tps") ) {
    out = stmv__tps( p, dat=pxts, pa=pa, lambda=varObs/varSpatial, nu=nu, phi=phi, varObs=varObs, varSpatial=varSpatial   )
  }

  if (p$stmv_twostep_space %in% c("fft") ) {
    out = stmv__fft( p=p, dat=pxts, pa=pa, nu=nu, phi=phi, varObs=varObs, varSpatial=varSpatial )
  }

  if (p$stmv_twostep_space %in% c("gam") ) {
    p$stmv_local_modelformula = p$stmv_local_modelformula_space
    out = stmv__gam( p, dat=pxts, pa=pa, nu=nu, phi=phi, varObs=varObs, varSpatial=varSpatial   )
  }

  if (p$stmv_twostep_space %in% c("glm") ) {
    p$stmv_local_modelformula = p$stmv_local_modelformula_space
    out = stmv__glm( p, dat=pxts, pa=pa, nu=nu, phi=phi, varObs=varObs, varSpatial=varSpatial   )
  }

  if (p$stmv_twostep_space %in% c("bayesx") ) {
    p$stmv_local_modelformula = p$stmv_local_modelformula_space
    out = stmv__bayesx( p, dat=pxts, pa=pa, nu=nu, phi=phi, varObs=varObs, varSpatial=varSpatial  )
  }

  # TODO
  # evaluate goodness of fit of data (nonboosted):
  #  out$stmv_stats$rsquared =

  return( out )

  if (0) {
    lattice::levelplot( mean ~ plon + plat, data=out$predictions[out$predictions[,p$stmv_variables$TIME]==2012.05,], col.regions=heat.colors(100), scale=list(draw=FALSE) , aspect="iso" )
    lattice::levelplot( mean ~ plon + plat, data=out$predictions, col.regions=heat.colors(100), scale=list(draw=FALSE) , aspect="iso" )
    for( i in sort(unique(out$predictions[,p$stmv_variables$TIME])))  print(lattice::levelplot( mean ~ plon + plat, data=out$predictions[out$predictions[,p$stmv_variables$TIME]==i,], col.regions=heat.colors(100), scale=list(draw=FALSE) , aspect="iso" ) )
  }


}
