# keel-web: Nginx, Coraza and Anubis on Keel Core (handbook decisions 0030
# and 0041), built as a layer on core:
#
#     bt-layer web --parent core
#
# What it installs is the keel-web package of plan/main and what it depends
# on; conf.d/main fails the build when the image is not in the simple
# state. Nginx serves 80; behind Anubis (the cloud modes) 80 redirects to
# 443, served with the machine's certificate. Webmin stays on 12321.
WEBMIN_FW_TCP_INCOMING = 22 80 443 12321

include $(FAB_PATH)/common/mk/turnkey.mk
