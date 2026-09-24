#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh" "$1"

# ============================================================================
# Golden pins (tests 2000-2011; 2012-2016 cover what the diff-source
# refactor changed on purpose): byte-exact records of what git-hunk prints,
# and of what it hands to `git apply`, for every diff source and every kind of
# file section. They were taken from the binary as it stood before the
# file-section and diff-source refactors, which must leave hashes, ranges and
# unfiltered patches byte-identical. A refactor that changes one of these on
# purpose updates the one block pinning it, and says so.
#
# Blob ids in `index` lines depend on the object format (SHA-1 or SHA-256, see
# the git3-defaults hostile profile), so expected patches name them with
# tokens resolved against the repo (see golden_expand). Hunk hashes are
# git-hunk's own SHA-1 over path and content, the same under either format,
# and are written out literally -- except a binary file's, whose content is
# its blob ids, so it is a token too.
#
# Listings are sorted before comparing: the pager hostile profile sets
# diff.orderFile, which reorders files in git's output without changing a hash.
# ============================================================================

# One distinct line per number, so no two lines of the fixture are alike and
# every diff algorithm (see the algorithm hostile profile) aligns them the same.
lines() {
    local i
    for ((i = $2; i <= $3; i++)); do printf '%s line %02d of the golden fixture\n' "$1" "$i"; done
}

ACCENT="$(printf 'h\303\251llo.txt')"

# History shared by every scenario:
#
#   R ── C1 ── C2   (HEAD; C1 edits mod.txt line 15, C2 edits other.txt line 3)
#          └── S    (branch `side`; adds side.txt)
#
# R is the root commit. R...side is S plus C1, HEAD...side is S alone, and
# HEAD..side also reverts C2 -- so the three-dot and two-dot forms differ.
build_template() {
    git init -q "$1"
    cd "$1"
    git config user.email "test@git-hunk.test"
    git config user.name "git-hunk test"
    # Auto-maintenance detaches after a commit; its lock file vanishing
    # mid-copy made golden_repo's `cp -R` fail at random.
    git config maintenance.auto false
    git config gc.auto 0
    lines mod 1 30 > mod.txt
    lines gonestaged 1 6 > gone-staged.txt
    lines gonewt 1 6 > gone-wt.txt
    lines renamed 1 12 > old-name.txt
    printf 'bin\000ary\001v1\n' > bin.dat
    printf 'target a\n' > target-a
    printf 'target b\n' > target-b
    ln -s target-a link
    lines typechange 1 4 > tc.txt
    lines accent 1 6 > "$ACCENT"
    lines other 1 6 > other.txt
    git add -A
    git commit -q -m "R: root"
    git tag R
    lines mod 1 30 | sed 's/^mod line 15 .*/mod line 15 changed in C1/' > mod.txt
    git commit -q -am "C1: edit mod.txt"
    git tag C1
    git switch -q -c side
    lines side 1 4 > side.txt
    git add side.txt
    git commit -q -m "S: add side.txt"
    git switch -q -
    lines other 1 6 | sed 's/^other line 03 .*/other line 03 changed in C2/' > other.txt
    git commit -q -am "C2: edit other.txt"
    git tag C2
    cd /
}

# Every kind of section at once, none sharing a path: unstaged edits, deletion,
# binary, symlink retarget, file->symlink typechange and a non-ASCII path;
# staged new, empty, deleted and renamed-with-edit files; untracked text,
# empty and symlink files.
mixed_state() {
    lines mod 1 30 | sed -e 's/^mod line 15 .*/mod line 15 changed in C1/' \
        -e 's/^mod line 05 .*/mod line 05 edited in worktree/' \
        -e 's/^mod line 25 .*/mod line 25 edited in worktree/' > mod.txt
    rm gone-wt.txt
    printf 'bin\000ary\001v2\n' > bin.dat
    rm link && ln -s target-b link
    rm tc.txt && ln -s target-a tc.txt
    lines accent 1 6 | sed 's/^accent line 04 .*/accent line 04 edited in worktree/' > "$ACCENT"
    lines new 1 3 > new.txt
    : > empty.txt
    git add new.txt empty.txt
    git rm -q gone-staged.txt
    git mv old-name.txt new-name.txt
    lines renamed 1 12 | sed 's/^renamed line 06 .*/renamed line 06 changed by the rename/' > new-name.txt
    git add new-name.txt
    lines untracked 1 2 > u.txt
    : > u-empty.txt
    ln -s target-a u-link
}

# The new, empty and renamed files of mixed_state as intent-to-add entries,
# which puts them in the unstaged diff where `add` can stage them.
intent_to_add_state() {
    lines new 1 3 > new.txt
    : > empty.txt
    mv old-name.txt new-name.txt
    lines renamed 1 12 | sed 's/^renamed line 06 .*/renamed line 06 changed by the rename/' > new-name.txt
    git add -N new.txt empty.txt new-name.txt
}

