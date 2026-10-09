ifeq ($(EDITH_MAKE_GATE),)

export EDITH_MAKE_GATE := 1

.PHONY: .edith-make-gate
.edith-make-gate:
	@python3 -B scripts/make-resource-gate.py exec --goals $(if $(MAKECMDGOALS),$(MAKECMDGOALS),ci) -- $(MAKE) $(MAKECMDGOALS)

ifeq ($(MAKECMDGOALS),)
.DEFAULT_GOAL := .edith-make-gate
else
.PHONY: $(MAKECMDGOALS)
$(MAKECMDGOALS): .edith-make-gate
	@:
endif

else

EXTENSION_SWIFT_JOBS ?= 2

FLAGS := $(if $(PR),--pr $(PR)) $(if $(BRANCH),--branch $(BRANCH))
PKG := Packages/Edith
STUDIO_PKG := Packages/EdithStudio
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

.PHONY: ghostty build install camera-profiles reset reinstall release release-dry loc ci ci-all ci-comments ci-secrets ci-duplicate-keys ci-lint ci-scripts ci-scripts-batch ci-performance ci-docs ci-companion-runtime ci-site ci-promo ci-browser ci-swift ci-swift-check ci-swift-lint ci-swift-build ci-swift-test ci-swift-test-batch ci-studio ci-studio-batch ci-hygiene ci-community ci-yaml ci-markdown ci-links ci-workflows ci-security ci-gitleaks ci-cargo-audit ci-osv ci-semgrep ci-trivy ci-companion ci-companion-migrate ci-tools verify-release-build-settings verify-bundle ci-shipping shipping-fixture site-dev cli icon wiki wiki-push bench-cli performance-fixture approve-package-plugins

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

ci-scripts-batch:
	@test -n "$(BATCH)" || { echo "set BATCH to a scripts test batch" >&2; exit 1; }
	@set -eu; \
	  paths="$$(python3 scripts/test-batches.py script-paths "$(BATCH)")"; \
	  bun test $$paths

ci-performance:
	bun scripts/check-performance-audit.mjs
	bun scripts/check-database-size.mjs
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
	cd $(STUDIO_PKG) && find Sources Tests Package.swift -type f -name '*.swift' ! -name '._*' -print0 | xargs -0 swift format lint --strict --parallel

ci-meeting-microphone:
	python3 scripts/build-meeting-microphone.py --test --output .build/meeting-microphone

ci-swift-build: approve-package-plugins ci-meeting-microphone
	@test -n "$(DEVELOPER_DIR)" \
	  || { echo "Xcode is required to build edth.xcodeproj; install it or run xcode-select -s" >&2; exit 1; }
	$(XCODEBUILD) -scheme EdithMain -configuration Debug $(SIGN_OVERRIDES) build

ci-swift-test: ci-studio
	cd $(PKG) && ./test.sh $(if $(FILTER),--filter '$(FILTER)')

.PHONY: ci-host host ci-marketplace-runtime ci-marketplace-host extension-dev ci-extension-support ci-extension-docs ci-extension-commands ci-extension-workers
ci-host:
	swift format lint --strict --parallel --recursive Packages/EdithHost/Sources Packages/EdithHost/Tests Packages/EdithHost/Package.swift
	swift test --package-path Packages/EdithHost --build-system native --jobs $(EXTENSION_SWIFT_JOBS) -Xswiftc -plugin-path -Xswiftc "$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"

host:
	bun scripts/build-minimal-host.mjs

extension-dev:
	bun scripts/build-extension-package.mjs $(EXTENSION) --development

ci-extension-support:
	swift format lint --strict --parallel --recursive Packages/ExtensionSupport/Sources Packages/ExtensionSupport/Tests Packages/ExtensionSupport/Package.swift Extensions/keepAwake Extensions/focusDim Extensions/windowSweaters Extensions/colorPicker Extensions/keystrokeHighlight Extensions/systemStats Extensions/micMute Extensions/emoji Extensions/homebrew Extensions/calendar Extensions/jev Extensions/presenter Extensions/system Extensions/timeLapse Extensions/cleaner Extensions/appMaintenance Extensions/blitztree Extensions/plugins Extensions/notchShelf Extensions/clipboard Extensions/music Extensions/docs Extensions/latex Extensions/usage Extensions/companion Extensions/Package.swift Packages/EdithDocsWorker/Sources Packages/EdithDocsWorker/Tests Packages/EdithDocsWorker/Package.swift
	swift test --package-path Packages/ExtensionSupport --build-system native --jobs $(EXTENSION_SWIFT_JOBS) -Xswiftc -plugin-path -Xswiftc "$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"
	swift test --package-path Extensions --build-system native --jobs $(EXTENSION_SWIFT_JOBS) -Xswiftc -plugin-path -Xswiftc "$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins" $(if $(FILTER),--filter '$(FILTER)')

.PHONY: ci-extension-audio-mixer
ci-extension-audio-mixer:
	swift format lint --strict --recursive Extensions/audioMixer
	swift test --package-path Extensions/audioMixer --build-system native --jobs $(EXTENSION_SWIFT_JOBS) -Xswiftc -plugin-path -Xswiftc "$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"

ci-extension-docs:
	swift test --package-path Packages/EdithDocsWorker --build-system native --jobs $(EXTENSION_SWIFT_JOBS)

