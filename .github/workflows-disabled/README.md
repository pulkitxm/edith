# Parked workflows

Edith moved to a private repository and its GitHub Actions minutes are limited,
so every workflow that used to live in `.github/workflows/` has been parked here.
GitHub only runs workflows found under `.github/workflows/`, so keeping them in
this sibling folder disables them without deleting anything. Dependabot is parked
the same way, as `.github/dependabot.yml.disabled`.

Nothing about the workflows themselves changed. They are the exact files that ran
before, and the tests under `scripts/` still validate them from this location, so
they stay correct and ready to switch back on.

## Running the checks locally

Everything the workflows enforced now runs from the `Makefile`. See `AGENTS.md`
in the repository root for the full list. The short version:

- `make ci-all` runs every check the workflows ran.
- `make ci` runs the fast product checks.
- `make release` cuts and publishes a release, which CI used to do.

## Bringing a workflow back

Move it back into the live folder and commit:

```sh
git mv .github/workflows-disabled/ci.yml .github/workflows/ci.yml
```

To restore everything at once:

```sh
git mv .github/workflows-disabled .github/workflows
git mv .github/dependabot.yml.disabled .github/dependabot.yml
```

Re-enabling assumes the account's Actions billing is healthy again, and the
release secrets (`MACOS_CERT_P12`, `MACOS_CERT_PASSWORD`, `SPARKLE_PRIVATE_KEY`,
and the push tokens) are still present in the repository settings.