GOLDEN_TEMPLATE="$(mktemp -d)"
SHIM_DIR="$(mktemp -d)"
trap 'cleanup_repo; rm -rf "$GOLDEN_TEMPLATE" "$SHIM_DIR"' EXIT
build_template "$GOLDEN_TEMPLATE/repo"
cp "$SCRIPT_DIR/git-shim.sh" "$SHIM_DIR/git"
chmod +x "$SHIM_DIR/git"
TEE="$SHIM_DIR/tee"

# A fresh copy of the template with the named state functions applied.
golden_repo() {
    cleanup_repo
    CURRENT_REPO="$(mktemp -d)"
    cp -R "$GOLDEN_TEMPLATE/repo/." "$CURRENT_REPO"
    cd "$CURRENT_REPO"
    # The copy has new inodes; refresh so no clean path reads as stat-dirty.
    git update-index -q --refresh > /dev/null || true
    local state
    for state in "$@"; do "$state"; done
}

# Run git-hunk with each patch it hands `git apply` saved as $TEE/apply.<N>.patch.
tee_hunk() {
    rm -rf "$TEE"
    mkdir "$TEE"
    PATH="$SHIM_DIR:$PATH" GIT_HUNK_SHIM_TEE="$TEE" "$GIT_HUNK" "$@"
}

# The C-quoted form git gives the non-ASCII path in patch headers, or the raw
# bytes under core.quotePath=false (the quotepath hostile profile).
accent_path() {
    if [[ "$(git config --bool core.quotePath 2>/dev/null || true)" == false ]]; then
        printf '%s/%s' "$1" "$ACCENT"
    else
        printf '"%s/h\\303\\251llo.txt"' "$1"
    fi
}

# git-hunk's hash of a binary change to <path> between blobs <old> and <new>:
# SHA-1 over the path, line 0 and the blob ids of the section's index line.
binary_hash() {
    printf '%s\0%s\0binary %s..%s' "$1" 0 "$2" "$3" \
        | if command -v sha1sum > /dev/null; then sha1sum; else shasum -a 1; fi | cut -c1-7
}

# stdin -> stdout, replacing object-format dependent tokens with this repo's
# values. Resolve before the command under test changes the index.
#   {head:P}   blob id of P at HEAD         {file:P}  blob id of worktree file P
#   {str:S}    blob id of the bytes S       {zero}    the all-zero object id
#   {acc:a} {acc:b}                         the non-ASCII path, see accent_path
#   {bin:P}      hash of P's binary change, index to worktree
#   {binroot:P}  hash of P's binary creation in the root commit R
golden_expand() {
    local text tok kind arg val
    text="$(cat; printf .)"
    text="${text%.}"
    local re='\{(head|file|str|zero|acc|binroot|bin):?([^}]*)\}'
    while [[ "$text" =~ $re ]]; do
        tok="${BASH_REMATCH[0]}"
        kind="${BASH_REMATCH[1]}"
        arg="${BASH_REMATCH[2]}"
        case "$kind" in
            head) val="$(git rev-parse "HEAD:$arg")" ;;
            file) val="$(git hash-object -- "$arg")" ;;
            str) val="$(printf '%s' "$arg" | git hash-object --stdin)" ;;
            zero) val="$(git rev-parse HEAD | tr '0-9a-f' '0')" ;;
            acc) val="$(accent_path "$arg")" ;;
            bin) val="$(binary_hash "$arg" "$(git rev-parse ":$arg")" "$(git hash-object -- "$arg")")" ;;
            binroot) val="$(binary_hash "$arg" "$(git rev-parse HEAD | tr '0-9a-f' '0')" "$(git rev-parse "R:$arg")")" ;;
        esac
        text="${text//"$tok"/"$val"}"
    done
    printf '%s' "$text"
}

# Compare two files byte for byte; on mismatch, fail with a unified diff.
check_bytes() {
    local label="$1" want="$2" got="$3"
    cmp -s "$want" "$got" && return 0
    fail "$label: bytes differ (--- want, +++ got):"$'\n'"$(diff -u "$want" "$got" || true)"
}

# Compare two strings; on mismatch, fail with a unified diff.
check_text() {
    local label="$1" want="$2" got="$3"
    [[ "$want" == "$got" ]] && return 0
    fail "$label: output differs (--- want, +++ got):"$'\n'"$(diff -u <(printf '%s\n' "$want") <(printf '%s\n' "$got") || true)"
}

# `list --porcelain --oneline <args>` against the expected lines on stdin,
# expanded by golden_expand, both sorted (see the header).
check_list() {
    local label="$1"
    shift
    local want got
    want="$(golden_expand | LC_ALL=C sort)"
    got="$("$GIT_HUNK" list --porcelain --oneline "$@" | LC_ALL=C sort)"
    check_text "$label: list $*" "$want" "$got"
}

