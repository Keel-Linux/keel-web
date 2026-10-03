Keel Web
========

Keel Web is the appliance of `Keel Linux`_ that serves the web: Nginx,
Coraza (a WAF inside Nginx, with the OWASP Core Rule Set) and Anubis (proof
of work, behind Nginx). It is built as a layer on `Keel Core`_ and is the
base of every Keel web appliance (handbook decisions 0030, 0036 and 0041).

- **Simple installation:** plain Nginx. Coraza and Anubis are installed and
  off.
- **Cloud installations:** Coraza blocks what the Core Rule Set refuses,
  and Anubis challenges browsers before the site, letting the search
  engines' verified crawlers through.

The recipe (``Makefile``, ``plan/main``, ``conf.d``) builds the layer, and
``packages/keel-web`` is the ``keel-web`` package: the appliance manifest
keel reads and the pieces of Nginx configuration that belong to the
appliance rather than to an overlay. Test state and plan: ``COVERAGE.md``;
how to run the tests, and what was shown on a built image:
``tests/README.md``.

Until keel renders the sites of decision 0042, Keel Web serves one site,
its own default site, ``/etc/nginx/sites-available/keel-default``: the
default server on ports 80 and 443, IPv6 first and IPv4 on, a placeholder
page saying that this is a Keel Web node with no site configured yet and
where the operator configures one (confconsole, ``/etc/keel/instance.yaml``),
with its own 404 and 50x pages and no server version. The pages are
``/var/www/keel-default``, a link to ``/usr/share/keel-web/default-site``.
The package's postinst enables the site in place of Debian's default
site, whose link it removes and whose file it keeps, with the care
decision 0042 asks of keel's sites: only an unedited Debian default site
is replaced, and an operator's default server is left alone. A remove or
purge gives Debian's link back. When the ``anubis`` overlay is turned on,
the state hook of ``keel-web`` puts ``/etc/nginx/sites-available/default-anubis``
(the same pages, behind Anubis) in its place, and puts ``keel-default``
back when it is turned off; the two are never enabled together.

Both sites serve HTTPS on 443 with the machine's certificate, the
``default`` certificate of decision 0042 as ``turnkey-make-ssl-cert
--default`` writes it (``/etc/ssl/private/cert.pem``, ``cert.key`` and
``dhparams.pem``; the front reads the same certificate as
``/usr/local/share/ca-certificates/cert.crt``): self-signed by
``keel-host-keys.service`` at the first boot, before Nginx starts, until
the confconsole Certificate screen issues one through ACME at the same
paths. A browser warns about the self-signed certificate once; there is
no HSTS until the certificate is a CA's (Keel-Linux/tracker#51). Port 80
differs: the default site serves it, because ACME's http-01 needs it to
answer; behind Anubis it answers 301 to the same URL on HTTPS, since
Anubis sets its cookies ``Secure`` and over plain HTTP no browser could
pass its challenge. ``/keel-health`` answers 204 on both schemes on the
default site. Both sites answer by name and by IP. Anubis redirects a
solved challenge only to the scheme, host and port the request came to
(anubis 1.27.0-0+keel3 with ``REDIRECT_DOMAINS`` left empty): any name or
address the site is reached by works, a new DNS name or a public IP
behind NAT included, and no other host can be reached through it.
The usage screen lists ``https://<address>``, right in every mode, and the
keel banner takes the scheme of its Web line from it.

The project's contributions to this repository are licensed
GPL-3.0-or-later (``LICENSE``; project decision 0007). The organization
guidelines that every Keel repository follows are at
https://keel-linux.github.io/guidelines.html.

.. _Keel Linux: https://github.com/keel-linux
.. _Keel Core: https://github.com/Keel-Linux/keel-core
