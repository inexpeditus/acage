# Installs agentcage as:
#   $(PREFIX)/bin/acage
#   $(PREFIX)/lib/agentcage/*.sh
#   $(PREFIX)/share/agentcage/{domain.xml,image-signing.asc}
#   $(PREFIX)/share/doc/agentcage/README.md, $(PREFIX)/share/licenses/agentcage/LICENSE
# Packagers: make install PREFIX=/usr DESTDIR="$pkgdir"

PREFIX ?= /usr/local
DESTDIR ?=
BIN = $(DESTDIR)$(PREFIX)/bin
LIB = $(DESTDIR)$(PREFIX)/lib/agentcage
DATA = $(DESTDIR)$(PREFIX)/share/agentcage
DOC = $(DESTDIR)$(PREFIX)/share/doc/agentcage
LICENSES = $(DESTDIR)$(PREFIX)/share/licenses/agentcage

LIBS = lib/common.sh lib/pool.sh lib/alpine.sh lib/harness.sh lib/share.sh lib/cloudinit.sh lib/image.sh \
       lib/provision.sh lib/backend-libvirt.sh lib/backend-qemu.sh
DATAFILES = share/domain.xml share/image-signing.asc

.PHONY: all install uninstall check

all:
	@echo "Nothing to build. Run 'make install' (PREFIX=$(PREFIX))."

install:
	mkdir -p $(BIN) $(LIB) $(DATA) $(DOC) $(LICENSES)
	install -m 0755 acage $(BIN)/acage
	install -m 0644 $(LIBS) $(LIB)/
	install -m 0644 $(DATAFILES) $(DATA)/
	install -m 0644 README.md $(DOC)/
	install -m 0644 LICENSE $(LICENSES)/

uninstall:
	rm -f $(BIN)/acage
	rm -rf $(LIB) $(DATA) $(DOC) $(LICENSES)

check:
	for f in acage $(LIBS); do bash -n $$f || exit 1; done
	shellcheck -x -s bash -S error acage $(LIBS)
