FLAGS := $(if $(PR),--pr $(PR)) $(if $(BRANCH),--branch $(BRANCH))

.PHONY: build reset reinstall

build:
	apps/macos/build.sh $(FLAGS)

reset:
	apps/macos/reset.sh

reinstall: reset
	apps/macos/build.sh --install $(FLAGS)
