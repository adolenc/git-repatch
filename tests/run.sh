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
sedi() { # in-place sed, portably (BSD sed's -i wants a suffix argument)
	local e=$1 f; shift
	for f in "$@"; do sed "$e" "$f" > "$f.sedi" && mv "$f.sedi" "$f"; done
}
ins() { # ins before|after <exact line> <text, \n for multi-line> <file>...
	local m=$1 p=$2 t=$3 f; shift 3  # awk -v expands the \n escapes
	for f in "$@"; do
		awk -v m="$m" -v p="$p" -v t="$t" \
			'$0 == p && m == "before" { print t } { print } $0 == p && m == "after" { print t }' \
			"$f" > "$f.ins" && mv "$f.ins" "$f"
	done
}

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
	ins after 'import sys' 'foo_timeout = 5' a.py b.py
	ins after '    x = 1' '    foo_retry = 3' a.py b.py
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
	ins before 'def main():' 'def foo_setup():\n    fa = 1\n    fb = 2\n    return fa + fb\n' a.py
	ins after '    x = 1' '    foo_retry = 3' a.py
	git add . && git commit -qm 'add foo block' && git tag foo
	cd - >/dev/null || exit 1
}

SEDT='s/foo_timeout = 5/bar_timeout = 10/'
SEDR='s/foo_retry = 3/bar_retry = 6/'

# --- 1: dup single lines via -s ---------------------------------------------

make_repo "$WORK/t1"; ( cd "$WORK/t1" && "$TOOL" -q --no-edit -s "$SEDT" -s "$SEDR" )
is "dup: exit code" "$?" 0
is "dup: a.py placement (timeout)" "$(line "$WORK/t1/a.py" 4)" "bar_timeout = 10"
is "dup: a.py placement (retry)"   "$(line "$WORK/t1/a.py" 9)" "    bar_retry = 6"
is "dup: b.py placement (timeout)" "$(line "$WORK/t1/b.py" 4)" "bar_timeout = 10"
is "dup: index untouched" "$(git -C "$WORK/t1" status --porcelain | sort | tr -d '\n')" " M a.py M b.py"

# --- 2: multi-line block stays contiguous, after the original ---------------

make_block_repo "$WORK/t2"
( cd "$WORK/t2" && "$TOOL" -q --no-edit -s 's/foo_setup/bar_setup/' -s 's/f\([ab]\) =/b\1 =/' -s 's/fa + fb/ba + bb/' )
is "block: exit code" "$?" 0
is "block: first dup line right after original block" "$(line "$WORK/t2/a.py" 9)" "def bar_setup():"
is "block: contiguous" "$(sed -n '9,12p' "$WORK/t2/a.py" | tr '\n' '|')" \
	"def bar_setup():|    ba = 1|    bb = 2|    return ba + bb|"

# --- 3: editor deletes a '+' line; later hunk must still land exactly -------

make_block_repo "$WORK/t3"
cat > "$WORK/ed3" <<'EOF'
#!/bin/sh
sed -e '/^+    fb = 2$/d' -e '/^+/{/^+++ /!s/foo_/bar_/;}' "$1" > "$1.n" && mv "$1.n" "$1"
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
	&& "$TOOL" -q --no-edit --staged -s "$SEDT" )
is "staged: exit code" "$?" 0
is "staged: placement" "$(line "$WORK/t4/a.py" 4)" "bar_timeout = 10"
is "staged: status" "$(git -C "$WORK/t4" status --porcelain)" "MM a.py"

# --- 5: stacking a third variant via git add -u + --staged -------------------

make_repo "$WORK/t5"
( cd "$WORK/t5" && "$TOOL" -q --no-edit -s "$SEDT" -s "$SEDR" \
	&& git add -u \
	&& "$TOOL" -q --no-edit --staged -s 's/bar_\(.*\) = .*/baz_\1 = 99/' )
is "stack: exit code" "$?" 0
is "stack: foo,bar,baz in order" "$(sed -n '3,5p' "$WORK/t5/a.py" | tr '\n' '|')" \
	"foo_timeout = 5|bar_timeout = 10|baz_timeout = 99|"

