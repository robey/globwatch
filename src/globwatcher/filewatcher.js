let events = require("events");
let fs = require("fs");
let path = require("path");
let Promise = require("bluebird");
let util = require("util");

class FileWatcher {
  constructor(options_in = {}) {
    let options = {
      period: 250,
      persistent: true
    };
    for (let key in options_in) options[key] = options_in[key];
    // frequency of stat() checking, in milliseconds
    this.period = options.period;
    // should our timer keep the process alive?
    this.persistent = options.persistent;
    // timer that periodically checks for file changes
    this.timer = null;
    // filename -> Watch
    this.watches = {};
    // chain of running checks
    this.ongoing = null;
  }

  close() {
    this.watches = {};
    if (this.timer != null) {
      clearInterval(this.timer);
      this.timer = null;
    }
  }

  watch(filename, mtime = null, size = null) {
    filename = path.resolve(filename);
    let watch = this.watches[filename];
    if (watch == null) {
      watch = this.watches[filename] = new Watch(filename, mtime, size);
    }
    if (this.timer == null) {
      this.timer = setInterval(() => this.check(), this.period);
      if (!this.persistent) this.timer.unref();
    }
    return watch;
  }

  unwatch(filename) {
    filename = path.resolve(filename);
    delete this.watches[filename];
  }

  watchFor(filename) {
    return this.watches[path.resolve(filename)];
  }

  // runs a scan of all outstanding watches.
  // if a scan is currently running, the new scan is queued up behind it.
  // returns a promise that will be fulfilled when this new scan is finished.
  check() {
    this.ongoing = (this.ongoing || Promise.resolve()).then(() => {
      let watches = Object.keys(this.watches).map((key) => this.watches[key]);
      let completion = Promise.all(watches.map((watch) => watch.check()));
      this.ongoing = completion.then(() => {
        this.ongoing = null;
      });
      return this.ongoing;
    });
    return this.ongoing;
  }
}

class Watch extends events.EventEmitter {
  constructor(filename, mtime, size) {
    super();
    this.filename = filename;
    this.mtime = mtime;
    this.size = size;

    this.callbacks = [];
    if (this.mtime == null || this.size == null) {
      try {
        let stat = fs.statSync(this.filename);
        this.mtime = stat.mtime.getTime();
        this.size = stat.size;
      } catch (error) {
        // nevermind.
      }
    }
  }

  check() {
    return Promise.promisify(fs.stat)(this.filename).catch((error) => null).then((stat) => {
      if (this.mtime != null && stat != null && (this.mtime != stat.mtime.getTime() || this.size != stat.size)) {
        this.emit("changed", stat);
      }
      if (stat != null) {
        this.mtime = stat.mtime.getTime();
        this.size = stat.size;
      } else {
        this.mtime = null;
        this.size = null;
      }
    });
  }
}


exports.FileWatcher = FileWatcher;
