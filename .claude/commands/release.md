Create a new GitHub release with an auto-incremented version tag.

Argument: $ARGUMENTS (optional) — "major", "minor", or "patch". If no argument is provided, ask the user which bump type they want.

Steps:
1. Run `gh release list --limit 1` to get the latest release tag
2. If no releases exist, use `v0.1.0`
3. Otherwise, bump based on the argument:
   - "major": `v0.1.2` → `v1.0.0`
   - "minor": `v0.1.2` → `v0.2.0`
   - "patch" or empty: `v0.1.2` → `v0.1.3`
4. Commit any uncommitted changes first if there are any (ask the user)
5. Create the release: `gh release create <tag> --title "<tag>" --generate-notes`
6. Show the user the release URL and remind them the GitHub Actions workflow will build, sign, notarize, and upload the app automatically
