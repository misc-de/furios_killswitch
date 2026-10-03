# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
#
# One C file, one shared object, and the directory phosh looks in - which
# comes from phosh's own pkg-config file rather than from a guess about the
# architecture: on this phone it is /usr/lib/aarch64-linux-gnu/phosh/plugins,
# and nothing here has to know that.

PLUGIN      := furios-killswitch
SO          := libphosh-plugin-$(PLUGIN).so
PKGS        := gtk+-3.0 gio-2.0 gmodule-no-export-2.0 phosh-plugins
PLUGIN_DIR  := $(shell pkg-config --variable=status_icons_plugins_dir phosh-plugins)

CFLAGS  ?= -O2 -g
CFLAGS  += -Wall -Wextra -Wno-unused-parameter -fPIC $(shell pkg-config --cflags $(PKGS))
LDFLAGS += -shared
LDLIBS  += $(shell pkg-config --libs $(PKGS))

all: $(SO) $(PLUGIN).plugin

$(SO): killswitch-icons.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $< $(LDLIBS)

# The .plugin file names the .so by its full path, and that path is the one
# pkg-config gives - so it is written here rather than kept as a file with a
# directory baked into it.
$(PLUGIN).plugin: plugin.in Makefile
	sed 's|@PLUGIN_DIR@|$(PLUGIN_DIR)|' $< > $@

install: all
	install -Dm644 $(SO) $(DESTDIR)$(PLUGIN_DIR)/$(SO)
	install -Dm644 $(PLUGIN).plugin $(DESTDIR)$(PLUGIN_DIR)/$(PLUGIN).plugin

uninstall:
	rm -f $(DESTDIR)$(PLUGIN_DIR)/$(SO) $(DESTDIR)$(PLUGIN_DIR)/$(PLUGIN).plugin

# The test builds against the same headers and loads the built .so the way
# the shell does. It needs a display, and says so rather than failing when
# there is none - see tests/run-tests.sh.
# -rdynamic: the test stands in for phosh's two exported shell functions,
# and the plugin finds them the way it does in phosh - in the program.
tests/plugin-loads: tests/plugin-loads.c
	$(CC) $(CFLAGS) -rdynamic -o $@ $< $(LDLIBS)

check: $(SO) tests/plugin-loads
	./tests/plugin-loads .

clean:
	rm -f $(SO) $(PLUGIN).plugin tests/plugin-loads

.PHONY: all install uninstall check clean
