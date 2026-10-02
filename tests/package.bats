#!/usr/bin/env bats
# The keel-web package of packages/keel-web (handbook decision 0041, first
# implementation, step 7): built for real with dpkg-buildpackage, then its
# fields, its files and the manifest it ships read back. Needs dpkg-dev,
# debhelper and python3-yaml; no root, no network.

bats_require_minimum_version 1.5.0

PACKAGE_DIR="$BATS_TEST_DIRNAME/../packages/keel-web"
HOOK=usr/lib/keel/overlays/anubis/state.d/50keel-web
SITE=etc/nginx/sites-available/default-anubis

setup_file() {
    BUILD=$(mktemp -d)
    export BUILD
    cp -a "$PACKAGE_DIR" "$BUILD/src"
    (cd "$BUILD/src" && dpkg-buildpackage -us -uc -b >"$BUILD/build.log" 2>&1)
    DEB=$(ls "$BUILD"/keel-web_*_all.deb)
    export DEB
    dpkg-deb -x "$DEB" "$BUILD/root"
}

teardown_file() {
    rm -rf "$BUILD"
}

# the manifest as Python reads it, one expression per call
manifest() {
    python3 -c 'import sys, yaml
m = yaml.safe_load(open(sys.argv[1]))
print(eval(sys.argv[2]))' "$PACKAGE_DIR/manifest.yaml" "$1"
}

# one line of `dpkg-deb -c` for PATH
listed() {
    dpkg-deb -c "$DEB" | grep " ./$1\$"
}

# the package

@test "one binary package, keel-web, architecture all" {
    run dpkg-deb -f "$DEB" Package Architecture
    [ "$status" -eq 0 ]
    [ "$output" = $'Package: keel-web\nArchitecture: all' ]
}

@test "it depends on Core, the three Web overlays and the keel that runs state hooks" {
    run dpkg-deb -f "$DEB" Depends
    [ "$status" -eq 0 ]
    # anubis 1.27.0-0+keel2 serves the challenge to a client without gzip
    # (keel-web#2); keel-overlay-coraza 0.1.2 lets Anubis's pass-challenge
    # through when the site is opened by IP and names the rule it blocks
    # with in its audit log (0.1.1: its state hook, gzip answers whole)
    [ "$output" = "anubis (>= 1.27.0-0+keel2), keel (>= 0.15.0), keel-core, keel-overlay-anubis, keel-overlay-coraza (>= 0.1.2), keel-overlay-nginx" ]
}

@test "the manifest is installed as /usr/share/keel/appliances/web.yaml, 0644 root" {
    cmp "$PACKAGE_DIR/manifest.yaml" "$BUILD/root/usr/share/keel/appliances/web.yaml"
    run listed usr/share/keel/appliances/web.yaml
    [[ "$output" == "-rw-r--r-- root/root "* ]]
}

@test "the Anubis front of the default site is a conffile of Nginx's layout" {
    cmp "$PACKAGE_DIR/default-anubis" "$BUILD/root/$SITE"
    run listed "$SITE"
    [[ "$output" == "-rw-r--r-- root/root "* ]]
    run dpkg-deb -I "$DEB" conffiles
    [ "$output" = "/$SITE" ]
}

@test "the anubis state hook is an executable of root's that nobody else may write" {
    cmp "$PACKAGE_DIR/anubis-front" "$BUILD/root/$HOOK"
    run listed "$HOOK"
    [[ "$output" == "-rwxr-xr-x root/root "* ]]
}

# An upgrade that changes the front (0.1.1 moved it to HTTPS) reaches a
# running Nginx: the same trigger the libnginx-mod-* packages activate
@test "an install or upgrade has a running Nginx reload, through nginx's trigger" {
    run dpkg-deb -I "$DEB" triggers
    [ "$status" -eq 0 ]
    [[ "$output" == *"activate-noawait nginx-reload"* ]]
}

@test "nothing links the front at installation: no file in sites-enabled, no postinst" {
    [ ! -e "$BUILD/root/etc/nginx/sites-enabled" ]
    run dpkg-deb -I "$DEB" postinst
    [ "$status" -ne 0 ]
}

