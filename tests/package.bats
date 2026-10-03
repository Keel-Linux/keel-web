#!/usr/bin/env bats
# The keel-web package of packages/keel-web (handbook decision 0041, first
# implementation, step 7): built for real with dpkg-buildpackage, then its
# fields, its files, its two sites, its pages, its maintainer scripts and
# the manifest it ships read back. Needs dpkg-dev, debhelper and
# python3-yaml; no root, no network. The postinst and postrm are the built
# ones, run against a scratch root through DPKG_ROOT, with dpkg-query as a
# stub first in PATH (nginx-common's conffile checksum); nginx -t is not
# run under a scratch root, tests/site.bats runs it on a machine.

bats_require_minimum_version 1.5.0

PACKAGE_DIR="$BATS_TEST_DIRNAME/../packages/keel-web"
HOOK=usr/lib/keel/overlays/anubis/state.d/50keel-web
SITE=etc/nginx/sites-available/keel-default
FRONT=etc/nginx/sites-available/default-anubis
PAGES=usr/share/keel-web/default-site
DROPIN=usr/lib/systemd/system/nginx.service.d/keel-web.conf
DEBIAN_TEXT="# Debian's default server, as nginx-common ships it"

setup_file() {
    BUILD=$(mktemp -d)
    export BUILD
    cp -a "$PACKAGE_DIR" "$BUILD/src"
    (cd "$BUILD/src" && dpkg-buildpackage -us -uc -b >"$BUILD/build.log" 2>&1)
    DEB=$(ls "$BUILD"/keel-web_*_all.deb)
    export DEB
    dpkg-deb -x "$DEB" "$BUILD/root"
    dpkg-deb -e "$DEB" "$BUILD/control"
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
    # (keel-web#2), and keel3 redirects a solved challenge only to the
    # request's own origin while REDIRECT_DOMAINS is empty, as keel-web
    # leaves it (Keel-Linux/anubis#3); keel-overlay-coraza 0.1.2 lets
    # Anubis's pass-challenge through when the site is opened by IP and
    # names the rule it blocks with in its audit log (0.1.1: its state
    # hook, gzip answers whole)
    [ "$output" = "anubis (>= 1.27.0-0+keel3), keel (>= 0.15.0), keel-core, keel-overlay-anubis, keel-overlay-coraza (>= 0.1.2), keel-overlay-nginx" ]
}

@test "the manifest is installed as /usr/share/keel/appliances/web.yaml, 0644 root" {
    cmp "$PACKAGE_DIR/manifest.yaml" "$BUILD/root/usr/share/keel/appliances/web.yaml"
    run listed usr/share/keel/appliances/web.yaml
    [[ "$output" == "-rw-r--r-- root/root "* ]]
}

@test "the default site and its Anubis front are conffiles of Nginx's layout" {
    cmp "$PACKAGE_DIR/keel-default" "$BUILD/root/$SITE"
    cmp "$PACKAGE_DIR/default-anubis" "$BUILD/root/$FRONT"
    run listed "$SITE"
    [[ "$output" == "-rw-r--r-- root/root "* ]]
    run listed "$FRONT"
    [[ "$output" == "-rw-r--r-- root/root "* ]]
    run dpkg-deb -I "$DEB" conffiles
    [ "$output" = $'/'"$FRONT"$'\n/'"$SITE" ]
}

@test "the pages of the default site are installed under /usr/share, never /var/www" {
    local page
    for page in index.html 404.html 50x.html; do
        cmp "$PACKAGE_DIR/site/$page" "$BUILD/root/$PAGES/$page"
        run listed "$PAGES/$page"
        [[ "$output" == "-rw-r--r-- root/root "* ]]
    done
    run bash -c "dpkg-deb -c '$DEB' | awk '{print \$6}' | grep -c '^./var/www'"
    [ "$output" = 0 ]
}

@test "the anubis state hook is an executable of root's that nobody else may write" {
    cmp "$PACKAGE_DIR/anubis-front" "$BUILD/root/$HOOK"
    run listed "$HOOK"
    [[ "$output" == "-rwxr-xr-x root/root "* ]]
}

