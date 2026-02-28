#!/usr/bin/env bash
# Create a deterministic git test repo in a temp directory.
# Prints the directory path to stdout. Caller is responsible for cleanup.
#
# Usage:
#   REPO="$(bash tests/setup-repo.sh)"
#   trap 'rm -rf "$REPO"' EXIT
#   cd "$REPO"
#
# The repo has 3 files (alpha.txt, beta.txt, gamma.txt), each 30+ lines,
# with 2 commits of history. File content is deterministic so hunk hashes
# are stable across runs.
set -euo pipefail

REPO="$(mktemp -d)"
cd "$REPO"

git init -q
git config user.email "test@git-hunk.test"
git config user.name "git-hunk test"

# --- Commit 1: initial content (3 files, 30 lines each) ---

cat > alpha.txt <<'EOF'
Lorem ipsum dolor sit amet consectetur adipiscing elit.
Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.
Ut enim ad minim veniam quis nostrud exercitation ullamco laboris.
Nisi ut aliquip ex ea commodo consequat duis aute irure dolor.
In reprehenderit in voluptate velit esse cillum dolore eu fugiat.
Nulla pariatur excepteur sint occaecat cupidatat non proident.
Sunt in culpa qui officia deserunt mollit anim id est laborum.
Curabitur pretium tincidunt lacus nunc pellentesque magna.
Id aliquet risus feugiat in ante metus dictum at tempor.
Commodo sed egestas egestas fringilla phasellus faucibus.
Scelerisque viverra mauris in aliquam sem fringilla ut morbi.
Tincidunt lobortis feugiat vivamus at augue eget arcu dictum.
Varius vel pharetra vel turpis nunc eget lorem dolor sed.
Viverra ipsum nunc aliquet bibendum enim facilisis gravida neque.
Convallis a cras semper auctor neque vitae tempus quam.
Pellentesque id nibh tortor id aliquet lectus proin nibh.
Nisl condimentum id venenatis a condimentum vitae sapien.
Pellentesque nec nam aliquam sem et tortor consequat id.
Porta lorem mollis aliquam ut porttitor leo a diam.
Sollicitudin aliquam ultrices sagittis orci a scelerisque.
Purus in mollis nunc sed id semper risus in hendrerit.
Gravida in fermentum et sollicitudin ac orci phasellus.
Egestas congue quisque egestas diam in arcu cursus euismod.
Quis ipsum suspendisse ultrices gravida dictum fusce ut.
Placerat in egestas erat imperdiet sed euismod nisi porta.
Lorem donec massa sapien faucibus et molestie ac feugiat.
Sed vulputate mi sit amet mauris commodo quis imperdiet.
Massa tincidunt dui ut ornare lectus sit amet est placerat.
In vitae turpis massa sed elementum tempus egestas sed.
Faucibus turpis in eu mi bibendum neque egestas congue.
EOF

cat > beta.txt <<'EOF'
Amet consectetur adipiscing elit pellentesque habitant morbi.
Tristique senectus et netus et malesuada fames ac turpis.
Egestas sed tempus urna et pharetra pharetra massa massa.
Ultricies mi quis hendrerit dolor magna eget est lorem.
Ipsum dolor sit amet consectetur adipiscing elit ut aliquam.
Purus sit amet luctus venenatis lectus magna fringilla urna.
Porttitor eget dolor morbi non arcu risus quis varius.
Quam vulputate dignissim suspendisse in est ante in nibh.
Mauris cursus mattis molestie a iaculis at erat pellentesque.
Adipiscing at in tellus integer feugiat scelerisque varius.
Morbi tincidunt ornare massa eget egestas purus viverra.
Accumsan lacus vel facilisis volutpat est velit egestas dui.
Id ornare arcu odio ut sem nulla pharetra diam sit.
Amet nisl suscipit adipiscing bibendum est ultricies integer.
Quis auctor elit sed vulputate mi sit amet mauris commodo.
Quis vel eros donec ac odio tempor orci dapibus ultrices.
In mollis nunc sed id semper risus in hendrerit gravida.
Rutrum tellus pellentesque eu tincidunt tortor aliquam nulla.
Facilisi cras fermentum odio eu feugiat pretium nibh ipsum.
Consequat nisl vel pretium lectus quam id leo in vitae.
Turpis egestas integer eget aliquet nibh praesent tristique.
Magna sit amet purus gravida quis blandit turpis cursus.
In hac habitasse platea dictumst vestibulum rhoncus est.
Pellentesque pulvinar pellentesque habitant morbi tristique.
Senectus et netus et malesuada fames ac turpis egestas.
Integer enim neque volutpat ac tincidunt vitae semper quis.
Lectus urna duis convallis convallis tellus id interdum velit.
Laoreet id donec ultrices tincidunt arcu non sodales neque.
Sodales ut eu sem integer vitae justo eget magna fermentum.
Iaculis at erat pellentesque adipiscing commodo elit at.
EOF

