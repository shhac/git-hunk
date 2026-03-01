# git-hunk demo recording
# Run: vhs assets/demo.tape
Output assets/demo.gif
Output assets/demo.webm

Set Theme "Catppuccin Mocha"
Set FontFamily "Fira Code"
Set FontSize 15
Set Width 680
Set Height 460
Set Padding 16
Set Framerate 5
Set TypingSpeed 50ms
Set CursorBlink false

# Hidden setup: create demo repo with 3 hunks
Hide
Type "bash assets/demo-setup.sh"
Enter
Sleep 2s
Type "cd /tmp/hunk-demo"
Enter
Sleep 300ms
Type "clear"
Enter
Sleep 300ms
Show

# Demo: show git status before staging
Type "git status -s"
Sleep 200ms
Enter
Sleep 2s

# Demo: list hunks (compact overview)
Type "git hunk list --oneline"
Sleep 200ms
Enter
Sleep 2.5s

# Demo: inspect a specific hunk before staging
Type "git hunk diff 760c"
Sleep 200ms
Enter
Sleep 3s

# Demo: stage just that hunk
Type "git hunk add 760c"
Sleep 200ms
Enter
Sleep 2s

# Demo: git status after partial staging
Type "git status -s"
Sleep 200ms
Enter
Sleep 2.5s

# Demo: verify what's staged
Type "git hunk list --staged --oneline"
Sleep 200ms
Enter
Sleep 2.5s
