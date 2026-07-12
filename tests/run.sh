#!/bin/bash
# git-repatch test suite. Hermetic: throwaway repos under $TMPDIR, no user
# git config, editors faked via GIT_EDITOR scripts. Run: tests/run.sh
set -u

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
TOOL=$TESTS_DIR/../git-repatch
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset EDITOR VISUAL GIT_EDITOR

WORK=$(mktemp -d "${TMPDIR:-/tmp}/repatch-tests.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

N=0; FAILED=0
ok()   { N=$((N+1)); printf 'ok %d - %s\n' "$N" "$1"; }
bad()  { N=$((N+1)); FAILED=$((FAILED+1)); printf 'FAIL %d - %s\n' "$N" "$1"; }
is()   { # is <desc> <actual> <expected>
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi
}
line() { sed -n "$2p" "$1"; }
clean_tree() { [ -z "$(git -C "$1" status --porcelain)" ]; }

# --- fixtures ---------------------------------------------------------------

make_repo() { # $1: dir. base commit + "add foo knobs" commit (2 hunks x 2 files)
	git init -q "$1" && cd "$1" || exit 1
	cat > a.py <<-'EOF'
	import os
	import sys

	def main():
	    x = 1
	    print("hi")
	    return x
	EOF
	cp a.py b.py
	git add . && git commit -qm base && git tag base
	sed -i 's/^import sys$/import sys\nfoo_timeout = 5/' a.py b.py
	sed -i 's/^    x = 1$/    x = 1\n    foo_retry = 3/' a.py b.py
	git add . && git commit -qm 'add foo knobs' && git tag foo
	cd - >/dev/null || exit 1
}

make_block_repo() { # $1: dir. base + commit adding a 5-line block and one line
	git init -q "$1" && cd "$1" || exit 1
	cat > a.py <<-'EOF'
	import os
	import sys

	def main():
	    x = 1
	    print("hi")
	    return x
	EOF
	git add . && git commit -qm base && git tag base
	sed -i 's/^def main():$/def foo_setup():\n    fa = 1\n    fb = 2\n    return fa + fb\n\ndef main():/' a.py
	sed -i 's/^    x = 1$/    x = 1\n    foo_retry = 3/' a.py
	git add . && git commit -qm 'add foo block' && git tag foo
	cd - >/dev/null || exit 1
}

SEDT='s/foo_timeout = 5/bar_timeout = 10/'
SEDR='s/foo_retry = 3/bar_retry = 6/'

# --- 1: dup single lines via -s ---------------------------------------------

make_repo "$WORK/t1"; ( cd "$WORK/t1" && "$TOOL" -q -s "$SEDT" -s "$SEDR" )
is "dup: exit code" "$?" 0
is "dup: a.py placement (timeout)" "$(line "$WORK/t1/a.py" 4)" "bar_timeout = 10"
is "dup: a.py placement (retry)"   "$(line "$WORK/t1/a.py" 9)" "    bar_retry = 6"
is "dup: b.py placement (timeout)" "$(line "$WORK/t1/b.py" 4)" "bar_timeout = 10"
is "dup: index untouched" "$(git -C "$WORK/t1" status --porcelain | sort | tr -d '\n')" " M a.py M b.py"

# --- 2: multi-line block stays contiguous, after the original ---------------

make_block_repo "$WORK/t2"
( cd "$WORK/t2" && "$TOOL" -q -s 's/foo_setup/bar_setup/' -s 's/f\([ab]\) =/b\1 =/' -s 's/fa + fb/ba + bb/' )
is "block: exit code" "$?" 0
is "block: first dup line right after original block" "$(line "$WORK/t2/a.py" 9)" "def bar_setup():"
is "block: contiguous" "$(sed -n '9,12p' "$WORK/t2/a.py" | tr '\n' '|')" \
	"def bar_setup():|    ba = 1|    bb = 2|    return ba + bb|"

# --- 3: editor deletes a '+' line; later hunk must still land exactly -------

make_block_repo "$WORK/t3"
cat > "$WORK/ed3" <<'EOF'
#!/bin/sh
sed -i -e '/^+    fb = 2$/d' -e '/^+/{/^+++ /!s/foo_/bar_/;}' "$1"
EOF
chmod +x "$WORK/ed3"
( cd "$WORK/t3" && GIT_EDITOR="$WORK/ed3" "$TOOL" -q )
is "recount: exit code" "$?" 0
is "recount: shortened block placed" "$(sed -n '9,11p' "$WORK/t3/a.py" | tr '\n' '|')" \
	"def bar_setup():|    fa = 1|    return fa + fb|"
is "recount: later hunk not shifted" "$(line "$WORK/t3/a.py" 16)" "    bar_retry = 3"

# --- 4: --staged source ------------------------------------------------------

make_repo "$WORK/t4"
( cd "$WORK/t4" \
	&& git reset -q --hard base \
	&& ins after 'import sys' 'foo_timeout = 5' a.py \
	&& git add a.py \
	&& "$TOOL" -q --staged -s "$SEDT" )
is "staged: exit code" "$?" 0
is "staged: placement" "$(line "$WORK/t4/a.py" 4)" "bar_timeout = 10"
is "staged: status" "$(git -C "$WORK/t4" status --porcelain)" "MM a.py"

# --- 5: stacking a third variant via git add -u + --staged -------------------

make_repo "$WORK/t5"
( cd "$WORK/t5" && "$TOOL" -q -s "$SEDT" -s "$SEDR" \
	&& git add -u \
	&& "$TOOL" -q --staged -s 's/bar_\(.*\) = .*/baz_\1 = 99/' )
is "stack: exit code" "$?" 0
is "stack: foo,bar,baz in order" "$(sed -n '3,5p' "$WORK/t5/a.py" | tr '\n' '|')" \
	"foo_timeout = 5|bar_timeout = 10|baz_timeout = 99|"

# --- 6: plain mode (change absent from the tree) -----------------------------

make_repo "$WORK/t6"
( cd "$WORK/t6" && git checkout -q base && "$TOOL" -q foo -s "$SEDT" -s "$SEDR" )
is "plain: exit code" "$?" 0
is "plain: lands at original location" "$(line "$WORK/t6/a.py" 3)" "bar_timeout = 10"
is "plain: second hunk" "$(line "$WORK/t6/a.py" 7)" "    bar_retry = 6"

# --- 7: empty buffer aborts, tree untouched ----------------------------------

make_repo "$WORK/t7"
printf '#!/bin/sh\n: > "$1"\n' > "$WORK/ed7"; chmod +x "$WORK/ed7"
( cd "$WORK/t7" && GIT_EDITOR="$WORK/ed7" "$TOOL" -q 2>/dev/null )
is "abort: exit code" "$?" 1
clean_tree "$WORK/t7" && ok "abort: tree untouched" || bad "abort: tree untouched"

# --- 8: mangled context -> apply fails atomically -> retry -> abort ----------

make_repo "$WORK/t8"
cat > "$WORK/ed8" <<'EOF'
#!/bin/sh
if grep -q 'APPLY FAILED' "$1"; then : > "$1"; else sed -i 's/foo/bar/g' "$1"; fi
EOF
chmod +x "$WORK/ed8"
( cd "$WORK/t8" && GIT_EDITOR="$WORK/ed8" "$TOOL" -q 2>/dev/null )
is "mangle: aborted via retry loop" "$?" 1
clean_tree "$WORK/t8" && ok "mangle: nothing written" || bad "mangle: nothing written"

# --- 9: invoked from a subdirectory ------------------------------------------

make_repo "$WORK/t9"
( cd "$WORK/t9" && mkdir -p sub && cd sub && "$TOOL" -q -s "$SEDT" -s "$SEDR" )
is "subdir: exit code" "$?" 0
is "subdir: applied at toplevel" "$(line "$WORK/t9/a.py" 4)" "bar_timeout = 10"

# --- 10: pathspec limiting ----------------------------------------------------

make_repo "$WORK/t10"
( cd "$WORK/t10" && "$TOOL" -q -s "$SEDT" -s "$SEDR" -- a.py )
is "pathspec: exit code" "$?" 0
is "pathspec: a.py changed" "$(git -C "$WORK/t10" status --porcelain)" " M a.py"

# --- 11: repatching the same commit twice is refused with guidance -----------

make_repo "$WORK/t11"
( cd "$WORK/t11" && "$TOOL" -q -s "$SEDT" -s "$SEDR" )
err=$( cd "$WORK/t11" && "$TOOL" -q -s "$SEDT" 2>&1 )
is "twice: exit code" "$?" 2
case "$err" in *--staged*) ok "twice: error suggests --staged" ;; *) bad "twice: error suggests --staged ($err)" ;; esac