# Tests 2000-2003 read one repo in the mixed state and never change it.
golden_repo mixed_state

# ============================================================================
# Test 2000: list pins, worktree source: tracked and untracked, and each filter
# ============================================================================
check_list "test 2000" <<'EOF'
0e58f0b	u-empty.txt	0	0	new file
27a3329	mod.txt	2	8	mod line 05 of the golden fixture
293154f	link@	1	1	target-a
2b987ac	gone-wt.txt	0	0	deleted
3477055	u-link@	1	1	new file
5f6b3e9	tc.txt@	1	1	new file
{bin:bin.dat}	bin.dat	0	0	binary
810dfd6	u.txt	1	2	new file
b8f50d4	tc.txt	0	0	deleted
d98411e	héllo.txt	1	6	accent line 04 of the golden fixture
f7c1445	mod.txt	22	28	mod line 25 of the golden fixture
EOF
check_list "test 2000" --tracked-only <<'EOF'
27a3329	mod.txt	2	8	mod line 05 of the golden fixture
293154f	link@	1	1	target-a
2b987ac	gone-wt.txt	0	0	deleted
5f6b3e9	tc.txt@	1	1	new file
{bin:bin.dat}	bin.dat	0	0	binary
b8f50d4	tc.txt	0	0	deleted
d98411e	héllo.txt	1	6	accent line 04 of the golden fixture
f7c1445	mod.txt	22	28	mod line 25 of the golden fixture
EOF
check_list "test 2000" --untracked-only <<'EOF'
0e58f0b	u-empty.txt	0	0	new file
3477055	u-link@	1	1	new file
810dfd6	u.txt	1	2	new file
EOF
pass "test 2000: worktree listings pinned (default, --tracked-only, --untracked-only)"

# ============================================================================
# Test 2001: list pins, context width: -U0 trims every hunk to its changed
# lines; -U10 merges mod.txt's two hunks into one
# ============================================================================
check_list "test 2001" -U0 <<'EOF'
0e58f0b	u-empty.txt	0	0	new file
293154f	link@	1	1	target-a
2b987ac	gone-wt.txt	0	0	deleted
3477055	u-link@	1	1	new file
46f63a7	héllo.txt	4	4	accent line 04 of the golden fixture
5ab9db8	mod.txt	25	25	mod line 25 of the golden fixture
5f6b3e9	tc.txt@	1	1	new file
{bin:bin.dat}	bin.dat	0	0	binary
810dfd6	u.txt	1	2	new file
b8f50d4	tc.txt	0	0	deleted
e53d435	mod.txt	5	5	mod line 05 of the golden fixture
EOF
check_list "test 2001" -U10 <<'EOF'
0e58f0b	u-empty.txt	0	0	new file
293154f	link@	1	1	target-a
2b987ac	gone-wt.txt	0	0	deleted
3477055	u-link@	1	1	new file
5f6b3e9	tc.txt@	1	1	new file
{bin:bin.dat}	bin.dat	0	0	binary
810dfd6	u.txt	1	2	new file
b8f50d4	tc.txt	0	0	deleted
d98411e	héllo.txt	1	6	accent line 04 of the golden fixture
fc6340f	mod.txt	1	30	mod line 05 of the golden fixture
EOF
pass "test 2001: -U0 and -U10 listings pinned"

# ============================================================================
# Test 2002: list pins, index sources: old-anchored ranges (a deletion keeps
# its range, a new file reads 0 0)
# ============================================================================
check_list "test 2002" --staged <<'EOF'
af6a5e1	new.txt	0	0	new file
b02cd0b	empty.txt	0	0	new file
b34f350	new-name.txt	3	9	renamed line 06 of the golden fixture
e2fe77c	gone-staged.txt	1	6	deleted
EOF
check_list "test 2002" --staged --ref R <<'EOF'
0adc154	mod.txt	12	18	mod line 15 of the golden fixture
af6a5e1	new.txt	0	0	new file
b02cd0b	empty.txt	0	0	new file
b34f350	new-name.txt	3	9	renamed line 06 of the golden fixture
bd8ab1d	other.txt	1	6	other line 03 of the golden fixture
e2fe77c	gone-staged.txt	1	6	deleted
EOF
check_list "test 2002" --staged --ref HEAD~1 <<'EOF'
af6a5e1	new.txt	0	0	new file
b02cd0b	empty.txt	0	0	new file
b34f350	new-name.txt	3	9	renamed line 06 of the golden fixture
bd8ab1d	other.txt	1	6	other line 03 of the golden fixture
e2fe77c	gone-staged.txt	1	6	deleted
EOF
pass "test 2002: --staged, --staged --ref R and --staged --ref HEAD~1 listings pinned"