# --- 6: change absent from the tree is refused with guidance ------------------

make_repo "$WORK/t6"
err=$( cd "$WORK/t6" && git checkout -q base && "$TOOL" -q --no-edit foo -s "$SEDT" 2>&1 )
is "absent: exit code" "$?" 2
case "$err" in *absent*) ok "absent: explained" ;; *) bad "absent: explained ($err)" ;; esac
clean_tree "$WORK/t6" && ok "absent: tree untouched" || bad "absent: tree untouched"

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
if grep -q 'APPLY FAILED' "$1"; then : > "$1"; else sed 's/foo/bar/g' "$1" > "$1.n" && mv "$1.n" "$1"; fi
EOF
chmod +x "$WORK/ed8"
( cd "$WORK/t8" && GIT_EDITOR="$WORK/ed8" "$TOOL" -q 2>/dev/null )
is "mangle: aborted via retry loop" "$?" 1
clean_tree "$WORK/t8" && ok "mangle: nothing written" || bad "mangle: nothing written"

# --- 9: invoked from a subdirectory ------------------------------------------

make_repo "$WORK/t9"
( cd "$WORK/t9" && mkdir -p sub && cd sub && "$TOOL" -q --no-edit -s "$SEDT" -s "$SEDR" )
is "subdir: exit code" "$?" 0
is "subdir: applied at toplevel" "$(line "$WORK/t9/a.py" 4)" "bar_timeout = 10"

# --- 10: pathspec limiting ----------------------------------------------------

make_repo "$WORK/t10"
( cd "$WORK/t10" && "$TOOL" -q --no-edit -s "$SEDT" -s "$SEDR" -- a.py )
is "pathspec: exit code" "$?" 0
is "pathspec: a.py changed" "$(git -C "$WORK/t10" status --porcelain)" " M a.py"

# --- 11: repatching the same commit twice is refused with guidance -----------

make_repo "$WORK/t11"
( cd "$WORK/t11" && "$TOOL" -q --no-edit -s "$SEDT" -s "$SEDR" )
err=$( cd "$WORK/t11" && "$TOOL" -q --no-edit -s "$SEDT" 2>&1 )
is "twice: exit code" "$?" 2
case "$err" in *--staged*) ok "twice: error suggests --staged" ;; *) bad "twice: error suggests --staged ($err)" ;; esac

# --- 12: file created by the source: note + commented section, rest works ----

make_repo "$WORK/t12"
( cd "$WORK/t12" \
	&& printf 'brand new\n' > util.py && git add util.py \
	&& sedi 's/^    return x$/    return x + 1/' a.py && git add a.py \
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

# --- 14: merge commits are refused ---------------------------------------------

make_repo "$WORK/t14"
( cd "$WORK/t14" \
	&& git checkout -q -b side base && ins before 'import os' '# side' a.py && git commit -qam side \
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
	&& sedi 's/^    return x$/    return x  # tagged/' a.py && git add a.py \
	&& git commit -qm 'binary + text' )
( cd "$WORK/t15" && "$TOOL" -q --no-edit -s 's/# tagged/# tagged twice/' 2>/dev/null )
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
( cd "$WORK/t18" && "$TOOL" -q --no-edit -s 's/foo_mid = 5/bar_mid = 6/' )
is "no-newline: exit code" "$?" 0
is "no-newline: placement" "$(line "$WORK/t18/f.py" 3)" "bar_mid = 6"
[ -n "$(tail -c1 "$WORK/t18/f.py")" ] \
	&& ok "no-newline: EOF still has no newline" || bad "no-newline: EOF still has no newline"

# --- 19: block added at EOF of a no-newline file: skipped with a note ---------

git init -q "$WORK/t19" && ( cd "$WORK/t19" \
	&& printf 'a\nb' > f.txt && git add . && git commit -qm one \
	&& printf 'a\nb\nc' > f.txt && git commit -qam two )
err=$( cd "$WORK/t19" && "$TOOL" -q --no-edit -s 's/c/d/' 2>&1 )
is "eof-no-newline: exit code" "$?" 1
case "$err" in *"trailing newline"*) ok "eof-no-newline: note surfaced" ;; *) bad "eof-no-newline: note surfaced ($err)" ;; esac
clean_tree "$WORK/t19" && ok "eof-no-newline: tree untouched" || bad "eof-no-newline: tree untouched"

