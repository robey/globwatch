let events = require("events");
let fs = require("fs");
let glob = require("glob");
let minimatch = require("minimatch");
let path = require("path");
let Promise = require("bluebird");
let util = require("util");
let _ = require("lodash");

glob = Promise.promisify(glob);
let readdir = Promise.promisify(fs.readdir);
let FileWatcher = require("./filewatcher").FileWatcher;

// FIXME this should probably be in a minimatch wrapper class
function folderMatchesMinimatchPrefix(folderSegments, minimatchSet) {
  for (let i = 0; i < folderSegments.length; i++) {
    let segment = folderSegments[i];
    let miniSegment = minimatchSet[i];
    if (miniSegment == minimatch.GLOBSTAR) return true;
    if (typeof miniSegment == "string") {
      if (miniSegment != segment) return false;
    } else {
      if (!miniSegment.test(segment)) return false;
    }
  }
  return true;
}

exports.folderMatchesMinimatchPrefix = folderMatchesMinimatchPrefix;


// sometimes helpful for my own debugging.
function debugWithTimestamp(message) {
  const now = Date.now()
  const timestamp = new Date(now).toString().slice(16, 24) + "." + (1000 + now % 1000).toString().slice(1)
  console.log(timestamp + ": " + message);
}

exports.debugWithTimestamp = debugWithTimestamp;


// map (absolute) folder names, which are being folder-level watched, to a
// set of (absolute) filenames in that folder that are being file-level
// watched.
class WatchMap {
  constructor() {
    // map: folderName -> (filename -> true)
    this.map = {};
  }

  clear() {
    this.map = {};
  }

  watchFolder(folderName) {
    if (this.map[folderName] == undefined) this.map[folderName] = {};
  }

  unwatchFolder(folderName) {
    delete this.map[folderName];
  }

  watchFile(filename, parent) {
    if (this.map[parent] == undefined) this.map[parent] = {};
    this.map[parent][filename] = true;
  }

  unwatchFile(filename, parent) {
    delete this.map[parent][filename];
  }

  getFolders() {
    return Object.keys(this.map);
  }

  getFilenames(folderName) {
    return Object.keys(this.map[folderName] || {});
  }

  getAllFilenames() {
    let rv = [];
    this.getFolders().forEach((folder) => {
      rv = rv.concat(this.getFilenames(folder));
    });
    return rv;
  }

  getNestedFolders(folderName) {
    return this.getFolders().filter((f) => f.slice(0, folderName.length) == folderName);
  }

  watchingFolder(folderName) {
    return this.map[folderName] != undefined;
  }

  watchingFile(filename, parent) {
    if (parent == null) parent = path.dirname(filename);
    return this.map[parent] != null && this.map[parent][filename] != null;
  }

  toDebug() {
    let out = [];
    Object.keys(this.map).sort().forEach((folder) => {
      out.push(folder);
      Object.keys(this.map[folder]).sort().forEach((filename) => out.push(`  '- ${filename}`));
    });
    return out.join("\n") + "\n";
  }
}


function globwatcher(pattern, options) {
  return new GlobWatcher(pattern, options);
}

exports.globwatcher = globwatcher;


class GlobWatcher extends events.EventEmitter {
  constructor(patterns, options = {}) {
    super();
    this.closed = false;
    this.cwd = options.cwd || process.cwd();
    this.debounceInterval = options.debounceInterval || 10;
    this.interval = options.interval || 250;
    this.debug = options.debug || (() => null);
    if (this.debug === true) this.debug = debugWithTimestamp;
    this.persistent = options.persistent || false;
    this.emitFolders = options.emitFolders || false;
    this.watchMap = new WatchMap();
    this.fileWatcher = new FileWatcher(options);
    // map of (absolute) folderName -> FSWatcher
    this.watchers = {};
    // (ordered) list of glob patterns to watch
    this.patterns = [];
    // minimatch sets for our patterns
    this.minimatchSets = [];
    // set of folder watch events to check on after the debounce interval
    this.checkQueue = {};
    if (typeof patterns == "string") patterns = [ patterns ];
    this.originalPatterns = patterns;
    if (options.snapshot) {
      this.restoreFrom(options.snapshot, patterns);
    } else {
      this.add(...patterns);
    }
  }

  add(...patterns) {
    this.debug(`add: ${util.inspect(patterns)}`);
    this.originalPatterns = this.originalPatterns.concat(patterns);
    this.addPatterns(patterns);
    this.ready = Promise.all(this.patterns.map((p) => {
      return glob(p, { nonegate: true }).then((files) => {
        files.forEach((filename) => this.addWatch(filename));
      });
    })).then(() => {
      this.stopWatches();
      this.startWatches();
      // give a little delay to wait for things to calm down
      return Promise.delay(this.debounceInterval);
    }).then(() => {
      this.debug(`add complete: ${util.inspect(patterns)}`);
      return this;
    });
  }

