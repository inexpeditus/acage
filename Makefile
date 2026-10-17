# Installs agentcage as:
#   $(PREFIX)/bin/acage
#   $(PREFIX)/lib/agentcage/*.sh
#   $(PREFIX)/share/agentcage/{domain.xml,image-signing.asc}
#   $(PREFIX)/share/man/man1/acage.1
#   $(PREFIX)/share/doc/agentcage/README.md, $(PREFIX)/share/licenses/agentcage/LICENSE
# Packagers: make install PREFIX=/usr DESTDIR="$pkgdir"

PREFIX ?= /usr/local
DESTDIR ?=
BIN = $(DESTDIR)$(PREFIX)/bin
LIB = $(DESTDIR)$(PREFIX)/lib/agentcage
DATA = $(DESTDIR)$(PREFIX)/share/agentcage
DOC = $(DESTDIR)$(PREFIX)/share/doc/agentcage
MAN1 = $(DESTDIR)$(PREFIX)/share/man/man1
LICENSES = $(DESTDIR)$(PREFIX)/share/licenses/agentcage

LIBS = lib/common.sh lib/pool.sh lib/alpine.sh lib/harness.sh lib/share.sh lib/cloudinit.sh lib/image.sh \
       lib/provision.sh lib/push.sh lib/backend-libvirt.sh lib/backend-qemu.sh
DATAFILES = share/domain.xml share/image-signing.asc share/firewall.nft \
            share/motd.agent share/motd.user

.PHONY: all install uninstall check test e2e

all:
	@echo "Nothing to build. Run 'make install' (PREFIX=$(PREFIX))."

install:
	mkdir -p $(BIN) $(LIB) $(DATA) $(DOC) $(LICENSES) $(MAN1)
	install -m 0755 acage $(BIN)/acage
	install -m 0644 $(LIBS) $(LIB)/
	install -m 0644 $(DATAFILES) $(DATA)/
	install -m 0644 acage.1 $(MAN1)/
	install -m 0644 README.md $(DOC)/
	install -m 0644 LICENSE $(LICENSES)/

uninstall:
	rm -f $(BIN)/acage $(MAN1)/acage.1
	rm -rf $(LIB) $(DATA) $(DOC) $(LICENSES)

check:
	for f in acage $(LIBS) tests/run tests/e2e tests/*.sh; do bash -n $$f || exit 1; done
	shellcheck -x -s bash -S error acage $(LIBS) tests/run tests/e2e tests/*.sh
	if command -v mandoc >/dev/null; then mandoc -T lint -W warning acage.1; \
	else groff -mdoc -ww -z acage.1; fi

test:
	tests/run

# A real VM, start to finish (KVM, network, a few minutes; sudo for libvirt).
# make e2e BACKEND=qemu to test the qemu backend instead.
BACKEND ?= libvirt
e2e:
	tests/e2e --backend $(BACKEND)
