#!/usr/bin/env bats
# Unit tests of conf.d/main, the conf script fab runs in the image chroot
# of the web layer. It is run here against a scratch tree through
# KEEL_CONF_ROOT, so nothing needs root, a chroot or the packages: the
# files are made the way the packages leave them in a simple installation.

bats_require_minimum_version 1.5.0

CONF="$BATS_TEST_DIRNAME/../conf.d/main"
WANTS=etc/systemd/system/multi-user.target.wants
SITE=/etc/nginx/sites-available/keel-default

setup() {
    ROOT=$(mktemp -d)
    export KEEL_CONF_ROOT="$ROOT"
    mkdir -p "$ROOT/etc/anubis" "$ROOT/etc/nginx/sites-available" "$ROOT/etc/nginx/sites-enabled" \
        "$ROOT/etc/nginx/modules-enabled" "$ROOT/etc/nginx/conf.d" "$ROOT/$WANTS"
    # as keel-web's postinst leaves it: its default site linked, Debian's
    # file in place and its link gone
    echo "# Debian's default server" > "$ROOT/etc/nginx/sites-available/default"
    echo "# keel-web's default site" > "$ROOT$SITE"
    ln -s "$SITE" "$ROOT/etc/nginx/sites-enabled/keel-default"
    echo "BIND=[::1]:8923" > "$ROOT/etc/anubis/keel.env"
    # the pages: a directory here, a link to /usr/share/keel-web on a machine
    mkdir -p "$ROOT/var/www/keel-default"
    echo "<title>Keel Web</title>" > "$ROOT/var/www/keel-default/index.html"
    echo "<title>Not found</title>" > "$ROOT/var/www/keel-default/404.html"
    echo "<title>Not available</title>" > "$ROOT/var/www/keel-default/50x.html"
    mkdir -p "$ROOT/etc/confconsole"
    cp "$BATS_TEST_DIRNAME/../overlay/etc/confconsole/services.txt" "$ROOT/etc/confconsole/services.txt"
}

# the usage screen of the recipe's overlay

USAGE="$BATS_TEST_DIRNAME/../overlay/etc/confconsole/services.txt"

# HTTPS: the default site serves it in every mode, with the machine's
# certificate, and the keel banner takes the scheme of its Web line from
# this file (keel-core's keel_banner_web_scheme)
@test "usage: the site comes first, HTTPS, by IPv6 and by IPv4, then Webmin and SSH" {
    run cat "$USAGE"
    [ "${lines[0]}" = 'Web:        https://[$ipaddr6]' ]
    [ "${lines[1]}" = 'Webmin:     https://[$ipaddr6]:12321' ]
    [ "${lines[2]}" = 'SSH/SFTP:   root@$ipaddr6 (port 22)' ]
    [ "${lines[3]}" = 'Web:        https://$ipaddr' ]
    [ "${lines[4]}" = 'Webmin:     https://$ipaddr:12321' ]
    [ "${lines[5]}" = 'SSH/SFTP:   root@$ipaddr (port 22)' ]
    [ "${#lines[@]}" -eq 6 ]
}

# No web shell, which Keel dropped from Core (Keel-Linux/handbook#31)
@test "usage: every line fits the screen and names no web shell" {
    run awk 'length > 50' "$USAGE"
    [ -z "$output" ]
    run grep -c -i 'shell\|12320' "$USAGE"
    [ "$output" = 0 ]
}

teardown() {
    rm -rf "$ROOT"
}

# the image as it should be

@test "the simple state passes: keel-web's default site, no key, nothing of Coraza or Anubis on" {
    run bash "$CONF"
    [ "$status" -eq 0 ]
}

# what no image may carry

@test "an Anubis signing key fails the build" {
    echo 00 > "$ROOT/etc/anubis/keel.key"
    run bash "$CONF"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL: /etc/anubis/keel.key is in the image"* ]]
}

@test "a dangling link where the key goes fails the build too" {
    ln -s /srv/gone "$ROOT/etc/anubis/keel.key"
    run bash "$CONF"
    [ "$status" -eq 1 ]
}

@test "a record of the overlays' state hooks fails the build" {
    mkdir -p "$ROOT/var/lib/keel/overlays"
    echo enabled > "$ROOT/var/lib/keel/overlays/coraza"
    run bash "$CONF"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL: /var/lib/keel/overlays/coraza is in the image"* ]]
}

