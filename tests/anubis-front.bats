#!/usr/bin/env bats
# Unit tests of packages/keel-web/anubis-front, the state hook keel runs
# as /usr/lib/keel/overlays/anubis/state.d/50keel-web when the anubis
# overlay is turned on or off. It runs against a scratch /etc/nginx named
# by KEEL_NGINX_DIR, with nginx as a stub first in PATH that logs its
# arguments: no root, no Nginx. The tree starts as keel-web's postinst
# leaves a simple installation: keel-default linked, Debian's default not.

bats_require_minimum_version 1.5.0

HOOK="$BATS_TEST_DIRNAME/../packages/keel-web/anubis-front"

setup() {
    T=$(mktemp -d)
    N="$T/nginx"
    mkdir -p "$N/sites-available" "$N/sites-enabled" "$T/bin"
    echo "# Debian's default server, as nginx-common ships it" > "$N/sites-available/default"
    echo "# keel-web's default site" > "$N/sites-available/keel-default"
    echo "# keel-web's front" > "$N/sites-available/default-anubis"
    ln -s "$N/sites-available/keel-default" "$N/sites-enabled/keel-default"
    export KEEL_NGINX_DIR="$N"
    export KEEL_NGINX_PID="$T/nginx.pid"
    echo $$ > "$KEEL_NGINX_PID"
    export CALLS="$T/calls"
    : > "$CALLS"
    # nginx: -t fails while $T/t-fails exists, -s reload while
    # $T/reload-fails does; both log what the tree held when called
    cat > "$T/bin/nginx" <<'STUB'
#!/bin/bash
echo "nginx $* [$(cd "$KEEL_NGINX_DIR/sites-enabled" && ls | tr '\n' ' ')]" >> "$CALLS"
[ "$1" = -t ] && [ -e "$STUB_DIR/t-fails" ] && { echo "nginx: [emerg] test failed" >&2; exit 1; }
[ "$1" = -s ] && [ -e "$STUB_DIR/reload-fails" ] && { echo "nginx: [error] reload failed" >&2; exit 1; }
exit 0
STUB
    chmod +x "$T/bin/nginx"
    export STUB_DIR="$T"
    PATH="$T/bin:$PATH"
    # the machine's certificate, which keel-host-keys makes at first boot
    export KEEL_WEB_CERT="$T/cert.crt" KEEL_WEB_KEY="$T/cert.key"
    echo "-----BEGIN CERTIFICATE-----" > "$KEEL_WEB_CERT"
    echo "-----BEGIN PRIVATE KEY-----" > "$KEEL_WEB_KEY"
}

teardown() {
    rm -rf "$T"
}

front_linked() {
    [ "$(readlink "$N/sites-enabled/default-anubis")" = "$N/sites-available/default-anubis" ]
}

site_linked() {
    [ "$(readlink "$N/sites-enabled/keel-default")" = "$N/sites-available/keel-default" ]
}

# a plain test, not `! -L`: nothing at the path, link or file
nothing_at() {
    [ ! -e "$1" ] && [ ! -L "$1" ]
}

# usage

@test "no argument is a usage error" {
    run bash "$HOOK"
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage: anubis-front enabled|disabled"* ]]
}

@test "a word other than enabled or disabled is a usage error" {
    run bash "$HOOK" on
    [ "$status" -eq 2 ]
}

# enabled

@test "enabled puts the front in place of the default site, tests and reloads" {
    run bash "$HOOK" enabled
    [ "$status" -eq 0 ]
    front_linked
    nothing_at "$N/sites-enabled/keel-default"
    [ "$(cat "$CALLS")" = $'nginx -t [default-anubis ]\nnginx -s reload [default-anubis ]' ]
    [[ "$output" == *"enabled: the default site goes through Anubis"* ]]
}

@test "enabled twice is unchanged and touches nothing" {
    bash "$HOOK" enabled
    : > "$CALLS"
    run bash "$HOOK" enabled
    [ "$status" -eq 0 ]
    [[ "$output" == *"unchanged (enabled)"* ]]
    [ ! -s "$CALLS" ]
}

# Debian's default site is nothing to the hook any more: keel-web's
# postinst took its link away, and the postrm gives it back
@test "enabled never touches Debian's default site" {
    ln -s "$N/sites-available/default" "$N/sites-enabled/default"
    run bash "$HOOK" enabled
    [ "$status" -eq 0 ]
    front_linked
    [ "$(readlink "$N/sites-enabled/default")" = "$N/sites-available/default" ]
}

