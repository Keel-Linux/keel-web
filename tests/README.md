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
  named by `KEEL_NGINX_DIR`, with `nginx` as a stub first in `PATH`: the
  front put in place of keel-web's default site and back, a link of the
  operator's or a file left alone, no front at all where the default
  site's link is gone (the default server is the operator's), Debian's
  default site never touched, the rollback when `nginx -t` or the reload
  fails, Nginx stopped, and the two sites never enabled together.
- `image-conf.bats`: unit tests of `conf.d/main`, run against a scratch
  tree named by `KEEL_CONF_ROOT`.
- `package.bats`: builds `packages/keel-web` with `dpkg-buildpackage` and
  reads back its fields, its files, the two sites, the pages, the
  manifest's Web table, and the postinst and postrm run against a scratch
  root through `DPKG_ROOT` with `dpkg-query` as a stub (nginx-common's
  conffile checksum). Needs `dpkg-dev`, `debhelper` and `python3-yaml`
  besides `bats`; it runs in the check `build / trixie`
  (`.github/workflows/packages.yml`), with lintian over the source and
  binary package.
- `site.bats`: the default site on a machine. It runs as root on a
  disposable trixie machine booted with systemd, with Nginx,
  keel-overlay-nginx, keel-overlay-anubis and keel-web installed and the
  machine's certificate where keel-host-keys writes it, only where
  `KEEL_WEB_SITE_TEST=1`; `KEEL_WEB_DEB` names the `.deb` to reinstall.
  It checks `nginx -t`, `/keel-health` on both loopbacks and both schemes,
  the placeholder over HTTP and HTTPS with the machine's certificate,
  HTTP/2 and TLS 1.2 and 1.3, no server version, the 404 page,
  nginx.service ordered after keel-host-keys.service, the switch to the
  front and back through the state hook, a remove, reinstall and purge,
  the postinst's rollback when `nginx -t` refuses, and an installation
  before the certificate is made (the site enabled, the check left to the
  first boot). The check `site / trixie` runs it; Anubis is not running
  there, so behind the front port 443 answers 502 with the site's 50x
  page.
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
    ls -l /etc/nginx/sites-enabled        # keel-default alone
    curl -s http://[<address>]/           # the placeholder, from Nginx
    curl -sk https://[<address>]/         # the same, with the machine's certificate
    curl -s -o /dev/null -w '%{http_code}' http://[<address>]/keel-health    # 204
    curl -sk -o /dev/null -w '%{http_code}' https://[<address>]/keel-health  # 204
    grep '^check' /etc/keel/monit/keel-manifest.conf

and Monit's file checks sshd, webmin, postfix and nginx with its
`/keel-health` probe, nothing else. The usage screen and the banner say
`https://`.

Then the spec moves to a cloud installation: `installation.mode:
cloud_simple`, and the overlays of that column (`wireguard`, `crowdsec`,
`coraza`, `anubis` enabled), applied with `keel spec apply --system`.
keel enables and starts `anubis@keel.service`, runs the state hooks
(Coraza's, which links the module and checks its probe, and keel-web's,
which puts the front in the default site's place), and Monit's file gains
`crowdsec`, `firewall-bouncer`, `anubis` and `waf-blocks`. From outside
the container (`-k`: the machine's certificate is self-signed):

    curl -s -o /dev/null -w '%{http_code} %{redirect_url}' http://[<address>]/x   # 301 https://[<address>]/x
    curl -sk -o /dev/null -w '%{http_code}' 'https://[<address>]/?q=<script>alert(1)</script>'   # 403
    grep -F '[id \"941100\"]' /var/log/coraza/audit.log   # the rule that blocked, on the container
    curl -sk -A 'Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0' \
        https://[<address>]/             # Anubis's challenge page

and without gzip, the challenge every time, never 500 (keel-web#2):

    for i in $(seq 200); do curl -sk -o /dev/null -w '%{http_code}\n' \
        -A 'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)' \
        https://[<address>]/; done | sort | uniq -c                  # 200 200

A real browser (chromium with playwright-core, not headless Chrome's user
agent, which the policy denies) passes the challenge and gets the
placeholder, by name and by IP, IPv6 and IPv4: by IP, Anubis's
pass-challenge carries `redir=https://<IP>/`, which CRS 931100 blocked
until keel-overlay-coraza 0.1.2.

A verified crawler is Googlebot's user agent from one of Google's
published ranges. A test cannot send from those addresses, so it is
simulated behind a trusted proxy, the `header` case of decision 0042's
`web.real_ip`: a file in `conf.d` trusts the test client's address
(`set_real_ip_from`) and takes the client from `X-Forwarded-For`. Nginx
then hands Anubis that address in `X-Real-IP`, as it would a real one:

    curl -sk -A 'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)' \
        -H 'X-Forwarded-For: 2001:4860:4801:10::1' https://[<address>]/  # the page
    curl -sk -A 'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)' \
        https://[<address>]/                                              # challenged

A second `keel spec apply --system` changes nothing, and turning the two
overlays off again puts the default site back (the placeholder on both
schemes, HTTP not redirected) and unloads Coraza.
