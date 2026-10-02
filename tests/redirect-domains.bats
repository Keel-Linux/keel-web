#!/usr/bin/env bats
# Unit tests of packages/keel-web/anubis-redirect-domains, which writes
# REDIRECT_DOMAINS for anubis@keel.service before each start: the
# machine's names and global addresses, the hosts the default site is
# reached by. `hostname` and `ip` are stubs first in PATH; no root.

bats_require_minimum_version 1.5.0

SCRIPT="$BATS_TEST_DIRNAME/../packages/keel-web/anubis-redirect-domains"

setup() {
    T=$(mktemp -d)
    mkdir -p "$T/bin"
    export STUB_DIR="$T"
    # hostname: the short name, or with -f the fqdn ($T/no-fqdn: fails)
    cat > "$T/bin/hostname" <<'STUB'
#!/bin/bash
if [ "${1:-}" = -f ]; then
    [ -e "$STUB_DIR/no-fqdn" ] && exit 1
    cat "$STUB_DIR/fqdn"
else
    cat "$STUB_DIR/short"
fi
STUB
    # ip -o addr show scope global: the lines of $T/addresses
    cat > "$T/bin/ip" <<'STUB'
#!/bin/bash
[ "$*" = "-o addr show scope global" ] || { echo "ip: unexpected $*" >&2; exit 2; }
cat "$STUB_DIR/addresses"
STUB
    chmod +x "$T/bin/hostname" "$T/bin/ip"
    echo web > "$T/short"
    echo web.example.org > "$T/fqdn"
    cat > "$T/addresses" <<'ADDR'
2: eth0    inet 10.0.3.158/24 brd 10.0.3.255 scope global dynamic eth0\       valid_lft 3000sec preferred_lft 3000sec
2: eth0    inet6 fd42:b2:0:1:8848:28ff:fefc:fe06/64 scope global dynamic mngtmpaddr \       valid_lft 3000sec preferred_lft 3000sec
ADDR
    PATH="$T/bin:$PATH"
    OUT="$T/run/keel-web/anubis.env"
}

teardown() {
    rm -rf "$T"
}

@test "the names and the global addresses, IPv6 bracketed as a URL's host" {
    run bash "$SCRIPT" "$OUT"
    [ "$status" -eq 0 ]
    [ "$(cat "$OUT")" = "REDIRECT_DOMAINS=web,web.example.org,10.0.3.158,[fd42:b2:0:1:8848:28ff:fefc:fe06]" ]
    [ "$(stat -c %a "$OUT")" = 644 ]
}

@test "upper case is lowered and a name given twice is written once" {
    echo WEB > "$T/short"
    echo web > "$T/fqdn"
    run bash "$SCRIPT" "$OUT"
    [ "$(cat "$OUT")" = "REDIRECT_DOMAINS=web,10.0.3.158,[fd42:b2:0:1:8848:28ff:fefc:fe06]" ]
}

@test "no fqdn: the short name and the addresses" {
    : > "$T/no-fqdn"
    run bash "$SCRIPT" "$OUT"
    [ "$status" -eq 0 ]
    [ "$(cat "$OUT")" = "REDIRECT_DOMAINS=web,10.0.3.158,[fd42:b2:0:1:8848:28ff:fefc:fe06]" ]
}

@test "no global address: the names only" {
    : > "$T/addresses"
    run bash "$SCRIPT" "$OUT"
    [ "$(cat "$OUT")" = "REDIRECT_DOMAINS=web,web.example.org" ]
}

# an empty list would make Anubis redirect anywhere: the unit must not start
@test "nothing at all fails and writes nothing" {
    : > "$T/short"
    : > "$T/no-fqdn"
    : > "$T/addresses"
    run bash "$SCRIPT" "$OUT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no name and no address"* ]]
    [ ! -e "$OUT" ]
}

@test "a second run replaces the file whole" {
    bash "$SCRIPT" "$OUT"
    : > "$T/addresses"
    bash "$SCRIPT" "$OUT"
    [ "$(cat "$OUT")" = "REDIRECT_DOMAINS=web,web.example.org" ]
    run ls "$(dirname "$OUT")"
    [ "$output" = anubis.env ]
}

@test "no argument is a usage error" {
    run bash "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage: anubis-redirect-domains FILE"* ]]
}
