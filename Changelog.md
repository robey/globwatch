## 1.1.0 (18 august 2013)

- added currentSet(), to get the set of filenames that currently exist

## 1.0.2 (1 july 2013)

- folders were getting added to the file tree as if they were files, but only
  during the initial watch setup. this broke detection of new nested files
  in some cases.
- optimization: stuff changed folders into a set, and scan the whole set
  after the debounce interval. should prevent us from scanning the same
  folder 100 times.

## 1.0.1 (2 june 2013)

- first real version
