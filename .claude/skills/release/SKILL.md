---
name: release
description: This skill should be used when creating a new release for git-hunk, including version bumping, changelog updates, tagging, and publishing through GitHub Actions. Invoked when creating releases, bumping versions, publishing releases, or preparing release tags.
allowed-tools: Read, Edit, Bash, Grep
---

# git-hunk Release Process

Automate the complete release workflow for git-hunk using GitHub Actions CI/CD.

## Instructions

### 1. Verify Prerequisites

Before starting the release:

```bash
# Run all tests
zig build test

# Build and verify
zig build -Doptimize=ReleaseFast
./zig-out/bin/git-hunk --version
```

All tests must pass before proceeding.

### 2. Update Release Dependencies

Three files must be updated for every release:

**File 1: CHANGELOG.md**
- Add new version section at the top (below the `# Changelog` heading)
- Format: `## [X.Y.Z] - YYYY-MM-DD`
- Categories: Added, Fixed, Changed
- The release workflow extracts this section for GitHub release notes

**File 2: build.zig**
- Update default version string
- Format: `const version_option = b.option([]const u8, "version", "Version string") orelse "X.Y.Z";`

**File 3: build.zig.zon**
- Update `.version = "X.Y.Z"`

### 3. Create Release Commit

```bash
git add CHANGELOG.md build.zig build.zig.zon
gm chore release "bump version to X.Y.Z"
```

### 4. Create and Push Tag

```bash
# Create annotated tag
git tag -a vX.Y.Z -m "Release vX.Y.Z

Brief summary of changes

See CHANGELOG.md for full details."

# Push commit and tag
git push origin main
git push origin vX.Y.Z
```

### 5. Automated Release Process

Once the tag is pushed, GitHub Actions automatically:

1. **Builds for all platforms:**
   - macOS Universal (Intel + ARM combined via lipo)
   - macOS x86_64
   - macOS ARM64
   - Linux x86_64
   - Linux ARM64

2. **Creates GitHub Release:**
   - Extracts changelog section for release notes
   - Attaches all platform tarballs (`git-hunk-{platform}.tar.gz`)
   - Publishes release (not draft)

3. **Timeline:** ~10-15 minutes for full release

### 6. Verify Release

```bash
# Check release on GitHub
gh release view vX.Y.Z

# Download and test a platform binary
curl -L https://github.com/shhac/git-hunk/releases/download/vX.Y.Z/git-hunk-macos-universal.tar.gz | tar xz
./git-hunk --version  # Should show new version
```

### 7. Update Homebrew Tap

The Homebrew formula may live in a sibling repo. Check for it at `../homebrew-tap/` relative to this repo's parent directory. The skill does not assume the path exists — probe for it.

```bash
# Probe for the tap repo (try common relative path)
TAP_DIR="$(git rev-parse --show-toplevel)/../homebrew-tap"
if [ ! -d "$TAP_DIR/Formula" ]; then
  echo "Homebrew tap not found at $TAP_DIR — skipping formula update"
  # Stop here for Homebrew; the release is still complete without it
fi
```

If found, update `Formula/git-hunk.rb`:

1. **Download each platform tarball and compute SHA256:**

```bash
VERSION="X.Y.Z"
BASE_URL="https://github.com/shhac/git-hunk/releases/download/v${VERSION}"
for PLATFORM in aarch64-macos x86_64-macos aarch64-linux x86_64-linux; do
  curl -sL "${BASE_URL}/git-hunk-${PLATFORM}.tar.gz" | shasum -a 256
done
```

2. **Update the formula** with new version, URLs, and SHA256 hashes. The formula structure:

```ruby
class GitHunk < Formula
  desc "Non-interactive CLI for staging git diff hunks by content hash"
  homepage "https://github.com/shhac/git-hunk"
  version "X.Y.Z"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/shhac/git-hunk/releases/download/vX.Y.Z/git-hunk-aarch64-macos.tar.gz"
      sha256 "<hash>"
    end
    on_intel do
      url "https://github.com/shhac/git-hunk/releases/download/vX.Y.Z/git-hunk-x86_64-macos.tar.gz"
      sha256 "<hash>"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/shhac/git-hunk/releases/download/vX.Y.Z/git-hunk-aarch64-linux.tar.gz"
      sha256 "<hash>"
    end
    on_intel do
      url "https://github.com/shhac/git-hunk/releases/download/vX.Y.Z/git-hunk-x86_64-linux.tar.gz"
      sha256 "<hash>"
    end
  end

  def install
    bin.install "git-hunk"
  end

  test do
    assert_match "git-hunk X.Y.Z", shell_output("#{bin}/git-hunk --version")
  end
end
```

3. **Commit and push the tap update:**

```bash
cd "$TAP_DIR"
git add Formula/git-hunk.rb
git commit -m "git-hunk X.Y.Z"
git push
```

If the formula file doesn't exist yet, create it from the template above.

## Version Numbering

Follow semantic versioning (semver):

- **Major (X.0.0)**: Breaking changes to CLI interface or porcelain format
- **Minor (0.X.0)**: New features, backward compatible
- **Patch (0.0.X)**: Bug fixes, backward compatible

## Hotfix Releases

For urgent fixes:

```bash
# 1. Create hotfix branch from main
git swc paul/hotfix-X.Y.Z

# 2. Make fix, update CHANGELOG.md, build.zig, build.zig.zon
# 3. Test thoroughly
# 4. Merge to main
git sw main
git merge paul/hotfix-X.Y.Z

# 5. Tag and push
git tag -a vX.Y.Z -m "Release vX.Y.Z"
git push origin main vX.Y.Z
```

## Manual Builds (Optional)

For testing or custom builds, use the manual build artifacts workflow:

1. Go to GitHub Actions > "Build Artifacts"
2. Click "Run workflow"
3. Select branch to build from
4. Download artifacts from workflow run (30-day retention)

## Troubleshooting Releases

**Release workflow failed:**
- Check GitHub Actions logs for build errors
- Verify CHANGELOG.md has correct format
- Ensure all tests pass locally first

**Missing platform in release:**
- Check workflow run for specific platform failure
- May need to rerun failed jobs in GitHub Actions

**Changelog extraction failed:**
- Verify CHANGELOG.md format matches: `## [X.Y.Z] - YYYY-MM-DD`
- Ensure there's content between version headers

## Release Checklist

Before completing release:

- [ ] All tests pass
- [ ] CHANGELOG.md updated with version section
- [ ] build.zig version updated
- [ ] build.zig.zon version updated
- [ ] Binary builds and shows correct version (`--version`)
- [ ] Changes committed with `chore[release]` message
- [ ] Tag created with proper format (vX.Y.Z)
- [ ] Tag pushed to GitHub
- [ ] GitHub Actions workflow triggered
- [ ] Release published with binaries
- [ ] Release verified by downloading artifact
- [ ] Homebrew tap updated (if `../homebrew-tap/` exists)
