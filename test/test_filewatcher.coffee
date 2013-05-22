fs = require 'fs'
path = require 'path'
Q = require 'q'
shell = require 'shelljs'
should = require 'should'
touch = require 'touch'
util = require 'util'

test_util = require("./test_util")
futureTest = test_util.futureTest
withTempFolder = test_util.withTempFolder

FileWatcher = require("../lib/globwatch/filewatcher").FileWatcher

makeFixtures = (folder) ->
  past = Date.now() - 1000
  [
    "#{folder}/one.x"
    "#{folder}/sub/one.x"
    "#{folder}/sub/two.x"
    "#{folder}/nested/three.x"
    "#{folder}/nested/weird.jpg"
  ].map (file) ->
    shell.mkdir "-p", path.dirname(file)
    touch.sync file, mtime: past

fixtures = (f) ->
  futureTest withTempFolder (folder) ->
    makeFixtures(folder)
    f(folder)

describe "FileWatcher", ->
  beforeEach ->
    FileWatcher.reset()

  afterEach ->
    FileWatcher.reset()

  it "creates a watch", fixtures (folder) ->
    (FileWatcher.timer?).should.eql(false)
    watch = FileWatcher.watch("#{folder}/one.x")
    (watch?).should.eql(true)
    (FileWatcher.timer?).should.eql(true)
    Q(true)
  
  it "reuses the same watch for the same filename", fixtures (folder) ->    
    watch1 = FileWatcher.watch("#{folder}/one.x")
    watch2 = FileWatcher.watch("#{folder}/one.x")
    watch1.should.equal(watch2)
    Q(true)
 
  it "notices a change", fixtures (folder) ->
    watch = FileWatcher.watch("#{folder}/one.x")
    count = 0
    watch.on 'changed', -> count += 1
    touch.sync "#{folder}/one.x"
    count.should.eql(0)
    watch.check().then ->
      count.should.eql(1)

  it "notices several changes at once", fixtures (folder) ->
    countOne = 0
    countTwo = 0
    FileWatcher.watch("#{folder}/sub/one.x").on 'changed', -> countOne += 1
    FileWatcher.watch("#{folder}/sub/two.x").on 'changed', -> countTwo += 1
    touch.sync "#{folder}/sub/one.x"
    touch.sync "#{folder}/sub/two.x"
    countOne.should.eql(0)
    countTwo.should.eql(0)
    FileWatcher.check().then ->
      countOne.should.eql(1)
      countTwo.should.eql(1)

  it "notices changes on a timer", fixtures (folder) ->
    countOne = 0
    countTwo = 0
    FileWatcher.watch("#{folder}/sub/one.x").on 'changed', -> countOne += 1
    FileWatcher.watch("#{folder}/sub/two.x").on 'changed', -> countTwo += 1
    touch.sync "#{folder}/sub/one.x"
    touch.sync "#{folder}/sub/two.x"
    countOne.should.eql(0)
    countTwo.should.eql(0)
    Q.delay(FileWatcher.period + 10).then ->
      countOne.should.eql(1)
      countTwo.should.eql(1)

  it "queues stacked check() calls", fixtures (folder) ->
    count = 0
    FileWatcher.watch("#{folder}/one.x").on 'changed', -> count += 1
    touch.sync "#{folder}/one.x", mtime: Date.now() + 1000
    visited = [ false, false ]
    x1 = FileWatcher.check().then ->
      count.should.eql(1)
      touch.sync "#{folder}/one.x", mtime: Date.now() + 2000
      visited[1].should.eql(false)
      visited[0] = true
    x2 = FileWatcher.check().then ->
      visited[0].should.eql(true)
      visited[1] = true
      count.should.eql(2)
    visited[0].should.eql(false)
    visited[1].should.eql(false)
    Q.all([ x1, x2 ])

  it "detects size changes", futureTest withTempFolder (folder) ->
    now = Date.now() - 15000
    write = (data) ->
      fs.writeFileSync("#{folder}/shifty.x", data)
      touch.sync "#{folder}/shifty.x", mtime: now
    write "abcdefghij"
    count = 0
    FileWatcher.watch("#{folder}/shifty.x").on 'changed', -> count += 1
    write "klmnopqrst"
    FileWatcher.check()
    .then ->
      count.should.eql(0)
      write "abcdef"
      FileWatcher.check()
    .then ->
      count.should.eql(1)

  it "can unwatch", futureTest withTempFolder (folder) ->
    touch.sync "#{folder}/changes.x", mtime: Date.now() - 15000
    watch = FileWatcher.watch "#{folder}/changes.x"
    count = 0
    watch.on 'changed', -> count += 1
    touch.sync "#{folder}/changes.x", mtime: Date.now() - 11000
    FileWatcher.check()
    .then ->
      count.should.eql(1)
      FileWatcher.unwatch "#{folder}/changes.x"
      touch.sync "#{folder}/changes.x", mtime: Date.now() - 6000
      FileWatcher.check()
    .then ->
      count.should.eql(1)

