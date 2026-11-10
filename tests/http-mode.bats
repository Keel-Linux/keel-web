#!/usr/bin/env bats
# Unit tests of packages/keel-web/http-mode, installed as
# /usr/lib/keel-web/http-mode (handbook decision 0079): port 80 serves the
# site while the machine's certificate is self-signed, and redirects to
# HTTPS while a certificate authority's is in place. It runs against a
# scratch /etc/nginx named by KEEL_NGINX_DIR, with nginx and systemctl as
# stubs first in PATH that log their arguments: no root, no Nginx. The
# certificates are real ones that openssl makes: a self-signed one as
# turnkey-make-ssl-cert makes it, and a leaf that a test CA issued, as
# ACME gives it (the leaf first, then the chain).

bats_require_minimum_version 1.5.0

SCRIPT="$BATS_TEST_DIRNAME/../packages/keel-web/http-mode"

setup_file() {
    CERTS=$(mktemp -d)
    export CERTS
    local quiet=(-days 2 -nodes -newkey rsa:2048)
    openssl req -x509 "${quiet[@]}" -subj /CN=keel.example \
        -keyout "$CERTS/self.key" -out "$CERTS/self.crt" 2>/dev/null
    openssl req -x509 "${quiet[@]}" -subj /CN=Test-CA \
        -addext basicConstraints=critical,CA:TRUE \
        -keyout "$CERTS/ca.key" -out "$CERTS/ca.crt" 2>/dev/null
    openssl req "${quiet[@]}" -subj /CN=keel.example \
        -keyout "$CERTS/leaf.key" -out "$CERTS/leaf.csr" 2>/dev/null
    openssl x509 -req -in "$CERTS/leaf.csr" -CA "$CERTS/ca.crt" \
        -CAkey "$CERTS/ca.key" -CAcreateserial -days 2 \
        -extfile <(printf 'subjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\n') \
        -out "$CERTS/leaf.crt" 2>/dev/null
    cat "$CERTS/leaf.crt" "$CERTS/ca.crt" > "$CERTS/fullchain.crt"
    # a private CA that issues a leaf under its own name: the same subject
    # and issuer, but the authority key is the CA's
    openssl req "${quiet[@]}" -subj /CN=Test-CA \
        -keyout "$CERTS/same.key" -out "$CERTS/same.csr" 2>/dev/null
    openssl x509 -req -in "$CERTS/same.csr" -CA "$CERTS/ca.crt" \
        -CAkey "$CERTS/ca.key" -CAcreateserial -days 2 \
        -extfile <(printf 'subjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\n') \
        -out "$CERTS/same-name.crt" 2>/dev/null
    # a self-signed certificate with no key identifiers at all
    openssl req -x509 "${quiet[@]}" -subj /CN=bare \
        -addext subjectKeyIdentifier=none -addext authorityKeyIdentifier=none \
        -keyout "$CERTS/bare.key" -out "$CERTS/bare.crt" 2>/dev/null
}

teardown_file() {
    rm -rf "$CERTS"
}

setup() {
    T=$(mktemp -d)
    N="$T/nginx"
    SHARE="$T/share"
    mkdir -p "$N/snippets" "$SHARE" "$T/bin" "$T/anubis"
    echo "# acme" > "$N/snippets/keel-web-acme.conf"
    echo "# redirect" > "$SHARE/http-redirect.conf"
    echo "COOKIE_SECURE=false" > "$SHARE/anubis-http.env"
    export KEEL_NGINX_DIR="$N" KEEL_WEB_SHARE="$SHARE"
    export KEEL_WEB_ANUBIS_ENV="$T/anubis/keel-web-http.env"
    export KEEL_NGINX_PID="$T/nginx.pid"
    export KEEL_WEB_CERT="$T/cert.crt"
    cp "$CERTS/self.crt" "$KEEL_WEB_CERT"
    export CALLS="$T/calls"
    : > "$CALLS"
    # nginx: -t fails while $T/t-fails exists, -s reload while
    # $T/reload-fails does; both log whether the redirect was linked, and
    # which challenge links were there
    cat > "$T/bin/nginx" <<'STUB'
#!/bin/bash
state=serve
[ -L "$KEEL_NGINX_DIR/keel-web/http-redirect.conf" ] && state=redirect
for acme in site front; do
    [ -L "$KEEL_NGINX_DIR/keel-web/$acme-acme.conf" ] && state="$state,$acme"
done
echo "nginx $* [$state]" >> "$CALLS"
[ "$1" = -t ] && [ -e "$STUB_DIR/t-fails" ] && { echo "nginx: [emerg] test failed" >&2; exit 1; }
[ "$1" = -s ] && [ -e "$STUB_DIR/reload-fails" ] && { echo "nginx: [error] reload failed" >&2; exit 1; }
exit 0
STUB
    cat > "$T/bin/systemctl" <<'STUB'
#!/bin/bash
echo "systemctl $*" >> "$CALLS"
# is-active: Anubis runs while $T/anubis-active exists
[ "$2" = is-active ] && { [ -e "$STUB_DIR/anubis-active" ]; exit; }
[ -e "$STUB_DIR/systemctl-fails" ] && exit 1
exit 0
STUB
    chmod +x "$T/bin/nginx" "$T/bin/systemctl"
    export STUB_DIR="$T"
    touch "$T/anubis-active"
    PATH="$T/bin:$PATH"
}

