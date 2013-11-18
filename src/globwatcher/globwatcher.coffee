events = require 'events'
fs = require 'fs'
glob = require 'glob'
minimatch = require 'minimatch'
path = require 'path'
Q = require 'q'
util = require 'util'

makePromise = require("./make_promise").makePromise
FileWatcher = require("./filewatcher").FileWatcher

# FIXME this should probably be in a minimatch wrapper class
folderMatchesMinimatchPrefix = (folderSegments, minimatchSet) ->
  for segment, i in folderSegments
    if i >= minimatchSet.length then return false
    miniSegment = minimatchSet[i]
    if miniSegment == minimatch.GLOBSTAR then return true
    if typeof miniSegment == "string"
      if miniSegment != segment then return false
    else
      if not miniSegment.test(segment) then return false
  true

exports.folderMatchesMinimatchPrefix = folderMatchesMinimatchPrefix


# map (absolute) folder names, which are being folder-level watched, to a
# set of (absolute) filenames in that folder that are being file-level
# watched.
class WatchMap
  constructor: (@map = {}) ->
    # @map: folderName -> (filename -> true)

  clear: ->
    @map = {}

  watchFolder: (folderName) ->
    @map[folderName] or= {}

  unwatchFolder: (folderName) ->
    delete @map[folderName]

  watchFile: (filename, parent) ->
    (@map[parent] or= {})[filename] = true

  unwatchFile: (filename, parent) ->
    delete @map[parent][filename]

  getFolders: -> Object.keys(@map)

  getFilenames: (folderName) -> Object.keys(@map[folderName] or {})

  getAllFilenames: ->
    rv = []
    for folder in @getFolders()
      rv = rv.concat(@getFilenames(folder))
    rv

  getNestedFolders: (folderName) ->
    f for f in @getFolders() when f[...(folderName.length)] == folderName

  watchingFolder: (folderName) -> @map[folderName]?

  watchingFile: (filename, parent) ->
    if not parent? then parent = path.dirname(filename)
    @map[parent]?[filename]?

  toDebug: ->
    out = []
    for folder in Object.keys(@map).sort()
      out.push folder
      for filename in Object.keys(@map[folder]).sort() then out.push "  `- #{filename}"
    out.join("\n") + "\n"


exports.globwatcher = (pattern, options) ->
  new GlobWatcher(pattern, options)