# the simple state of the three overlays

@test "Anubis enabled fails the build" {
    ln -s /usr/lib/systemd/system/anubis@.service "$ROOT/$WANTS/anubis@keel.service"
    run bash "$CONF"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL: anubis@keel.service is enabled in the image"* ]]
}

@test "Coraza's module linked fails the build" {
    ln -s /usr/share/nginx/modules-available/mod-http-coraza.conf \
        "$ROOT/etc/nginx/modules-enabled/50-mod-http-coraza.conf"
    run bash "$CONF"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL: /etc/nginx/modules-enabled/50-mod-http-coraza.conf is in the image"* ]]
}

@test "Coraza's configuration linked fails the build" {
    ln -s /etc/nginx/coraza/keel.conf "$ROOT/etc/nginx/conf.d/keel-coraza.conf"
    run bash "$CONF"
    [ "$status" -eq 1 ]
}

@test "the Anubis front linked fails the build" {
    ln -s /etc/nginx/sites-available/default-anubis "$ROOT/etc/nginx/sites-enabled/default-anubis"
    run bash "$CONF"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL: /etc/nginx/sites-enabled/default-anubis is in the image"* ]]
}

# the default site of a simple installation is keel-web's, in Debian's
# place: the postinst links it when Debian's is the unedited one
# nginx-common shipped, and the build must find that it did

@test "keel-web's default site not enabled fails the build" {
    rm "$ROOT/etc/nginx/sites-enabled/keel-default"
    run bash "$CONF"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL: keel-web's default site is not enabled in the image"* ]]
}

@test "a keel-default link that is not keel-web's fails the build" {
    ln -sfn /srv/mine "$ROOT/etc/nginx/sites-enabled/keel-default"
    run bash "$CONF"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL: keel-web's default site is not enabled in the image"* ]]
}

@test "Debian's default site enabled fails the build" {
    ln -s /etc/nginx/sites-available/default "$ROOT/etc/nginx/sites-enabled/default"
    run bash "$CONF"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL: Debian's default site is enabled in the image"* ]]
}

@test "Debian's default site missing from sites-available fails the build: the purge of keel-web puts it back" {
    rm "$ROOT/etc/nginx/sites-available/default"
    run bash "$CONF"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL: /etc/nginx/sites-available/default is not in the image"* ]]
}

# the pages of the default site, reached through /var/www/keel-default

@test "a default site with no page fails the build" {
    rm "$ROOT/var/www/keel-default/index.html"
    run bash "$CONF"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL: /var/www/keel-default/index.html, a page of the default site, is not in the image"* ]]
}

@test "a default site with no 404 or 50x page fails the build" {
    rm "$ROOT/var/www/keel-default/404.html"
    run bash "$CONF"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL: /var/www/keel-default/404.html"* ]]
    rm "$ROOT/var/www/keel-default/50x.html"
    run bash "$CONF"
    [[ "$output" == *"FATAL: /var/www/keel-default/50x.html"* ]]
}

# Core's recipe ships a usage screen of Webmin and SSH only; the web layer
# must replace it, or the console never shows the site (screenshot 024),
# and it must say HTTPS, which is what the site serves and what the banner
# reads the scheme from

@test "a usage screen that does not list the site fails the build" {
    printf '%s\n' 'Webmin:     https://[$ipaddr6]:12321' 'SSH/SFTP:   root@$ipaddr6 (port 22)' \
        > "$ROOT/etc/confconsole/services.txt"
    run bash "$CONF"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL: /etc/confconsole/services.txt does not list the site over HTTPS"* ]]
}

@test "a usage screen that lists the site over plain HTTP fails the build" {
    sed -i 's|https://|http://|' "$ROOT/etc/confconsole/services.txt"
    run bash "$CONF"
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not list the site over HTTPS"* ]]
}

@test "no usage screen at all fails the build too" {
    rm "$ROOT/etc/confconsole/services.txt"
    run bash "$CONF"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL: /etc/confconsole/services.txt does not list the site over HTTPS"* ]]
}

@test "every problem is reported, not only the first" {
    echo 00 > "$ROOT/etc/anubis/keel.key"
    rm "$ROOT/etc/nginx/sites-enabled/keel-default"
    run bash "$CONF"
    [ "$status" -eq 1 ]
    [[ "$output" == *"keel.key"* ]]
    [[ "$output" == *"default site"* ]]
}
