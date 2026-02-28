#!/bin/bash
# Setup script for untracked files + discard demo
set -e

rm -rf /tmp/hunk-demo-untracked
mkdir -p /tmp/hunk-demo-untracked
cd /tmp/hunk-demo-untracked
git init -q

cat > main.py << 'PYEOF'
def greet(name):
    return f"Hello, {name}!"

def farewell(name):
    return f"Goodbye, {name}!"

if __name__ == "__main__":
    print(greet("world"))
PYEOF

git add . && git commit -qm "initial"

# Modify tracked file + create untracked file
cat > main.py << 'PYEOF'
def greet(name):
    return f"Hello, {name}!"

def farewell(name):
    return f"Goodbye, {name}! See you soon."

if __name__ == "__main__":
    print(greet("world"))
    print(farewell("world"))
PYEOF

cat > utils.py << 'PYEOF'
def validate(name):
    if not name or not isinstance(name, str):
        raise ValueError("name must be a non-empty string")
    return name.strip()
PYEOF

cat > scratch.py << 'PYEOF'
# quick test — delete before committing
print("hello" + " " + "world")
PYEOF
