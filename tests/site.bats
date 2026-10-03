#!/usr/bin/env bats
# The default site of Keel Web on a Debian 13 machine with systemd and
# Nginx running, keel-web installed with keel-overlay-nginx and
# keel-overlay-anubis: what a simple installation serves (handbook
# decisions 0030, 0042), the mode switch the anubis state hook makes and
# undoes, and a remove and reinstall of the package.
#
# This suite changes the machine it runs on: it links and unlinks sites,
# reloads Nginx, removes and installs keel-web. It runs only where
# KEEL_WEB_SITE_TEST=1 says the machine is disposable, as root, under
# systemd, with the machine's certificate at the paths keel-host-keys
# writes it. KEEL_WEB_DEB names the keel-web .deb to reinstall (default:
# dist/keel-web_*_all.deb of the repository). The CI job "site" of
# packages.yml runs it in a trixie LXC system container booted with
# systemd; Anubis itself is not running there, so behind the front port
# 443 answers 502, which is enough to see that the front took it.
#
# Every verdict is the one Nginx, curl, openssl and dpkg give on the
# machine. Refutations are written "run ! cmd", never a bare "! cmd".

bats_require_minimum_version 1.5.0

SITE=/etc/nginx/sites-available/keel-default
FRONT=/etc/nginx/sites-available/default-anubis
ENABLED=/etc/nginx/sites-enabled
PAGES=/usr/share/keel-web/default-site
HOOK=/usr/lib/keel/overlays/anubis/state.d/50keel-web
RECORD=/var/lib/keel-web/debian-default-unlinked
CERT=/usr/local/share/ca-certificates/cert.crt
DROPIN=/usr/lib/systemd/system/nginx.service.d/keel-web.conf

setup_file() {
    if [ "${KEEL_WEB_SITE_TEST:-}" != 1 ]; then
        echo "refusing to run: this suite reloads Nginx and removes and" \
            "installs keel-web; set KEEL_WEB_SITE_TEST=1 on a disposable machine" >&2
        return 1
    fi
    if [ "$(id -u)" -ne 0 ]; then
        echo "refusing to run: needs root" >&2
        return 1
    fi
    if [ ! -d /run/systemd/system ]; then
        echo "refusing to run: needs systemd running; Nginx is its service" >&2
        return 1
    fi
    # the address the site is reached by from outside: port 80 of the
    # loopback is keel-overlay-nginx's /keel-health server
    ADDR="$(ip -o -6 addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)"
    if [ -n "$ADDR" ]; then
        HOST="[$ADDR]"
    else
        ADDR="$(ip -o -4 addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)"
        HOST="$ADDR"
    fi
    if [ -z "$ADDR" ]; then
        echo "refusing to run: the machine has no global address to reach the site by" >&2
        return 1
    fi
    export ADDR HOST
}

setup() {
    REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    DEB="${KEEL_WEB_DEB:-$(ls "$REPO"/dist/keel-web_*_all.deb 2>/dev/null | head -1)}"
    export DEBIAN_FRONTEND=noninteractive
}

# the status of URL, following nothing
code() {
    curl -sk -o /dev/null -w '%{http_code}' "$@"
}

# the body of URL
body() {
    curl -sk "$@"
}

# a reload is a signal to the master: the new workers take a moment
eventually_code() {
    local want=$1 url=$2 i got
    for i in $(seq 50); do
        got="$(code "$url")"
        [ "$got" = "$want" ] && return 0
        sleep 0.1
    done
    echo "wanted $want from $url, got $got" >&2
    return 1
}

# the same for a page: Debian's and the default site both answer 200, so
# a switch between them shows in the body alone
eventually_says() {
    local want=$1 url=$2 i
    for i in $(seq 50); do
        [[ "$(body "$url")" == *"$want"* ]] && return 0
        sleep 0.1
    done
    echo "wanted \"$want\" from $url" >&2
    return 1
}

site_linked() {
    [ "$(readlink "$ENABLED/keel-default")" = "$SITE" ]
}

