Q = require 'q'

exports.makePromise = (f) ->
  (x...) ->
    deferred = Q.defer()
    f(x..., deferred.makeNodeResolver())
    deferred.promise