  close() {
    this.debug("close");
    this.stopWatches();
    this.watchMap.clear();
    this.fileWatcher.close();
    this.closed = true;
    this.debug("/close");
  }

  // scan every covered folder again to see if there were any changes.
  check() {
    this.debug("-> check");
    let folders = Object.keys(this.watchers).map((folderName) => this.folderChanged(folderName));
    return Promise.all([ this.fileWatcher.check() ].concat(folders)).then(() => {
      this.debug("<- check");
    });
  }

  // what files exist *right now* that match the watches?
  currentSet() {
    return this.watchMap.getAllFilenames();
  }

  // filename -> { mtime size }
  snapshot() {
    let state = {};
    this.watchMap.getAllFilenames().forEach((filename) => {
      let w = this.fileWatcher.watchFor(filename);
      if (w) state[filename] = { mtime: w.mtime, size: w.size };
    });
    return state;
  }


  // ----- internals:

  // restore from a { filename -> { mtime size } } snapshot.
  restoreFrom(state, patterns) {
    this.addPatterns(patterns);
    Object.keys(state).forEach((filename) => {
      let folderName = path.dirname(filename);
      if (folderName != "/") folderName += "/";
      this.watchMap.watchFile(filename, folderName);
    });
    // now, start watches.
    this.watchMap.getFolders().forEach((folderName) => {
      this.watchFolder(folderName);
    });
    Object.keys(state).forEach((filename) => {
      this.watchFile(filename, state[filename].mtime, state[filename].size);
    });
    // give a little delay to wait for things to calm down.
    this.ready = Promise.delay(this.debounceInterval).then(() => {
      this.debug(`restore complete: ${util.inspect(patterns)}`);
      return this.check();
    }).then(() => this);
  }

  addPatterns(patterns) {
    patterns.forEach((p) => {
      p = this.absolutePath(p);
      if (this.patterns.indexOf(p) < 0) this.patterns.push(p);
    });

    this.minimatchSets = [];
    this.patterns.forEach((p) => {
      this.minimatchSets = this.minimatchSets.concat(new minimatch.Minimatch(p, { nonegate: true }).set);
    });

    this.minimatchSets.forEach((set) => this.watchPrefix(set));
  }

  // make sure we are watching at least the non-glob prefix of this pattern,
  // in case the pattern represents a folder that doesn't exist yet.
  watchPrefix(minimatchSet) {
    let index = 0;
    while (index < minimatchSet.length && typeof minimatchSet[index] == "string") index += 1;
    if (index == minimatchSet.length) index -= 1;
    let prefix = path.join("/", ...minimatchSet.slice(0, index));
    let parent = path.dirname(prefix);
    // if the prefix doesn't exist, backtrack within reason (don't watch "/").
    while (!fs.existsSync(prefix) && parent != path.dirname(parent)) {
      prefix = path.dirname(prefix);
      parent = path.dirname(parent);
    }
    if (fs.existsSync(prefix)) {
      if (prefix[prefix.length - 1] != "/") prefix += "/";
      this.watchMap.watchFolder(prefix);
    }
  }

  absolutePath(p) {
    return p[0] == '/' ? p : path.join(this.cwd, p);
  }

  isMatch(filename) {
    return _.some(this.patterns, (p) => minimatch(filename, p, { nonegate: true }));
  }

  addWatch(filename) {
    let isdir = false;
    try {
      isdir = fs.statSync(filename).isDirectory();
    } catch (error) {
      // don't worry about it.
    }
    if (isdir) {
      // watch whole folder
      filename += "/";
      this.watchMap.watchFolder(filename);
    } else {
      let parent = path.dirname(filename);
      if (parent != "/") parent += "/";
      this.watchMap.watchFile(filename, parent);
    }
  }

  stopWatches() {
    _.forIn(this.watchers, (watcher, x) => {
      watcher.close();
    });
    this.watchMap.getFolders().forEach((folderName) => {
      this.watchMap.getFilenames(folderName).forEach((filename) => this.fileWatcher.unwatch(filename));
    });
    this.watchers = {};
    this.closed = true;
  }

  startWatches() {
    this.watchMap.getFolders().forEach((folderName) => {
      this.watchFolder(folderName);
      this.watchMap.getFilenames(folderName).forEach((filename) => {
        if (filename[filename.length - 1] != "/") this.watchFile(filename);
      });
    });
    this.closed = false;
  }

