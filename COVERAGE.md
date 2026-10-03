# Test coverage baseline

Measured on 2026-10-03, following the project decisions 0003 (90 percent
floor per repository, 95 percent for every file the project writes), 0004
(shell: bats plus kcov) and 0006 (the gate runs in GitHub Actions and is a
required status on the default branch).

## What this repository is

An appliance recipe and the package it installs, written by the project
(handbook decisions 0030, 0041 and 0042, step 7 of 0041's first
implementation):

| Path | What it is | Measured |
| --- | --- | --- |
| `Makefile` | the Webmin firewall ports and the include of `turnkey.mk` from common | the image build |
| `plan/main` | `#include <turnkey/base>` and `keel-web` | the image build |
| `conf.d/main` | fails the build when the image is not in the simple state: an Anubis key, a record of the state hooks, Anubis enabled, Coraza linked, the Anubis front linked, keel-web's default site not enabled, Debian's default site enabled or its file gone, a page of the default site missing, a usage screen that does not list the site over HTTPS | 100 percent, see below |
| `overlay/etc/confconsole/services.txt` | the usage screen: the site over HTTPS, Webmin and SSH, IPv6 then IPv4, over Core's | `tests/image-conf.bats` |
| `packages/keel-web/manifest.yaml` | the appliance manifest of Keel Web, the format's worked example byte for byte | `tests/package.bats`, and `keel manifest validate` on the image |
| `packages/keel-web/keel-default` | the default site of a simple installation: the default server on 80 and 443 with the machine's certificate, the placeholder pages, `/keel-health` | `tests/package.bats`, and `tests/site.bats` on a booted container |
| `packages/keel-web/site/*.html` | the placeholder, 404 and 50x pages | `tests/package.bats` (static, no external resource, no TurnKey, no version), and `tests/site.bats` served |
| `packages/keel-web/default-anubis` | the default site behind Anubis, HTTPS with port 80 redirecting | `tests/package.bats`, and `tests/site.bats` for the switch |
| `packages/keel-web/anubis-front` | the state hook keel runs when the anubis overlay is turned on or off: the front in the default site's place and back | 100 percent, see below; and `tests/site.bats` on a booted container |
| `packages/keel-web/debian/postinst` | enables the default site in place of Debian's unedited default site, links the pages, tests with `nginx -t` | `tests/package.bats`, run against a scratch root through `DPKG_ROOT`; `tests/site.bats` for the real install, reinstall and `nginx -t` |
| `packages/keel-web/debian/postrm` | on remove and purge, the sites leave `sites-enabled/` and Debian's default site is linked again | `tests/package.bats`, the same way; `tests/site.bats` for the real remove and purge |

Every other package, hook and conf script of the image comes from `common`,
`keel`, `keel-core`, the step 5 packaging repositories, `fab` and the Debian
and TurnKey archives, each measured in its own repository.

## What "test" means here

As for keel-core (its COVERAGE.md): the layer boots in an LXC container,
its first boot completes headless from an instance spec, and the machine
matches the spec. The boot test (`tests/boot-test.sh`, its library and its
bats file, the same as keel-core's) runs on the self-hosted runner against
the layers the mirror publishes: the web layer since the maintainer's
attended release of 2026-10-02. What boots there is the published layer,
never this branch; the evidence for a branch is its isolated build and the
run on the built image (`tests/README.md`, "The package on a built image"),
and, for the package on a machine, `tests/site.bats` in the check
`site / trixie`.

## State

| What | Measured | How |
| --- | --- | --- |
| `tests/lib/boot-test-lib.sh` | 100 percent (109 of 109 lines, 30 bats tests, kcov 43) | `COVERAGE_THRESHOLD=100 tests/coverage.sh` |
| `packages/keel-web/anubis-front` | 100 percent (75 of 75 lines, 27 bats tests, kcov 43) | the same |
| `conf.d/main` | 100 percent (25 of 25 lines, 20 bats tests, two of them on the overlay's usage screen, kcov 43), run against a scratch tree through `KEEL_CONF_ROOT` | the same |
| `packages/keel-web` | built with `dpkg-buildpackage` and linted clean with lintian on trixie; its fields, files, trigger, Nginx's drop-in, postinst (with and without the machine's certificate), postrm, two sites, pages and manifest read back by 62 bats tests | `tests/package.bats`, the check `build / trixie` |
| The default site on a machine | 21 bats tests on a booted trixie container with Nginx, keel-overlay-nginx, keel-overlay-anubis and keel-web installed: `nginx -t`, `/keel-health` on both loopbacks and both schemes, the placeholder over HTTP and HTTPS with the machine's certificate, HTTP/2 and TLS 1.2 and 1.3, no server version, the 404 page, nginx.service after keel-host-keys.service, the switch to the front and back through the state hook with the 50x page behind it, remove, reinstall and purge, the postinst's rollback when `nginx -t` refuses and an installation before the certificate is made | `tests/site.bats`, the check `site / trixie` |
| The image | built in isolation on 2026-10-01, core then web, from the packages of this branch and of keel#63; booted in LXC in a simple installation and moved to cloud simple through the spec | `tests/README.md`, "The package on a built image" |

Baseline for the threshold in `.github/workflows/tests.yml`: 100, the
measured number of the three project-authored shell files; it is only ever
raised.

## Gate

`.github/workflows/tests.yml` has two jobs, as keel-core's: `tests` calls
`test-shell.yml` with threshold 100 (the check `tests / coverage`), and
`appliance` calls `test-appliance.yml` with `appliance: web` and
`parent: core` (the check `appliance / boot-published-layer`), gated on
the organization variable `KEEL_LXC_RUNNER`.
`.github/workflows/packages.yml` builds, lints and tests the package in a
trixie system container through `lxc-trixie.yml` (the check
`build / trixie`), then installs it with Nginx and common's nginx and
anubis overlays on a booted trixie system container and runs
`tests/site.bats` (the check `site / trixie`).

## Plan

1. The default site and its front are the one site Keel Web serves until
   keel renders the sites of decision 0042 (Keel-Linux/tracker#51); then
   `keel-default`, `default-anubis` and the hook give way to keel's
   `keel-default.conf` and `protect.anubis` per site, and HSTS comes with
   a CA's certificate.
2. The image run of `tests/README.md` is to be repeated on an image built
   from this branch: the placeholder on both schemes in a simple
   installation, the front after `keel spec apply --system` moves the spec
   to a cloud mode, and the placeholder back.
