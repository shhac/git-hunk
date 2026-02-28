# git-hunk stash demo
# Run: vhs assets/demo-stash.tape
Output assets/demo-stash.gif
Output assets/demo-stash.webm

Set Theme "Catppuccin Mocha"
Set FontFamily "Fira Code"
Set FontSize 15
Set Width 680
Set Height 460
Set Padding 16
Set Framerate 5
Set TypingSpeed 50ms
Set CursorBlink false

# Hidden setup
Hide
Type "bash assets/demo-stash-setup.sh"
Enter
Sleep 2s
Type "cd /tmp/hunk-demo-stash"
Enter
Sleep 300ms
Type "clear"
Enter
Sleep 300ms
Show

# Show starting state
Type "git status -s"
Sleep 200ms
Enter
Sleep 2s

# List hunks
Enter
Type "git hunk list --oneline"
Sleep 200ms
Enter
Sleep 2.5s

# Stage the validation fix
Enter
Type "git hunk add 7f71"
Sleep 200ms
Enter
Sleep 2s

# Check status after staging
Type "git status -s"
Sleep 200ms
Enter
Sleep 2s

# Stash the logging experiment for later
Enter
Type "git hunk stash f598 -m 'wip: logging setup'"
Sleep 200ms
Enter
Sleep 2.5s

# Check status — working tree clean
Type "git status -s"
Sleep 200ms
Enter
Sleep 2s

# Commit the staged fix
Type "git commit -m 'fix: validate POST body'"
Sleep 200ms
Enter
Sleep 2s

# Show stash entry
Type "git --no-pager stash list"
Sleep 200ms
Enter
Sleep 2s

# Pop it back
Enter
Type "git hunk stash pop"
Sleep 200ms
Enter
Sleep 2.5s

# Final status — unstashed changes restored
Type "git status -s"
Sleep 200ms
Enter
Sleep 2s