  watchFolder(folderName) {
    this.debug(`watch: ${folderName}`);
    try {
      this.watchers[folderName] = fs.watch(folderName, { persistent: this.persistent, recursive: false }, (event) => {
        this.debug(`watch event: ${folderName}`);
        this.checkQueue[folderName] = true;
        // wait a short interval to make sure the new folder has some staying power.
        setTimeout(() => this.scanQueue(), this.debounceInterval);
      });
    } catch (error) {
      // never mind.
    }
  }

  scanQueue() {
    let folders = Object.keys(this.checkQueue);
    this.checkQueue = {};
    folders.forEach((f) => this.folderChanged(f));
  }

  watchFile(filename, mtime = null, size = null) {
    this.debug(`watchFile: ${filename}`);
    // FIXME @persistent @interval
    this.fileWatcher.watch(filename, mtime, size).on("changed", () => {
      this.debug(`watchFile event: ${filename}`);
      this.emit("changed", filename);
    });
  }

  folderChanged(folderName) {
    // keep a scoreboard so we can avoid calling readdir() on a folder while
    // we're literally in the middle of a readdir() on that folder already.
    if (!this.folderChangedScoreboard) this.folderChangedScoreboard = {};
    if (this.folderChangedScoreboard[folderName]) return Promise.resolve();
    this.folderChangedScoreboard[folderName] = true;

    this.debug(`-> check folder: ${folderName}`);
    if (this.closed) {
      this.debug("<- check n/m, closed");
      return Promise.resolve();
    }
    return readdir(folderName).catch((error) => {
      delete this.folderChangedScoreboard[folderName];
      if (this.emitFolders) this.emit("deleted", folderName);
      this.debug(`   ERR: ${error}`);
      return [];
    }).then((current) => {
      delete this.folderChangedScoreboard[folderName];
      if (this.closed) {
        this.debug("<- check n/m, closed");
        return Promise.resolve();
      }

      // add "/" to folders
      current = current.map((filename) => {
        filename = path.join(folderName, filename);
        try {
          if (fs.statSync(filename).isDirectory()) filename += "/";
        } catch (error) {
          // file vanished before we could stat it!
        }
        return filename;
      });
      let previous = this.watchMap.getFilenames(folderName);
      if (previous.length == 0 && this.emitFolders) this.emit("added", folderName);

      // deleted files/folders
      previous.filter((x) => current.indexOf(x) < 0).map((f) => {
        f[f.length - 1] == '/' ? this.folderDeleted(f) : this.fileDeleted(f);
      });

      // new files/folders
      return Promise.all(current.filter((x) => previous.indexOf(x) < 0).map((f) => {
        return f[f.length - 1] == '/' ? this.folderAdded(f) : this.fileAdded(f, folderName);
      }));
    }).then(() => {
      this.debug(`<- check folder: ${folderName}`);
    });
  }

  fileDeleted(filename) {
    this.debug(`file deleted: ${filename}`);
    let parent = path.dirname(filename);
    if (parent != "/") parent += "/";
    if (this.watchMap.watchingFile(filename, parent)) {
      fs.unwatchFile(filename);
      this.watchMap.unwatchFile(filename, parent);
    }
    this.emit("deleted", filename);
  }

  folderDeleted(folderName) {
    // this is trouble, bartman-style, because it may be the only indication
    // we get that an entire subtree is gone. recurse through them, marking
    // everything as dead.
    this.debug(`folder deleted: ${folderName}`);
    // getNestedFolders() also includes this folder (folderName).
    this.watchMap.getNestedFolders(folderName).forEach((folder) => {
      this.watchMap.getFilenames(folder).forEach((filename) => this.fileDeleted(filename));
      if (this.watchers[folder]) {
        this.watchers[folder].close();
        delete this.watchers[folder];
      }
      this.watchMap.unwatchFolder(folder);
    });
  }

  fileAdded(filename, folderName) {
    if (!this.isMatch(filename)) return Promise.resolve();
    this.debug(`file added: ${filename}`);
    this.watchMap.watchFile(filename, folderName);
    this.watchFile(filename);
    this.emit("added", filename);
    return Promise.resolve();
  }

  folderAdded(folderName) {
    // if it potentially matches the prefix of a glob we're watching, start
    // watching it, and recursively check for new files.
    if (!this.folderIsInteresting(folderName)) return Promise.resolve();
    this.debug(`folder added: ${folderName}`);
    this.watchMap.watchFolder(folderName);
    this.watchFolder(folderName);
    return this.folderChanged(folderName);
  }

  // does this folder match the prefix for an existing watch-pattern?
  folderIsInteresting(folderName) {
    let folderSegments = folderName.split("/");
    folderSegments = folderSegments.slice(0, folderSegments.length - 1);
    return _.some(this.minimatchSets, (set) => folderMatchesMinimatchPrefix(folderSegments, set));
  }
}
