Create a new GitHub release with an auto-incremented version tag.

Argument: $ARGUMENTS (optional) — "major", "minor", or "patch". If no argument is provided, ask the user which bump type they want.

Steps:
1. Run `gh release list --limit 1` to get the latest release tag
2. If no releases exist, use `v0.1.0`
3. Otherwise, bump based on the argument:
   - "major": `v0.1.2` → `v1.0.0`
   - "minor": `v0.1.2` → `v0.2.0`
   - "patch" or empty: `v0.1.2` → `v0.1.3`
4. Update `MARKETING_VERSION` in `macos/project.yml` to the new version (without the `v` prefix, e.g. `0.2.0`)
5. Commit the version bump and any other uncommitted changes (ask the user if there are uncommitted changes beyond the version bump)
6. Check the current branch. If on `main`, push to the remote (`git push origin main`). If on a different branch, ask the user what to do before proceeding.
7. Create the release: `gh release create <tag> --title "<tag>" --generate-notes`
8. Show the user the release URL and remind them the GitHub Actions workflow will build, sign, notarize, and upload the app automatically