# postrm, the built one, run against a scratch root through DPKG_ROOT

postrm_root() {
    PR="$BATS_TEST_TMPDIR/root"
    mkdir -p "$PR/etc/nginx/sites-available" "$PR/etc/nginx/sites-enabled" "$PR/var/lib/keel-web"
    echo "server {}" > "$PR/etc/nginx/sites-available/default"
    ln -s /etc/nginx/sites-available/default-anubis "$PR/etc/nginx/sites-enabled/default-anubis"
    : > "$PR/var/lib/keel-web/debian-default-unlinked"
    dpkg-deb -e "$DEB" "$BATS_TEST_TMPDIR/control"
}

@test "postrm purge takes the front out and links Debian's default site again" {
    postrm_root
    DPKG_ROOT="$PR" run sh "$BATS_TEST_TMPDIR/control/postrm" purge
    [ "$status" -eq 0 ]
    [ ! -L "$PR/etc/nginx/sites-enabled/default-anubis" ]
    [ "$(readlink "$PR/etc/nginx/sites-enabled/default")" = /etc/nginx/sites-available/default ]
    [ ! -e "$PR/var/lib/keel-web" ]
}

@test "postrm purge keeps a default link of the operator's and makes none unrecorded" {
    postrm_root
    ln -s /srv/mine "$PR/etc/nginx/sites-enabled/default"
    DPKG_ROOT="$PR" run sh "$BATS_TEST_TMPDIR/control/postrm" purge
    [ "$(readlink "$PR/etc/nginx/sites-enabled/default")" = /srv/mine ]
    rm "$PR/etc/nginx/sites-enabled/default"
    mkdir -p "$PR/var/lib/keel-web"
    DPKG_ROOT="$PR" run sh "$BATS_TEST_TMPDIR/control/postrm" purge
    [ ! -L "$PR/etc/nginx/sites-enabled/default" ]
}

@test "postrm remove leaves the front and the record" {
    postrm_root
    DPKG_ROOT="$PR" run sh "$BATS_TEST_TMPDIR/control/postrm" remove
    [ "$status" -eq 0 ]
    [ -L "$PR/etc/nginx/sites-enabled/default-anubis" ]
    [ -f "$PR/var/lib/keel-web/debian-default-unlinked" ]
}

@test "postrm purge leaves a front link that is not keel-web's" {
    postrm_root
    ln -sfn /srv/other "$PR/etc/nginx/sites-enabled/default-anubis"
    DPKG_ROOT="$PR" run sh "$BATS_TEST_TMPDIR/control/postrm" purge
    [ "$(readlink "$PR/etc/nginx/sites-enabled/default-anubis")" = /srv/other ]
}

@test "it installs the manifest, the site, the hook and their documentation, nothing more" {
    run bash -c "dpkg-deb -c '$DEB' | awk '{print \$6}' | grep -v '/\$' | sort"
    [ "$status" -eq 0 ]
    [ "$output" = "./$SITE"$'\n'"./$HOOK"$'\n./usr/share/doc/keel-web/changelog.gz\n./usr/share/doc/keel-web/copyright\n./usr/share/keel/appliances/web.yaml' ]
}

# the site

# Anubis's cookies are Secure, so over plain HTTP no browser passed the
# challenge (the maintainer's screenshot 114): the front serves HTTPS and
# port 80 only redirects (handbook decision 0042, redirect_http)
@test "site: the front takes the default server on ports 80 and 443, IPv6 first, TLS on 443" {
    run grep -E '^\s*listen [^u]' "$PACKAGE_DIR/default-anubis"
    [ "${lines[0]}" = $'\tlisten [::]:80 default_server;' ]
    [ "${lines[1]}" = $'\tlisten 80 default_server;' ]
    [ "${lines[2]}" = $'\tlisten [::]:443 ssl default_server;' ]
    [ "${lines[3]}" = $'\tlisten 443 ssl default_server;' ]
    [ "${#lines[@]}" -eq 4 ]
}

