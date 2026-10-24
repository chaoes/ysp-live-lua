CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra
LUAJIT_CFLAGS ?= $(shell pkg-config --cflags luajit 2>/dev/null)
LUAJIT_LIBS ?= $(shell pkg-config --libs luajit 2>/dev/null || echo -lluajit-5.1)

.PHONY: all clean
all: build/ysp_runner

build/ysp_runner: src/ysp_runner.c
	@mkdir -p build
	$(CC) $(CFLAGS) $(LUAJIT_CFLAGS) $< -o $@ $(LUAJIT_LIBS)

clean:
	rm -rf build
