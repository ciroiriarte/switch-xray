PREFIX    ?= /usr/local
MANPREFIX ?= $(PREFIX)/share/man

.PHONY: install-man uninstall-man

install-man:
	install -d $(DESTDIR)$(MANPREFIX)/man8
	install -m 644 man/man8/switch-xray.8 $(DESTDIR)$(MANPREFIX)/man8/switch-xray.8

uninstall-man:
	rm -f $(DESTDIR)$(MANPREFIX)/man8/switch-xray.8
