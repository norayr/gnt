# gnt - Gentoo package tooling in Free Pascal.
#
# Everything reads /var/db/pkg directly through the shared portage.pas unit.
# There is no runtime dependency on emerge, equery or other any library.

FPC      ?= fpc
FPCFLAGS ?= -Mobjfpc -Sh -O2

# Tools are listed by source base name; each builds to an executable of the
# same name. The shared unit and its test live alongside them.
TOOLS = gntpkg gnt-get gntorphan gntfsorphan

.PHONY: all test clean install uninstall help

all: $(TOOLS)
	@echo "built: $(TOOLS)"

portage.ppu: portage.pas
	$(FPC) $(FPCFLAGS) $<

# Every tool depends on the shared unit, so a change there rebuilds them all.
$(TOOLS): %: %.pas portage.ppu
	$(FPC) $(FPCFLAGS) $<

# Synthetic + live-vardb regression tests for the shared unit.
test: tportage
	./tportage

tportage: tportage.pas portage.ppu
	$(FPC) $(FPCFLAGS) $<

clean:
	rm -f *.o *.ppu $(TOOLS) tportage

install: all
	install -d $(DESTDIR)/usr/bin
	install -m 0755 $(TOOLS) $(DESTDIR)/usr/bin/

uninstall:
	rm -f $(addprefix $(DESTDIR)/usr/bin/,$(TOOLS))

help:
	@echo "usage:"
	@echo "  make all        build the tools (default)"
	@echo "  make test       run the portage.pas regression tests"
	@echo "  make clean      remove build products"
	@echo "  make install    install to /usr/bin"