ci-extension-workers:
	swift build --package-path Packages/EdithHost --build-system native --jobs $(EXTENSION_SWIFT_JOBS) --product HostLifecycleHarness
	bun scripts/test-extension-workers.mjs $(EXTENSION)

.PHONY: ci-music-native
ci-music-native:
	cargo fmt --manifest-path Extensions/music/Native/Cargo.toml --check
	cargo test --locked --jobs $(EXTENSION_SWIFT_JOBS) --manifest-path Extensions/music/Native/Cargo.toml

.PHONY: ci-extension-studio ci-extension-studio-native
ci-extension-studio:
	$(MAKE) -C Extensions/studio ci-studio-extension

ci-extension-studio-native:
	swift test --package-path Extensions/studio/NativeRuntime --build-system native --no-parallel --jobs $(EXTENSION_SWIFT_JOBS) -Xswiftc -plugin-path -Xswiftc "$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"

ci-extension-commands:
	bun scripts/test-extension-commands.mjs

ci-marketplace-runtime:
	swift format lint --strict --parallel --recursive Packages/ExtensionMarketplace/Sources Packages/ExtensionMarketplace/Tests
	swift test --package-path Packages/ExtensionMarketplace --build-system native --jobs $(EXTENSION_SWIFT_JOBS)

ci-marketplace-host: ci-host host
	python3 -B scripts/test-extension-size-report.py
	python3 -B scripts/test-extension-host-size-report.py
	bun scripts/extension-host-abi.mjs --write
	bun test scripts/build-extension-support.test.js scripts/extension-owned-sources.test.js scripts/extension-host-abi.test.js scripts/extension-release-plan.test.js scripts/extension-publish.test.js scripts/extension-release-ready.test.js
	$(MAKE) ci-marketplace-runtime
	$(MAKE) ci-extension-support ci-extension-docs
	$(MAKE) ci-extension-commands
	$(MAKE) ci-extension-workers
	$(MAKE) ci-comments

ci-swift-test-batch:
	@test -n "$(BATCH)" || { echo "set BATCH to a swift test batch" >&2; exit 1; }
	cd $(PKG) && ./test.sh --batch "$(BATCH)"

ci-studio:
	cd $(STUDIO_PKG) && swift test --no-parallel

ci-studio-batch:
	@test -n "$(BATCH)" || { echo "set BATCH to a studio test batch" >&2; exit 1; }
	@set -eu; \
	  spec="$$(python3 scripts/test-batches.py studio-args "$(BATCH)")"; \
	  flag="$$(printf '%s\n' "$$spec" | sed -n '1p')"; \
	  pattern="$$(printf '%s\n' "$$spec" | sed -n '2p')"; \
	  cd $(STUDIO_PKG) && swift test --no-parallel "$$flag" "$$pattern"

ci-browser:
	plutil -extract NSAppTransportSecurity.NSAllowsArbitraryLoadsInWebContent raw Resources/HelperInfo.plist | grep -qx true
	cd $(PKG) && ./test.sh --filter '^EdithTests\.(NotchBrowser|Browser|Chrome|LocalStorageSeed)'

ci-swift-check: ci-swift-lint ci-swift-build ci-swift-test

ci-swift: ci-swift-check
	./build.sh --no-open
	$(MAKE) verify-bundle

verify-release-build-settings:
	bun test scripts/shipping-host.test.js

verify-bundle:
	python3 scripts/verify-shipping-host.py dist/Edith.app

ci-shipping:
	bun test scripts/shipping-host.test.js scripts/build-install.test.js scripts/local-install-signing.test.js scripts/release-workflows.test.js scripts/ci-routing.test.js scripts/camera-extension.test.js

shipping-fixture:
	@test -n "$(HOST_FIXTURE)" || { echo "set HOST_FIXTURE to a signed empty host" >&2; exit 1; }
	python3 scripts/package-shipping-host.py "$(HOST_FIXTURE)" local/shipping-fixture/Edith.app --identity - --release
	python3 scripts/verify-shipping-host.py local/shipping-fixture/Edith.app --release
	python3 scripts/package-host-dmg.py local/shipping-fixture/Edith.app local/shipping-fixture/Edith.dmg


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
	actionlint .github/workflows/*.yml
	zizmor --persona=pedantic --min-severity=high --format=plain .github/workflows/*.yml

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
	  --skip-dirs Packages/Edith/.build --skip-dirs Packages/EdithStudio/.build --skip-dirs apps/macos/.build --skip-dirs build --skip-dirs dist \
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

endif

.PHONY: ghostty-extension ci-extension-terminal
ghostty-extension:
	test -d Extensions/terminal/Native/vendor/GhosttyKit.xcframework -a -f Extensions/terminal/Native/vendor/GhosttyResources/terminfo/78/xterm-ghostty || $(MAKE) ghostty

ci-extension-terminal: ghostty-extension
	swift format lint --strict --parallel --recursive Extensions/terminal
	swift test --package-path Extensions/terminal/Native --build-system native --jobs $(EXTENSION_SWIFT_JOBS) -Xswiftc -plugin-path -Xswiftc "$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"
	swift test --package-path Extensions/terminal --build-system native --jobs $(EXTENSION_SWIFT_JOBS) -Xswiftc -plugin-path -Xswiftc "$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins" $(if $(FILTER),--filter '$(FILTER)')