# ============================================================================
# Test 2003: list pins, commit and range sources, including the root commit
# and A...B against A..B
# ============================================================================
check_list "test 2003" --ref HEAD <<'EOF'
bd8ab1d	other.txt	1	6	other line 03 of the golden fixture
EOF
check_list "test 2003" --ref R <<'EOF'
22d7e6a	link@	1	1	new file
386b1d0	gone-staged.txt	1	6	new file
7e3bc63	gone-wt.txt	1	6	new file
{binroot:bin.dat}	bin.dat	0	0	new binary file
b55199d	target-b	1	1	new file
c242648	target-a	1	1	new file
cb0fb8f	other.txt	1	6	new file
cde95e9	héllo.txt	1	6	new file
da22ee3	tc.txt	1	4	new file
dabc72f	old-name.txt	1	12	new file
dd76e39	mod.txt	1	30	new file
EOF
check_list "test 2003" --ref R..HEAD <<'EOF'
0adc154	mod.txt	12	18	mod line 15 of the golden fixture
bd8ab1d	other.txt	1	6	other line 03 of the golden fixture
EOF
check_list "test 2003" --ref R...side <<'EOF'
0adc154	mod.txt	12	18	mod line 15 of the golden fixture
70e617d	side.txt	1	4	new file
EOF
check_list "test 2003" --ref HEAD...side <<'EOF'
70e617d	side.txt	1	4	new file
EOF
check_list "test 2003" --ref HEAD..side <<'EOF'
668335b	other.txt	1	6	other line 03 changed in C2
70e617d	side.txt	1	4	new file
EOF
pass "test 2003: --ref commit, root-commit, two-dot and three-dot listings pinned"

# ============================================================================
# Test 2004: result-group porcelain after add and reset -- the hash each
# selection lands as on the other side. Adding a rename lands as the same
# rename; resetting one leaves the old path deleted and the new one
# untracked, and both are its result.
# ============================================================================
check_result() {
    local label="$1" want="$2"
    shift 2
    check_text "$label: git-hunk $*" "$want" "$("$GIT_HUNK" "$@" --porcelain)"
}
golden_repo mixed_state
check_result "test 2004" $'staged\t27a3329\t27a3329\tmod.txt' add 27a3329
golden_repo mixed_state
check_result "test 2004" $'staged\tf7c1445:5\t7020c96\tmod.txt' add f7c1445:5
golden_repo mixed_state
check_result "test 2004" $'staged\t810dfd6:2\ta2a38f1\tu.txt' add 810dfd6:2
golden_repo mixed_state
check_result "test 2004" $'unstaged\te2fe77c\tc257e99\tgone-staged.txt' reset e2fe77c
golden_repo mixed_state
check_result "test 2004" $'unstaged\tb34f350\t7c745cd,aa914db\tnew-name.txt' reset b34f350
golden_repo intent_to_add_state
check_result "test 2004" $'staged\tb34f350\tb34f350\tnew-name.txt' add b34f350
pass "test 2004: result groups of add <sha>, add <sha>:<line> and reset <sha> pinned"

# ============================================================================
# The unfiltered patch text of each kind of section, as git-hunk hands it to
# `git apply` and as `diff <sha>` shows it (plus one trailing blank line).
# Tokens in braces are resolved by golden_expand.
# ============================================================================
patch_text() {
    case "$1" in
        mod) cat <<'EOT'
diff --git a/mod.txt b/mod.txt
index {head:mod.txt}..{file:mod.txt} 100644
--- a/mod.txt
+++ b/mod.txt
@@ -2,7 +2,7 @@ mod line 01 of the golden fixture
 mod line 02 of the golden fixture
 mod line 03 of the golden fixture
 mod line 04 of the golden fixture
-mod line 05 of the golden fixture
+mod line 05 edited in worktree
 mod line 06 of the golden fixture
 mod line 07 of the golden fixture
 mod line 08 of the golden fixture
EOT
        ;;
        deleted) cat <<'EOT'
diff --git a/gone-wt.txt b/gone-wt.txt
deleted file mode 100644
index {head:gone-wt.txt}..{zero}
--- a/gone-wt.txt
+++ /dev/null
@@ -1,6 +0,0 @@
-gonewt line 01 of the golden fixture
-gonewt line 02 of the golden fixture
-gonewt line 03 of the golden fixture
-gonewt line 04 of the golden fixture
-gonewt line 05 of the golden fixture
-gonewt line 06 of the golden fixture
EOT
        ;;
        accent) cat <<'EOT'
