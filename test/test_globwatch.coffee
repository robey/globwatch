fs = require 'fs'
minimatch = require 'minimatch'
path = require 'path'
Q = require 'q'
shell = require 'shelljs'
should = require 'should'
touch = require 'touch'
util = require 'util'

test_util = require("./test_util")
futureTest = test_util.futureTest
withTempFolder = test_util.withTempFolder

globwatch = require("../lib/globwatch/globwatch")

dump = (x) -> util.inspect x, false, null, true

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

# capture add/remove/change into an object for later inspection
capture = (g) ->
  summary = {}
  g.on "added", (filename) ->
    (summary["added"] or= []).push filename
    summary["added"].sort()
  g.on "deleted", (filename) ->
    (summary["deleted"] or= []).push filename
    summary["deleted"].sort()
  g.on "changed", (filename) ->
    (summary["changed"] or= []).push filename
    summary["changed"].sort()
  summary

describe "globwatch", ->
  it "folderMatchesMinimatchPrefix", ->
    set = new minimatch.Minimatch("/home/commie/**/*.js", nonegate: true).set[0]
    globwatch.folderMatchesMinimatchPrefix([ "", "home" ], set).should.equal(true)
    globwatch.folderMatchesMinimatchPrefix([ "", "home", "commie" ], set).should.equal(true)
    globwatch.folderMatchesMinimatchPrefix([ "", "home", "robey" ], set).should.equal(false)
    globwatch.folderMatchesMinimatchPrefix([ "", "home", "commie", "rus" ], set).should.equal(true)
    set = new minimatch.Minimatch("/home/commie/x*/*.js", nonegate: true).set[0]
    globwatch.folderMatchesMinimatchPrefix([ "", "home" ], set).should.equal(true)
    globwatch.folderMatchesMinimatchPrefix([ "", "home", "commie" ], set).should.equal(true)
    globwatch.folderMatchesMinimatchPrefix([ "", "home", "robey" ], set).should.equal(false)
    globwatch.folderMatchesMinimatchPrefix([ "", "home", "commie", "rus" ], set).should.equal(false)
    globwatch.folderMatchesMinimatchPrefix([ "", "home", "commie", "xyggurat" ], set).should.equal(true)
    globwatch.folderMatchesMinimatchPrefix([ "", "home", "commie", "xyggurat", "toofar" ], set).should.equal(false)

  it "addWatch", futureTest ->
    g = globwatch.globwatch("/wut")
    g.ready.then ->
      for f in [
        "/absolute.txt"
        "/sub/absolute.txt"
        "/deeply/nested/file/why/nobody/knows.txt"
      ] then g.addWatch(f)
      g.watchMap.getFolders().sort().should.eql [ "/", "/deeply/nested/file/why/nobody/", "/sub/" ]
      g.watchMap.getFilenames("/").should.eql [ "/absolute.txt" ]
      g.watchMap.getFilenames("/sub/").should.eql [ "/sub/absolute.txt" ]
      g.watchMap.getFilenames("/deeply/nested/file/why/nobody/").should.eql [ "/deeply/nested/file/why/nobody/knows.txt" ]
    .fin ->
      g.close()

  it "can parse patterns", fixtures (folder) ->
    g = globwatch.globwatch("#{folder}/**/*.x")
    g.patterns.should.eql [ "#{folder}/**/*.x" ]
    g.ready.then ->
      Object.keys(g.watchers).sort().should.eql [ "#{folder}/", "#{folder}/nested/", "#{folder}/sub/" ]
      g.watchMap.getFolders().sort().should.eql [ "#{folder}/", "#{folder}/nested/", "#{folder}/sub/" ]
      g.watchMap.getFilenames("#{folder}/").should.eql [ "#{folder}/one.x" ]
      g.watchMap.getFilenames("#{folder}/nested/").should.eql [ "#{folder}/nested/three.x" ]
      g.watchMap.getFilenames("#{folder}/sub/").should.eql [ "#{folder}/sub/one.x", "#{folder}/sub/two.x" ]
    .fin ->
      g.close()

  it "can parse patterns relative to cwd", fixtures (folder) ->
    g = globwatch.globwatch("**/*.x", cwd: "#{folder}/sub")
    g.patterns.should.eql [ "#{folder}/sub/**/*.x" ]
    g.ready.then ->
      Object.keys(g.watchers).sort().should.eql [ "#{folder}/sub/" ]
      g.watchMap.getFolders().sort().should.eql [ "#{folder}/sub/" ]
      g.watchMap.getFilenames("#{folder}/sub/").should.eql [ "#{folder}/sub/one.x", "#{folder}/sub/two.x" ]
    .fin ->
      g.close()

  it "handles odd relative paths", fixtures (folder) ->
    g = globwatch.globwatch("../sub/**/*.x", cwd: "#{folder}/nested")
    g.patterns.should.eql [ "#{folder}/sub/**/*.x" ]
    g.ready.then ->
      Object.keys(g.watchers).sort().should.eql [ "#{folder}/sub/" ]
      g.watchMap.getFolders().sort().should.eql [ "#{folder}/sub/" ]
      g.watchMap.getFilenames("#{folder}/sub/").should.eql [ "#{folder}/sub/one.x", "#{folder}/sub/two.x" ]
    .fin ->
      g.close()

  it "notices new files", fixtures (folder) ->
    g = globwatch.globwatch("#{folder}/**/*.x")
    summary = null
    g.ready.then ->
      summary = capture(g)
      touch.sync "#{folder}/nested/four.x"
      touch.sync "#{folder}/sub/not-me.txt"
      Q.delay(g.debounceInterval * 4)
    .then ->
      g.close()
      summary.should.eql {
        added: [ "#{folder}/nested/four.x" ]
      }

  it "notices new files only in cwd", fixtures (folder) ->
    g = globwatch.globwatch("**/*.x", cwd: "#{folder}/sub")
    summary = null
    g.ready.then ->
      summary = capture(g)
      touch.sync "#{folder}/nested/four.x"
      touch.sync "#{folder}/sub/not-me.txt"
      touch.sync "#{folder}/sub/four.x"
      Q.delay(g.debounceInterval * 4)
    .then ->
      g.close()
      summary.should.eql {
        added: [ "#{folder}/sub/four.x" ]
      }

  it "notices new files nested deeply", fixtures (folder) ->
    g = globwatch.globwatch("#{folder}/**/*.x")
    summary = null
    g.ready.then ->
      summary = capture(g)
      shell.mkdir "-p", "#{folder}/nested/more/deeply"
      touch.sync "#{folder}/nested/more/deeply/nine.x"
      Q.delay(g.debounceInterval * 4)
    .then ->
      g.close()
      summary.should.eql {
        added: [ "#{folder}/nested/more/deeply/nine.x" ]
      }

  it "notices deleted files", fixtures (folder) ->
    g = globwatch.globwatch("**/*.x", cwd: "#{folder}")
    summary = null
    g.ready.then ->
      summary = capture(g)
      fs.unlinkSync("#{folder}/sub/one.x")
      Q.delay(g.debounceInterval * 4)
    .then ->
      g.close()
      summary.should.eql {
        deleted: [ "#{folder}/sub/one.x" ]
      }

  it "notices a rename as an add + delete", fixtures (folder) ->
    g = globwatch.globwatch("**/*.x", cwd: "#{folder}")
    summary = null
    g.ready.then ->
      summary = capture(g)
      fs.renameSync "#{folder}/sub/two.x", "#{folder}/sub/twelve.x"
      Q.delay(g.debounceInterval * 4)
    .then ->
      g.close()
      summary.should.eql {
        added: [ "#{folder}/sub/twelve.x" ]
        deleted: [ "#{folder}/sub/two.x" ]
      }

  it "handles a nested delete", fixtures (folder) ->
    shell.mkdir "-p", "#{folder}/nested/more/deeply"
    touch.sync "#{folder}/nested/more/deeply/here.x"
    g = globwatch.globwatch("**/*.x", cwd: "#{folder}")
    summary = null
    g.ready.then ->
      summary = capture(g)
      shell.rm "-r", "#{folder}/nested"
      # this seems to be due to a bug in node/uv where watch events may be delayed by up to 250ms?
      Q.delay(g.debounceInterval * 4)
    .then ->
      g.close()
      summary.should.eql {
        deleted: [ "#{folder}/nested/more/deeply/here.x", "#{folder}/nested/three.x" ]
      }

  it "handles a changed file", fixtures (folder) ->
    g = globwatch.globwatch("**/*", cwd: "#{folder}")
    summary = null
    g.ready.then ->
      summary = capture(g)
      fs.writeFileSync "#{folder}/sub/one.x", "gahhhhhh"
      Q.delay(g.interval)
    .then ->
      g.close()
      summary.should.eql {
        changed: [ "#{folder}/sub/one.x" ]
      }

  it "follows a safe-write", fixtures (folder) ->
    g = globwatch.globwatch("**/*", cwd: "#{folder}")
    summary = null
    savee = "#{folder}/one.x"
    backup = "#{folder}/one.x~"
    g.ready.then ->
      summary = capture(g)
      fs.writeFileSync backup, fs.readFileSync(savee)
      fs.unlinkSync savee
      fs.renameSync backup, savee
      Q.delay(g.interval)
    .then ->
      g.close()
      summary.should.eql {
        changed: [ savee ]
      }

  it "only emits once for a changed file", fixtures (folder) ->
    g = globwatch.globwatch("**/*", cwd: "#{folder}")
    summary = null
    g.ready.then ->
      summary = capture(g)
      fs.writeFileSync "#{folder}/one.x", "wheeeeeee"
      Q.delay(g.interval)
    .then ->
      summary.should.eql {
        changed: [ "#{folder}/one.x" ]
      }
      Q.delay(g.interval)
    .then ->
      summary.should.eql {
        changed: [ "#{folder}/one.x" ]
      }
    .fin ->
      g.close()

  it "emits twice if a file was changed twice", fixtures (folder) ->
    g = globwatch.globwatch("**/*", cwd: "#{folder}")
    summary = null
    g.ready.then ->
      summary = capture(g)
      fs.writeFileSync "#{folder}/one.x", "wheeeeeee"
      Q.delay(g.interval)
    .then ->
      summary.should.eql {
        changed: [ "#{folder}/one.x" ]
      }
      fs.writeFileSync "#{folder}/one.x", "wheeeeeee"
      Q.delay(g.interval)
    .then ->
      summary.should.eql {
        changed: [ "#{folder}/one.x", "#{folder}/one.x" ]
      }
    .fin ->
      g.close()

  it "doesn't mind watching a nonexistent folder", fixtures (folder) ->
    g = globwatch.globwatch("#{folder}/not/there/*")
    g.ready.then ->
      3.should.equal(3)
    .fin ->
      g.close()

  it "sees a new matching file even if the whole folder was missing when it started", futureTest withTempFolder (folder) ->
    g = globwatch.globwatch("#{folder}/not/there/*")
    summary = null
    g.ready.then ->
      summary = capture(g)
      shell.mkdir "-p", "#{folder}/not/there"
      fs.writeFileSync "#{folder}/not/there/ten.x", "wheeeeeee"
      Q.delay(g.interval)
    .then ->
      summary.should.eql {
        added: [ "#{folder}/not/there/ten.x" ]
      }
    .fin ->
      g.close()

  it "sees a new matching file even if nested folders were missing when it started", fixtures (folder) ->
    g = globwatch.globwatch("#{folder}/sub/deeper/*.x")
    summary = null
    g.ready.then ->
      summary = capture(g)
      shell.mkdir "-p", "#{folder}/sub/deeper"
      fs.writeFileSync "#{folder}/sub/deeper/ten.x", "wheeeeeee"
      Q.delay(g.interval)
    .then ->
      summary.should.eql {
        added: [ "#{folder}/sub/deeper/ten.x" ]
      }
    .fin ->
      g.close()

  it "sees a new matching file even if the entire tree was erased and re-created", fixtures (folder) ->
    shell.mkdir "-p", "#{folder}/nested/deeper"
    touch.sync "#{folder}/nested/deeper/four.x"
    g = globwatch.globwatch("#{folder}/nested/deeper/*.x")
    summary = null
    g.ready.then ->
      summary = capture(g)
      shell.rm "-r", "#{folder}/nested"
      shell.mkdir "-p", "#{folder}/nested/deeper"
      fs.writeFileSync "#{folder}/nested/deeper/ten.x", "wheeeeeee"
      Q.delay(g.interval)
    .then ->
      summary.should.eql {
        deleted: [ "#{folder}/nested/deeper/four.x" ]
        added: [ "#{folder}/nested/deeper/ten.x" ]
      }
    .fin ->
      g.close()

  it "sees a new matching file even if the folder exists but was empty", fixtures (folder) ->
    shell.mkdir "-p", "#{folder}/nested/deeper"
    g = globwatch.globwatch("#{folder}/nested/deeper/*.x")
    summary = null
    g.ready.then ->
      summary = capture(g)
      fs.writeFileSync "#{folder}/nested/deeper/ten.x", "wheeeeeee"
      Q.delay(g.interval)
    .then ->
      summary.should.eql {
        added: [ "#{folder}/nested/deeper/ten.x" ]
      }
    .fin ->
      g.close()
