# Temporary npm security bundle

This is a local, reproducible npm 12.2.1 security rebuild. It is not an official npm release.
It replaces the bundled `ip-address` with 10.7.4, `undici` with 6.29.1,
`glob` with 14.0.3, `minimatch` with 11.0.3, and `path-scurry` with 3.0.0,
and adds minimatch's `@isaacs/nonrecursive-glob-match` 1.0.3 dependency.
The result identifies itself as `12.2.1+security.20261031`. Original npm
source code and license notices are preserved. Bundled consumer manifests
update only the dependency ranges required by the new glob/minimatch majors.

As of 2026-10-31, official npm 12.2.1 is the latest release and still includes
ip-address 10.7.2, undici 6.29.0, glob 13.0.6, and minimatch 10.2.5. npm child overrides do not replace these
bundled files. OpenClaw 2026.10.6 still declares npm 12.2.0, undici 8.11.2 and
zod 4.6.5, so that host upgrade does not resolve these findings.

The October 31 refresh addresses GHSA-3g3m-2fjr-6pw4 (glob traversal after
cancellation) and GHSA-g3hv-75wg-m249 (minimatch pattern amplification).
These fixes require new upstream majors; they are not source backports.
The root minimatch override also patches OpenClaw's separate copy. No audit
findings are ignored, and the OpenClaw host version is not downgraded.

The root package pins this archive explicitly and OpenClaw references it through
`"npm": "$npm"`. HomeClaw records npm as a runtime dependency, matching its
existing effective role; Parcel records it as a development dependency. The
root reference is necessary for valid portable resolution: a transitive file
override alone failed dependency-tree/clean-install checks.

Clean installs consume the already-patched archive, including when install
scripts are disabled. The archive is checked by the package lock's SHA-512
integrity. The npm archive needs no install hook or npm security configuration. A separate
OpenClaw consumer compatibility patch is described below.

Regenerate manually from the repository root:

```sh
python3 scripts/rebuild-security-npm.py
```

`npm-security-sources.json` pins the seven official registry tarballs by URL and
SHA-512 integrity. The script verifies them before extraction, replaces only
the six dependency package directories, checks that other file bytes and executable modes
are unchanged apart from npm's version and declared glob/minimatch dependency ranges, and writes a deterministic archive.
Temporary original sources remain available for inspection. Provenance records
all changed paths and the resulting hashes. The verification command reconstructs and compares the complete patched tree
against these pinned sources.

Archive SHA-256:
`30da6d0a20b463c82c85023420643b15f4ab7a8963ac1742bdebf18deb829610`

This adds about 3.6 MB per repository and a temporary maintenance responsibility.
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

CI also runs `node --test scripts/test-security-npm.mjs` after installation.
It checks the installed patched versions and bundled dependency ranges,
regresses cancellation and amplification behavior, and exercises npm install,
workspace discovery, and package packing in an offline fixture. It also checks
OpenClaw's declared limiter API. The lockfile keeps p-limit 7.3.3 for OpenClaw
and the separate compatible 2.3.0 copy for legacy p-locate.

## OpenClaw minimatch consumer compatibility

OpenClaw 2026.10.5 expects RegExp objects in `Minimatch.set`, while minimatch 11
returns Matcher objects. The root postinstall runs
`scripts/patch-openclaw-minimatch.mjs` to accept the new objects' public `test`
method in the systemd environment-file pattern consumer. It checks the exact
locked version and complete file SHA-256 before and after the one-expression
change, is idempotent, rejects upstream drift, and refuses to patch dependency
trees outside this repository. No installed/global OpenClaw host is modified.

When intentionally installing with `--ignore-scripts`, run
`node scripts/patch-openclaw-minimatch.mjs` before builds, tests, or using the
local OpenClaw dependency. The regression suite executes the installed wildcard
consumer without initializing a host, and verifies patch idempotence and drift
rejection. Review or remove this patch when updating the locked host version.