front_linked() {
    [ "$(readlink "$ENABLED/default-anubis")" = "$FRONT" ]
}

nothing_at() {
    [ ! -e "$1" ] && [ ! -L "$1" ]
}

# the machine as installed

@test "Nginx runs and accepts the configuration with the default site" {
    systemctl is-active nginx.service
    run nginx -t
    [ "$status" -eq 0 ]
    site_linked
}

# keel-host-keys.service makes the certificate Nginx needs to start; it is
# not on this machine, and a Wants= of a missing unit is no error
@test "nginx.service wants and starts after keel-host-keys.service, through keel-web's drop-in" {
    run systemctl show nginx.service -p DropInPaths --value
    [[ "$output" == *"$DROPIN"* ]]
    run systemctl show nginx.service -p Wants --value
    [[ " $output " == *" keel-host-keys.service "* ]]
    run systemctl show nginx.service -p After --value
    [[ " $output " == *" keel-host-keys.service "* ]]
}

@test "Debian's default site is disabled, its file kept, and the removal recorded" {
    nothing_at "$ENABLED/default"
    [ -f /etc/nginx/sites-available/default ]
    [ -f "$RECORD" ]
}

@test "the pages are the package's, through /var/www/keel-default" {
    [ "$(readlink /var/www/keel-default)" = "$PAGES" ]
    [ -f /var/www/keel-default/index.html ]
    [ -f /var/www/keel-default/404.html ]
    [ -f /var/www/keel-default/50x.html ]
}

