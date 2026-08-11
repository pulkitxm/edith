FLAGS := $(if $(PR),--pr $(PR)) $(if $(BRANCH),--branch $(BRANCH))
PKG := Packages/Edith
SIGN_OVERRIDES := CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
XCODEBUILD := xcodebuild -project edth.xcodeproj -derivedDataPath build -quiet \
  -onlyUsePackageVersionsFromResolvedFile COMPILER_INDEX_STORE_ENABLE=NO

SELECTED_DEV_DIR := $(shell xcode-select -p 2>/dev/null)
ifneq ($(wildcard $(SELECTED_DEV_DIR)/usr/bin/xcodebuild),)
  DEVELOPER_DIR := $(SELECTED_DEV_DIR)
else
  DEVELOPER_DIR := $(firstword $(wildcard /Applications/Xcode*.app/Contents/Developer))
endif
export DEVELOPER_DIR

.PHONY: build install reset reinstall release loc ci ci-comments ci-secrets ci-duplicate-keys ci-lint ci-scripts ci-site ci-promo ci-swift ci-swift-check ci-swift-lint ci-swift-build ci-swift-test verify-bundle site-dev cli icon wiki wiki-push linux-test linux-build linux-run linux-diagnose linux-metadata linux-package linux-check

ci:
	bun install --frozen-lockfile
	$(MAKE) ci-comments ci-secrets ci-duplicate-keys ci-lint ci-scripts ci-site ci-promo ci-swift

linux-test:
	swift test --package-path $(PKG)

linux-build:
	swift build --package-path $(PKG) --product edith-linux

linux-run:
	swift run --package-path $(PKG) edith-linux

linux-diagnose:
	swift run --package-path $(PKG) edith-linux --diagnose

linux-metadata:
	desktop-file-validate packaging/linux/com.pulkit.Edith.desktop
	appstreamcli validate --no-net packaging/linux/com.pulkit.Edith.metainfo.xml

linux-package:
	packaging/debian/build-deb.sh

linux-check: linux-test linux-metadata linux-package

site-dev:
	cd apps/site && python3 -m http.server 8000

cli:
	$(XCODEBUILD) -scheme ed -configuration Release build
	$(XCODEBUILD) -scheme edh -configuration Release build
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

verify-bundle:
	test -f dist/Edith.app/Contents/MacOS/Edith
	test -x dist/Edith.app/Contents/MacOS/ed
	test -x dist/Edith.app/Contents/MacOS/edh
	test 1 -eq "$$(find dist/Edith.app -name Sparkle.framework | wc -l | tr -d ' ')"
	test -d "dist/Edith.app/Contents/Library/Applications/Edith Files.app/Contents/MacOS/../../../../../Frameworks/Sparkle.framework"
	test -f dist/Edith.app/Contents/Resources/Edith_EdithKit.bundle/Contents/Resources/claude.svg
	test -f dist/Edith.app/Contents/Resources/Edith_EdithKit.bundle/Contents/Resources/codex.svg
	test -f dist/Edith.app/Contents/Library/LoginItems/Edith.app/Contents/MacOS/Edith
	test -f dist/Edith.app/Contents/Library/LoginItems/Edith.app/Contents/Resources/MenuBar.png
	test -x "dist/Edith.app/Contents/Library/Applications/Edith Files.app/Contents/MacOS/EdithFiles"
	test -f "dist/Edith.app/Contents/Library/Applications/Edith Files.app/Contents/Resources/Edith_Edith.bundle/Contents/Resources/appicon.png"
	/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "dist/Edith.app/Contents/Library/Applications/Edith Files.app/Contents/Info.plist" | grep -qx com.pulkit.edith.files
	test -f dist/Edith.app/Contents/Library/LoginItems/Edith.app/Contents/Resources/AppIcon.icns
	test -f dist/Edith.app/Contents/Library/LoginItems/Edith.app/Contents/Resources/Edith_EdithKit.bundle/Contents/Resources/claude.svg
	test -f dist/Edith.app/Contents/Library/LoginItems/Edith.app/Contents/Resources/Edith_EdithKit.bundle/Contents/Resources/codex.svg
	test -z "$$(find dist/Edith.app -print | grep Helper)"
	/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' dist/Edith.app/Contents/Library/LoginItems/Edith.app/Contents/Info.plist | grep -qx Edith
	@for plist in dist/Edith.app/Contents/Info.plist dist/Edith.app/Contents/Library/LoginItems/Edith.app/Contents/Info.plist; do \
	  for field in CFBundleName CFBundleDisplayName; do \
	    /usr/libexec/PlistBuddy -c "Print :$$field" "$$plist" | grep -q Helper \
	      && { echo "$$plist $$field mentions Helper" >&2; exit 1; }; \
	  done; \
	done; exit 0
	codesign --verify dist/Edith.app/Contents/Library/LoginItems/Edith.app
	codesign --verify "dist/Edith.app/Contents/Library/Applications/Edith Files.app"
	codesign --verify --deep --strict dist/Edith.app

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
