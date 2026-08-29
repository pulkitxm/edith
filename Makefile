FLAGS := $(if $(PR),--pr $(PR)) $(if $(BRANCH),--branch $(BRANCH))
PKG := Packages/Edith
SIGN_OVERRIDES := CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
XCODEBUILD := xcodebuild -project edth.xcodeproj -derivedDataPath build -quiet \
	-destination 'platform=macOS,arch=arm64' \
	-onlyUsePackageVersionsFromResolvedFile COMPILER_INDEX_STORE_ENABLE=NO

SELECTED_DEV_DIR := $(shell xcode-select -p 2>/dev/null)
ifneq ($(wildcard $(SELECTED_DEV_DIR)/usr/bin/xcodebuild),)
  DEVELOPER_DIR := $(SELECTED_DEV_DIR)
else
  DEVELOPER_DIR := $(firstword $(wildcard /Applications/Xcode*.app/Contents/Developer))
endif
export DEVELOPER_DIR

.PHONY: ghostty build install reset reinstall release loc ci ci-comments ci-secrets ci-duplicate-keys ci-lint ci-scripts ci-performance ci-docs ci-companion-runtime ci-site ci-promo ci-swift ci-swift-check ci-swift-lint ci-swift-build ci-swift-test verify-release-build-settings verify-bundle site-dev cli icon wiki wiki-push bench-cli performance-fixture

ci:
	bun install --frozen-lockfile
	$(MAKE) ci-comments ci-secrets ci-duplicate-keys ci-lint ci-scripts ci-performance ci-site ci-promo ci-swift

site-dev:
	cd apps/site && python3 -m http.server 8000

cli:
	$(XCODEBUILD) -scheme ed -configuration Release build
	build/Build/Products/Release/ed install --directory $(HOME)/.local/bin
	build/Build/Products/Release/ed completions install

icon:
	@set -eu; \
	ARTWORK="$(PKG)/Sources/Edith/Resources/appicon.png"; \
	rm -rf AppIcon.iconset && mkdir AppIcon.iconset; \
	for s in 16 32 128 256 512; do \
	  sips -z $$s $$s "$$ARTWORK" --out "AppIcon.iconset/icon_$${s}x$${s}.png" >/dev/null; \
	  sips -z $$((s*2)) $$((s*2)) "$$ARTWORK" --out "AppIcon.iconset/icon_$${s}x$${s}@2x.png" >/dev/null; \
	done; \
	iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns; \
	rm -rf AppIcon.iconset; \
	cp "$$ARTWORK" $(PKG)/Sources/EdithHelper/MenuBar.png; \
	sips -c 942 942 $(PKG)/Sources/EdithHelper/MenuBar.png >/dev/null; \
	sips -z 80 80 $(PKG)/Sources/EdithHelper/MenuBar.png >/dev/null

wiki:
	bun scripts/sync-wiki.mjs

wiki-push:
	bun scripts/sync-wiki.mjs --push

ci-comments:
	bun scripts/strip-comments.mjs --selftest
	bun scripts/strip-comments.mjs --check

ci-secrets:
	bun run check-secrets

ci-duplicate-keys:
	bun run check-duplicate-keys

ci-lint:
	bun run lint

ci-scripts:
	bun test ./scripts

ci-performance:
	bun scripts/check-performance-audit.mjs
	./scripts/bench-helper.sh --fixture scripts/fixtures/bench-helper.samples >/dev/null

bench-cli:
	bun scripts/bench-cli.mjs

performance-fixture:
	bun scripts/generate-dashboard-fixture.mjs --output $${OUTPUT:-/tmp/edith-dashboard-large.json}

ci-docs:
	bun test scripts/cli-docs.test.js scripts/sync-wiki.test.js

ci-companion-runtime:
	bun test scripts/companion-runtime.test.js