RESTART=$'systemctl --quiet is-active anubis@keel.service\nsystemctl --no-block restart anubis@keel.service'

teardown() {
    rm -rf "$T"
}

nginx_runs() {
    echo $$ > "$KEEL_NGINX_PID"
}

redirect_linked() {
    [ "$(readlink "$N/keel-web/http-redirect.conf")" = "$SHARE/http-redirect.conf" ]
}

# the challenge link of SITE (site or front) points to keel-web's snippet
acme_linked() {
    [ "$(readlink "$N/keel-web/$1-acme.conf")" = "$N/snippets/keel-web-acme.conf" ]
}

# a route file in DIR (keel-default.d or keel-front.d) with the text TEXT
route() {
    mkdir -p "$N/$1"
    printf '%s\n' "$3" > "$N/$1/$2"
}

NTFY_ROUTE=$'location ^~ /.well-known/acme-challenge/ {\n\ttry_files $uri =404;\n}\n\nlocation ~ ^/ {\n\tinclude /etc/nginx/snippets/keel-ntfy-proxy.conf;\n}'

anubis_linked() {
    [ "$(readlink "$KEEL_WEB_ANUBIS_ENV")" = "$SHARE/anubis-http.env" ]
}

nothing_at() {
    [ ! -e "$1" ] && [ ! -L "$1" ]
}

issued_cert() {
    cp "$CERTS/fullchain.crt" "$KEEL_WEB_CERT"
}

# usage

@test "an argument is a usage error" {
    run bash "$SCRIPT" --reload
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage: http-mode"* ]]
}

# self-signed: port 80 serves the site

@test "self-signed: port 80 serves, no redirect, Anubis's cookies without Secure" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    nothing_at "$N/keel-web/http-redirect.conf"
    anubis_linked
    [[ "$output" == *"port 80 serves the site as 443 does"* ]]
    [ "$(cat "$CALLS")" = "$RESTART" ]
}

@test "an Anubis that does not run is not started: it reads the file at its start" {
    rm "$T/anubis-active"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    anubis_linked
    [ "$(cat "$CALLS")" = "systemctl --quiet is-active anubis@keel.service" ]
}

@test "self-signed with no key identifiers is still self-signed" {
    cp "$CERTS/bare.crt" "$KEEL_WEB_CERT"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    nothing_at "$N/keel-web/http-redirect.conf"
    anubis_linked
}

@test "no certificate at all: port 80 serves" {
    rm "$KEEL_WEB_CERT"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    nothing_at "$N/keel-web/http-redirect.conf"
    [[ "$output" == *"self-signed or not there"* ]]
}

@test "a file that is no certificate: port 80 serves" {
    echo "not a certificate" > "$KEEL_WEB_CERT"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    nothing_at "$N/keel-web/http-redirect.conf"
}

@test "self-signed twice: nothing changes, nothing is reloaded or restarted" {
    bash "$SCRIPT"
    : > "$CALLS"
    nginx_runs
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -s "$CALLS" ]
}

# issued: port 80 redirects

@test "a CA's certificate: port 80 redirects, Anubis's cookies Secure again" {
    bash "$SCRIPT"
    issued_cert
    : > "$CALLS"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    redirect_linked
    nothing_at "$KEEL_WEB_ANUBIS_ENV"
    [[ "$output" == *"port 80 redirects to HTTPS"* ]]
    # Nginx is not running: the link is read at its start
    [ "$(cat "$CALLS")" = "$RESTART" ]
}

@test "a CA's leaf under the CA's own name is not self-signed" {
    cp "$CERTS/same-name.crt" "$KEEL_WEB_CERT"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    redirect_linked
}