# An upgrade that changes a site (0.1.1 moved the front to HTTPS, 0.2.0
# adds the default site) reaches a running Nginx: the same trigger the
# libnginx-mod-* packages activate
@test "an install or upgrade has a running Nginx reload, through nginx's trigger" {
    run dpkg-deb -I "$DEB" triggers
    [ "$status" -eq 0 ]
    [[ "$output" == *"activate-noawait nginx-reload"* ]]
}

@test "nothing in sites-enabled is shipped: the postinst links the default site, the hook the front" {
    [ ! -e "$BUILD/root/etc/nginx/sites-enabled" ]
    [ -f "$BUILD/control/postinst" ]
    [ -f "$BUILD/control/postrm" ]
}

@test "it installs the manifest, the two sites, the three pages, the hook, Nginx's drop-in and their documentation, nothing more" {
    run bash -c "dpkg-deb -c '$DEB' | awk '{print \$6}' | grep -v '/\$' | sort"
    [ "$status" -eq 0 ]
    expected="$(printf '%s\n' "./$SITE" "./$FRONT" "./$HOOK" "./$DROPIN" \
        "./$PAGES/index.html" "./$PAGES/404.html" "./$PAGES/50x.html" \
        ./usr/share/doc/keel-web/changelog.gz ./usr/share/doc/keel-web/copyright \
        ./usr/share/keel/appliances/web.yaml | sort)"
    [ "$output" = "$expected" ]
}

# Nginx reads the machine's certificate to start at all, port 80 included:
# keel-host-keys.service makes a missing one, so Nginx wants it and starts
# after it. An ExecStartPre= of a drop-in would run after nginx.service's
# own nginx -t, which fails first.
@test "Nginx's drop-in has it want and start after keel-host-keys.service, and nothing else" {
    cmp "$PACKAGE_DIR/nginx-keel-host-keys.conf" "$BUILD/root/$DROPIN"
    run listed "$DROPIN"
    [[ "$output" == "-rw-r--r-- root/root "* ]]
    run grep -v -e '^#' -e '^$' "$BUILD/root/$DROPIN"
    [ "$output" = $'[Unit]\nWants=keel-host-keys.service\nAfter=keel-host-keys.service' ]
}

# the maintainer scripts, the built ones, against a scratch root through
# DPKG_ROOT: nginx-common's default site linked as a fresh nginx leaves it

