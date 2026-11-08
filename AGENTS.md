# Provisioning changes

When adding or changing development tools, keep all supported environments in
sync: the Linux container and VM (`inside_deps/ubuntu-packages.txt` and shared
installers), the macOS VM (`lima/macos/provision.sh`), and Claude cloud setup
(`tools/claude-cloud-setup.sh`). Check each backend explicitly; their package
lists are not all shared. Document any intentional platform differences.

Whenever provisioning changes, update `provisioning-revision` in the README's
Claude Code cloud setup snippet to today's date in `YYYY-MM-DD-N` format.
Increment `N` for additional revisions on the same day. This refreshes the
cached setup; changing the downloaded script alone does not refresh that cache.

Run the relevant existing provisioning tests and shell syntax checks. Distinguish
stubbed tests from actual image builds or native macOS provisioning in reports.
