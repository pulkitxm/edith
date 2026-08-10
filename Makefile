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

.PHONY: build install reset reinstall release loc ci ci-comments ci-secrets ci-lint ci-scripts ci-site ci-promo ci-swift ci-swift-check ci-swift-lint ci-swift-build ci-swift-test verify-bundle site-dev cli icon wiki wiki-push

ci:
	bun install --frozen-lockfile
	$(MAKE) ci-comments ci-secrets ci-lint ci-scripts ci-site ci-promo ci-swift

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

release:
	@set -eu; \
	test -n "$(V)" || { echo "release blocked: set V, for example make release V=1.8.0" >&2; exit 1; }; \
	command -v gh >/dev/null 2>&1 || { echo "release blocked: gh CLI is not installed" >&2; exit 1; }; \
	gh auth status >/dev/null 2>&1 || { echo "release blocked: gh CLI is not authenticated" >&2; exit 1; }; \
	KEY=$$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Resources/Info.plist 2>/dev/null || true); \
	test -n "$$KEY" || { echo "release blocked: set SUPublicEDKey in Resources/Info.plist" >&2; exit 1; }; \
	if command -v generate_appcast >/dev/null 2>&1; then \
	  GENERATE_APPCAST=$$(command -v generate_appcast); \
	else \
	  GENERATE_APPCAST=$$(find build/SourcePackages/artifacts -type f -name generate_appcast -perm -u+x -print -quit 2>/dev/null || true); \
	fi; \
	test -n "$$GENERATE_APPCAST" \
	  || { echo "release blocked: generate_appcast is not on PATH and not in build/SourcePackages/artifacts" >&2; exit 1; }; \
	BUILD=$$(( $$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist) + 1 )); \
	for p in Resources/Info.plist Resources/HelperInfo.plist; do \
	  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(V)" $$p; \
	  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $$BUILD" $$p; \
	done; \
	git commit -m "Bump version to $(V)" Resources/Info.plist Resources/HelperInfo.plist; \
	git tag "v$(V)"; \
	./build.sh --no-open --release; \
	rm -rf dmg-root Edith.dmg; \
	mkdir dmg-root; \
	cp -R dist/Edith.app dmg-root/; \
	ln -s /Applications dmg-root/Applications; \
	hdiutil create -volname Edith -srcfolder dmg-root -format UDZO Edith.dmg; \
	rm -rf dmg-root; \
	rm -rf dist/appcast; \
	mkdir dist/appcast; \
	cp Edith.dmg dist/appcast/; \
	"$$GENERATE_APPCAST" \
	  --download-url-prefix "https://github.com/pulkitxm/edith/releases/download/v$(V)/" \
	  dist/appcast; \
	test -f dist/appcast/appcast.xml || mv dist/appcast/appcast dist/appcast/appcast.xml; \
	test -f dist/appcast/appcast.xml || { echo "release blocked: generate_appcast did not create dist/appcast/appcast.xml" >&2; exit 1; }; \
	grep -q 'url="https://github.com/pulkitxm/edith/releases/download/v$(V)/Edith.dmg"' dist/appcast/appcast.xml \
	  || { echo "release blocked: appcast enclosure does not point at the v$(V) release asset" >&2; exit 1; }; \
	git push origin HEAD "v$(V)"; \
	gh release create "v$(V)" --title "Edith v$(V)" --generate-notes \
	  Edith.dmg \
	  dist/appcast/appcast.xml \
	|| gh release upload "v$(V)" --clobber \
	  Edith.dmg \
	  dist/appcast/appcast.xml

loc:
	cloc --vcs=git