@test "site: port 80 answers every request with 301 to the same URL on HTTPS" {
    run awk '/listen 80 default_server/,/^}/' "$PACKAGE_DIR/default-anubis"
    [[ "$output" == *$'\treturn 301 https://$host$request_uri;'* ]]
    [[ "$output" != *keel-anubis.conf* ]]
}

@test "site: 443 uses the machine's certificate, the default of decision 0042" {
    grep -q $'^\tssl_certificate /usr/local/share/ca-certificates/cert.crt;$' "$PACKAGE_DIR/default-anubis"
    grep -q $'^\tssl_certificate_key /etc/ssl/private/cert.key;$' "$PACKAGE_DIR/default-anubis"
    grep -q $'^\tssl_protocols TLSv1.2 TLSv1.3;$' "$PACKAGE_DIR/default-anubis"
}

# HSTS over a self-signed certificate locks visitors out (0042, tls.hsts)
@test "site: no HSTS while the certificate may be self-signed" {
    run grep -c -i 'strict-transport-security' "$PACKAGE_DIR/default-anubis"
    [ "$output" = 0 ]
}

@test "site: every request on 443 goes through the overlay's Anubis snippet" {
    run grep -c 'include /etc/nginx/snippets/keel-anubis.conf;' "$PACKAGE_DIR/default-anubis"
    [ "$output" = 1 ]
    run awk '/listen 443 ssl default_server/,/^}/' "$PACKAGE_DIR/default-anubis"
    [[ "$output" == *'include /etc/nginx/snippets/keel-anubis.conf;'* ]]
}

@test "site: what Anubis allows is served on keel-app.sock, trusting X-Real-IP from unix: only" {
    grep -q $'^\tlisten unix:/run/nginx/keel-app.sock;$' "$PACKAGE_DIR/default-anubis"
    grep -q $'^\tset_real_ip_from unix:;$' "$PACKAGE_DIR/default-anubis"
    grep -q $'^\treal_ip_header X-Real-IP;$' "$PACKAGE_DIR/default-anubis"
    run grep -c 'set_real_ip_from' "$PACKAGE_DIR/default-anubis"
    [ "$output" = 1 ]
}

# Anubis asks the socket for gzip and passes it on to a client that
# accepts it (measured), so the socket keeps Debian's gzip on: the front
# does not compress what it proxies
@test "site: the socket Anubis reads keeps gzip, so browsers get it" {
    run grep -c 'gzip' "$PACKAGE_DIR/default-anubis"
    [ "$output" = 0 ]
}

@test "site: the content is Debian's default site's, /var/www/html" {
    grep -q $'^\troot /var/www/html;$' "$PACKAGE_DIR/default-anubis"
    grep -q $'^\tindex index.html index.htm index.nginx-debian.html;$' "$PACKAGE_DIR/default-anubis"
}

# the manifest: the Web table of decision 0041

@test "manifest: an appliance named web, version 1, on core" {
    run manifest '(m["manifest_version"], m["kind"], m["name"], m["base"])'
    [ "$output" = "(1, 'appliance', 'web', 'core')" ]
}

@test "manifest: nginx is enabled in every mode" {
    run manifest 'm["overlays"]["nginx"]'
    [ "$output" = "{'simple': 'enabled', 'cloud_simple': 'enabled', 'cloud_advanced': 'enabled'}" ]
}

@test "manifest: coraza is disabled in simple and enabled in the cloud modes" {
    run manifest 'm["overlays"]["coraza"]'
    [ "$output" = "{'simple': 'disabled', 'cloud_simple': 'enabled', 'cloud_advanced': 'enabled'}" ]
}

@test "manifest: anubis is disabled in simple and enabled in the cloud modes" {
    run manifest 'm["overlays"]["anubis"]'
    [ "$output" = "{'simple': 'disabled', 'cloud_simple': 'enabled', 'cloud_advanced': 'enabled'}" ]
}

@test "manifest: exactly the three overlays of Web, and nothing else of its own" {
    run manifest '(sorted(m["overlays"]), sorted(set(m) - {"manifest_version", "kind", "name", "title", "summary", "base", "overlays"}))'
    [ "$output" = "(['anubis', 'coraza', 'nginx'], [])" ]
}
