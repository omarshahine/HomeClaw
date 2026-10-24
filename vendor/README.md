# Temporary npm security bundle

This is a local, reproducible npm 12.2.1 security rebuild. It is not an official npm release.
It replaces only the bundled `ip-address` package with 10.7.4 and `undici` with
6.29.1, then identifies the result as `12.2.1+security.20261024`. The original npm
code, all other bundled packages, and license notices are preserved.

As of 2026-10-24, official npm 12.2.1 is the latest release and still includes
ip-address 10.7.2 and undici 6.29.0. npm child overrides do not replace these
bundled files. OpenClaw 2026.10.6 still declares npm 12.2.0, undici 8.11.2 and
zod 4.6.5, so that host upgrade does not resolve these findings.

The root package pins this archive explicitly and OpenClaw references it through
`"npm": "$npm"`. HomeClaw records npm as a runtime dependency, matching its
existing effective role; Parcel records it as a development dependency. The
root reference is necessary for valid portable resolution: a transitive file
override alone failed dependency-tree/clean-install checks.

Clean installs consume the already-patched archive, including when install
scripts are disabled. The archive is checked by the package lock's SHA-512
integrity. No postinstall patch hook or npm security configuration is required.

Regenerate manually from the repository root:

```sh
python3 scripts/rebuild-security-npm.py
```

`npm-security-sources.json` pins the three official registry tarballs by URL and
SHA-512 integrity. The script verifies them before extraction, replaces only
the two package directories, checks that other file bytes and executable modes
are unchanged apart from npm's version, and writes a deterministic archive.
Temporary original sources remain available for inspection. Provenance records
all changed paths and the resulting hashes. Rebuilds produced byte-identical
archives in both repositories and on repeated generation.

Archive SHA-256:
`bc845cf944e23b9f15e62d6aecc93d2fee5b74a70d831ac75c0126b43b21afb6`

This adds about 3.1 MB per repository and a temporary maintenance responsibility.
Before changing source pins, review the upstream package changes, regenerate,
verify installed bundle versions and npm parent semver ranges, and rerun clean
full/production installs, audits, builds, unit tests and plugin checks. Keep the
archive, sources, provenance and rebuild script together in any future change.

Remove this rebuild once an official npm release bundles compatible fixed
versions. Restore the root package/override to that official release, regenerate
the lockfile, and verify the actual installed bundle. Package overrides are
root-project policy: consumers of the published plugin do not inherit them, and
this does not patch an unrelated globally installed OpenClaw host.

CI runs `python3 scripts/rebuild-security-npm.py --check` before dependency
installation. This downloads and verifies the pinned sources, reconstructs the
expected file tree, and compares every file byte/executable mode plus provenance
with the committed archive. It does not rewrite the archive or provenance.
