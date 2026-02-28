# git-hunk untracked files + selective staging demo
# Run: vhs assets/demo-untracked.tape
Output assets/demo-untracked.gif
Output assets/demo-untracked.webm

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
Type "bash assets/demo-untracked-setup.sh"
Enter
Sleep 2s
Type "cd /tmp/hunk-demo-untracked"
Enter
Sleep 300ms
Type "clear"
Enter
Sleep 300ms
Show

# Show starting state — modified + 2 untracked
Type "git status -s"
Sleep 200ms
Enter
Sleep 2s

# List hunks — tracked and untracked together
Enter
Type "git hunk list --oneline"
Sleep 200ms
Enter
Sleep 2.5s

# Stage the untracked utils file
Enter
Type "git hunk add 2bb9"
Sleep 200ms
Enter
Sleep 2s

# Discard the scratch file
Enter
Type "git hunk discard --force f479"
Sleep 200ms
Enter
Sleep 2s

# Check status — utils staged, scratch gone
Type "git status -s"
Sleep 200ms
Enter
Sleep 2s

# Stage the tracked change too
Enter
Type "git hunk add fdc6"
Sleep 200ms
Enter
Sleep 2s

# Commit everything
Type "git commit -m 'add utils and update farewell'"
Sleep 200ms
Enter
Sleep 2s

# Clean
Type "git status -s"
Sleep 200ms
Enter
Sleep 2s
