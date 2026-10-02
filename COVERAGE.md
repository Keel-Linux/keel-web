# Test coverage baseline

Measured on 2026-10-01, following the project decisions 0003 (90 percent
floor per repository, 95 percent for every file the project writes), 0004
(shell: bats plus kcov) and 0006 (the gate runs in GitHub Actions and is a
required status on the default branch).

## What this repository is

An appliance recipe and the package it installs, written by the project
(handbook decisions 0030 and 0041, step 7 of its first implementation):

| Path | What it is | Measured |
| --- | --- | --- |
| `Makefile` | the Webmin firewall ports and the include of `turnkey.mk` from common | the image build |
| `plan/main` | `#include <turnkey/base>` and `keel-web` | the image build |
| `conf.d/main` | fails the build when the image is not in the simple state: an Anubis key, a record of the state hooks, Anubis enabled, Coraza linked, the Anubis front linked, Debian's default site not enabled, no page for it, a usage screen that does not list the site | 100 percent, see below |
| `overlay/etc/confconsole/services.txt` | the usage screen: the site, Webmin and SSH, IPv6 then IPv4, over Core's | `tests/image-conf.bats` |
| `overlay/var/www/html/index.html` | the page of the default site: common's removelist deletes `/var/www/html`, Debian's page with it | data |
| `packages/keel-web/manifest.yaml` | the appliance manifest of Keel Web, the format's worked example byte for byte | `tests/package.bats`, and `keel manifest validate` on the image |
| `packages/keel-web/default-anubis` | Debian's default site behind Anubis, HTTPS with port 80 redirecting | `tests/package.bats`, and the image run |
| `packages/keel-web/anubis-front` | the state hook keel runs when the anubis overlay is turned on or off | 100 percent, see below |
| `packages/keel-web/debian/postrm` | on purge, the front's link goes and Debian's default site is linked again | `tests/package.bats`, run against a scratch root through `DPKG_ROOT` |

Every other package, hook and conf script of the image comes from `common`,
`keel`, `keel-core`, the step 5 packaging repositories, `fab` and the Debian
and TurnKey archives, each measured in its own repository.

## What "test" means here

As for keel-core (its COVERAGE.md): the layer boots in an LXC container,
its first boot completes headless from an instance spec, and the machine
matches the spec. The boot test (`tests/boot-test.sh`, its library and its
bats file, the same as keel-core's) runs on the self-hosted runner against
the layers the mirror publishes. The web layer has not been published yet,
so `test-appliance.yml` runs with `allow_unpublished: true` and passes
saying so; the evidence for this branch is its isolated build and the run
on the built image (`tests/README.md`, "The package on a built image").

## State

| What | Measured | How |
| --- | --- | --- |
| `tests/lib/boot-test-lib.sh` | 100 percent (109 of 109 lines, 30 bats tests, kcov 43) | `COVERAGE_THRESHOLD=100 tests/coverage.sh` |
| `packages/keel-web/anubis-front` | 100 percent (84 of 84 lines, 28 bats tests, kcov 43) | the same |
| `conf.d/main` | 100 percent (20 of 20 lines, 15 bats tests, two of them on the overlay's usage screen, kcov 43), run against a scratch tree through `KEEL_CONF_ROOT` | the same |
| `packages/keel-web` | built with `dpkg-buildpackage` and linted clean with lintian on trixie; its fields, files, trigger, postrm, site and manifest read back by 27 bats tests | `tests/package.bats`, the check `packages / build` |
| The image | built in isolation on 2026-10-01, core then web, from the packages of this branch and of keel#63; booted in LXC in a simple installation and moved to cloud simple through the spec | `tests/README.md`, "The package on a built image" |

Baseline for the threshold in `.github/workflows/tests.yml`: 100, the
measured number of the three project-authored shell files; it is only ever
raised.

## Gate

`.github/workflows/tests.yml` has two jobs, as keel-core's: `tests` calls
`test-shell.yml` with threshold 100 (the check `tests / coverage`), and
`appliance` calls `test-appliance.yml` with `appliance: web`, `parent: core`
and `allow_unpublished: true` (the check `appliance / boot-published-layer`),
gated on the organization variable `KEEL_LXC_RUNNER`.
`.github/workflows/packages.yml` builds, lints and tests the package in a
trixie system container through `lxc-trixie.yml` (the check
`build / trixie`).

## Plan

1. Remove `allow_unpublished` once the maintainer's attended release
   publishes the web layer; the workflow then makes it an error.
2. The default site behind Anubis is the one site Keel Web serves until
   keel renders the sites of decision 0042; then `default-anubis` and its
   hook give way to keel's `protect.anubis` per site.
