FLAGS := $(if $(PR),--pr $(PR)) $(if $(BRANCH),--branch $(BRANCH))

.PHONY: build install reset reinstall loc

build:
	apps/macos/build.sh $(FLAGS)

install:
	apps/macos/build.sh --install $(FLAGS)

reset:
	apps/macos/reset.sh

reinstall: reset
	apps/macos/build.sh --install $(FLAGS)

loc:
	cloc --vcs=git
