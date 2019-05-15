
stmv__mba = function( p=NULL, dat=NULL, pa=NULL, lambda=NULL, variablelist=FALSE, ...  ) {
  #\\ this is the core engine of stmv .. localised space (no-time) modelling interpolation
  # \ as a 2D gaussian process (basically, simple krigimg or TPS -- time is treated as being independent)
  #\\ note: time is not being modelled and treated independently
  #\\      .. you had better have enough data in each time slice ..  essentially this is cubic b-splines interpolation

  library(MBA)

  if (variablelist)  return( c() )

  sdTotal = sd(dat[,p$variable$Y], na.rm=T)

  x_r = range(dat[,p$variables$LOCS[1]])
  x_c = range(dat[,p$variables$LOCS[2]])

  nr = round( diff(x_r)/p$pres ) + 1
  nc = round( diff(x_c)/p$pres ) + 1

  # final output grid
  x_locs = expand.grid(
    seq( x_r[1], x_r[2], length.out=nr ),
    seq( x_c[1], x_c[2], length.out=nc )
  )
  attr( x_locs , "out.attrs") = NULL
  names( x_locs ) = p$variables$LOCS

  dat$mean = NA
  pa$mean = NA
  pa$sd = sdTotal  # this is ignored with fft

  origin=c(x_r[1], x_c[1])
  res=c(p$pres, p$pres)

  zz = matrix(1:(nr*nc), nrow = nr, ncol = nc)

  for ( ti in 1:p$nt ) {

    if ( exists("TIME", p$variables) ) {
      xi   = which( dat[ , p$variables$TIME] == p$prediction.ts[ti] )
      pa_i = which( pa[, p$variables$TIME] == p$prediction.ts[ti] )
      if (length(xi) < 5 ) {
        # print( ti)
        next()
      }
    } else {
      xi   = 1:nrow(dat) # all data as p$nt==1
      pa_i = 1:nrow(pa)
    }

    # u = as.image(
    #   dat[xi, p$variables$Y],
    #   ind=as.matrix(array_map( "xy->2", coords=dat[xi,p$variables$LOCS], origin=origin, res=res )),
    #   na.rm=TRUE,
    #   nx=nr,
    #   ny=nc
    # )

    Z = mba.surf(dat[xi, c(p$variables$LOCS, p$variables$Y)], no.X=nr, no.Y=nc, extend=TRUE)$z

    # bounds check: make sure predictions exist
    Z_i = array_map( "xy->2", coords=pa[pa_i,p$variables$LOCS], origin=origin, res=res )
    Z_i_test = which( Z_i[,1]<1 | Z_i[,2]<1  | Z_i[,1] > nr | Z_i[,2] > nc )

    if (length(Z_i_test) > 0) {
      keep = zz[ Z_i[-Z_i_test,] ]
      pa$mean[pa_i[keep]] = Z[keep]
      keep = NULL
    } else {
      pa$mean[pa_i] = Z[Z_i]
    }

    # pa$sd[pa_i] = NA  ## fix as NA
    Z = Z_i = Z_i_test = NULL

  }

  # plot(pred ~ z , dat)
  # lattice::levelplot( mean ~ plon + plat, data=pa, col.regions=heat.colors(100), scale=list(draw=FALSE) , aspect="iso" )
  ss = lm( dat$mean ~ dat[,p$variables$Y], na.action=na.omit)
  if ( "try-error" %in% class( ss ) ) return( NULL )
  rsquared = summary(ss)$r.squared
  if (rsquared < p$stmv_rsquared_threshold ) return(NULL)

  stmv_stats = list( sdTotal=sdTotal, rsquared=rsquared, ndata=nrow(dat) ) # must be same order as p$statsvars
  return( list( predictions=pa, stmv_stats=stmv_stats ) )
}