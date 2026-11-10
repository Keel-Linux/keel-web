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
REDIRECT=/etc/nginx/keel-web/http-redirect.conf
SITE_ACME=/etc/nginx/keel-web/site-acme.conf
FRONT_ACME=/etc/nginx/keel-web/front-acme.conf
ACME_SNIPPET=/etc/nginx/snippets/keel-web-acme.conf
ANUBIS_ENV=/etc/anubis/keel-web-http.env

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
    # the address the site is reached by from outside: the loopback of
    # port 80 is the site's too (0079), but never redirects
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
@test "nginx.service wants and starts after keel-host-keys.service and keel-web-http.service, through keel-web's drop-in" {
    run systemctl show nginx.service -p DropInPaths --value
    [[ "$output" == *"$DROPIN"* ]]
    run systemctl show nginx.service -p Wants --value
    [[ " $output " == *" keel-host-keys.service "* ]]
    [[ " $output " == *" keel-web-http.service "* ]]
    run systemctl show nginx.service -p After --value
    [[ " $output " == *" keel-host-keys.service "* ]]
    [[ " $output " == *" keel-web-http.service "* ]]
}

# decision 0079: the certificate here is self-signed, so http-mode has
# port 80 serve the site and Anubis's cookies go without Secure
@test "keel-web-http.path watches the certificate, and http-mode ran: no redirect, Anubis's file linked" {
    systemctl is-enabled keel-web-http.path
    systemctl is-active keel-web-http.path
    systemctl is-enabled keel-web-http.service
    nothing_at "$REDIRECT"
    [ "$(readlink "$ANUBIS_ENV")" = /usr/share/keel-web/anubis-http.env ]
    # keel-web 0.4.3: no route has its own challenge location here
    [ "$(readlink "$SITE_ACME")" = "$ACME_SNIPPET" ]
    [ "$(readlink "$FRONT_ACME")" = "$ACME_SNIPPET" ]
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

# the manifest's check: 204 on the loopback, where the default site takes
# port 80 from keel-overlay-nginx's server (0079), and on the machine's
# address on both schemes
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

# 0079: http://127.0.0.1/ is the site, not keel-health.conf's 404, so a
# check on the machine reaches the application on top
@test "the placeholder is served at / on the loopback of port 80" {
    [ "$(code 'http://127.0.0.1/')" = 200 ]
    [ "$(code 'http://[::1]/')" = 200 ]
    run body 'http://127.0.0.1/'
    [[ "$output" == *"No site is configured"* ]]
    [ "$(code 'http://127.0.0.1/no-such-page')" = 404 ]
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

# 0079: with the self-signed certificate, port 80 goes through Anubis as
# 443 does, with no redirect; the loopback too, but for /keel-health
@test "anubis enabled: the front takes the default server, and HTTP, HTTPS and the loopback are Anubis's" {
    run "$HOOK" enabled
    [ "$status" -eq 0 ]
    front_linked
    nothing_at "$ENABLED/keel-default"
    nothing_at "$ENABLED/default"
    run nginx -t
    [ "$status" -eq 0 ]
    # Anubis is not running on this machine: the proxy answers 502, with
    # the default site's 50x page, not the placeholder
    local url
    for url in "http://$HOST/" "https://$HOST/" 'http://127.0.0.1/' 'http://[::1]/'; do
        eventually_code 502 "$url"
        run body "$url"
        [[ "$output" == *"<title>Not available</title>"* ]]
        [[ "$output" == *"This Keel Web node could not answer the request."* ]]
        [[ "$output" != *"No site is configured"* ]]
        [[ "$output" != *"nginx/"* ]]
    done
    # the manifest's check, before Anubis, to the loopback only
    [ "$(code 'http://127.0.0.1/keel-health')" = 204 ]
    [ "$(code 'http://[::1]/keel-health')" = 204 ]
    [ "$(code "https://$HOST/keel-health")" = 403 ]
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

# Decision 0079: a certificate that a CA issued makes port 80 redirect to
# HTTPS, by keel-web-http.path alone, and the self-signed one back makes
# it serve again. Only cert.crt changes: the default site serves TLS from
# cert.pem, so its key still matches. The test CA is made here.
put_issued_cert() {
    local dir="$BATS_FILE_TMPDIR/ca"
    mkdir -p "$dir"
    openssl req -x509 -days 2 -nodes -newkey rsa:2048 -subj /CN=Site-Test-CA \
        -addext basicConstraints=critical,CA:TRUE \
        -keyout "$dir/ca.key" -out "$dir/ca.crt" 2>/dev/null
    openssl req -days 2 -nodes -newkey rsa:2048 -subj /CN=keel.example \
        -keyout "$dir/leaf.key" -out "$dir/leaf.csr" 2>/dev/null
    openssl x509 -req -in "$dir/leaf.csr" -CA "$dir/ca.crt" -CAkey "$dir/ca.key" \
        -CAcreateserial -days 2 \
        -extfile <(printf 'subjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\n') \
        -out "$dir/leaf.crt" 2>/dev/null
    cp "$CERT" "$BATS_FILE_TMPDIR/self-signed.crt"
    cat "$dir/leaf.crt" "$dir/ca.crt" > "$CERT"
}

# http-mode links the redirect first, then removes Anubis's file: wait for
# both
eventually_redirects() {
    local i
    for i in $(seq 100); do
        [ -L "$REDIRECT" ] && nothing_at "$ANUBIS_ENV" && return 0
        sleep 0.1
    done
    return 1
}

eventually_serves() {
    local i
    for i in $(seq 100); do
        nothing_at "$REDIRECT" && [ -L "$ANUBIS_ENV" ] && return 0
        sleep 0.1
    done
    return 1
}

@test "a CA's certificate: port 80 redirects to HTTPS, except ACME's challenges and the loopback" {
    put_issued_cert
    eventually_redirects
    eventually_code 301 "http://$HOST/x"
    run curl -s -o /dev/null -w '%{redirect_url}' "http://$HOST/x?y=1"
    [ "$output" = "https://$HOST/x?y=1" ]
    # dehydrated's WELLKNOWN on port 80, never redirected
    mkdir -p /var/lib/dehydrated/acme-challenges
    echo token-value > /var/lib/dehydrated/acme-challenges/site-test-token
    [ "$(body "http://$HOST/.well-known/acme-challenge/site-test-token")" = token-value ]
    [ "$(code "http://$HOST/.well-known/acme-challenge/no-such-token")" = 404 ]
    rm -f /var/lib/dehydrated/acme-challenges/site-test-token
    # the loopback and 443 still serve the site
    [ "$(code 'http://127.0.0.1/')" = 200 ]
    [ "$(code 'http://[::1]/keel-health')" = 204 ]
    [ "$(code "https://$HOST/")" = 200 ]
}

@test "the self-signed certificate back: port 80 serves the site again" {
    cp "$BATS_FILE_TMPDIR/self-signed.crt" "$CERT"
    eventually_serves
    [ "$(readlink "$ANUBIS_ENV")" = /usr/share/keel-web/anubis-http.env ]
    eventually_code 200 "http://$HOST/"
    run body "http://$HOST/"
    [[ "$output" == *"No site is configured"* ]]
}

# The front reads cert.crt with cert.key, so the whole pair changes here:
# the key and cert.pem first, cert.crt, which keel-web-http.path watches,
# last
put_issued_pair() {
    local dir="$BATS_FILE_TMPDIR/ca"
    mkdir -p "$BATS_FILE_TMPDIR/self"
    cp /etc/ssl/private/cert.key /etc/ssl/private/cert.pem "$CERT" "$BATS_FILE_TMPDIR/self/"
    cp "$dir/leaf.key" /etc/ssl/private/cert.key
    cat "$dir/leaf.crt" "$dir/ca.crt" "$dir/leaf.key" /etc/ssl/private/dhparams.pem > /etc/ssl/private/cert.pem
    cat "$dir/leaf.crt" "$dir/ca.crt" > "$CERT"
}

put_self_pair() {
    cp "$BATS_FILE_TMPDIR/self/cert.key" "$BATS_FILE_TMPDIR/self/cert.pem" /etc/ssl/private/
    cp "$BATS_FILE_TMPDIR/self/cert.crt" "$CERT"
}

@test "anubis enabled with a CA's certificate: port 80 redirects, ACME's challenges and the loopback do not" {
    run "$HOOK" enabled
    [ "$status" -eq 0 ]
    front_linked
    put_issued_pair
    eventually_redirects
    run nginx -t
    [ "$status" -eq 0 ]
    eventually_code 301 "http://$HOST/x"
    run curl -s -o /dev/null -w '%{redirect_url}' "http://$HOST/x"
    [ "$output" = "https://$HOST/x" ]
    mkdir -p /var/lib/dehydrated/acme-challenges
    echo token-value > /var/lib/dehydrated/acme-challenges/site-test-token
    [ "$(body "http://$HOST/.well-known/acme-challenge/site-test-token")" = token-value ]
    [ "$(code "http://$HOST/.well-known/acme-challenge/no-such-token")" = 404 ]
    rm -f /var/lib/dehydrated/acme-challenges/site-test-token
    # the loopback goes to Anubis (not running here: 502), never redirected
    [ "$(code 'http://127.0.0.1/')" = 502 ]
    [ "$(code 'http://[::1]/keel-health')" = 204 ]
    [ "$(code "https://$HOST/")" = 502 ]
    put_self_pair
    eventually_serves
    eventually_code 502 "http://$HOST/x"
    run "$HOOK" disabled
    [ "$status" -eq 0 ]
    site_linked
}

# Decision 0059, point 4: a route that a stack puts in keel-default.d is
# served by the default site on both schemes, and behind Anubis by the
# server on keel-app.sock, which Anubis proxies to.
ROUTE=/etc/nginx/keel-default.d/50-site-test.conf

put_route() {
    printf 'location = /keel-route-test {\n\treturn 200 "route\\n";\n}\n' > "$ROUTE"
    nginx -t
    systemctl reload nginx.service
}

@test "a route in keel-default.d is served by the default site on both schemes" {
    put_route
    eventually_code 200 "http://$HOST/keel-route-test"
    [ "$(body "http://$HOST/keel-route-test")" = route ]
    [ "$(body "https://$HOST/keel-route-test")" = route ]
    rm -f "$ROUTE"
    systemctl reload nginx.service
    eventually_code 404 "http://$HOST/keel-route-test"
}

@test "behind Anubis, a route in keel-default.d is served on keel-app.sock" {
    put_route
    run "$HOOK" enabled
    [ "$status" -eq 0 ]
    front_linked
    for i in $(seq 50); do
        [ -S /run/nginx/keel-app.sock ] && break
        sleep 0.1
    done
    run curl -s --unix-socket /run/nginx/keel-app.sock http://keel/keel-route-test
    [ "$output" = route ]
    run "$HOOK" disabled
    [ "$status" -eq 0 ]
    site_linked
    rm -f "$ROUTE"
    systemctl reload nginx.service
}

@test "behind Anubis, the front refuses a body of more than 1 MB, and a file in keel-front.d raises the limit" {
    local file=/etc/nginx/keel-front.d/zz-keel-web-test.conf head=/tmp/keel-web-body.bin
    head -c 2097152 /dev/zero > "$head"
    run "$HOOK" enabled
    [ "$status" -eq 0 ]
    front_linked
    run curl -sk -o /dev/null -w '%{http_code}' --data-binary "@$head" "https://$HOST/"
    [ "$output" = 413 ]
    # one limit in the file, and the front sets none: Nginx accepts it
    echo 'client_max_body_size 8m;' > "$file"
    nginx -t
    systemctl reload nginx.service
    for i in $(seq 50); do
        run curl -sk -o /dev/null -w '%{http_code}' --data-binary "@$head" "https://$HOST/"
        [ "$output" != 413 ] && break
        sleep 0.2
    done
    # the front took the body; Anubis is not running here, so the answer is 502
    [ "$output" = 502 ]
    rm -f "$file" "$head"
    run "$HOOK" disabled
    [ "$status" -eq 0 ]
    systemctl reload nginx.service
}

# Static files (2026-11-07): Anubis is not running here, so an answer
# of 502 says that the front gave the request to Anubis, and 200 says
# that Nginx served the file from the disk without Anubis.
@test "behind Anubis, a static file on the disk is served without Anubis; a .php path, a missing file and a hidden path go to Anubis" {
    local root=/var/www/keel-web-static-test conf=/etc/nginx/keel-static.d/zz-keel-web-test.conf
    mkdir -p "$root/css" "$root/.git"
    echo 'body { color: red; }' > "$root/css/site.css"
    echo 'body { color: red; }' > "$root/.git/x.css"
    echo '<?php echo 1;' > "$root/index.php"
    run "$HOOK" enabled
    [ "$status" -eq 0 ]
    # the default root: /var/www/keel-default has no such file
    eventually_code 502 "https://$HOST/css/site.css"
    echo "root $root;" > "$conf"
    nginx -t
    systemctl reload nginx.service
    eventually_code 200 "https://$HOST/css/site.css"
    run curl -sk -o /dev/null -w '%{content_type}' "https://$HOST/css/site.css"
    [[ "$output" == text/css* ]]
    [ "$(body "https://$HOST/css/site.css")" = 'body { color: red; }' ]
    [ "$(code "http://$HOST/css/site.css")" = 200 ]
    [ "$(code "https://$HOST/css/missing.css")" = 502 ]
    [ "$(code "https://$HOST/index.php")" = 502 ]
    [ "$(code "https://$HOST/index.php/css/site.css")" = 502 ]
    [ "$(code "https://$HOST/index.php?f=/css/site.css")" = 502 ]
    [ "$(code "https://$HOST/css/site.css.php")" = 502 ]
    [ "$(code "https://$HOST/.git/x.css")" = 502 ]
    [ "$(code "https://$HOST/css/")" = 502 ]
    rm -rf "$conf" "$root"
    run "$HOOK" disabled
    [ "$status" -eq 0 ]
    systemctl reload nginx.service
}

# keel-web 0.4.3: a route that serves ACME's challenge itself keeps it.
# The route of keel-ntfy 19.0-5 (stable 1), a file of the image that no
# package owns, has its own location for the challenge in keel-default.d.
# With keel-web 0.4.0 to 0.4.2 the port 80 server had two such locations,
# Nginx refused the configuration ("duplicate location") and did not
# start. Here the route is byte for byte the image's, with the two maps of
# the image's conf.d/keel-ntfy.conf and a stand-in for its proxy snippet
# (ntfy does not run here).
NTFY_ROUTE=/etc/nginx/keel-default.d/60-keel-ntfy.conf
NTFY_MAPS=/etc/nginx/conf.d/keel-ntfy.conf
NTFY_PROXY=/etc/nginx/snippets/keel-ntfy-proxy.conf

put_ntfy() {
    cat > "$NTFY_MAPS" <<'MAPS'
map $http_upgrade $keel_ntfy_connection {
	default upgrade;
	'' close;
}

map $server_addr $keel_ntfy_proto {
	default $scheme;
	~^unix: https;
}

map $keel_ntfy_proto $keel_ntfy_plain {
	default 0;
	http 1;
}
MAPS
    printf 'return 200 "ntfy stand-in\\n";\n' > "$NTFY_PROXY"
    cat > "$NTFY_ROUTE" <<'ROUTE'
# keel-ntfy: the route of ntfy (handbook decision 0063), as the image of
# 19.0-5 has it
location ^~ /.well-known/acme-challenge/ {
	try_files $uri =404;
}

location ~ ^/ {
	if ($keel_ntfy_plain) {
		return 301 https://$host$request_uri;
	}
	client_max_body_size 1m;
	include /etc/nginx/snippets/keel-ntfy-proxy.conf;
}
ROUTE
}

# what the configuration of keel-web 0.4.2 did with that route: the
# challenge location of keel-web in the same server
@test "the route of keel-ntfy beside keel-web's challenge location is a duplicate that nginx -t refuses" {
    put_ntfy
    [ "$(readlink "$SITE_ACME")" = "$ACME_SNIPPET" ]
    run nginx -t
    [ "$status" -ne 0 ]
    [[ "$output" == *"duplicate location"* ]]
}

# an upgrade, as the package is installed again: the postinst restarts
# keel-web-http.service, whose http-mode removes the link and reloads
# Nginx before the nginx-reload trigger reloads it
@test "the package installed with that route: the link goes, nginx -t passes, Nginx runs" {
    [ -f "$DEB" ]
    run dpkg -i "$DEB"
    [ "$status" -eq 0 ]
    nothing_at "$SITE_ACME"
    [ "$(readlink "$FRONT_ACME")" = "$ACME_SNIPPET" ]
    run nginx -t
    [ "$status" -eq 0 ]
    systemctl is-active nginx.service
    run journalctl -u keel-web-http.service --no-pager -n 20
    [[ "$output" == *"$NTFY_ROUTE serves ACME's challenge itself: $SITE_ACME is not linked"* ]]
}

# at boot and at each start of Nginx: http-mode runs first, while Nginx
# does not run, so a link that is there by mistake goes before Nginx reads
# it
@test "a restart of Nginx with that route: http-mode removes the link first, and Nginx starts" {
    ln -s "$ACME_SNIPPET" "$SITE_ACME"
    run nginx -t
    [ "$status" -ne 0 ]
    systemctl restart nginx.service
    systemctl is-active nginx.service
    nothing_at "$SITE_ACME"
    run nginx -t
    [ "$status" -eq 0 ]
    # the route serves the challenge on port 80, from the site's root, and
    # every other path of port 80 goes to HTTPS, as keel-ntfy has it
    eventually_code 404 "http://$HOST/.well-known/acme-challenge/no-such-token"
    [ "$(code "http://$HOST/x")" = 301 ]
    [ "$(body "https://$HOST/x")" = "ntfy stand-in" ]
    [ "$(code "https://$HOST/keel-health")" = 204 ]
}

# The answer to a missing challenge on that route with a CA's certificate
# is written to the log, not asserted: =404 runs the site's error_page,
# an internal redirect that the server-level redirect of
# http-redirect.conf sees again. The route is the image's, not keel-web's.
@test "with that route and a CA's certificate: Nginx accepts the redirect, and the route keeps the challenge" {
    put_issued_cert
    eventually_redirects
    run nginx -t
    [ "$status" -eq 0 ]
    nothing_at "$SITE_ACME"
    eventually_code 301 "http://$HOST/x"
    echo "# measured: a missing challenge on the route of keel-ntfy with a CA's certificate answers $(code "http://$HOST/.well-known/acme-challenge/no-such-token")" >&3
    cp "$BATS_FILE_TMPDIR/self-signed.crt" "$CERT"
    eventually_serves
}

# every other appliance: no such route, and port 80 is as with 0.4.2
@test "the route gone: a restart of Nginx links keel-web's challenge location again, and it serves the challenge" {
    rm -f "$NTFY_ROUTE" "$NTFY_MAPS" "$NTFY_PROXY"
    systemctl restart nginx.service
    systemctl is-active nginx.service
    [ "$(readlink "$SITE_ACME")" = "$ACME_SNIPPET" ]
    run nginx -t
    [ "$status" -eq 0 ]
    mkdir -p /var/lib/dehydrated/acme-challenges
    echo token-value > /var/lib/dehydrated/acme-challenges/site-test-token
    eventually_code 200 "http://$HOST/.well-known/acme-challenge/site-test-token"
    [ "$(body "http://$HOST/.well-known/acme-challenge/site-test-token")" = token-value ]
    [ "$(code "http://$HOST/.well-known/acme-challenge/no-such-token")" = 404 ]
    rm -f /var/lib/dehydrated/acme-challenges/site-test-token
    [ "$(code "http://$HOST/")" = 200 ]
}

# the front: its port 80 server includes keel-front.d, so a route there
# with its own challenge location keeps it
@test "behind Anubis, a route in keel-front.d with its own challenge location keeps it, and Nginx starts" {
    local file=/etc/nginx/keel-front.d/zz-keel-web-acme-test.conf
    run "$HOOK" enabled
    [ "$status" -eq 0 ]
    front_linked
    printf 'location ^~ /.well-known/acme-challenge/ {\n\treturn 200 "front route\\n";\n}\n' > "$file"
    run nginx -t
    [ "$status" -ne 0 ]
    [[ "$output" == *"duplicate location"* ]]
    systemctl restart nginx.service
    systemctl is-active nginx.service
    nothing_at "$FRONT_ACME"
    [ "$(readlink "$SITE_ACME")" = "$ACME_SNIPPET" ]
    eventually_code 200 "http://$HOST/.well-known/acme-challenge/x"
    [ "$(body "http://$HOST/.well-known/acme-challenge/x")" = "front route" ]
    rm -f "$file"
    systemctl restart nginx.service
    [ "$(readlink "$FRONT_ACME")" = "$ACME_SNIPPET" ]
    run "$HOOK" disabled
    [ "$status" -eq 0 ]
    site_linked
    run nginx -t
    [ "$status" -eq 0 ]
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
    # the drop-in and http-mode's units leave with the package, and
    # systemd knows
    nothing_at "$DROPIN"
    nothing_at /usr/lib/systemd/system/keel-web-http.path
    nothing_at "$ANUBIS_ENV"
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
    local said=$output
    [ "$status" -eq 0 ]
    site_linked
    nothing_at "$ENABLED/default"
    eventually_code 200 "https://$HOST/" || {
        echo "$said" >&3
        nginx -t >&3 2>&1 || :
        ss -ltnp >&3 2>&1 || :
        journalctl -u nginx -u keel-web-http --no-pager -n 40 >&3 2>&1 || :
        false
    }
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
