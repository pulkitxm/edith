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

.PHONY: ghostty build install camera-profiles reset reinstall release release-dry loc ci ci-all ci-comments ci-secrets ci-duplicate-keys ci-lint ci-scripts ci-performance ci-docs ci-companion-runtime ci-site ci-promo ci-browser ci-swift ci-swift-check ci-swift-lint ci-swift-build ci-swift-test ci-hygiene ci-community ci-yaml ci-markdown ci-links ci-workflows ci-security ci-gitleaks ci-cargo-audit ci-osv ci-semgrep ci-trivy ci-companion ci-companion-migrate ci-tools verify-release-build-settings verify-bundle site-dev cli icon wiki wiki-push bench-cli performance-fixture approve-package-plugins

ci:
	bun install --frozen-lockfile
	$(MAKE) ci-comments ci-secrets ci-duplicate-keys ci-lint ci-scripts ci-performance ci-docs ci-companion-runtime ci-site ci-promo ci-browser ci-swift

ci-all:
	bun install --frozen-lockfile
	$(MAKE) ci-comments ci-secrets ci-duplicate-keys ci-lint ci-scripts ci-performance ci-docs ci-companion-runtime ci-site ci-promo ci-hygiene ci-security ci-companion ci-browser ci-swift

release:
	./scripts/release-local.sh

release-dry:
	./scripts/release-local.sh --dry-run

site-dev:
	cd apps/site && python3 -m http.server 8000

approve-package-plugins:
	python3 scripts/approve-package-plugins.py

cli: approve-package-plugins
	$(XCODEBUILD) -scheme ed -configuration Release build
	build/Build/Products/Release/ed install --directory $(HOME)/.local/bin
	build/Build/Products/Release/ed completions install

icon:
	@set -eu; \
	CHROME="$${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"; \
	ARTWORK="$(PKG)/Sources/Edith/Resources/appicon.png"; \
	rm -f "$$ARTWORK"; \
	"$$CHROME" --headless --disable-gpu --hide-scrollbars --allow-file-access-from-files \
	  --force-color-profile=srgb --default-background-color=00000000 --window-size=1024,1024 \
	  --screenshot="$(CURDIR)/$$ARTWORK" "file://$(CURDIR)/Resources/AppIcon.svg" >/dev/null 2>&1; \
	test -s "$$ARTWORK"; \
	rm -rf AppIcon.iconset && mkdir AppIcon.iconset; \
	for s in 16 32 128 256 512; do \
	  sips -z $$s $$s "$$ARTWORK" --out "AppIcon.iconset/icon_$${s}x$${s}.png" >/dev/null; \
	  sips -z $$((s*2)) $$((s*2)) "$$ARTWORK" --out "AppIcon.iconset/icon_$${s}x$${s}@2x.png" >/dev/null; \
	done; \
	iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns; \
	rm -rf AppIcon.iconset; \
	sips -z 128 128 "$$ARTWORK" --out $(PKG)/Sources/EdithKit/Resources/share-icon.png >/dev/null; \
	cp "$$ARTWORK" $(PKG)/Sources/EdithHelper/MenuBar.png; \
	sips -c 942 942 $(PKG)/Sources/EdithHelper/MenuBar.png >/dev/null; \
	sips -z 80 80 $(PKG)/Sources/EdithHelper/MenuBar.png >/dev/null; \
	cp "$$ARTWORK" apps/site/app-icon.png; \
	cp "$$ARTWORK" apps/promo-video/public/logo.png; \
	sips -z 512 512 "$$ARTWORK" --out apps/site/app-icon-512.png >/dev/null; \
	sips -z 180 180 "$$ARTWORK" --out apps/site/favicon-180.png >/dev/null

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
	bun test ./scripts --path-ignore-patterns '**/._*'

ci-performance:
	bun scripts/check-performance-audit.mjs
	./scripts/bench-helper.sh --fixture scripts/fixtures/bench-helper.samples >/dev/null

bench-cli:
	bun scripts/bench-cli.mjs

performance-fixture:
	bun scripts/generate-dashboard-fixture.mjs --output $${OUTPUT:-/tmp/edith-dashboard-large.json}

ci-docs:
	bun test scripts/cli-docs.test.js scripts/sync-wiki.test.js
	bun scripts/generate-cli-docs-bundle.mjs --check

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
	cd $(PKG) && find Sources Tests Package.swift -type f -name '*.swift' ! -name '._*' -print0 | xargs -0 swift format lint --strict --parallel

