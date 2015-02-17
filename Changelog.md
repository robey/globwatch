## 1.3.1 (11 jul 2014)

- coffee-script is not a dependency, just a dev dependency. [ceejbot]

## 1.3.0 (11 jul 2014)

- added `emitFolders` flag to ask for `added`/`removed` events to be emitted for folders, too.

## 1.2.3 (22 apr 2013)

- pinned Q at version 1.x.

## 1.2.2 (27 oct 2013)

- fix bug where a pattern with no globs (just listing a file) wouldn't be
  checked correctly when restoring state.

## 1.2.1 (18 sep 2013)

- globwatcher objects now save the original (non-normalized) pattern strings in `originalPatterns`.

## 1.2.0 (21 aug 2013)

- added snapshot(), for storing state between runs.

## 1.1.0 (18 aug 2013)

- added currentSet(), to get the set of filenames that currently exist.

## 1.0.2 (1 jul 2013)

- folders were getting added to the file tree as if they were files, but only during the initial watch setup. this broke detection of new nested files in some cases.
- optimization: stuff changed folders into a set, and scan the whole set after the debounce interval. should prevent us from scanning the same folder 100 times.

## 1.0.1 (2 jun 2013)

- first real version
