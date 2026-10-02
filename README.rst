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
Debian's default site. When the ``anubis`` overlay is turned on, the state
hook of ``keel-web`` puts ``/etc/nginx/sites-available/default-anubis``
(the same content, behind Anubis) in its place, and puts Debian's back
when it is turned off.

Behind Anubis the site is HTTPS only: Anubis sets its cookies ``Secure``,
so over plain HTTP no browser could pass its challenge. Port 443 serves
with the machine's certificate (``/usr/local/share/ca-certificates/cert.crt``
and ``/etc/ssl/private/cert.key``, the ``default`` certificate of decision
0042), self-signed at the first boot until the confconsole Certificate
screen issues one through ACME, and port 80 answers 301 to the same URL on
HTTPS. A browser warns about the self-signed certificate once; there is no
HSTS until the certificate is a CA's. The site answers by name and by IP.
Anubis redirects a solved challenge only to the machine's own short name,
fqdn and global addresses (``REDIRECT_DOMAINS``, written by
``keel-web-anubis-domains.service`` before each start of
``anubis@keel``): another name pointed at the machine gets Anubis's error
page until keel renders the sites of decision 0042 (tracker#51), and a
changed name or address needs ``systemctl restart anubis@keel``.
In a simple installation, with no Anubis, Debian's site serves port 80, so
the usage screen lists ``http://<address>``, right in every mode.

The project's contributions to this repository are licensed
GPL-3.0-or-later (``LICENSE``; project decision 0007). The organization
guidelines that every Keel repository follows are at
https://keel-linux.github.io/guidelines.html.

.. _Keel Linux: https://github.com/keel-linux
.. _Keel Core: https://github.com/Keel-Linux/keel-core