ci-swift-build: approve-package-plugins
	@test -n "$(DEVELOPER_DIR)" \
	  || { echo "Xcode is required to build edth.xcodeproj; install it or run xcode-select -s" >&2; exit 1; }
	$(XCODEBUILD) -scheme EdithMain -configuration Debug $(SIGN_OVERRIDES) build

ci-swift-test:
	cd $(PKG) && ./test.sh

ci-browser:
	plutil -extract NSAppTransportSecurity.NSAllowsArbitraryLoadsInWebContent raw Resources/HelperInfo.plist | grep -qx true
	cd $(PKG) && ./test.sh --filter '^EdithTests\.(NotchBrowser|Browser|Chrome|LocalStorageSeed)'

ci-swift-check: ci-swift-lint ci-swift-build ci-swift-test

ci-swift: ci-swift-check
	./build.sh --no-open
	$(MAKE) verify-bundle

verify-release-build-settings:
	@for target in EdithMain EdithHelper; do \
	  settings="$$(xcodebuild -project edth.xcodeproj -scheme $$target -configuration Release -derivedDataPath build \
	    -onlyUsePackageVersionsFromResolvedFile -showBuildSettings)" || exit 1; \
	  test "$$(printf '%s\n' "$$settings" | awk '$$1 == "DEAD_CODE_STRIPPING" { print $$3; exit }')" = YES \
	    || { echo "$$target Release DEAD_CODE_STRIPPING must be YES" >&2; exit 1; }; \
	  test "$$(printf '%s\n' "$$settings" | awk '$$1 == "SWIFT_OPTIMIZATION_LEVEL" { print $$3; exit }')" = -Osize \
	    || { echo "$$target Release SWIFT_OPTIMIZATION_LEVEL must be -Osize" >&2; exit 1; }; \
	done