scratch_root() {
    PR="$BATS_TEST_TMPDIR/root"
    mkdir -p "$PR/etc/nginx/sites-available" "$PR/etc/nginx/sites-enabled" \
        "$PR/var/www" "$PR/$PAGES"
    echo "$DEBIAN_TEXT" > "$PR/etc/nginx/sites-available/default"
    echo "# keel-web's default site" > "$PR/$SITE"
    echo "# keel-web's front" > "$PR/$FRONT"
    ln -s /etc/nginx/sites-available/default "$PR/etc/nginx/sites-enabled/default"
    # dpkg-query: nginx-common's conffiles, the default site with the
    # checksum of DEBIAN_TEXT; nothing while $BATS_TEST_TMPDIR/no-nginx-common exists
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat > "$BATS_TEST_TMPDIR/bin/dpkg-query" <<STUB
#!/bin/sh
[ -e "$BATS_TEST_TMPDIR/no-nginx-common" ] && { echo "dpkg-query: no packages found matching nginx-common" >&2; exit 1; }
echo " /etc/nginx/nginx.conf 0123456789abcdef0123456789abcdef"
echo " /etc/nginx/sites-available/default $(echo "$DEBIAN_TEXT" | md5sum | cut -d' ' -f1)"
STUB
    chmod +x "$BATS_TEST_TMPDIR/bin/dpkg-query"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

postinst() {
    DPKG_ROOT="$PR" sh "$BUILD/control/postinst" "$@"
}

postrm() {
    DPKG_ROOT="$PR" sh "$BUILD/control/postrm" "$@"
}

site_linked() {
    [ "$(readlink "$PR/etc/nginx/sites-enabled/keel-default")" = "/$SITE" ]
}

debian_linked() {
    [ "$(readlink "$PR/etc/nginx/sites-enabled/default")" = /etc/nginx/sites-available/default ]
}

debian_recorded() {
    [ -f "$PR/var/lib/keel-web/debian-default-unlinked" ]
}

# the machine's certificate as turnkey-make-ssl-cert --default writes it,
# which keel-host-keys does at the first boot: not there in an image build
machine_cert() {
    mkdir -p "$PR/etc/ssl/private"
    local file
    for file in cert.pem cert.key dhparams.pem; do
        echo "# $file" > "$PR/etc/ssl/private/$file"
    done
}

# the postinst

@test "postinst: a first installation puts the default site in Debian's place, and records it" {
    scratch_root
    run postinst configure
    [ "$status" -eq 0 ]
    site_linked
    [ ! -e "$PR/etc/nginx/sites-enabled/default" ] && [ ! -L "$PR/etc/nginx/sites-enabled/default" ]
    [ -f "$PR/etc/nginx/sites-available/default" ]
    debian_recorded
    [ -f "$PR/var/lib/keel-web/keel-default-enabled" ]
    [[ "$output" == *"keel-web: the default site is enabled"* ]]
}

# fab's chroot: the certificate comes at the first boot, so nginx -t would
# refuse the site there, and conf.d/main fails a build whose default site
# is not enabled
@test "postinst: before the machine's certificate is made, the site is enabled and nginx -t left to the first boot" {
    scratch_root
    run postinst configure
    [ "$status" -eq 0 ]
    site_linked
    debian_recorded
    [ -f "$PR/var/lib/keel-web/keel-default-enabled" ]
    [ "$(grep -c 'first boot' <<< "$output")" = 1 ]
    [[ "$output" == *"/etc/ssl/private/cert.pem"*"nginx -t"*"first boot"* ]]
}

@test "postinst: either half of the certificate missing leaves nginx -t to the first boot" {
    local file
    for file in cert.pem cert.key dhparams.pem; do
        rm -rf "$BATS_TEST_TMPDIR/root"
        scratch_root
        machine_cert
        rm "$PR/etc/ssl/private/$file"
        run postinst configure
        [ "$status" -eq 0 ]
        site_linked
        [[ "$output" == *"first boot"* ]]
    done
}

@test "postinst: with the machine's certificate in place, nothing is left to the first boot" {
    scratch_root
    machine_cert
    run postinst configure
    [ "$status" -eq 0 ]
    site_linked
    [[ "$output" != *"first boot"* ]]
}

@test "postinst: the pages are reached through /var/www/keel-default, a link to the package's directory" {
    scratch_root
    postinst configure
    [ "$(readlink "$PR/var/www/keel-default")" = "/$PAGES" ]
}

@test "postinst: a /var/www/keel-default of the operator's is left alone" {
    scratch_root
    mkdir "$PR/var/www/keel-default"
    echo mine > "$PR/var/www/keel-default/index.html"
    run postinst configure
    [ "$status" -eq 0 ]
    [ ! -L "$PR/var/www/keel-default" ]
    [ "$(cat "$PR/var/www/keel-default/index.html")" = mine ]
}

@test "postinst: an edited Debian default site is the operator's: left alone, the default site not enabled, and said" {
    scratch_root
    echo "server { listen 80 default_server; root /srv/mine; }" > "$PR/etc/nginx/sites-available/default"
    run postinst configure
    [ "$status" -eq 0 ]
    [[ "$output" == *"edited"*"not enabled"* ]]
    debian_linked
    [ ! -L "$PR/etc/nginx/sites-enabled/keel-default" ]
    run debian_recorded
    [ "$status" -ne 0 ]
}

@test "postinst: with nginx-common's checksum unreadable, Debian's default site is left alone" {
    scratch_root
    : > "$BATS_TEST_TMPDIR/no-nginx-common"
    run postinst configure
    [ "$status" -eq 0 ]
    debian_linked
    [ ! -L "$PR/etc/nginx/sites-enabled/keel-default" ]
}

@test "postinst: a default link that is not Debian's, or a file, is left alone" {
    scratch_root
    ln -sfn /srv/mine "$PR/etc/nginx/sites-enabled/default"
    run postinst configure
    [ "$status" -eq 0 ]
    [[ "$output" == *"not enabled"* ]]
    [ "$(readlink "$PR/etc/nginx/sites-enabled/default")" = /srv/mine ]
    [ ! -L "$PR/etc/nginx/sites-enabled/keel-default" ]
    rm "$PR/etc/nginx/sites-enabled/default"
    echo "server {}" > "$PR/etc/nginx/sites-enabled/default"
    run postinst configure
    [ "$status" -eq 0 ]
    [ -f "$PR/etc/nginx/sites-enabled/default" ]
    [ ! -L "$PR/etc/nginx/sites-enabled/keel-default" ]
}

# Debian's link gone is the operator's choice, and the default server may
# be a site of theirs: the default site would take default_server from it
@test "postinst: with Debian's default unlinked the default server is the operator's, and the default site is not enabled" {
    scratch_root
    rm "$PR/etc/nginx/sites-enabled/default"
    run postinst configure
    [ "$status" -eq 0 ]
    [[ "$output" == *"Debian's default site is not enabled"*"operator's"* ]]
    [ ! -L "$PR/etc/nginx/sites-enabled/keel-default" ]
    run debian_recorded
    [ "$status" -ne 0 ]
}

@test "postinst: a keel-default link of the operator's where the site goes is left alone" {
    scratch_root
    ln -s /srv/mine "$PR/etc/nginx/sites-enabled/keel-default"
    run postinst configure
    [ "$status" -eq 0 ]
    [ "$(readlink "$PR/etc/nginx/sites-enabled/keel-default")" = /srv/mine ]
    debian_linked
}

# an upgrade from 0.1.1 in a cloud mode: the front is linked, Debian's
# default is not, and the hook puts the default site in when the front goes
@test "postinst: with the front linked, nothing is linked and the default site is said to be behind Anubis" {
    scratch_root
    rm "$PR/etc/nginx/sites-enabled/default"
    ln -s "/$FRONT" "$PR/etc/nginx/sites-enabled/default-anubis"
    mkdir -p "$PR/var/lib/keel-web"
    : > "$PR/var/lib/keel-web/debian-default-unlinked"
    run postinst configure 0.1.1
    [ "$status" -eq 0 ]
    [[ "$output" == *"behind Anubis"* ]]
    [ ! -L "$PR/etc/nginx/sites-enabled/keel-default" ]
    [ "$(readlink "$PR/etc/nginx/sites-enabled/default-anubis")" = "/$FRONT" ]
    debian_recorded
}

# an upgrade from 0.1.1 in a simple installation: Debian's default site is
# linked, as on a first installation
@test "postinst: an upgrade from 0.1.1 enables the default site as a first installation does" {
    scratch_root
    run postinst configure 0.1.1
    [ "$status" -eq 0 ]
    site_linked
    debian_recorded
}

@test "postinst: an upgrade with the default site enabled changes nothing" {
    scratch_root
    postinst configure
    run postinst configure 0.2.0
    [ "$status" -eq 0 ]
    site_linked
    [[ "$output" != *"the default site is enabled"* ]]
}

# the operator removed the link keel-web made: an upgrade does not put it
# back, as apache2's maintscript helper remembers a2dissite
@test "postinst: an upgrade does not re-enable a default site the operator disabled" {
    scratch_root
    postinst configure
    rm "$PR/etc/nginx/sites-enabled/keel-default"
    run postinst configure 0.2.0
    [ "$status" -eq 0 ]
    [ ! -L "$PR/etc/nginx/sites-enabled/keel-default" ]
    [[ "$output" == *"disabled by the operator"* ]]
}

@test "postinst: anything but configure does nothing" {
    scratch_root
    run postinst abort-upgrade 0.1.1
    [ "$status" -eq 0 ]
    debian_linked
    [ ! -L "$PR/etc/nginx/sites-enabled/keel-default" ]
}

# the postrm: the pages leave with a remove, so the sites leave
# sites-enabled with it; the conffiles stay in sites-available until the
# purge, as dpkg has it

@test "postrm remove takes the default site out and links Debian's default site again" {
    scratch_root
    postinst configure
    run postrm remove
    [ "$status" -eq 0 ]
    [ ! -L "$PR/etc/nginx/sites-enabled/keel-default" ]
    debian_linked
    [ ! -L "$PR/var/www/keel-default" ]
    [ ! -e "$PR/var/lib/keel-web/debian-default-unlinked" ]
}

@test "postrm purge after remove is quiet and leaves Debian's default site linked" {
    scratch_root
    postinst configure
    postrm remove
    run postrm purge
    [ "$status" -eq 0 ]
    debian_linked
    [ ! -e "$PR/var/lib/keel-web" ]
}

@test "postrm purge takes the front out and links Debian's default site again" {
    scratch_root
    postinst configure
    rm "$PR/etc/nginx/sites-enabled/keel-default"
    ln -s "/$FRONT" "$PR/etc/nginx/sites-enabled/default-anubis"
    run postrm purge
    [ "$status" -eq 0 ]
    [ ! -L "$PR/etc/nginx/sites-enabled/default-anubis" ]
    debian_linked
    [ ! -e "$PR/var/lib/keel-web" ]
}

@test "a reinstall after a remove enables the default site again" {
    scratch_root
    postinst configure
    postrm remove
    run postinst configure 0.2.0
    [ "$status" -eq 0 ]
    site_linked
    debian_recorded
}

@test "postrm keeps a default link of the operator's and makes none unrecorded" {
    scratch_root
    postinst configure
    ln -s /srv/mine "$PR/etc/nginx/sites-enabled/default"
    run postrm purge
    [ "$(readlink "$PR/etc/nginx/sites-enabled/default")" = /srv/mine ]
    rm "$PR/etc/nginx/sites-enabled/default"
    run postrm purge
    [ "$status" -eq 0 ]
    [ ! -L "$PR/etc/nginx/sites-enabled/default" ]
}

@test "postrm leaves links and a /var/www/keel-default that are not keel-web's" {
    scratch_root
    postinst configure
    ln -sfn /srv/other "$PR/etc/nginx/sites-enabled/default-anubis"
    ln -sfn /srv/other "$PR/etc/nginx/sites-enabled/keel-default"
    rm "$PR/var/www/keel-default"
    mkdir "$PR/var/www/keel-default"
    run postrm purge
    [ "$status" -eq 0 ]
    [ "$(readlink "$PR/etc/nginx/sites-enabled/default-anubis")" = /srv/other ]
    [ "$(readlink "$PR/etc/nginx/sites-enabled/keel-default")" = /srv/other ]
    [ -d "$PR/var/www/keel-default" ]
}

@test "postrm upgrade changes nothing" {
    scratch_root
    postinst configure
    run postrm upgrade 0.2.0
    [ "$status" -eq 0 ]
    site_linked
    debian_recorded
}

# the default site: /etc/nginx/sites-available/keel-default

@test "default site: the default server on 80 and 443, IPv6 first, IPv4 on, TLS on 443, HTTP/2" {
    run grep -E '^\s*listen ' "$PACKAGE_DIR/keel-default"
    [ "${lines[0]}" = $'\tlisten [::]:80 default_server;' ]
    [ "${lines[1]}" = $'\tlisten 0.0.0.0:80 default_server;' ]
    [ "${lines[2]}" = $'\tlisten [::]:443 ssl default_server;' ]
    [ "${lines[3]}" = $'\tlisten 0.0.0.0:443 ssl default_server;' ]
    [ "${#lines[@]}" -eq 4 ]
    grep -q $'^\thttp2 on;$' "$PACKAGE_DIR/keel-default"
}

# The machine's certificate as turnkey-make-ssl-cert --default writes it
# (keel-host-keys at the first boot, the Certificate screen through ACME
# later, at the same paths): the combined cert.pem, the key, the DH
# parameters
@test "default site: the machine's certificate, key and DH parameters from /etc/ssl/private" {
    grep -q $'^\tssl_certificate /etc/ssl/private/cert.pem;$' "$PACKAGE_DIR/keel-default"
    grep -q $'^\tssl_certificate_key /etc/ssl/private/cert.key;$' "$PACKAGE_DIR/keel-default"
    grep -q $'^\tssl_dhparam /etc/ssl/private/dhparams.pem;$' "$PACKAGE_DIR/keel-default"
    grep -q $'^\tssl_protocols TLSv1.2 TLSv1.3;$' "$PACKAGE_DIR/keel-default"
}

# Mozilla's "intermediate": session tickets off, their key never rotates
# while Nginx runs and so undoes forward secrecy
@test "default site: no TLS session tickets" {
    grep -q $'^\tssl_session_tickets off;$' "$PACKAGE_DIR/keel-default"
}

@test "default site: TLS 1.2 ciphers are zz-ssl-ciphers', forward secret only" {
    local ciphers cipher
    ciphers="$(grep -oP "^\tssl_ciphers '\K[^']+" "$PACKAGE_DIR/keel-default")"
    [ "$ciphers" = "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305" ]
    for cipher in ${ciphers//:/ }; do
        [[ "$cipher" == ECDHE-* || "$cipher" == DHE-* ]]
    done
    grep -q $'^\tssl_prefer_server_ciphers off;$' "$PACKAGE_DIR/keel-default"
}

# HSTS over a self-signed certificate locks visitors out: it comes after
# ACME (Keel-Linux/tracker#51, 0042 tls.hsts)
@test "default site: no HSTS, and the follow-up written where the next reader looks" {
    run bash -c "grep -v '^[[:space:]]*#' '$PACKAGE_DIR/keel-default' | grep -c -i 'strict-transport-security'"
    [ "$output" = 0 ]
    grep -q 'TODO(Keel-Linux/tracker#51, decision 0042 tls.hsts)' "$PACKAGE_DIR/keel-default"
}

# ACME's http-01 needs port 80 to answer; the redirect is the cloud site's
@test "default site: HTTP is served, not redirected" {
    run bash -c "grep -v '^[[:space:]]*#' '$PACKAGE_DIR/keel-default' | grep -c 'return 301'"
    [ "$output" = 0 ]
}

@test "default site: the placeholder pages, from /var/www/keel-default, with its own 404 and 50x" {
    grep -q $'^\troot /var/www/keel-default;$' "$PACKAGE_DIR/keel-default"
    grep -q $'^\tindex index.html;$' "$PACKAGE_DIR/keel-default"
    grep -q $'^\terror_page 404 /404.html;$' "$PACKAGE_DIR/keel-default"
    grep -q $'^\terror_page 500 502 503 504 /50x.html;$' "$PACKAGE_DIR/keel-default"
    run awk '/location = \/404.html/,/}/' "$PACKAGE_DIR/keel-default"
    [[ "$output" == *internal* ]]
    run awk '/location = \/50x.html/,/}/' "$PACKAGE_DIR/keel-default"
    [[ "$output" == *internal* ]]
}

@test "default site: no server version in headers or error pages" {
    grep -q $'^\tserver_tokens off;$' "$PACKAGE_DIR/keel-default"
}

# the manifest's check, on the site's own addresses and on both schemes;
# the loopback on port 80 is keel-overlay-nginx's keel-health.conf
@test "default site: /keel-health answers 204 through try_files, as the overlay's does" {
    run bash -c "awk '/location = \/keel-health/,/}/' '$PACKAGE_DIR/keel-default' | grep -v '^[[:space:]]*#'"
    [[ "$output" == *'try_files /.keel-health-is-no-file =204;'* ]]
    [[ "$output" != *return* ]]
}

# the pages

@test "pages: the placeholder says what this is and where a site is configured, nothing of TurnKey or a version" {
    local index="$PACKAGE_DIR/site/index.html"
    grep -q '<title>Keel Web</title>' "$index"
    grep -q 'Keel Web' "$index"
    grep -qi 'no site' "$index"
    grep -q 'confconsole' "$index"
    grep -q 'instance.yaml' "$index"
    run grep -c -i 'turnkey\|nginx/[0-9]\|version' "$index"
    [ "$output" = 0 ]
}

@test "pages: 404 and 50x name the site and what happened" {
    grep -q '<title>Not found' "$PACKAGE_DIR/site/404.html"
    grep -q 'Keel Web' "$PACKAGE_DIR/site/404.html"
    grep -q '<title>Not available' "$PACKAGE_DIR/site/50x.html"
    grep -q 'Keel Web' "$PACKAGE_DIR/site/50x.html"
}

# plain and static: nothing a browser would fetch from elsewhere, nothing
# that runs
@test "pages: every page is static, with no external resource and no script" {
    local page
    for page in index.html 404.html 50x.html; do
        run grep -c -i -E '<script|<link |<iframe|<img|@import|url\(|https?://|src=' "$PACKAGE_DIR/site/$page"
        [ "$output" = 0 ]
        grep -q '<!DOCTYPE html>' "$PACKAGE_DIR/site/$page"
        grep -q '<meta charset="utf-8">' "$PACKAGE_DIR/site/$page"
        grep -q 'lang="en"' "$PACKAGE_DIR/site/$page"
    done
}

# the Anubis front: /etc/nginx/sites-available/default-anubis

# Anubis's cookies are Secure, so over plain HTTP no browser passed the
# challenge (the maintainer's screenshot 114): the front serves HTTPS and
# port 80 only redirects (handbook decision 0042, redirect_http)
@test "front: the front takes the default server on ports 80 and 443, IPv6 first, TLS on 443" {
    run grep -E '^\s*listen [^u]' "$PACKAGE_DIR/default-anubis"
    [ "${lines[0]}" = $'\tlisten [::]:80 default_server;' ]
    [ "${lines[1]}" = $'\tlisten 80 default_server;' ]
    [ "${lines[2]}" = $'\tlisten [::]:443 ssl default_server;' ]
    [ "${lines[3]}" = $'\tlisten 443 ssl default_server;' ]
    [ "${#lines[@]}" -eq 4 ]
}

@test "front: port 80 answers every request with 301 to the same URL on HTTPS" {
    run awk '/listen 80 default_server/,/^}/' "$PACKAGE_DIR/default-anubis"
    [[ "$output" == *$'\treturn 301 https://$host$request_uri;'* ]]
    [[ "$output" != *keel-anubis.conf* ]]
}

@test "front: 443 uses the machine's certificate, the default of decision 0042" {
    grep -q $'^\tssl_certificate /usr/local/share/ca-certificates/cert.crt;$' "$PACKAGE_DIR/default-anubis"
    grep -q $'^\tssl_certificate_key /etc/ssl/private/cert.key;$' "$PACKAGE_DIR/default-anubis"
    grep -q $'^\tssl_protocols TLSv1.2 TLSv1.3;$' "$PACKAGE_DIR/default-anubis"
}

# the list of common's conf/turnkey.d/zz-ssl-ciphers (Mozilla's
# "intermediate"), forward secret only, for TLS 1.2; TLS 1.3's suites are
# all forward secret
@test "front: TLS 1.2 ciphers are zz-ssl-ciphers', forward secret only" {
    local ciphers
    ciphers="$(grep -oP "^\tssl_ciphers '\K[^']+" "$PACKAGE_DIR/default-anubis")"
    [ "$ciphers" = "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305" ]
    local cipher
    for cipher in ${ciphers//:/ }; do
        [[ "$cipher" == ECDHE-* || "$cipher" == DHE-* ]]
    done
    grep -q $'^\tssl_prefer_server_ciphers off;$' "$PACKAGE_DIR/default-anubis"
}

@test "front: the HSTS and passthrough follow-ups are written where the next reader looks" {
    grep -q 'TODO(Keel-Linux/tracker#51, decision 0042 tls.hsts)' "$PACKAGE_DIR/default-anubis"
    grep -q '# Strict-Transport-Security once' "$PACKAGE_DIR/default-anubis"
    grep -q 'A tls-passthrough site of 0042 needs the stream front on port 443' "$PACKAGE_DIR/default-anubis"
}

# HSTS over a self-signed certificate locks visitors out (0042, tls.hsts)
@test "front: no HSTS while the certificate may be self-signed" {
    run bash -c "grep -v '^[[:space:]]*#' '$PACKAGE_DIR/default-anubis' | grep -c -i 'strict-transport-security'"
    [ "$output" = 0 ]
}

@test "front: every request on 443 goes through the overlay's Anubis snippet" {
    run grep -c 'include /etc/nginx/snippets/keel-anubis.conf;' "$PACKAGE_DIR/default-anubis"
    [ "$output" = 1 ]
    run awk '/listen 443 ssl default_server/,/^}/' "$PACKAGE_DIR/default-anubis"
    [[ "$output" == *'include /etc/nginx/snippets/keel-anubis.conf;'* ]]
}

@test "front: what Anubis allows is served on keel-app.sock, trusting X-Real-IP from unix: only" {
    grep -q $'^\tlisten unix:/run/nginx/keel-app.sock;$' "$PACKAGE_DIR/default-anubis"
    grep -q $'^\tset_real_ip_from unix:;$' "$PACKAGE_DIR/default-anubis"
    grep -q $'^\treal_ip_header X-Real-IP;$' "$PACKAGE_DIR/default-anubis"
    run grep -c 'set_real_ip_from' "$PACKAGE_DIR/default-anubis"
    [ "$output" = 1 ]
}

# Anubis asks the socket for gzip and passes it on to a client that
# accepts it (measured), so the socket keeps Debian's gzip on: the front
# does not compress what it proxies
@test "front: the socket Anubis reads keeps gzip, so browsers get it" {
    run grep -c 'gzip' "$PACKAGE_DIR/default-anubis"
    [ "$output" = 0 ]
}

# the same content in both modes: the pages of the default site
@test "front: the content is the default site's, /var/www/keel-default" {
    grep -q $'^\troot /var/www/keel-default;$' "$PACKAGE_DIR/default-anubis"
    grep -q $'^\tindex index.html;$' "$PACKAGE_DIR/default-anubis"
    run grep -c '/var/www/html' "$PACKAGE_DIR/default-anubis"
    [ "$output" = 0 ]
}

# a 502 or 504 while Anubis is down or slow is Nginx's own, on 443: the
# Keel pages there too, never nginx's stock page; the socket's server has
# them for what it serves
@test "front: 443 and the socket answer errors with the default site's 404 and 50x pages" {
    run grep -c $'^\terror_page 404 /404.html;$' "$PACKAGE_DIR/default-anubis"
    [ "$output" = 2 ]
    run grep -c $'^\terror_page 500 502 503 504 /50x.html;$' "$PACKAGE_DIR/default-anubis"
    [ "$output" = 2 ]
    run awk '/listen 443 ssl default_server/,/^}/' "$PACKAGE_DIR/default-anubis"
    [[ "$output" == *$'\troot /var/www/keel-default;'* ]]
    [[ "$output" == *$'\terror_page 500 502 503 504 /50x.html;'* ]]
    [[ "$output" == *$'location = /50x.html {\n\t\tinternal;\n\t}'* ]]
    [[ "$output" == *$'location = /404.html {\n\t\tinternal;\n\t}'* ]]
}

@test "front: no server version in headers or error pages, in any of its three servers" {
    run grep -c $'^\tserver_tokens off;$' "$PACKAGE_DIR/default-anubis"
    [ "$output" = 3 ]
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