diff --git {acc:a} {acc:b}
index {head:héllo.txt}..{file:héllo.txt} 100644
--- {acc:a}
+++ {acc:b}
@@ -1,6 +1,6 @@
 accent line 01 of the golden fixture
 accent line 02 of the golden fixture
 accent line 03 of the golden fixture
-accent line 04 of the golden fixture
+accent line 04 edited in worktree
 accent line 05 of the golden fixture
 accent line 06 of the golden fixture
EOT
        ;;
        symlink) cat <<'EOT'
diff --git a/link b/link
index {head:link}..{str:target-b} 120000
--- a/link
+++ b/link
@@ -1 +1 @@
-target-a
\ No newline at end of file
+target-b
\ No newline at end of file
EOT
        ;;
        typechange-delete) cat <<'EOT'
diff --git a/tc.txt b/tc.txt
deleted file mode 100644
index {head:tc.txt}..{zero}
--- a/tc.txt
+++ /dev/null
@@ -1,4 +0,0 @@
-typechange line 01 of the golden fixture
-typechange line 02 of the golden fixture
-typechange line 03 of the golden fixture
-typechange line 04 of the golden fixture
EOT
        ;;
        typechange-create) cat <<'EOT'
diff --git a/tc.txt b/tc.txt
new file mode 120000
index {zero}..{str:target-a}
--- /dev/null
+++ b/tc.txt
@@ -0,0 +1 @@
+target-a
\ No newline at end of file
EOT
        ;;
        binary) cat <<'EOT'
diff --git a/bin.dat b/bin.dat
index {head:bin.dat}..{file:bin.dat} 100644
Binary file changed

EOT
        ;;
        untracked) cat <<'EOT'
diff --git a/u.txt b/u.txt
new file mode 100644
index {zero}..{file:u.txt}
--- /dev/null
+++ b/u.txt
@@ -0,0 +1,2 @@
+untracked line 01 of the golden fixture
+untracked line 02 of the golden fixture
EOT
        ;;
        untracked-empty) cat <<'EOT'
diff --git a/u-empty.txt b/u-empty.txt
new file mode 100644
index {zero}..{file:u-empty.txt}
EOT
        ;;
        untracked-symlink) cat <<'EOT'
diff --git a/u-link b/u-link
new file mode 120000
index {zero}..{str:target-a}
--- /dev/null
+++ b/u-link
@@ -0,0 +1 @@
+target-a
\ No newline at end of file
EOT
        ;;
        staged-deleted) cat <<'EOT'
diff --git a/gone-staged.txt b/gone-staged.txt
deleted file mode 100644
index {head:gone-staged.txt}..{zero}
--- a/gone-staged.txt
+++ /dev/null
@@ -1,6 +0,0 @@
-gonestaged line 01 of the golden fixture
-gonestaged line 02 of the golden fixture
-gonestaged line 03 of the golden fixture
-gonestaged line 04 of the golden fixture
-gonestaged line 05 of the golden fixture
-gonestaged line 06 of the golden fixture
EOT
        ;;
        new) cat <<'EOT'
diff --git a/new.txt b/new.txt
new file mode 100644
index {zero}..{file:new.txt}
--- /dev/null
+++ b/new.txt
@@ -0,0 +1,3 @@
+new line 01 of the golden fixture
+new line 02 of the golden fixture
+new line 03 of the golden fixture
EOT
        ;;
        empty) cat <<'EOT'
diff --git a/empty.txt b/empty.txt
new file mode 100644
index {zero}..{file:empty.txt}
EOT
        ;;
        rename) cat <<'EOT'
diff --git a/old-name.txt b/new-name.txt
rename from old-name.txt
rename to new-name.txt
index {head:old-name.txt}..{file:new-name.txt} 100644
--- a/old-name.txt
+++ b/new-name.txt
@@ -3,7 +3,7 @@ renamed line 02 of the golden fixture
 renamed line 03 of the golden fixture
 renamed line 04 of the golden fixture
 renamed line 05 of the golden fixture
-renamed line 06 of the golden fixture
+renamed line 06 changed by the rename
 renamed line 07 of the golden fixture
 renamed line 08 of the golden fixture
 renamed line 09 of the golden fixture
EOT
        ;;
        *) echo "patch_text: unknown kind '$1'" >&2; return 1 ;;
    esac
}

# check_applied <label> <kind>... -- <git-hunk args>: run git-hunk with the tee
# on; the patches it handed `git apply` must be exactly those kinds, in order.
check_applied() {
    local label="$1"
    shift
    local kinds=() k n=0 i
    while [[ "$1" != "--" ]]; do kinds+=("$1"); shift; done
    shift
    for k in ${kinds[@]+"${kinds[@]}"}; do
        n=$((n + 1))
        patch_text "$k" | golden_expand > "$SHIM_DIR/want.$n"
    done
    local rc=0
    tee_hunk "$@" > /dev/null || rc=$?
    [[ "$rc" -eq 0 ]] || fail "$label: git-hunk $* exited $rc"
    local got
    got="$(ls "$TEE" | wc -l | tr -d ' ')"
    [[ "$got" -eq "$n" ]] || fail "$label: git-hunk $* ran git apply $got times, want $n"
    for ((i = 1; i <= n; i++)); do
        check_bytes "$label: patch $i of git-hunk $*" "$SHIM_DIR/want.$i" "$TEE/apply.$i.patch"
    done
}