# --- 20: --no-edit -s that matches nothing is refused (typo guard) ------------

make_repo "$WORK/t20"
err=$( cd "$WORK/t20" && "$TOOL" -q --no-edit -s 's/NO_SUCH_THING/x/' 2>&1 )
is "noop-sed: exit code" "$?" 1
case "$err" in *"matched nothing"*) ok "noop-sed: explained" ;; *) bad "noop-sed: explained ($err)" ;; esac
clean_tree "$WORK/t20" && ok "noop-sed: tree untouched" || bad "noop-sed: tree untouched"

# --- 21: -U extra context is display-only '#c' lines --------------------------

git init -q "$WORK/t21" && ( cd "$WORK/t21" \
	&& printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\nl13\nl14\n' > f.txt \
	&& git add . && git commit -qm base \
	&& ins after 'l7' 'foo_x = 1' f.txt \
	&& git commit -qam 'add foo_x' )
cat > "$WORK/ed21" <<EOF
#!/bin/sh
cp "\$1" "$WORK/t21.buffer"
: > "\$1"
EOF
chmod +x "$WORK/ed21"
( cd "$WORK/t21" && GIT_EDITOR="$WORK/ed21" "$TOOL" -q --unified=6 2>/dev/null )
is "unified: live hunk unchanged by -U6" "$(grep -m1 '^@@ ' "$WORK/t21.buffer")" "@@ -5,7 +5,8 @@"
is "unified: 3 '#c' lines each side" "$(grep -c '^#c' "$WORK/t21.buffer")" 6
is "unified: first '#c' line" "$(grep -m1 '^#c' "$WORK/t21.buffer")" "#c l2"
( cd "$WORK/t21" && GIT_EDITOR="$WORK/ed21" "$TOOL" -q 2>/dev/null )
is "unified: default buffer has no '#c'" "$(grep -c '^#c' "$WORK/t21.buffer")" 0
( cd "$WORK/t21" && "$TOOL" -q --no-edit -U9 -s 's/foo_x = 1/bar_x = 2/' )
is "unified: -U9 end-to-end exit code" "$?" 0
is "unified: -U9 placement" "$(line "$WORK/t21/f.txt" 9)" "bar_x = 2"

# two changes far enough apart for separate hunks, close enough that their
# -U9 comment windows collide: every file line must render exactly once
git init -q "$WORK/t21b" && ( cd "$WORK/t21b" \
	&& printf 'm1\nm2\nm3\nm4\nm5\nm6\nm7\nm8\nm9\nm10\nm11\nm12\nm13\nm14\nm15\nm16\nm17\nm18\nm19\nm20\n' > g.txt \
	&& git add . && git commit -qm base \
	&& ins after 'm4' 'foo_a = 1' g.txt \
	&& ins after 'm12' 'foo_b = 1' g.txt \
	&& git commit -qam 'two knobs' )
cat > "$WORK/ed21b" <<EOF
#!/bin/sh
cp "\$1" "$WORK/t21b.buffer"
: > "\$1"
EOF
chmod +x "$WORK/ed21b"
( cd "$WORK/t21b" && GIT_EDITOR="$WORK/ed21b" "$TOOL" -q -U9 2>/dev/null )
is "unified: hunks stay separate under -U9" "$(grep -c '^@@ ' "$WORK/t21b.buffer")" 2
is "unified: no file line rendered twice" \
	"$(sed -n 's/^#c //p;s/^ //p' "$WORK/t21b.buffer" | sort | uniq -d | wc -l | tr -d ' ')" 0

err=$( cd "$WORK/t21" && "$TOOL" -q -U 2 2>&1 )
is "unified: -U2 refused" "$?" 3
case "$err" in *"at least 3"*) ok "unified: -U2 explained" ;; *) bad "unified: -U2 explained ($err)" ;; esac
err=$( cd "$WORK/t21" && "$TOOL" -q --unified=lots 2>&1 )
is "unified: non-numeric refused" "$?" 3

