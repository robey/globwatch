events = require 'events'
fs = require 'fs'
path = require 'path'
Q = require 'q'
util = require 'util'

makePromise = require("./make_promise").makePromise


class FileWatcher
  constructor: (options_in={}) ->
    options =
      period: 250
      persistent: true
    for k, v of options_in then options[k] = v
    # frequency of stat() checking, in milliseconds
    @period = options.period
    # should our timer keep the process alive?
    @persistent = options.persistent
    # timer that periodically checks for file changes
    @timer = null
    # filename -> Watch
    @watches = {}
    # chain of running checks
    @ongoing = null

  close: ->
    @watches = {}
    if @timer?
      clearInterval(@timer)
      @timer = null

  watch: (filename) ->
    filename = path.resolve(filename)
    watch = @watches[filename]
    if not watch?
      watch = @watches[filename] = new Watch(filename)
    if not @timer?
      @timer = setInterval((=> @check()), @period)
      if not @persistent then @timer.unref()
    watch

  unwatch: (filename) ->
    filename = path.resolve(filename)
    watch = @watches[filename]
    if watch? then delete @watches[filename]    

  watchFor: (filename) ->
    @watches[path.resolve(filename)]

  # runs a scan of all outstanding watches.
  # if a scan is currently running, the new scan is queued up behind it.
  # returns a promise that will be fulfilled when this new scan is finished.
  check: ->
    run = =>
      completion = Q.all(for filename, watch of @watches then watch.check())
      @ongoing = completion.then =>
        @ongoing = null
    if @ongoing?
      @ongoing = @ongoing.then(run)
    else
      run()


class Watch extends events.EventEmitter
  constructor: (@filename) ->
    @stat = null
    @callbacks = []
    @stat = fs.statSync @filename

  check: ->
    makePromise(fs.stat)(@filename)
    .fail (error) ->
      null
    .then (stat) =>
      if @stat? and stat? and (@stat.mtime.getTime() != stat.mtime.getTime() or @stat.size != stat.size)
        @emit 'changed', stat
      @stat = stat


exports.FileWatcher = FileWatcher