@test "a CA's certificate on a fresh machine: the redirect, and Anubis is not restarted" {
    issued_cert
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    redirect_linked
    [ ! -s "$CALLS" ]
}

@test "a CA's certificate with Nginx running: tested, then reloaded" {
    issued_cert
    nginx_runs
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(cat "$CALLS")" = $'nginx -t [redirect,site,front]\nnginx -s reload [redirect,site,front]' ]
}

@test "back to self-signed with Nginx running: the redirect goes, tested and reloaded" {
    issued_cert
    bash "$SCRIPT"
    cp "$CERTS/self.crt" "$KEEL_WEB_CERT"
    nginx_runs
    : > "$CALLS"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    nothing_at "$N/keel-web/http-redirect.conf"
    anubis_linked
    [ "$(cat "$CALLS")" = $'nginx -t [serve,site,front]\nnginx -s reload [serve,site,front]\n'"$RESTART" ]
}

@test "a link to an older file is pointed to the package's file again" {
    issued_cert
    mkdir -p "$N/keel-web"
    ln -s /nowhere "$N/keel-web/http-redirect.conf"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    redirect_linked
}

# failures

@test "nginx -t refuses the redirect: the link is put back and the run fails" {
    issued_cert
    nginx_runs
    touch "$T/t-fails"
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    nothing_at "$N/keel-web/http-redirect.conf"
    [[ "$output" == *"nginx -t refused the configuration"* ]]
}

@test "nginx -t refuses the configuration without the redirect: the redirect comes back" {
    issued_cert
    bash "$SCRIPT"
    cp "$CERTS/self.crt" "$KEEL_WEB_CERT"
    nginx_runs
    touch "$T/t-fails"
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    redirect_linked
}

@test "a failed reload puts the link back and reloads again" {
    issued_cert
    nginx_runs
    touch "$T/reload-fails"
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    nothing_at "$N/keel-web/http-redirect.conf"
    [[ "$output" == *"nginx -s reload failed"* ]]
    [ "$(grep -c 'nginx -s reload' "$CALLS")" = 2 ]
}

@test "Anubis does not restart: the run fails and says when it reads the file" {
    touch "$T/systemctl-fails"
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"anubis@keel.service did not restart"* ]]
}

@test "a file of the operator's where the redirect link goes is left alone" {
    issued_cert
    mkdir -p "$N/keel-web"
    echo "# the operator's" > "$N/keel-web/http-redirect.conf"
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not a link; it is left alone"* ]]
    [ "$(cat "$N/keel-web/http-redirect.conf")" = "# the operator's" ]
    [ ! -s "$CALLS" ]
}

@test "a file of the operator's where the Anubis link goes is left alone" {
    echo "COOKIE_SECURE=true" > "$KEEL_WEB_ANUBIS_ENV"
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [ "$(cat "$KEEL_WEB_ANUBIS_ENV")" = "COOKIE_SECURE=true" ]
}

@test "a pid file whose process is gone counts as Nginx not running" {
    issued_cert
    echo 999999999 > "$KEEL_NGINX_PID"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    redirect_linked
    [ ! -s "$CALLS" ]
}

# the challenge links (0.4.3): a route that serves ACME's challenge
# itself keeps it

@test "no route serves the challenge: both sites link keel-web's challenge location" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    acme_linked site
    acme_linked front
    [[ "$output" != *"serves ACME's challenge itself"* ]]
}

@test "routes with no challenge location of their own: both links stay" {
    route keel-default.d 50-php.conf $'location ~ \\.php$ {\n\treturn 404;\n}'
    route keel-front.d 50-up.conf 'client_max_body_size 8m;'
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    acme_linked site
    acme_linked front
}

