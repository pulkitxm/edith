DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
EXTENSION_SWIFT_JOBS ?= 1
export DEVELOPER_DIR
export SDKROOT := $(shell DEVELOPER_DIR="$(DEVELOPER_DIR)" xcrun --sdk macosx --show-sdk-path)

.PHONY: ci-studio-extension
ci-studio-extension:
	@studio_fixture=$$(mktemp -d /tmp/studio-extension-tests.XXXXXX); trap 'rm -rf "$$studio_fixture"' EXIT; EDITH_EXTENSION_DATA_ROOT="$$studio_fixture/data" EDITH_TEST_RUNTIME_ROOT="$$studio_fixture/runtime" EDITH_SHARED_DEFAULTS_SUITE="studio.tests.$$(uuidgen)" bun test.mjs $(if $(FILTER),'$(FILTER)')