# ============================================================================
# Test 2005: patches `add` hands git apply for each unstaged kind (forward).
# Each add touches only its own path, so they run in turn in one repo. A
# typechange is two patches, delete before create; a binary file is staged
# with `git add`, never through git apply.
# ============================================================================
golden_repo mixed_state
check_applied "test 2005" mod -- add 27a3329
check_applied "test 2005" deleted -- add 2b987ac
check_applied "test 2005" accent -- add d98411e
check_applied "test 2005" symlink -- add 293154f
check_applied "test 2005" typechange-delete typechange-create -- add b8f50d4 5f6b3e9
check_applied "test 2005" untracked -- add 810dfd6
check_applied "test 2005" untracked-empty -- add 0e58f0b
check_applied "test 2005" untracked-symlink -- add 3477055
check_applied "test 2005" -- add "$(printf '{bin:bin.dat}' | golden_expand)"
pass "test 2005: unfiltered add patches pinned for every unstaged kind"

# ============================================================================
# Test 2006: patches `add` hands git apply for a new file, an empty new file
# and a rename with an edit, reached through intent-to-add entries.
# ============================================================================
golden_repo intent_to_add_state
check_applied "test 2006" new -- add 2e718d7
check_applied "test 2006" empty -- add b02cd0b
check_applied "test 2006" rename -- add b34f350
pass "test 2006: unfiltered add patches pinned for new, empty and renamed files"

# ============================================================================
# Test 2007: patches `reset` hands git apply (with --reverse) for each staged
# kind. They are the forward patches; git apply reverses them.
# ============================================================================
golden_repo mixed_state
check_applied "test 2007" staged-deleted -- reset e2fe77c
check_applied "test 2007" new -- reset af6a5e1
check_applied "test 2007" empty -- reset b02cd0b
check_applied "test 2007" rename -- reset b34f350
pass "test 2007: unfiltered reset patches pinned for every staged kind"

# ============================================================================
# Test 2008: `diff <sha> --no-color` for each kind: the patch text plus one
# blank line (a binary section shows its placeholder line instead of a body).
# ============================================================================
check_diff() {
    local label="$1" kind="$2"
    shift 2
    { patch_text "$kind"; echo; } | golden_expand > "$SHIM_DIR/want.diff"
    "$GIT_HUNK" diff --no-color "$@" > "$SHIM_DIR/got.diff" 2>&1 || fail "$label: git-hunk diff $* exited $?"
    check_bytes "$label: git-hunk diff --no-color $*" "$SHIM_DIR/want.diff" "$SHIM_DIR/got.diff"
}
golden_repo mixed_state
check_diff "test 2008" mod 27a3329
check_diff "test 2008" deleted 2b987ac
check_diff "test 2008" accent d98411e
check_diff "test 2008" symlink 293154f
check_diff "test 2008" typechange-delete b8f50d4
check_diff "test 2008" typechange-create 5f6b3e9
check_diff "test 2008" binary "$(printf '{bin:bin.dat}' | golden_expand)"
check_diff "test 2008" untracked 810dfd6
check_diff "test 2008" untracked-empty 0e58f0b
check_diff "test 2008" untracked-symlink 3477055
check_diff "test 2008" staged-deleted --staged e2fe77c
check_diff "test 2008" new --staged af6a5e1
check_diff "test 2008" empty --staged b02cd0b
check_diff "test 2008" rename --staged b34f350
pass "test 2008: diff --no-color output pinned for every kind"

# check_error <label> <exit> <stderr> <git-hunk args>: exact exit code and
# stderr. Stdout is not compared: parse errors also print usage there.
check_error() {
    local label="$1" want_rc="$2" want_err="$3"
    shift 3
    local rc=0 err
    err="$("$GIT_HUNK" "$@" 2>&1 > /dev/null)" || rc=$?
    [[ "$rc" -eq "$want_rc" ]] || fail "$label: git-hunk $* exited $rc, want $want_rc"
    check_text "$label: stderr of git-hunk $*" "$want_err" "$err"
}