# --- 12: file created by the source: note + commented section, rest works ----

make_repo "$WORK/t12"
( cd "$WORK/t12" \
	&& printf 'brand new\n' > util.py && git add util.py \
	&& sed -i 's/^    return x$/    return x + 1/' a.py && git add a.py \
	&& git commit -qm 'new file + tweak' )
cat > "$WORK/ed12" <<EOF
#!/bin/sh
cp "\$1" "$WORK/t12.buffer"
: > "\$1"
EOF
chmod +x "$WORK/ed12"
( cd "$WORK/t12" && GIT_EDITOR="$WORK/ed12" "$TOOL" -q 2>/dev/null )
grep -q '^# note: util.py: created by the source change' "$WORK/t12.buffer" \
	&& ok "newfile: note present" || bad "newfile: note present"
grep -q '^# diff --git a/util.py b/util.py' "$WORK/t12.buffer" \
	&& ok "newfile: commented section present" || bad "newfile: commented section present"
grep -q '^# +brand new' "$WORK/t12.buffer" \
	&& ok "newfile: commented payload present" || bad "newfile: commented payload present"

# --- 13: --check writes nothing -----------------------------------------------

make_repo "$WORK/t13"
( cd "$WORK/t13" && "$TOOL" -q --check -s "$SEDT" -s "$SEDR" )
is "check: exit code" "$?" 0
clean_tree "$WORK/t13" && ok "check: tree untouched" || bad "check: tree untouched"