cat > gamma.txt <<'EOF'
Diam donec adipiscing tristique risus nec feugiat in fermentum.
Posuere ac ut consequat semper viverra nam libero justo laoreet.
Sit amet justo donec enim diam vulputate ut pharetra sit.
Amet risus nullam eget felis eget nunc lobortis mattis.
Aliquam faucibus purus in massa tempor nec feugiat nisl.
Pretium quam vulputate dignissim suspendisse in est ante.
In nibh mauris cursus mattis molestie a iaculis at erat.
Pellentesque adipiscing commodo elit at imperdiet dui accumsan.
Sit amet nisl purus in mollis nunc sed id semper.
Risus in hendrerit gravida rutrum quisque non tellus orci.
Ac turpis egestas maecenas pharetra convallis posuere morbi.
Leo in vitae turpis massa sed elementum tempus egestas.
Sed vulputate odio ut enim blandit volutpat maecenas volutpat.
Blandit aliquam etiam erat velit scelerisque in dictum non.
Consectetur a erat nam at lectus urna duis convallis.
Convallis tellus id interdum velit laoreet id donec ultrices.
Tincidunt arcu non sodales neque sodales ut eu sem integer.
Vitae justo eget magna fermentum iaculis eu non diam.
Phasellus vestibulum lorem sed risus ultricies tristique nulla.
Aliquet bibendum enim facilisis gravida neque convallis a cras.
Semper auctor neque vitae tempus quam pellentesque nec nam.
Aliquam sem et tortor consequat id porta nibh venenatis.
Cras adipiscing enim eu turpis egestas pretium aenean pharetra.
Magna ac placerat vestibulum lectus mauris ultrices eros in.
Cursus euismod quis viverra nibh cras pulvinar mattis nunc.
Sed blandit libero volutpat sed cras ornare arcu dui vivamus.
Arcu felis bibendum ut tristique et egestas quis ipsum.
Suspendisse ultrices gravida dictum fusce ut placerat orci nulla.
Pellentesque eu tincidunt tortor aliquam nulla facilisi cras.
Fermentum et sollicitudin ac orci phasellus egestas tellus rutrum.
EOF

git add alpha.txt beta.txt gamma.txt
git commit -m "initial: three files with lorem ipsum content" -q

# --- Commit 2: modify middle sections of each file ---

sed -i '' '10s/.*/Commodo sed egestas — modified in second commit./' alpha.txt
sed -i '' '20s/.*/Sollicitudin aliquam — modified in second commit./' alpha.txt

sed -i '' '8s/.*/Quam vulputate — modified in second commit./' beta.txt
sed -i '' '15s/.*/Quis auctor elit — modified in second commit./' beta.txt
sed -i '' '25s/.*/Senectus et netus — modified in second commit./' beta.txt

sed -i '' '12s/.*/Leo in vitae — modified in second commit./' gamma.txt
sed -i '' '22s/.*/Aliquam sem et — modified in second commit./' gamma.txt

git add alpha.txt beta.txt gamma.txt
git commit -m "update: modify middle sections across all files" -q

echo "$REPO"
