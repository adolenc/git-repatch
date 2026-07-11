# git-repatch

Replay an existing change through your editor into the working tree.

You just made a project-wide change - added a config knob, a log line, a
field - and now you need the *same lines again* with a different name.
`git repatch` shows the change as a patch, you edit the `+` lines, and the
edited copy lands in your working tree as unstaged changes, right next to the
original.

```
$ git repatch                     # opens the last commit's change in $EDITOR
$ git repatch -s 's/foo/bar/'     # same, non-interactive: sed the copy in
```

HEAD and the index are never touched: the only output is unstaged
working-tree changes, so `git diff` is the review and `git checkout -p` is
the undo.

## Install

Copy `git-repatch` somewhere on your `$PATH` and make it executable:

```sh
cp git-repatch /usr/local/bin/
chmod +x /usr/local/bin/git-repatch
```

## Usage

```
git repatch [<rev> | <rev>..<rev> | --staged | --worktree]
            [options] [--] [<pathspec>...]

source (default: HEAD)
  <rev>            that commit's diff          e.g. git repatch HEAD~2
  <rev>..<rev>     a range's cumulative diff   e.g. git repatch main..topic
  --staged         the index vs HEAD
  --worktree       all uncommitted changes vs HEAD
  -- <pathspec>    limit the source diff to these paths

options
  -s, --sed EXPR   sed s/pat/repl/[flags] applied to the seeded '+' lines
                   only (repeatable); skips the editor unless --edit
      --edit       open the editor even when -s is given
      --plain      force plain mode (skip the presence probe)
      --check      dry run: validate everything, write nothing
  -q, --quiet      suppress the report
```

## Two modes, picked automatically

**Duplicate mode** - the source change is already in your working tree (the
usual case: you just committed it). The buffer shows the original change as
context with a pre-seeded copy of every added block as `+` lines:

```
 import sys
 foo_timeout = 5
+foo_timeout = 5
 
 def main():
```

Edit the copy (`:g/^+/s/foo/bar/g`), save, and the sibling change lands right
after the original in every file.

**Plain mode** - the source change is absent from your tree (an older commit,
another branch). The buffer is the raw patch: cherry-pick with an edit step.

In either mode: edit **only** the `+` lines - context lines must keep
matching your tree. Deleting a `+` line, a hunk, or a file section skips it.
Changing a context line's leading `' '` to `'-'` also deletes that line from
your tree. `#` lines are ignored; an empty file aborts. A failed apply writes
nothing and reopens the editor with git's error message.

## Examples

```sh
# yesterday's commit added foo_timeout everywhere; add bar_timeout too
git repatch -s 's/foo_timeout = 5/bar_timeout = 10/'

# same, but review/adjust in the editor first
git repatch -s 's/foo/bar/' --edit

# stack a third variant on top of the previous repatch
git repatch --worktree -s 's/bar/baz/'

# replay one commit's change, editing as you go, in src/ only
git repatch HEAD~3 -- src/

# take a change from another branch, renamed on the way in
git repatch main..topic
```

## How it works (and why it never fuzzes)

A commit's patch can never be re-applied on top of itself: its context lines
describe the tree from *before* the commit. Fuzzy application (`git apply
-C0`) is not the answer - it silently drops single-line additions at the end
of the file. So `git repatch` only ever does strict applies:

1. **Probe.** `git apply -R --check` tells whether the change is present in
   the working tree, exactly; the forward check tells whether it is absent.
   That picks duplicate vs plain mode. Anything in between is refused with an
   explanation (a failed strict apply is atomic - nothing is half-written).
2. **Re-base the patch onto the current tree.** In a temp directory the
   source patch is reverse-applied to copies of the touched files,
   reconstructing "tree without the change"; re-diffing that against the real
   files yields every added block in *current* line numbers, from which the
   buffer is built: current lines as context, a duplicate of each block
   seeded after its original.
3. **Recount, then strict apply.** Your edits invalidate the `@@` headers,
   and `git apply --recount` would misplace later hunks, so repatch
   recomputes the headers itself and applies with no leniency flags at all,
   from the repo toplevel. The applied patch is kept at `.git/REPATCH.diff`.

## Caveats

- Repatching the *same commit* twice fails the presence probe (your first
  copy now sits inside the original's context). That's what `--worktree` is
  for: repatch the uncommitted result instead.
- Files *created* by the source can't be duplicated onto themselves; they
  appear as a commented-out section - uncomment and change the path to
  create a sibling file. Deletions, binaries and submodules are skipped with
  a note.
- A block added at the very end of a file that lacks a trailing newline is
  skipped (with a note).
- Merge commits have no single diff; use a range (`git repatch M^1..M`).

## Tests

```
tests/run.sh
```