# --- 14: merge commits are refused ---------------------------------------------

make_repo "$WORK/t14"
( cd "$WORK/t14" \
	&& git checkout -q -b side base && sed -i '1i # side' a.py && git commit -qam side \
	&& git checkout -q master 2>/dev/null || git -C "$WORK/t14" checkout -q main \
	&& true )
( cd "$WORK/t14" && git merge -q --no-edit side >/dev/null 2>&1 )
err=$( cd "$WORK/t14" && "$TOOL" -q HEAD 2>&1 )
is "merge: exit code" "$?" 3
case "$err" in *"merge commit"*) ok "merge: explained" ;; *) bad "merge: explained ($err)" ;; esac

# --- 15: binary sections skipped, text still repatches ------------------------

make_repo "$WORK/t15"
( cd "$WORK/t15" \
	&& printf '\000\001\002' > blob.bin && git add blob.bin \
	&& sed -i 's/^    return x$/    return x  # tagged/' a.py && git add a.py \
	&& git commit -qm 'binary + text' )
( cd "$WORK/t15" && "$TOOL" -q -s 's/# tagged/# tagged twice/' 2>/dev/null )
is "binary: exit code" "$?" 0
is "binary: text dup applied" "$(git -C "$WORK/t15" status --porcelain)" " M a.py"

# --- 16: installed as a git subcommand ----------------------------------------

# -h, not --help: git intercepts --help for external commands (man lookup)
out=$(PATH="$TESTS_DIR/..:$PATH" git repatch -h 2>&1)
is "git repatch -h: exit code" "$?" 0
case "$out" in *"usage: git repatch"*) ok "git repatch -h: usage shown" ;; *) bad "git repatch -h: usage shown" ;; esac

# --- 17: no changes -> exit 1 ---------------------------------------------------

make_repo "$WORK/t17"
( cd "$WORK/t17" && "$TOOL" -q --staged 2>/dev/null )
is "no changes: exit code" "$?" 1

# --- 18: file without trailing newline: mid-file dup works --------------------

git init -q "$WORK/t18" && ( cd "$WORK/t18" \
	&& printf 'import os\nfoo_a = 1' > f.py && git add . && git commit -qm one \
	&& printf 'import os\nfoo_mid = 5\nfoo_a = 1' > f.py && git commit -qam two )
( cd "$WORK/t18" && "$TOOL" -q -s 's/foo_mid = 5/bar_mid = 6/' )
is "no-newline: exit code" "$?" 0
is "no-newline: placement" "$(line "$WORK/t18/f.py" 3)" "bar_mid = 6"
[ -n "$(tail -c1 "$WORK/t18/f.py")" ] \
	&& ok "no-newline: EOF still has no newline" || bad "no-newline: EOF still has no newline"

# --- 19: block added at EOF of a no-newline file: skipped with a note ---------

git init -q "$WORK/t19" && ( cd "$WORK/t19" \
	&& printf 'a\nb' > f.txt && git add . && git commit -qm one \
	&& printf 'a\nb\nc' > f.txt && git commit -qam two )
err=$( cd "$WORK/t19" && "$TOOL" -q -s 's/c/d/' 2>&1 )
is "eof-no-newline: exit code" "$?" 1
case "$err" in *"trailing newline"*) ok "eof-no-newline: note surfaced" ;; *) bad "eof-no-newline: note surfaced ($err)" ;; esac
clean_tree "$WORK/t19" && ok "eof-no-newline: tree untouched" || bad "eof-no-newline: tree untouched"

# --- 20: -s that matches nothing is refused (typo guard) ----------------------

make_repo "$WORK/t20"
err=$( cd "$WORK/t20" && "$TOOL" -q -s 's/NO_SUCH_THING/x/' 2>&1 )
is "noop-sed: exit code" "$?" 1
case "$err" in *"matched nothing"*) ok "noop-sed: explained" ;; *) bad "noop-sed: explained ($err)" ;; esac
clean_tree "$WORK/t20" && ok "noop-sed: tree untouched" || bad "noop-sed: tree untouched"

# ------------------------------------------------------------------------------

printf '\n%d tests, %d failed\n' "$N" "$FAILED"
[ "$FAILED" -eq 0 ]