@test "the old route of keel-ntfy in keel-default.d: the default site's link goes, the front's stays" {
    route keel-default.d 60-keel-ntfy.conf "$NTFY_ROUTE"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    nothing_at "$N/keel-web/site-acme.conf"
    acme_linked front
    [[ "$output" == *"keel-web: $N/keel-default.d/60-keel-ntfy.conf serves ACME's challenge itself: $N/keel-web/site-acme.conf is not linked"* ]]
    [ "$(grep -c "serves ACME's challenge itself" <<< "$output")" = 1 ]
}

@test "a prefix location without ^~ and without the last slash counts too" {
    route keel-default.d 70-a.conf $'  location /.well-known/acme-challenge {\n\treturn 404;\n}'
    route keel-front.d 70-b.conf $'location\t^~\t/.well-known/acme-challenge/{ return 404; }'
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    nothing_at "$N/keel-web/site-acme.conf"
    nothing_at "$N/keel-web/front-acme.conf"
}

@test "a route in keel-front.d: the front's link goes, the default site's stays" {
    route keel-front.d 60-app.conf $'location ^~ /.well-known/acme-challenge/ {\n\treturn 404;\n}'
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    acme_linked site
    nothing_at "$N/keel-web/front-acme.conf"
    [[ "$output" == *"$N/keel-front.d/60-app.conf serves ACME's challenge itself: $N/keel-web/front-acme.conf is not linked"* ]]
}

# not a duplicate for Nginx, and keel-web's ^~ prefix wins over both
@test "a commented location, an exact location and a regular expression do not count" {
    route keel-default.d 60-a.conf $'# location ^~ /.well-known/acme-challenge/ {\n\t#location /.well-known/acme-challenge/ {'
    route keel-default.d 60-b.conf $'location = /.well-known/acme-challenge/ {\n\treturn 404;\n}'
    route keel-front.d 60-c.conf $'location ~ ^/\\.well-known/acme-challenge/ {\n\treturn 404;\n}'
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    acme_linked site
    acme_linked front
}

@test "a file that Nginx does not include (not *.conf) does not count" {
    route keel-default.d 60-keel-ntfy.conf.dpkg-old "$NTFY_ROUTE"
    route keel-front.d 60-off.conf.disabled "$NTFY_ROUTE"
    mkdir -p "$N/keel-default.d/sub.conf"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    acme_linked site
    acme_linked front
}

@test "a route comes with Nginx running: the link goes, tested, then reloaded" {
    bash "$SCRIPT"
    nginx_runs
    : > "$CALLS"
    route keel-default.d 60-keel-ntfy.conf "$NTFY_ROUTE"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    nothing_at "$N/keel-web/site-acme.conf"
    [ "$(cat "$CALLS")" = $'nginx -t [serve,front]\nnginx -s reload [serve,front]' ]
}

@test "the route goes: keel-web's challenge location comes back" {
    route keel-default.d 60-keel-ntfy.conf "$NTFY_ROUTE"
    bash "$SCRIPT"
    rm "$N/keel-default.d/60-keel-ntfy.conf"
    nginx_runs
    : > "$CALLS"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    acme_linked site
    [ "$(cat "$CALLS")" = $'nginx -t [serve,site,front]\nnginx -s reload [serve,site,front]' ]
}

@test "a challenge link to an older file is pointed to the snippet again" {
    mkdir -p "$N/keel-web"
    ln -s /nowhere "$N/keel-web/site-acme.conf"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    acme_linked site
}

@test "nginx -t refuses: every link is put back as it was" {
    bash "$SCRIPT"
    ln -sfn /older "$N/keel-web/front-acme.conf"
    issued_cert
    route keel-default.d 60-keel-ntfy.conf "$NTFY_ROUTE"
    nginx_runs
    touch "$T/t-fails"
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"nginx -t refused the configuration"* ]]
    nothing_at "$N/keel-web/http-redirect.conf"
    acme_linked site
    [ "$(readlink "$N/keel-web/front-acme.conf")" = /older ]
    # Anubis is not touched after a refusal
    anubis_linked
}

@test "a failed reload puts every link back and reloads again" {
    route keel-front.d 60-app.conf $'location ^~ /.well-known/acme-challenge/ {\n\treturn 404;\n}'
    bash "$SCRIPT"
    rm "$N/keel-front.d/60-app.conf"
    route keel-default.d 60-keel-ntfy.conf "$NTFY_ROUTE"
    nginx_runs
    : > "$CALLS"
    touch "$T/reload-fails"
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"nginx -s reload failed"* ]]
    acme_linked site
    nothing_at "$N/keel-web/front-acme.conf"
    [ "$(cat "$CALLS")" = $'nginx -t [serve,front]\nnginx -s reload [serve,front]\nnginx -s reload [serve,site]' ]
}

@test "a file of the operator's where a challenge link goes is left alone" {
    local acme
    for acme in site front; do
        rm -rf "$N/keel-web"
        mkdir -p "$N/keel-web"
        echo "# the operator's" > "$N/keel-web/$acme-acme.conf"
        run bash "$SCRIPT"
        [ "$status" -eq 1 ]
        [[ "$output" == *"$acme-acme.conf is not a link; it is left alone"* ]]
        [ "$(cat "$N/keel-web/$acme-acme.conf")" = "# the operator's" ]
        [ ! -s "$CALLS" ]
    done
}
