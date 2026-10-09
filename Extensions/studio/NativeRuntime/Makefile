DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
EXTENSION_SWIFT_JOBS ?= 1

.PHONY: ci-native-studio native-studio
ci-native-studio:
	swift test --package-path . --build-system native --jobs $(EXTENSION_SWIFT_JOBS) --force-resolved-versions --no-parallel -Xswiftc -plugin-path -Xswiftc "$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins" $(if $(FILTER),--filter '$(FILTER)')

native-studio:
	swift build --package-path . --build-system native --jobs $(EXTENSION_SWIFT_JOBS) --force-resolved-versions --product EdithStudio -c release