# ============================================================================
# Test 2009: which error wins when flags touching --ref/--staged conflict.
# The diff-source refactor moves this validation; the order must survive it.
# ============================================================================
golden_repo mixed_state
RANGE_ERR="error: --staged compares the index with one commit; 'R..HEAD' is a range"
check_error "test 2009" 1 "$RANGE_ERR" diff --staged --ref R..HEAD
check_error "test 2009" 1 "$RANGE_ERR" diff --staged --ref R..HEAD 27a3329
check_error "test 2009" 1 "$RANGE_ERR" check --staged --ref R..HEAD
check_error "test 2009" 1 "$RANGE_ERR" check --staged --ref R..HEAD --allow-empty
check_error "test 2009" 1 "$RANGE_ERR" list --ref R..HEAD --staged
check_error "test 2009" 1 "error: unknown flag '--bogus'" list --bogus --staged --ref R..HEAD
check_error "test 2009" 1 "error: --tracked-only and --untracked-only are mutually exclusive" \
    list --tracked-only --untracked-only --staged --ref R..HEAD
check_error "test 2009" 1 "error: --3way is not supported for this subcommand (only add, reset, restore, commit)" \
    stash --ref C1 --3way
check_error "test 2009" 1 "error: unknown flag '--staged'" add --staged
check_error "test 2009" 1 "error: --staged is not supported by commit -- use 'git commit' directly" commit --staged
check_error "test 2009" 1 "error: bad revision 'nope'" add --ref nope 27a3329
pass "test 2009: error precedence pinned for --ref/--staged flag combinations"

# ============================================================================
# Test 2010: an empty commit as --ref. Commands that act on hunks say there
# are no changes in it, naming the commit as typed; list and count report
# an empty diff as they do on a clean tree: nothing, and 0.
# ============================================================================
empty_commit_state() {
    git commit -q --allow-empty -m "E: empty"
    git tag E
    lines mod 1 30 | sed -e 's/^mod line 15 .*/mod line 15 changed in C1/' \
        -e 's/^mod line 05 .*/mod line 05 edited in worktree/' > mod.txt
}
golden_repo empty_commit_state
check_error "test 2010" 1 "no changes in 'E'" diff --ref E 27a3329
check_error "test 2010" 1 "no changes in 'E'" reset --ref E --all
check_error "test 2010" 1 "no changes in 'E'" restore --ref E --all
check_error "test 2010" 1 "no changes in 'E'" add --ref E --all
check_error "test 2010" 1 "no changes in 'E'" commit --ref E --all -m msg
check_error "test 2010" 1 "no changes in 'E..E'" diff --ref E..E 27a3329
check_error "test 2010" 0 "" list --ref E
[[ -z "$("$GIT_HUNK" list --ref E)" ]] || fail "test 2010: list --ref E printed hunks"
check_error "test 2010" 0 "" count --ref E
[[ "$("$GIT_HUNK" count --ref E)" == 0 ]] || fail "test 2010: count --ref E did not print 0"
pass "test 2010: empty-commit --ref messages pinned"

# ============================================================================
# Test 2011: a --ref patch that no longer applies. C1's change is already in
# the index, so staging it again conflicts. The message names the ref as
# typed and where it failed to land. git apply's own lines before it are
# git's, not pinned.
# ============================================================================
golden_repo
RC2011=0
ERR2011="$("$GIT_HUNK" add --ref HEAD~1 0adc154 2>&1 > /dev/null)" || RC2011=$?
[[ "$RC2011" -eq 1 ]] || fail "test 2011: add --ref HEAD~1 <sha> exited $RC2011, want 1"
check_text "test 2011: last stderr line of add --ref HEAD~1 <sha>" \
    "error: changes from 'HEAD~1' do not apply cleanly to the index (try --3way)" \
    "$(printf '%s\n' "$ERR2011" | tail -1)"
git diff --cached --quiet || fail "test 2011: the failed add changed the index"
# Reverting C2 in a worktree that already lacks its change conflicts there.
golden_repo
lines other 1 6 > other.txt
RC2011=0
ERR2011="$("$GIT_HUNK" restore --ref C2 bd8ab1d 2>&1 > /dev/null)" || RC2011=$?
[[ "$RC2011" -eq 1 ]] || fail "test 2011: restore --ref C2 <sha> exited $RC2011, want 1"
check_text "test 2011: last stderr line of restore --ref C2 <sha>" \
    "error: changes from 'C2' do not apply cleanly to the worktree (try --3way)" \
    "$(printf '%s\n' "$ERR2011" | tail -1)"
pass "test 2011: apply-conflict messages under add/restore --ref pinned"