# the manifest's check: 204 on the loopback, where keel-overlay-nginx's
# server answers port 80 and the default site answers 443, and on the
# machine's address on both schemes
@test "/keel-health answers 204 on both loopbacks and both schemes" {
    [ "$(code 'http://[::1]/keel-health')" = 204 ]
    [ "$(code 'http://127.0.0.1/keel-health')" = 204 ]
    [ "$(code 'https://[::1]/keel-health')" = 204 ]
    [ "$(code 'https://127.0.0.1/keel-health')" = 204 ]
    [ "$(code "http://$HOST/keel-health")" = 204 ]
    [ "$(code "https://$HOST/keel-health")" = 204 ]
}

@test "the placeholder is served at / over HTTP, not redirected" {
    [ "$(code "http://$HOST/")" = 200 ]
    run body -i "http://$HOST/"
    [[ "$output" == *"Content-Type: text/html"* ]]
    [[ "$output" == *"Keel Web"* ]]
    [[ "$output" == *"No site is configured"* ]]
    [[ "$output" == *"instance.yaml"* ]]
}

@test "the placeholder is served at / over HTTPS with the machine's certificate" {
    [ "$(code "https://$HOST/")" = 200 ]
    run body "https://$HOST/"
    [[ "$output" == *"No site is configured"* ]]
    # the certificate Nginx serves is cert.pem's: cert.crt verifies it
    local cn
    cn="$(openssl x509 -in "$CERT" -noout -subject -nameopt sep_multiline,utf8 | awk -F= '/CN=/ { print $2 }')"
    [ -n "$cn" ]
    run curl -s -o /dev/null -w '%{http_code}' --cacert "$CERT" \
        --resolve "$cn:443:$HOST" "https://$cn/"
    [ "$output" = 200 ]
}

@test "HTTPS is HTTP/2, TLS 1.2 and 1.3, never 1.1" {
    run curl -sk --http2 -o /dev/null -w '%{http_version}' "https://$HOST/"
    [ "$output" = 2 ]
    run curl -sk --tlsv1.2 --tls-max 1.2 -o /dev/null -w '%{http_code}' "https://$HOST/"
    [ "$output" = 200 ]
    run curl -sk --tlsv1.3 -o /dev/null -w '%{http_code}' "https://$HOST/"
    [ "$output" = 200 ]
    run ! curl -sk --tlsv1.1 --tls-max 1.1 -o /dev/null "https://$HOST/"
}

# the Server header, as curl prints it, lower-cased and without its CR
server_header() {
    curl -sk -I "$1" | grep -i '^server:' | tr -d '\r' | tr '[:upper:]' '[:lower:]'
}

@test "no server version in the headers" {
    run server_header "http://$HOST/"
    [ "$output" = "server: nginx" ]
    run server_header "https://$HOST/"
    [ "$output" = "server: nginx" ]
}

@test "an unknown path answers the site's own 404 page, naming no version" {
    [ "$(code "http://$HOST/no-such-page")" = 404 ]
    run body "http://$HOST/no-such-page"
    [[ "$output" == *"Not found"* ]]
    [[ "$output" == *"Keel Web"* ]]
    [[ "$output" != *"nginx/"* ]]
    [ "$(code "https://$HOST/no-such-page")" = 404 ]
    run body "https://$HOST/no-such-page"
    [[ "$output" == *"Not found"* ]]
}

@test "the error pages themselves are not served by name" {
    [ "$(code "http://$HOST/404.html")" = 404 ]
    [ "$(code "http://$HOST/50x.html")" = 404 ]
}

@test "nothing of TurnKey on the pages" {
    run body "http://$HOST/"
    [[ "$output" != *[Tt]urn[Kk]ey* ]]
    run body "http://$HOST/no-such-page"
    [[ "$output" != *[Tt]urn[Kk]ey* ]]
}

# the mode switch: the anubis overlay turned on puts the front in the
# default site's place, turned off puts the default site back

@test "anubis enabled: the front takes the default server, HTTP redirects to HTTPS, 443 is Anubis's" {
    run "$HOOK" enabled
    [ "$status" -eq 0 ]
    front_linked
    nothing_at "$ENABLED/keel-default"
    nothing_at "$ENABLED/default"
    run nginx -t
    [ "$status" -eq 0 ]
    eventually_code 301 "http://$HOST/x"
    run curl -s -o /dev/null -w '%{redirect_url}' "http://$HOST/x"
    [ "$output" = "https://$HOST/x" ]
    # Anubis is not running on this machine: the proxy behind 443 answers
    # 502, with the default site's 50x page, not the placeholder
    [ "$(code "https://$HOST/")" = 502 ]
    run body "https://$HOST/"
    [[ "$output" == *"<title>Not available</title>"* ]]
    [[ "$output" == *"This Keel Web node could not answer the request."* ]]
    [[ "$output" != *"No site is configured"* ]]
    [[ "$output" != *"nginx/"* ]]
}

@test "anubis enabled twice changes nothing" {
    run "$HOOK" enabled
    [ "$status" -eq 0 ]
    [[ "$output" == *"unchanged (enabled)"* ]]
    front_linked
}

@test "anubis disabled: the default site comes back and serves the placeholder" {
    run "$HOOK" disabled
    [ "$status" -eq 0 ]
    site_linked
    nothing_at "$ENABLED/default-anubis"
    nothing_at "$ENABLED/default"
    run nginx -t
    [ "$status" -eq 0 ]
    eventually_code 200 "http://$HOST/"
    run body "http://$HOST/"
    [[ "$output" == *"No site is configured"* ]]
    [ "$(code "https://$HOST/keel-health")" = 204 ]
}

@test "anubis disabled twice changes nothing" {
    run "$HOOK" disabled
    [ "$status" -eq 0 ]
    [[ "$output" == *"unchanged (disabled)"* ]]
    site_linked
}

# remove and reinstall: the pages leave with the package, so its sites
# leave sites-enabled and Debian's default site comes back; a reinstall
# puts the default site in again

@test "a remove disables the default site and links Debian's default site again" {
    [ -f "$DEB" ]
    run dpkg -r keel-web
    [ "$status" -eq 0 ]
    nothing_at "$ENABLED/keel-default"
    [ "$(readlink "$ENABLED/default")" = /etc/nginx/sites-available/default ]
    nothing_at /var/www/keel-default
    [ -f "$SITE" ]
    run nginx -t
    [ "$status" -eq 0 ]
    # Debian's page, through the nginx-reload trigger
    eventually_says "<title>Welcome to nginx!</title>" "http://$HOST/"
    [ "$(code "http://$HOST/")" = 200 ]
    run body "http://$HOST/"
    [[ "$output" == *"<title>Welcome to nginx!</title>"* ]]
    [[ "$output" != *"No site is configured"* ]]
    # the drop-in leaves with the package, and systemd knows
    nothing_at "$DROPIN"
    run systemctl show nginx.service -p DropInPaths --value
    [[ "$output" != *"$DROPIN"* ]]
}

@test "a reinstall puts the default site in Debian's place again" {
    run dpkg -i "$DEB"
    [ "$status" -eq 0 ]
    site_linked
    nothing_at "$ENABLED/default"
    [ -f "$RECORD" ]
    [ "$(readlink /var/www/keel-default)" = "$PAGES" ]
    run nginx -t
    [ "$status" -eq 0 ]
    eventually_says "No site is configured" "http://$HOST/"
    [ "$(code "http://$HOST/")" = 200 ]
}

@test "a purge and a fresh installation do the same" {
    run dpkg -P keel-web
    [ "$status" -eq 0 ]
    [ "$(readlink "$ENABLED/default")" = /etc/nginx/sites-available/default ]
    [ ! -e "$SITE" ]
    [ ! -e /var/lib/keel-web ]
    run dpkg -i "$DEB"
    [ "$status" -eq 0 ]
    site_linked
    nothing_at "$ENABLED/default"
    eventually_code 200 "https://$HOST/"
    [ "$(code "https://$HOST/keel-health")" = 204 ]
}

# the postinst's nginx -t: refused with the machine's certificate in place,
# Debian's default site is kept; with the certificate not made yet (fab's
# chroot, before keel-host-keys runs at the first boot) the site is enabled
# all the same and the check left to then

@test "a configuration nginx -t refuses keeps Debian's default site, the default site not enabled" {
    run dpkg -P keel-web
    [ "$status" -eq 0 ]
    echo 'keel_web_site_test_refused on;' > /etc/nginx/conf.d/zz-keel-web-site-test.conf
    run dpkg -i "$DEB"
    rm -f /etc/nginx/conf.d/zz-keel-web-site-test.conf
    [ "$status" -eq 0 ]
    [[ "$output" == *"nginx -t refused the configuration"* ]]
    nothing_at "$ENABLED/keel-default"
    [ "$(readlink "$ENABLED/default")" = /etc/nginx/sites-available/default ]
    nothing_at "$RECORD"
    run nginx -t
    [ "$status" -eq 0 ]
}

@test "an installation before the machine's certificate is made enables the default site, nginx -t left to the first boot" {
    run dpkg -P keel-web
    [ "$status" -eq 0 ]
    mkdir -p "$BATS_FILE_TMPDIR/ssl"
    mv /etc/ssl/private/cert.pem /etc/ssl/private/cert.key "$BATS_FILE_TMPDIR/ssl/"
    run dpkg -i "$DEB"
    local installed=$status said=$output
    # what the postinst's nginx -t would have refused
    run nginx -t
    local checked=$status
    mv "$BATS_FILE_TMPDIR/ssl/cert.pem" "$BATS_FILE_TMPDIR/ssl/cert.key" /etc/ssl/private/
    [ "$installed" -eq 0 ]
    [[ "$said" == *"nginx -t"*"first boot"* ]]
    [ "$checked" -ne 0 ]
    site_linked
    nothing_at "$ENABLED/default"
    [ -f "$RECORD" ]
    # the certificate made, the site serves
    run nginx -t
    [ "$status" -eq 0 ]
    systemctl reload nginx.service
    eventually_code 200 "https://$HOST/"
    run body "https://$HOST/"
    [[ "$output" == *"No site is configured"* ]]
}