# The front serves HTTPS with the machine's certificate: Anubis's cookies
# are Secure, so over plain HTTP no browser passes the challenge
# (screenshot 114). Without the certificate nginx -t would refuse the
# front anyway; the hook says why before it changes anything.
@test "enabled refuses while the machine's certificate is missing, and changes nothing" {
    rm "$KEEL_WEB_CERT"
    run bash "$HOOK" enabled
    [ "$status" -eq 1 ]
    [[ "$output" == *"$KEEL_WEB_CERT"*"the machine's certificate"*"not there"* ]]
    site_linked
    nothing_at "$N/sites-enabled/default-anubis"
    [ ! -s "$CALLS" ]
}

@test "enabled refuses while the certificate's key is missing, and changes nothing" {
    rm "$KEEL_WEB_KEY"
    run bash "$HOOK" enabled
    [ "$status" -eq 1 ]
    [[ "$output" == *"$KEEL_WEB_KEY"*"not there"* ]]
    site_linked
    [ ! -s "$CALLS" ]
}

@test "an empty certificate counts as missing" {
    : > "$KEEL_WEB_CERT"
    run bash "$HOOK" enabled
    [ "$status" -eq 1 ]
    site_linked
}

@test "disabled does not need the certificate" {
    bash "$HOOK" enabled
    rm "$KEEL_WEB_CERT" "$KEEL_WEB_KEY"
    run bash "$HOOK" disabled
    [ "$status" -eq 0 ]
    site_linked
}

@test "enabled refuses a keel-default link that points somewhere else" {
    ln -sfn /srv/mine "$N/sites-enabled/keel-default"
    run bash "$HOOK" enabled
    [ "$status" -eq 1 ]
    [[ "$output" == *"points to /srv/mine"* ]]
    nothing_at "$N/sites-enabled/default-anubis"
    [ "$(readlink "$N/sites-enabled/keel-default")" = /srv/mine ]
}

@test "enabled refuses a keel-default that is a file, not a link" {
    rm "$N/sites-enabled/keel-default"
    echo "server {}" > "$N/sites-enabled/keel-default"
    run bash "$HOOK" enabled
    [ "$status" -eq 1 ]
    [[ "$output" == *"not a link"* ]]
    [ -f "$N/sites-enabled/keel-default" ]
}

@test "enabled refuses a file of the operator's where the front goes" {
    echo "server {}" > "$N/sites-enabled/default-anubis"
    run bash "$HOOK" enabled
    [ "$status" -eq 1 ]
    [[ "$output" == *"not a link"* ]]
    site_linked
}

# The default site's link gone is the operator's choice, and the default
# server may be a site of theirs: the front would take default_server
# from it
@test "enabled with the default site unlinked leaves the default server alone and says so" {
    rm "$N/sites-enabled/keel-default"
    run bash "$HOOK" enabled
    [ "$status" -eq 0 ]
    [[ "$output" == *"keel-web's default site is not enabled"*"left alone"* ]]
    nothing_at "$N/sites-enabled/default-anubis"
    [ ! -s "$CALLS" ]
}

@test "enabled rolls back when nginx -t refuses the result" {
    : > "$T/t-fails"
    run bash "$HOOK" enabled
    [ "$status" -eq 1 ]
    [[ "$output" == *"nginx -t refused"* ]]
    site_linked
    nothing_at "$N/sites-enabled/default-anubis"
    [ "$(cat "$CALLS")" = 'nginx -t [default-anubis ]' ]
}

@test "enabled rolls back and reloads again when the reload fails" {
    : > "$T/reload-fails"
    run bash "$HOOK" enabled
    [ "$status" -eq 1 ]
    [[ "$output" == *"reload failed"* ]]
    site_linked
    nothing_at "$N/sites-enabled/default-anubis"
    [ "$(sed -n 3p "$CALLS")" = 'nginx -s reload [keel-default ]' ]
}

@test "enabled with Nginx stopped links and tests, and reloads nothing" {
    rm "$KEEL_NGINX_PID"
    run bash "$HOOK" enabled
    [ "$status" -eq 0 ]
    front_linked
    [ "$(cat "$CALLS")" = 'nginx -t [default-anubis ]' ]
    [[ "$output" == *"nginx is not running"* ]]
}

