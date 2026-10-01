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

The project's contributions to this repository are licensed
GPL-3.0-or-later (``LICENSE``; project decision 0007). The organization
guidelines that every Keel repository follows are at
https://keel-linux.github.io/guidelines.html.

.. _Keel Linux: https://github.com/keel-linux
.. _Keel Core: https://github.com/Keel-Linux/keel-core