ci-site:
	test -f apps/site/index.html
	test -f apps/site/CNAME
	grep -qx edith.pulkit.page apps/site/CNAME
	@! grep -rhoE '(src|href)="https?://[^"]+' apps/site/*.html \
	  | grep -vE 'https://(github\.com|www\.gnu\.org|docs\.github\.com|edith\.pulkit\.page)' \
	  || { echo "site references an unexpected external origin" >&2; exit 1; }
	@cd apps/site && rc=0; \
	  for ref in $$(grep -rhoE '(src|href)="/[^"#]*' ./*.html | cut -d'"' -f2); do \
	    test -e ".$$ref" || { echo "missing: $$ref" >&2; rc=1; }; \
	  done; \
	  exit $$rc

ci-promo:
	cd apps/promo-video && npm ci && npx tsc --noEmit

ci-swift-lint:
	cd $(PKG) && swift format lint --strict --parallel --recursive Sources Tests Package.swift

ci-swift-build:
	@test -n "$(DEVELOPER_DIR)" \
	  || { echo "Xcode is required to build edth.xcodeproj; install it or run xcode-select -s" >&2; exit 1; }
	$(XCODEBUILD) -scheme EdithMain -configuration Debug $(SIGN_OVERRIDES) build

ci-swift-test:
	cd $(PKG) && ./test.sh

ci-swift-check: ci-swift-lint ci-swift-build ci-swift-test

ci-swift: ci-swift-check
	./build.sh --no-open
	$(MAKE) verify-bundle

verify-release-build-settings:
	@test "$$(xcodebuild -project edth.xcodeproj -target EdithMain -configuration Release -showBuildSettings | awk '$$1 == "DEAD_CODE_STRIPPING" { print $$3; exit }')" = YES \
	  || { echo "Release DEAD_CODE_STRIPPING must be YES" >&2; exit 1; }
	@test "$$(xcodebuild -project edth.xcodeproj -target EdithMain -configuration Release -showBuildSettings | awk '$$1 == "SWIFT_OPTIMIZATION_LEVEL" { print $$3; exit }')" = -Osize \
	  || { echo "Release SWIFT_OPTIMIZATION_LEVEL must be -Osize" >&2; exit 1; }

verify-bundle: verify-release-build-settings
	test -f dist/Edith.app/Contents/MacOS/Edith
	test ! -L dist/Edith.app/Contents/MacOS/Edith
	test -x dist/Edith.app/Contents/MacOS/Edith
	file -b dist/Edith.app/Contents/MacOS/Edith | grep -q '^Mach-O'
	test -L dist/Edith.app/Contents/MacOS/ed
	test -x dist/Edith.app/Contents/MacOS/ed
	test "$$(readlink dist/Edith.app/Contents/MacOS/ed)" = Edith
	test ! -e dist/Edith.app/Contents/MacOS/edh
	test ! -L dist/Edith.app/Contents/MacOS/edh
	test 1 -eq "$$(find dist/Edith.app/Contents/MacOS -maxdepth 1 -type l -name ed | wc -l | tr -d ' ')"
	codesign --verify --strict dist/Edith.app/Contents/MacOS/Edith
	@install_dir="$$(mktemp -d /tmp/edith-install.XXXXXX)"; \
	  trap 'rm -rf "$$install_dir"' EXIT; \
	  dist/Edith.app/Contents/MacOS/ed install --directory "$$install_dir" >/dev/null; \
	  target="$$(pwd)/dist/Edith.app/Contents/MacOS/ed"; \
	  version="$$($$install_dir/ed --version)"; \
	  test "$$version" != development; \
	  for name in ed edith; do \
	    test -L "$$install_dir/$$name"; \
	    test "$$(readlink "$$install_dir/$$name")" = "$$target"; \
	    test -x "$$install_dir/$$name"; \
	    codesign --verify --strict "$$install_dir/$$name"; \
	    test "$$version" = "$$($$install_dir/$$name --version)"; \
	  done; \
	  test ! -e "$$install_dir/edh"; \
	  test ! -L "$$install_dir/edh"
	test 1 -eq "$$(find dist/Edith.app -name Sparkle.framework | wc -l | tr -d ' ')"
	test ! -e dist/Edith.app/Contents/Resources/Edith_Edith.bundle
	test ! -e "dist/Edith.app/Contents/Library/Applications/Edith Files.app"
	test -f dist/Edith.app/Contents/Resources/Edith_EdithKit.bundle/Contents/Resources/claude.svg
	test -f dist/Edith.app/Contents/Resources/Edith_EdithKit.bundle/Contents/Resources/codex.svg
	test -f dist/Edith.app/Contents/Resources/Edith_EdithKit.bundle/Contents/Resources/ChromeExtension/manifest.json
	test -f dist/Edith.app/Contents/Library/LoginItems/Edith.app/Contents/MacOS/Edith
	test -f dist/Edith.app/Contents/Library/LoginItems/Edith.app/Contents/Resources/MenuBar.png
	test -f dist/Edith.app/Contents/Library/LoginItems/Edith.app/Contents/Resources/AppIcon.icns
	test -f dist/Edith.app/Contents/Library/LoginItems/Edith.app/Contents/Resources/Edith_EdithKit.bundle/Contents/Resources/claude.svg
	test -f dist/Edith.app/Contents/Library/LoginItems/Edith.app/Contents/Resources/Edith_EdithKit.bundle/Contents/Resources/codex.svg
	/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' dist/Edith.app/Contents/Library/LoginItems/Edith.app/Contents/Info.plist | grep -qx com.pulkit.edith.helper
	test ! -e dist/Edith.app/Contents/Library/LoginItems/Edith.app/Contents/Library/PrivilegedHelperTools/com.pulkit.edith.lidawake
	test ! -e dist/Edith.app/Contents/Library/LoginItems/Edith.app/Contents/Library/LaunchDaemons/com.pulkit.edith.lidawake.plist
	test -x dist/Edith.app/Contents/Library/PrivilegedHelperTools/com.pulkit.edith.lidawake
	test "$$(stat -f %z dist/Edith.app/Contents/Library/PrivilegedHelperTools/com.pulkit.edith.lidawake)" -le 500000
	test -f dist/Edith.app/Contents/Library/LaunchDaemons/com.pulkit.edith.lidawake.v2.plist
	/usr/libexec/PlistBuddy -c 'Print :BundleProgram' dist/Edith.app/Contents/Library/LaunchDaemons/com.pulkit.edith.lidawake.v2.plist | grep -qx Contents/Library/PrivilegedHelperTools/com.pulkit.edith.lidawake
	/usr/libexec/PlistBuddy -c 'Print :AssociatedBundleIdentifiers:0' dist/Edith.app/Contents/Library/LaunchDaemons/com.pulkit.edith.lidawake.v2.plist | grep -qx com.pulkit.edith
	codesign -dvv dist/Edith.app/Contents/Library/PrivilegedHelperTools/com.pulkit.edith.lidawake 2>&1 | grep -qx Identifier=com.pulkit.edith.lidawake
	/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' dist/Edith.app/Contents/Library/LoginItems/Edith.app/Contents/Info.plist | grep -qx Edith
	@for plist in dist/Edith.app/Contents/Info.plist dist/Edith.app/Contents/Library/LoginItems/Edith.app/Contents/Info.plist; do \
	  for field in CFBundleName CFBundleDisplayName; do \
	    /usr/libexec/PlistBuddy -c "Print :$$field" "$$plist" | grep -q Helper \
	      && { echo "$$plist $$field mentions Helper" >&2; exit 1; }; \
	  done; \
	done; exit 0
	codesign --verify dist/Edith.app/Contents/Library/LoginItems/Edith.app
	codesign --verify --deep --strict dist/Edith.app


ghostty:
	scripts/build-ghostty.sh

build:
	./build.sh $(FLAGS)

install:
	./build.sh --install $(FLAGS)

reset:
	./reset.sh

reinstall: reset
	./build.sh --install $(FLAGS)

loc:
	cloc --vcs=git