@test "a pid file naming no process is Nginx stopped" {
    echo 999999999 > "$KEEL_NGINX_PID"
    run bash "$HOOK" enabled
    [ "$status" -eq 0 ]
    [ "$(cat "$CALLS")" = 'nginx -t [default-anubis ]' ]
}

# disabled

@test "disabled puts the default site back, tests and reloads" {
    bash "$HOOK" enabled
    : > "$CALLS"
    run bash "$HOOK" disabled
    [ "$status" -eq 0 ]
    site_linked
    nothing_at "$N/sites-enabled/default-anubis"
    [ "$(cat "$CALLS")" = $'nginx -t [keel-default ]\nnginx -s reload [keel-default ]' ]
    [[ "$output" == *"disabled: the default site is keel-web's"* ]]
}

@test "disabled on a tree that never had the front is unchanged" {
    run bash "$HOOK" disabled
    [ "$status" -eq 0 ]
    [[ "$output" == *"unchanged (disabled)"* ]]
    site_linked
    [ ! -s "$CALLS" ]
}

# a machine upgraded from keel-web 0.1.1 in a cloud mode: the front was
# put in Debian's place, and the default site has never been linked
@test "disabled after an upgrade from 0.1.1 puts the default site in, not Debian's" {
    rm "$N/sites-enabled/keel-default"
    ln -s "$N/sites-available/default-anubis" "$N/sites-enabled/default-anubis"
    run bash "$HOOK" disabled
    [ "$status" -eq 0 ]
    site_linked
    nothing_at "$N/sites-enabled/default-anubis"
    nothing_at "$N/sites-enabled/default"
}

@test "disabled with the default site's file gone makes no dangling link" {
    bash "$HOOK" enabled
    rm "$N/sites-available/keel-default"
    run bash "$HOOK" disabled
    [ "$status" -eq 0 ]
    [[ "$output" == *"disabled"*"no default site"* ]]
    nothing_at "$N/sites-enabled/keel-default"
    nothing_at "$N/sites-enabled/default-anubis"
}

@test "disabled keeps a keel-default link the operator made meanwhile" {
    bash "$HOOK" enabled
    ln -s /srv/elsewhere "$N/sites-enabled/keel-default"
    run bash "$HOOK" disabled
    [ "$status" -eq 0 ]
    [ "$(readlink "$N/sites-enabled/keel-default")" = /srv/elsewhere ]
    nothing_at "$N/sites-enabled/default-anubis"
}

@test "disabled refuses a file of the operator's where the front was" {
    echo "server {}" > "$N/sites-enabled/default-anubis"
    run bash "$HOOK" disabled
    [ "$status" -eq 1 ]
    [ -f "$N/sites-enabled/default-anubis" ]
}

@test "disabled puts the front back when nginx -t refuses the result" {
    bash "$HOOK" enabled
    : > "$T/t-fails"
    : > "$CALLS"
    run bash "$HOOK" disabled
    [ "$status" -eq 1 ]
    [[ "$output" == *"nginx -t refused"* ]]
    front_linked
    nothing_at "$N/sites-enabled/keel-default"
}

@test "disabled says so when the reload fails, and keeps the files disabled" {
    bash "$HOOK" enabled
    : > "$T/reload-fails"
    run bash "$HOOK" disabled
    [ "$status" -eq 1 ]
    [[ "$output" == *"until Nginx restarts"* ]]
    site_linked
    nothing_at "$N/sites-enabled/default-anubis"
}

@test "disabled with Nginx stopped unlinks and tests, and reloads nothing" {
    bash "$HOOK" enabled
    rm "$KEEL_NGINX_PID"
    : > "$CALLS"
    run bash "$HOOK" disabled
    [ "$status" -eq 0 ]
    site_linked
    [ "$(cat "$CALLS")" = 'nginx -t [keel-default ]' ]
}

# the two sites are never enabled together: every path through the hook
# ends with one of them, or with neither when the operator took theirs away
@test "enabled then disabled, twice over, leaves exactly one of the two sites enabled each time" {
    local round
    for round in 1 2; do
        bash "$HOOK" enabled
        front_linked
        nothing_at "$N/sites-enabled/keel-default"
        bash "$HOOK" disabled
        site_linked
        nothing_at "$N/sites-enabled/default-anubis"
    done
}