# --- 22: -s pre-seeds the buffer, then the editor still opens -----------------

make_repo "$WORK/t22"
cat > "$WORK/ed22" <<EOF
#!/bin/sh
echo \$# > "$WORK/t22.argc"
cp "\$1" "$WORK/t22.buffer"
touch "\$1"   # save without changes
EOF
chmod +x "$WORK/ed22"
( cd "$WORK/t22" && GIT_EDITOR="$WORK/ed22" "$TOOL" -q -s "$SEDT" -s "$SEDR" )
is "sed+editor: exit code" "$?" 0
grep -q '^+bar_timeout = 10$' "$WORK/t22.buffer" \
	&& ok "sed+editor: buffer already sedded" || bad "sed+editor: buffer already sedded"
[ -f "$WORK/t22.argc" ] && is "sed+editor: non-vim editor gets no extra args" "$(cat "$WORK/t22.argc")" 1
is "sed+editor: applied after editor save" "$(line "$WORK/t22/a.py" 4)" "bar_timeout = 10"

# --- 23: --no-edit without -s duplicates verbatim -----------------------------

make_repo "$WORK/t23"
( cd "$WORK/t23" && "$TOOL" -q --no-edit )
is "no-edit: exit code" "$?" 0
is "no-edit: verbatim duplicate" "$(sed -n '3,4p' "$WORK/t23/a.py" | tr '\n' '|')" \
	"foo_timeout = 5|foo_timeout = 5|"

# --- 24: quitting the editor without saving aborts ----------------------------

make_repo "$WORK/t24"
printf '#!/bin/sh\nexit 0\n' > "$WORK/ed24"; chmod +x "$WORK/ed24"
err=$( cd "$WORK/t24" && GIT_EDITOR="$WORK/ed24" "$TOOL" -q 2>&1 )
is "unsaved: exit code" "$?" 1
case "$err" in *"not saved"*) ok "unsaved: explained" ;; *) bad "unsaved: explained ($err)" ;; esac
clean_tree "$WORK/t24" && ok "unsaved: tree untouched" || bad "unsaved: tree untouched"

# save a broken edit, then quit the retry round without saving: still aborts
cat > "$WORK/ed24b" <<'EOF'
#!/bin/sh
if grep -q 'APPLY FAILED' "$1"; then exit 0; fi
sed 's/foo/bar/g' "$1" > "$1.n" && mv "$1.n" "$1"
EOF
chmod +x "$WORK/ed24b"
( cd "$WORK/t24" && GIT_EDITOR="$WORK/ed24b" "$TOOL" -q 2>/dev/null )
is "unsaved retry: exit code" "$?" 1
clean_tree "$WORK/t24" && ok "unsaved retry: tree untouched" || bad "unsaved retry: tree untouched"

# --- 25: a vim-family editor is handed -c 'set modified' (pre-dirtying) -------

make_repo "$WORK/t25"
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/nvim" <<'EOF'
#!/bin/sh
[ "$1" = "-c" ] && [ "$2" = "set modified" ] || exit 7
touch "$3"   # a dirtied buffer means :x/ZZ write even with no edits
EOF
chmod +x "$WORK/fakebin/nvim"
( cd "$WORK/t25" && GIT_EDITOR="$WORK/fakebin/nvim" "$TOOL" -q )
is "vim dirty: exit code" "$?" 0
is "vim dirty: verbatim duplicate applied" "$(line "$WORK/t25/a.py" 4)" "foo_timeout = 5"

# ------------------------------------------------------------------------------

printf '\n%d tests, %d failed\n' "$N" "$FAILED"
[ "$FAILED" -eq 0 ]