# ============================================================================
# Test 2012: every revision --ref names is checked before any diff runs, and
# a bad one is reported as typed -- a side of a range by itself.
# ============================================================================
golden_repo mixed_state
check_error "test 2012" 1 "error: bad revision 'nope'" list --ref nope
check_error "test 2012" 1 "error: bad revision 'nope'" list --staged --ref nope
check_error "test 2012" 1 "error: bad revision 'nope'" list --ref nope..HEAD
check_error "test 2012" 1 "error: bad revision 'nope'" list --ref R...nope
check_error "test 2012" 1 "error: bad revision 'nope'" reset --ref nope --all
check_error "test 2012" 1 "error: bad revision 'nope'" commit --ref nope --all -m msg
pass "test 2012: bad revisions reported as typed"

# ============================================================================
# Test 2013: the index against a commit names the commit when it has no
# changes, and --verbose suggests 'git add' only for unstaged changes.
# ============================================================================
golden_repo
check_error "test 2013" 1 "no staged changes relative to 'HEAD'" diff --staged --ref HEAD 27a3329
chmod +x mod.txt
NOTE2013="$("$GIT_HUNK" list -v 2>&1 > /dev/null)"
check_text "test 2013: list -v note" "note: mod.txt: mode change has no hunk — use 'git add mod.txt'" "$NOTE2013"
git add mod.txt
NOTE2013="$("$GIT_HUNK" list -v --staged 2>&1 > /dev/null)"
check_text "test 2013: list -v --staged note" "note: mod.txt: mode change has no hunk" "$NOTE2013"
pass "test 2013: index-against-commit and skipped-path wording pinned"

# ============================================================================
# Test 2014: a file named like a revision cannot shadow it. Revisions end
# with --, so git never has to guess whether 'main' or 'HEAD' is a path.
# ============================================================================
golden_repo
BRANCH2014="$(git symbolic-ref --short HEAD)"
printf 'shadow\n' > "$BRANCH2014"
printf 'shadow\n' > HEAD
git add "$BRANCH2014" HEAD
lines other 1 6 | sed 's/^other line 05 .*/other line 05 edited/' > other.txt
PATHS2014="$("$GIT_HUNK" list --staged --ref "$BRANCH2014" --porcelain --oneline | cut -f2 | LC_ALL=C sort | tr '\n' ' ')"
check_text "test 2014: paths of list --staged --ref $BRANCH2014" "$(printf '%s\n' HEAD "$BRANCH2014" | LC_ALL=C sort | tr '\n' ' ')" "$PATHS2014"
SHA2014="$("$GIT_HUNK" list --porcelain --oneline --file other.txt | cut -f1)"
[[ -n "$SHA2014" ]] || fail "test 2014: no hunk for other.txt"
"$GIT_HUNK" stash "$SHA2014" > /dev/null || fail "test 2014: stash with a file named HEAD failed"
git diff --quiet -- other.txt || fail "test 2014: stash left other.txt changed"
git stash list | grep -q . || fail "test 2014: stash stored nothing"
pass "test 2014: files named HEAD and like the branch shadow no revision"

# ============================================================================
# Test 2015: a result hash is the hash `list` then shows on that side, for a
# rename and for a new file, both ways.
# ============================================================================
# result_hashes <git-hunk args>: the result column of the porcelain output,
# one hash per line.
result_hashes() {
    "$GIT_HUNK" "$@" --porcelain | cut -f3 | tr ',' '\n' | LC_ALL=C sort
}
listed_hashes() {
    "$GIT_HUNK" list --porcelain --oneline "$@" | cut -f1 | LC_ALL=C sort
}
golden_repo intent_to_add_state
GOT2015="$(result_hashes add b34f350)"
check_text "test 2015: add of a rename" "$(listed_hashes --staged --file new-name.txt)" "$GOT2015"
golden_repo mixed_state
GOT2015="$(result_hashes reset b34f350)"
check_text "test 2015: reset of a rename" "$(listed_hashes --file new-name.txt --file old-name.txt)" "$GOT2015"
golden_repo mixed_state
GOT2015="$(result_hashes reset af6a5e1)"
check_text "test 2015: reset of a new file" "$(listed_hashes --file new.txt)" "$GOT2015"
GOT2015="$(result_hashes add "$GOT2015")"
check_text "test 2015: add of it again" "$(listed_hashes --staged --file new.txt)" "$GOT2015"
pass "test 2015: add and reset results match what list shows next"

# ============================================================================
# Test 2016: an untracked binary's hash is taken over full blob ids, so
# core.abbrev cannot change it.
# ============================================================================
golden_repo
printf 'untracked\000binary\n' > u.bin
WANT2016="$(binary_hash u.bin "$(git rev-parse HEAD | tr '0-9a-f' '0')" "$(git hash-object -- u.bin)")"
check_text "test 2016: untracked binary hash" "$WANT2016" "$(listed_hashes --file u.bin)"
git config core.abbrev 12
check_text "test 2016: untracked binary hash under core.abbrev=12" "$WANT2016" "$(listed_hashes --file u.bin)"
pass "test 2016: untracked binary hash independent of core.abbrev"

report_results
