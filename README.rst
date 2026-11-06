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

A stack layer adds its routes without a change to the two sites
(handbook decision 0059). Both include
``/etc/nginx/keel-default.d/*.conf``: the default site in its server, the
front in the server behind Anubis (``unix:/run/nginx/keel-app.sock``). A
``location`` block in a file there is served in the simple mode and, in
the cloud modes, behind Anubis. LNMP and LNPP put their check page,
``/keel-check/``, there. The directory ships empty.

The front limits a request body to 1 MB, the default of Nginx, and
includes ``/etc/nginx/keel-front.d/*.conf`` in its server on 443. The
front sets no ``client_max_body_size`` itself, because Nginx refuses a
second one in the same server. An application that takes uploads sets a
larger limit, once, in a file there. The directory ships empty. Coraza reads no file of an
upload as an argument (keel-overlay-coraza 0.1.4), so the size of an
upload does not change the memory of a worker.

Both sites serve HTTPS on 443 with the machine's certificate, the
``default`` certificate of decision 0042 as ``turnkey-make-ssl-cert
--default`` writes it (``/etc/ssl/private/cert.pem``, ``cert.key`` and
``dhparams.pem``; the front reads the same certificate as
``/usr/local/share/ca-certificates/cert.crt``): self-signed by
``keel-host-keys.service`` at the first boot, before Nginx starts, until
the confconsole Certificate screen issues one through ACME at the same
paths. A browser warns about the self-signed certificate once; there is
no HSTS until the certificate is a CA's (Keel-Linux/tracker#51).
Both sites answer by name and by IP. Anubis redirects a
solved challenge only to the scheme, host and port the request came to
(anubis 1.27.0-0+keel3 with ``REDIRECT_DOMAINS`` left empty): any name or
address the site is reached by works, a new DNS name or a public IP
behind NAT included, and no other host can be reached through it.
The usage screen lists ``https://<address>``, right in every mode, and the
keel banner takes the scheme of its Web line from it.

Port 80 (handbook decision 0079)
--------------------------------

Port 80 is the application's when an application sits on top of Keel Web,
and the placeholder's when none does. The rule depends on the machine's
certificate:

- **Self-signed** (the certificate of the first boot, or no certificate
  for a domain yet): port 80 serves the site as 443 does, with the same
  routes of ``keel-default.d`` and, in the cloud modes, through Anubis
  and Coraza. There is no redirect. So an application that does not
  control its domain name can be seen to work over HTTP before the name
  points to the machine. In the cloud modes Anubis sets its cookies
  without ``Secure`` (``COOKIE_SECURE=false``, ``COOKIE_SAME_SITE=Lax``)
  while this is so, because a browser does not keep a ``Secure`` cookie
  from a plain HTTP page and would never pass the challenge. The pass of
  a challenge is not a credential.
- **Issued by a certificate authority** (ACME through the confconsole
  Certificate screen or ``tls.acme`` of the instance spec): port 80
  answers 301 to the same URL on HTTPS, and Anubis's cookies are
  ``Secure`` again. ``/.well-known/acme-challenge/`` stays on port 80, so
  a certificate can be renewed; it is served from dehydrated's
  ``/var/lib/dehydrated/acme-challenges/``.

The switch is automatic. ``keel-web-http.path`` watches
``/usr/local/share/ca-certificates/cert.crt`` and starts
``keel-web-http.service``, which runs ``/usr/lib/keel-web/http-mode``;
every start of Nginx runs it first too. A certificate is self-signed when
its subject is its issuer and its authority key identifier is absent or
is its own subject key identifier, the rule of keel's ``inspect``.
``http-mode`` links ``/etc/nginx/keel-web/http-redirect.conf`` to the
package's file for a CA's certificate and removes the link for a
self-signed one; the public server on port 80 of each site includes
``/etc/nginx/keel-web/http-*.conf``, which matches no file while the
certificate is self-signed. For Anubis it links
``/etc/anubis/keel-web-http.env``, which ``anubis@keel.service`` reads
after ``keel.env``. Each change is tested with ``nginx -t`` and Nginx is
reloaded, or the link is put back; a running Anubis is restarted.

The loopback addresses of port 80, ``[::1]:80`` and ``127.0.0.1:80``,
belong to the sites, which take them as ``default_server`` from the server
of keel-overlay-nginx's ``conf.d/keel-health.conf``. They share the
server of port 443 and never redirect, whatever the certificate. So
``http://127.0.0.1/`` reaches the application for the checks that run on
the machine, and ``http://127.0.0.1/keel-health`` answers 204 without the
application, for the manifest's check. Behind Anubis, ``/keel-health``
answers the loopback only (403 to other clients). The content of the
sites is in three snippets in ``/etc/nginx/snippets/``:
``keel-web-site.conf`` (the pages and the routes), ``keel-web-front.conf``
(the Anubis front) and ``keel-web-acme.conf`` (the ACME challenges).

The project's contributions to this repository are licensed
GPL-3.0-or-later (``LICENSE``; project decision 0007). The organization
guidelines that every Keel repository follows are at
https://keel-linux.github.io/guidelines.html.

.. _Keel Linux: https://github.com/keel-linux
.. _Keel Core: https://github.com/Keel-Linux/keel-core
