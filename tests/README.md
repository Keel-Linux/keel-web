# Tests

What a test means for an appliance recipe is written in `COVERAGE.md`: the
recipe builds, the result boots in an LXC container, its first boot
completes headless from an instance spec, and the machine matches the spec.

## Layout

- `boot-test.sh`, `lib/boot-test-lib.sh`, `boot-test.bats`: the boot test
  of keel-core, unchanged, which `test-appliance.yml` of keel-linux/.github
  runs against the layers the mirror publishes (keel-core's
  `tests/README.md` documents it). `instance.yaml` is its spec, with the
  host named `web`.
- `anubis-front.bats`: unit tests of `packages/keel-web/anubis-front`, the
  state hook of the anubis overlay. It runs against a scratch `/etc/nginx`
  named by `KEEL_NGINX_DIR`, with `nginx` and `dpkg-query` as stubs first
  in `PATH`: the front put in place of Debian's default site and back, an
  edited default site or a link of the operator's left alone, the rollback
  when `nginx -t` or the reload fails, and Nginx stopped.
- `image-conf.bats`: unit tests of `conf.d/main`, run against a scratch
  tree named by `KEEL_CONF_ROOT`.
- `package.bats`: builds `packages/keel-web` with `dpkg-buildpackage` and
  reads back its fields, its files, the site, the manifest's Web table,
  and the postrm run against a scratch root through `DPKG_ROOT`. Needs
  `dpkg-dev`, `debhelper` and `python3-yaml` besides `bats`; it runs in
  the check `packages / build` (`.github/workflows/packages.yml`), with
  lintian over the source and binary package.
- `coverage.sh`: runs each bats file under kcov and fails when any
  measured file is below `COVERAGE_THRESHOLD` (default 95).

## Unit tests and coverage

Debian packages `bats` (1.11) and `kcov` (43); no root:

    bats tests/anubis-front.bats tests/image-conf.bats tests/boot-test.bats
    bats tests/package.bats
    COVERAGE_THRESHOLD=100 tests/coverage.sh

## The package on a built image

What the package does on a machine is proven on an image built from this
branch: the core layer, then the web layer on it (`bt-layer web --parent
core`), from the packages of the branch. The container is started as
keel-core's boot test does it, with a spec in a simple installation
(`appliance.name: web`, `installation.mode: simple`, every overlay of the
chain written out, `monitor.enabled: true` with a channel) and the conf
rendered by `keel spec apply --conf <rootfs>/etc/inithooks.conf --root
<rootfs>` before the first boot. Then, on the container:

    keel manifest validate
    keel manifest show web --resolved     # the Web table of decision 0041
    systemctl is-active anubis@keel       # inactive
    ls /etc/nginx/modules-enabled         # no 50-mod-http-coraza.conf
    curl -s http://[<address>]/           # the page of the default site, from Nginx
    grep '^check' /etc/keel/monit/keel-manifest.conf

and Monit's file checks sshd, webmin, postfix and nginx with its
`/keel-health` probe, nothing else.

Then the spec moves to a cloud installation: `installation.mode:
cloud_simple`, and the overlays of that column (`wireguard`, `crowdsec`,
`coraza`, `anubis` enabled), applied with `keel spec apply --system`.
keel enables and starts `anubis@keel.service`, runs the state hooks
(Coraza's, which links the module and checks its probe, and keel-web's,
which puts the default site behind Anubis), and Monit's file gains
`crowdsec`, `firewall-bouncer`, `anubis` and `waf-blocks`. From outside
the container:

    curl -s -o /dev/null -w '%{http_code}' 'http://[<address>]/?q=<script>alert(1)</script>'   # 403
    curl -s -A 'Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0' \
        http://[<address>]/              # Anubis's challenge page

A verified crawler is Googlebot's user agent from one of Google's
published ranges. A test cannot send from those addresses, so it is
simulated behind a trusted proxy, the `header` case of decision 0042's
`web.real_ip`: a file in `conf.d` trusts the test client's address
(`set_real_ip_from`) and takes the client from `X-Forwarded-For`. Nginx
then hands Anubis that address in `X-Real-IP`, as it would a real one:

    curl -s -A 'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)' \
        -H 'X-Forwarded-For: 2001:4860:4801:10::1' http://[<address>]/   # the page
    curl -s -A 'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)' \
        http://[<address>]/                                               # challenged

A second `keel spec apply --system` changes nothing, and turning the two
overlays off again puts Debian's default site back and unloads Coraza.
