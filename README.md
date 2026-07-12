# git-repatch

Replay an existing change through your editor into the working tree.

You just made a project-wide change and now you need to add the *same lines
again* except slightly modified (e.g. a second variable at mostly the same
places). `git repatch` shows the selected change as a patch, you edit the `+`
lines, and the edited copy lands in your working tree as unstaged changes,
right next to the original.

```
$ git repatch                     # opens the last commit's change in $EDITOR
$ git repatch -s 's/foo/bar/'     # same, non-interactive: sed the copy in
```

HEAD and the index are never touched: the only output is unstaged
working-tree changes, so `git diff` is the review and `git checkout -p` is
the undo.

## Install

Put [`git-repatch`](./git-repatch) somewhere on your `$PATH` and make it executable:

```sh
cp git-repatch /usr/local/bin/
chmod +x /usr/local/bin/git-repatch
```

## Usage

```
git repatch [<rev> | <rev>..<rev> | --staged]
            [options] [--] [<pathspec>...]

source (default: HEAD)
  <rev>            that commit's diff          e.g. git repatch HEAD~2
  <rev>..<rev>     a range's cumulative diff   e.g. git repatch main..topic
  --staged         the index vs HEAD
  -- <pathspec>    limit the source diff to these paths

options
  -s, --sed EXPR   sed s/pat/repl/[flags] applied to the seeded '+' lines
                   only (repeatable); skips the editor unless --edit
      --edit       open the editor even when -s is given
  -U, --unified N  context lines around each change (default 3, minimum 1)
      --check      dry run: validate everything, write nothing
  -q, --quiet      suppress the report
```

## Examples

```sh
# replay last commit's change, open the editor to adjust the copy
git repatch

# last commit added foo_timeout everywhere; add bar_timeout too
git repatch -s 's/foo_timeout = 5/bar_timeout = 10/'

# same, but review/adjust in the editor first
git repatch -s 's/foo/bar/' --edit

# stack a third variant on top of the previous repatch
git add -u && git repatch --staged -s 's/bar/baz/'

# replay one commit's change, editing as you go, in src/ only
git repatch HEAD~3 -- src/

# duplicate a range of commits in current branch
git repatch HEAD~5..HEAD~2
```

## Caveats

- Repatching the *same commit* twice fails the presence probe (your first
  copy now sits inside the original's context). Stage the copy and repatch
  that instead: `git add -u && git repatch --staged`.
- Files *created* by the source can't be duplicated onto themselves; they
  appear as a commented-out section - uncomment and change the path to
  create a sibling file. Deletions, binaries and submodules are skipped with
  a note.
- A block added at the very end of a file that lacks a trailing newline is
  skipped (with a note).
- Merge commits have no single diff; use a range (`git repatch M^1..M`).

## Tests

```bash
./tests/run.sh
```