verify-bundle: verify-release-build-settings
	test -f dist/Edith.app/Contents/MacOS/Edith
	test ! -L dist/Edith.app/Contents/MacOS/Edith
	test -x dist/Edith.app/Contents/MacOS/Edith
	file -b dist/Edith.app/Contents/MacOS/Edith | grep -q '^Mach-O'
	test -L dist/Edith.app/Contents/MacOS/ed
	test -x dist/Edith.app/Contents/MacOS/ed
	test "$$(readlink dist/Edith.app/Contents/MacOS/ed)" = ../Resources/ed-launcher
	test -f dist/Edith.app/Contents/Resources/ed-launcher
	test -x dist/Edith.app/Contents/Resources/ed-launcher
	head -n 1 dist/Edith.app/Contents/Resources/ed-launcher | grep -qx '#!/bin/sh'
	test ! -e dist/Edith.app/Contents/MacOS/edh
	test ! -L dist/Edith.app/Contents/MacOS/edh
	test 1 -eq "$$(find dist/Edith.app/Contents/MacOS -maxdepth 1 -type l -name ed | wc -l | tr -d ' ')"
	codesign --verify --strict dist/Edith.app/Contents/MacOS/Edith
	@set -e; install_dir="$$(mktemp -d /tmp/edith-install.XXXXXX)"; \
	  trap 'rm -rf "$$install_dir"' EXIT; \
	  dist/Edith.app/Contents/MacOS/ed install --directory "$$install_dir" >/dev/null; \
	  target="$$(pwd)/dist/Edith.app/Contents/MacOS/ed"; \
	  version="$$($$install_dir/ed --version)"; \
	  test -n "$$version"; \
	  test "$$version" != development; \
	  for name in ed edith; do \
	    test -L "$$install_dir/$$name"; \
	    test "$$(readlink "$$install_dir/$$name")" = "$$target"; \
	    test -x "$$install_dir/$$name"; \
	    test "$$version" = "$$($$install_dir/$$name --version)"; \
	  done; \
	  test ! -e "$$install_dir/edh"; \
	  test ! -L "$$install_dir/edh"
	test 1 -eq "$$(find dist/Edith.app -name Sparkle.framework | wc -l | tr -d ' ')"
	@! find dist/Edith.app -type f -perm -u+x -exec file {} + | grep -q 'universal binary'
	test ! -e dist/Edith.app/Contents/Resources/Edith_Edith.bundle
	find dist/Edith.app/Contents/Resources -path '*/GhosttyResources/ghostty/shell-integration/zsh/ghostty-integration' -type f | grep -q .
	find dist/Edith.app/Contents/Resources -path '*/GhosttyResources/terminfo/78/xterm-ghostty' -type f | grep -q .
	test -f dist/Edith.app/Contents/Resources/Edith_EdithKit.bundle/Contents/Resources/claude.svg
	test -f dist/Edith.app/Contents/Resources/Edith_EdithKit.bundle/Contents/Resources/codex.svg
	test -f dist/Edith.app/Contents/Resources/Edith_EdithKit.bundle/Contents/Resources/ChromeExtension/manifest.json
	test -f dist/Edith.app/Contents/Library/LoginItems/Edith.app/Contents/MacOS/Edith
	test -f dist/Edith.app/Contents/Library/LoginItems/Edith.app/Contents/Resources/MenuBar.png
	test -L dist/Edith.app/Contents/Library/LoginItems/Edith.app/Contents/Resources/AppIcon.icns
	test "$$(readlink dist/Edith.app/Contents/Library/LoginItems/Edith.app/Contents/Resources/AppIcon.icns)" = ../../../../../Resources/AppIcon.icns
	test -L dist/Edith.app/Contents/Library/LoginItems/Edith.app/Contents/Resources/Edith_EdithKit.bundle
	test "$$(readlink dist/Edith.app/Contents/Library/LoginItems/Edith.app/Contents/Resources/Edith_EdithKit.bundle)" = ../../../../../Resources/Edith_EdithKit.bundle
	test -f dist/Edith.app/Contents/Library/LoginItems/Edith.app/Contents/Resources/Edith_EdithKit.bundle/Contents/Resources/claude.svg
	test -f dist/Edith.app/Contents/Library/LoginItems/Edith.app/Contents/Resources/Edith_EdithKit.bundle/Contents/Resources/codex.svg
	python3 scripts/verify-app-identity.py dist/Edith.app
	test ! -e dist/Edith.app/Contents/Library/LoginItems/Edith.app/Contents/Library/PrivilegedHelperTools/com.pulkit.edith.lidawake
	test ! -e dist/Edith.app/Contents/Library/LoginItems/Edith.app/Contents/Library/LaunchDaemons/com.pulkit.edith.lidawake.plist
	test -x dist/Edith.app/Contents/Library/PrivilegedHelperTools/com.pulkit.edith.lidawake
	test "$$(stat -f %z dist/Edith.app/Contents/Library/PrivilegedHelperTools/com.pulkit.edith.lidawake)" -le 500000
	test -f dist/Edith.app/Contents/Library/LaunchDaemons/com.pulkit.edith.lidawake.v2.plist
	test -x dist/Edith.app/Contents/MacOS/edithd
	/usr/libexec/PlistBuddy -c 'Print :BundleProgram' dist/Edith.app/Contents/Library/LaunchDaemons/com.pulkit.edith.lidawake.v2.plist | grep -qx Contents/Library/PrivilegedHelperTools/com.pulkit.edith.lidawake
	/usr/libexec/PlistBuddy -c 'Print :AssociatedBundleIdentifiers:0' dist/Edith.app/Contents/Library/LaunchDaemons/com.pulkit.edith.lidawake.v2.plist | grep -qx com.pulkit.edith
	codesign -dvv dist/Edith.app/Contents/Library/PrivilegedHelperTools/com.pulkit.edith.lidawake 2>&1 | grep -qx Identifier=com.pulkit.edith.lidawake
	@for plist in dist/Edith.app/Contents/Info.plist dist/Edith.app/Contents/Library/LoginItems/Edith.app/Contents/Info.plist; do \
	  for field in CFBundleName CFBundleDisplayName; do \
	    /usr/libexec/PlistBuddy -c "Print :$$field" "$$plist" | grep -q Helper \
	      && { echo "$$plist $$field mentions Helper" >&2; exit 1; }; \
	  done; \
	done; exit 0
	codesign --verify dist/Edith.app/Contents/Library/LoginItems/Edith.app
	test 1 -eq "$$(find dist/Edith.app/Contents/Library/SystemExtensions -maxdepth 1 -name '*.camera.systemextension' | wc -l | tr -d ' ')"
	codesign --verify --strict dist/Edith.app/Contents/Library/SystemExtensions/*.camera.systemextension
	codesign --verify --deep --strict dist/Edith.app


ghostty:
	scripts/build-ghostty.sh

build:
	./build.sh $(FLAGS)

install:
	./build.sh --release --install $(FLAGS)

camera-profiles:
	./scripts/camera-profiles.sh

reset:
	./reset.sh

reinstall: reset
	./build.sh --release --install $(FLAGS)

loc:
	cloc --vcs=git

ci-hygiene:
	$(MAKE) ci-community ci-yaml ci-markdown ci-links ci-workflows

ci-community:
	test -s LICENSE && test -s README.md && test -s ARCHITECTURE.md \
	  && test -s CODE_OF_CONDUCT.md && test -s CONTRIBUTING.md && test -s GOVERNANCE.md \
	  && test -s SECURITY.md && test -s SUPPORT.md && test -s .github/CODEOWNERS \
	  && test -s .github/pull_request_template.md && test -s .github/ISSUE_TEMPLATE/bug.yml \
	  && test -s .github/ISSUE_TEMPLATE/feature.yml && test -s .github/ISSUE_TEMPLATE/config.yml

ci-yaml:
	@command -v yamllint >/dev/null || { echo "yamllint missing: run make ci-tools" >&2; exit 1; }
	yamllint --strict .

ci-markdown:
	bunx markdownlint-cli2

ci-links:
	@command -v lychee >/dev/null || { echo "lychee missing: run make ci-tools" >&2; exit 1; }
	GITHUB_TOKEN="$${GITHUB_TOKEN:-$$(gh auth token 2>/dev/null)}" lychee --config lychee.toml './**/*.md'

