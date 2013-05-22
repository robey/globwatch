child_process = require 'child_process'
Q = require 'q'
shell = require 'shelljs'

# run a test as a future, and call mocha's 'done' method at the end of the chain.
exports.futureTest = (f) ->
  (done) ->
    f().then((-> done()), ((error) -> done(error))).done()

exports.withTempFolder = (f) ->
  (x...) ->
    uniq = "/tmp/xtestx#{Date.now()}"
    shell.mkdir "-p", uniq
    # save old cwd, to restore afterwards, and cd into the temp folder.
    old_dir = process.cwd()
    process.chdir uniq
    # sometimes (especially on macs), the real folder name will be different.
    realname = process.cwd()
    f(realname, x...).fin ->
      process.chdir old_dir
      shell.rm "-r", uniq

# run a command & wait for it to end.
exports.execFuture = (command, options={}) ->
  deferred = Q.defer()
  p = child_process.exec command, options, (error, stdout, stderr) ->
    if error?
      deferred.reject(error)
    else
      deferred.resolve(process: p, stdout: stdout, stderr: stderr)
  deferred.promise
