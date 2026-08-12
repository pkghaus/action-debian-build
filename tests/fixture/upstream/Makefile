prefix ?= /usr
CFLAGS ?= -g -O2

all: fixture

fixture: fixture.c
	$(CC) $(CPPFLAGS) $(CFLAGS) $(LDFLAGS) -o $@ $<

install: fixture
	install -Dm0755 fixture $(DESTDIR)$(prefix)/bin/deb-build-fixture

clean:
	rm -f fixture

.PHONY: all install clean
