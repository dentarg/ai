---
name: jactionlint
description: Validate GitHub Actions workflows with jactionlint when creating, editing, or reviewing workflow YAML or composite actions.
---

# GitHub Actions validation

Run `jactionlint` from the repository root after changing workflows or composite
actions, or when reviewing them. Pass the relevant file paths for a focused
check, for example `jactionlint .github/workflows/ci.yml`.

Respect the repository's existing configuration. Fix findings introduced by
your changes and report relevant pre-existing findings without expanding the
task into unrelated cleanup. Rerun after fixes. Use `--diff` to inspect proposed
automatic fixes before applying them; do not suppress checks just to pass.