ci-workflows:
	@command -v actionlint >/dev/null || { echo "actionlint missing: run make ci-tools" >&2; exit 1; }
	@command -v zizmor >/dev/null || { echo "zizmor missing: run make ci-tools" >&2; exit 1; }
	actionlint .github/workflows-disabled/*.yml
	zizmor --persona=pedantic --min-severity=high --format=plain .github/workflows-disabled/*.yml

ci-security:
	$(MAKE) ci-secrets ci-gitleaks ci-cargo-audit ci-osv ci-semgrep ci-trivy

ci-gitleaks:
	@command -v gitleaks >/dev/null || { echo "gitleaks missing: run make ci-tools" >&2; exit 1; }
	gitleaks git --no-banner --redact --log-opts="HEAD" .

ci-cargo-audit:
	@cargo audit --version >/dev/null 2>&1 || { echo "cargo-audit missing: run make ci-tools" >&2; exit 1; }
	cd apps/companion && cargo audit

ci-osv:
	@command -v osv-scanner >/dev/null || { echo "osv-scanner missing: run make ci-tools" >&2; exit 1; }
	osv-scanner scan source --recursive .

ci-semgrep:
	@command -v semgrep >/dev/null || { echo "semgrep missing: run make ci-tools" >&2; exit 1; }
	semgrep scan --error --config p/rust --config p/swift --config p/secrets --config p/github-actions .

ci-trivy:
	@command -v trivy >/dev/null || { echo "trivy missing: run make ci-tools" >&2; exit 1; }
	trivy fs --scanners vuln,secret,misconfig --severity CRITICAL,HIGH --exit-code 1 --ignore-unfixed \
	  --skip-dirs Packages/Edith/.build --skip-dirs apps/macos/.build --skip-dirs build --skip-dirs dist \
	  --skip-dirs node_modules --skip-dirs apps/promo-video/node_modules --skip-dirs apps/companion/target \
	  --skip-dirs .wiki-build --skip-dirs .wiki-clone --skip-dirs $(PKG)/Vendor/GhosttyKit.xcframework \
	  --skip-dirs $(PKG)/Vendor/GhosttyResources --skip-dirs extras .

ci-companion:
	cd apps/companion && cargo +stable clippy --all-targets --locked -- -D warnings
	cd apps/companion && cargo +stable test --locked

ci-companion-migrate:
	@test -n "$$DATABASE_URL" || { echo "set DATABASE_URL to a pgvector database (start one with ac)" >&2; exit 1; }
	cd apps/companion && cargo +stable run --locked -- --migrate-only

ci-tools:
	brew install yamllint lychee gitleaks trivy osv-scanner actionlint zizmor semgrep go zig fish || true
	cargo install cargo-audit --locked || true