class GlobWatcher extends events.EventEmitter
  constructor: (patterns, options={}) ->
    @closed = false
    @cwd = options.cwd or process.cwd()
    @debounceInterval = options.debounceInterval or 10
    @interval = options.interval or 250
    @debug = options.debug or (->)
    @persistent = options.persistent or false
    @watchMap = new WatchMap
    @fileWatcher = new FileWatcher(options)
    # map of (absolute) folderName -> FSWatcher
    @watchers = {}
    # (ordered) list of glob patterns to watch
    @patterns = []
    # minimatch sets for our patterns
    @minimatchSets = []
    # set of folder watch events to check on after the debounce interval
    @checkQueue = {}
    if typeof patterns == "string" then patterns = [ patterns ]
    @originalPatterns = patterns
    if options.snapshot then @restoreFrom(options.snapshot, patterns) else @add(patterns...)

  add: (patterns...) ->
    @debug "add: #{util.inspect(patterns)}"
    @originalPatterns = @originalPatterns.concat(patterns)
    @addPatterns(patterns)
    @ready = Q.all(
      for p in @patterns
        makePromise(glob)(p, nonegate: true).then (files) =>
          for filename in files then @addWatch(filename)
    ).then =>
      @stopWatches()
      @startWatches()
      # give a little delay to wait for things to calm down
      Q.delay(@debounceInterval)
    .then =>
      @debug "add complete: #{util.inspect(patterns)}"
      @

  close: ->
    @debug "close"
    @stopWatches()
    @watchMap.clear()
    @fileWatcher.close()
    @closed = true

  # scan every covered folder again to see if there were any changes.
  check: ->
    @debug "-> check"
    folders = (Object.keys(@watchers).map (folderName) => @folderChanged(folderName))
    Q.all([ @fileWatcher.check() ].concat(folders)).then =>
      @debug "<- check"

  # what files exist *right now* that match the watches?
  currentSet: -> @watchMap.getAllFilenames()

  # filename -> { mtime size }
  snapshot: ->
    state = {}
    for filename in @watchMap.getAllFilenames()
      w = @fileWatcher.watchFor(filename)
      if w? then state[filename] = { mtime: w.mtime, size: w.size }
    state


  # ----- internals:

  # restore from a { filename -> { mtime size } } snapshot
  restoreFrom: (state, patterns) ->
    @addPatterns(patterns)
    for filename in Object.keys(state)
      folderName = path.dirname(filename)
      if folderName != "/" then folderName += "/"
      @watchMap.watchFile(filename, folderName)
    # now, start watches
    for folderName in @watchMap.getFolders()
      @watchFolder folderName
    for filename in Object.keys(state)
      @watchFile filename, state[filename].mtime, state[filename].size
    # give a little delay to wait for things to calm down
    @ready = Q.delay(@debounceInterval).then =>
      @debug "restore complete: #{util.inspect(patterns)}"
      @check()
    .then =>
      @

  addPatterns: (patterns) ->
    for p in patterns
      p = @absolutePath(p)
      if @patterns.indexOf(p) < 0 then @patterns.push(p)
    @minimatchSets = []
    for p in @patterns
      @minimatchSets = @minimatchSets.concat(new minimatch.Minimatch(p, nonegate: true).set)
    for set in @minimatchSets then @watchPrefix(set)

  # make sure we are watching at least the non-glob prefix of this pattern,
  # in case the pattern represents a folder that doesn't exist yet.
  watchPrefix: (minimatchSet) ->
    index = 0
    while index < minimatchSet.length and typeof minimatchSet[index] == "string" then index += 1
    if index == minimatchSet.length then index -= 1
    prefix = path.join("/", minimatchSet[...index]...)
    parent = path.dirname(prefix)
    # if the prefix doesn't exist, backtrack within reason (don't watch "/").
    while not fs.existsSync(prefix) and parent != path.dirname(parent)
      prefix = path.dirname(prefix)
      parent = path.dirname(parent)
    if fs.existsSync(prefix)
      if prefix[prefix.length - 1] != "/" then prefix += "/"
      @watchMap.watchFolder(prefix)

  absolutePath: (p) ->
    if p[0] == '/' then p else path.join(@cwd, p)

  isMatch: (filename) ->
    for p in @patterns then if minimatch(filename, p, nonegate: true) then return true
    false

  addWatch: (filename) ->
    isdir = try
      fs.statSync(filename).isDirectory()
    catch e
      false
    if isdir
      # watch whole folder
      filename += "/"
      @watchMap.watchFolder(filename)
    else
      parent = path.dirname(filename)
      if parent != "/" then parent += "/"
      @watchMap.watchFile(filename, parent)

  stopWatches: ->
    for filename, watcher of @watchers then watcher.close()
    for folderName in @watchMap.getFolders()
      for filename in @watchMap.getFilenames(folderName) then @fileWatcher.unwatch(filename)
    @watchers = {}

  startWatches: ->
    for folderName in @watchMap.getFolders()
      @watchFolder folderName
      for filename in @watchMap.getFilenames(folderName)
        if filename[filename.length - 1] != "/" then @watchFile filename

  watchFolder: (folderName) ->
    @debug "watch: #{folderName}"
    try
      @watchers[folderName] = fs.watch folderName, { persistent: @persistent }, (event) =>
        @debug "watch event: #{folderName}"
        @checkQueue[folderName] = true
        # wait a short interval to make sure the new folder has some staying power.
        setTimeout((=> @scanQueue()), @debounceInterval)
    catch e
      # never mind.
  
  scanQueue: ->
    folders = Object.keys(@checkQueue)
    @checkQueue = {}
    for f in folders then @folderChanged(f)

  watchFile: (filename, mtime = null, size = null) ->
    @debug "watchFile: #{filename}"
    # FIXME @persistent @interval
    @fileWatcher.watch(filename, mtime, size).on 'changed', =>
      @debug "watchFile event: #{filename}"
      @emit 'changed', filename

  folderChanged: (folderName) ->
    @debug "-> check folder: #{folderName}"
    return if @closed
    makePromise(fs.readdir)(folderName)
    .fail (error) =>
      @debug "   ERR: #{error}"
      []
    .then (current) =>
      return if @closed
      # add "/" to folders
      current = current.map (filename) ->
        filename = path.join(folderName, filename)
        try
          if fs.statSync(filename).isDirectory() then filename += "/"
        catch e
          # file vanished before we could stat it!
        filename
      previous = @watchMap.getFilenames(folderName)

      # deleted files/folders
      for f in previous.filter((x) -> current.indexOf(x) < 0)
        if f[f.length - 1] == '/' then @folderDeleted(f) else @fileDeleted(f)

      # new files/folders
      Q.all(
        for f in current.filter((x) -> previous.indexOf(x) < 0)
          if f[f.length - 1] == '/' then @folderAdded(f) else @fileAdded(f, folderName)
      )
    .then =>
      @debug "<- check folder: #{folderName}"

  fileDeleted: (filename) ->
    @debug "file deleted: #{filename}"
    parent = path.dirname(filename)
    if parent != "/" then parent += "/"
    if @watchMap.watchingFile(filename, parent)
      fs.unwatchFile(filename)
      @watchMap.unwatchFile(filename, parent)
    @emit 'deleted', filename

  folderDeleted: (folderName) ->
    # this is trouble, bartman-style, because it may be the only indication
    # we get that an entire subtree is gone. recurse through them, marking
    # everything as dead.
    @debug "folder deleted: #{folderName}"
    # getNestedFolders() also includes this folder (folderName).
    for folder in @watchMap.getNestedFolders(folderName)
      for filename in @watchMap.getFilenames(folder) then @fileDeleted(filename)
      if @watchers[folder]
        @watchers[folder].close()
        delete @watchers[folder]
      @watchMap.unwatchFolder(folder)

  fileAdded: (filename, folderName) ->
    return unless @isMatch(filename)
    @debug "file added: #{filename}"
    @watchMap.watchFile(filename, folderName)
    @watchFile filename
    @emit 'added', filename
    Q(null)

  folderAdded: (folderName) ->
    # if it potentially matches the prefix of a glob we're watching, start
    # watching it, and recursively check for new files.
    return null unless @folderIsInteresting(folderName)
    @debug "folder added: #{folderName}"
    @watchMap.watchFolder(folderName)
    @watchFolder folderName
    @folderChanged(folderName)

  # does this folder match the prefix for an existing watch-pattern?
  folderIsInteresting: (folderName) ->
    folderSegments = folderName.split("/")[0...-1]
    for set in @minimatchSets then if folderMatchesMinimatchPrefix(folderSegments, set) then return true
    false
