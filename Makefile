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

.PHONY: ghostty build install camera-profiles reset reinstall release release-dry loc ci ci-all ci-comments ci-secrets ci-duplicate-keys ci-lint ci-scripts ci-scripts-batch ci-performance ci-docs ci-companion-runtime ci-site ci-promo ci-browser ci-swift ci-swift-check ci-swift-lint ci-swift-build ci-swift-test ci-swift-test-batch ci-studio ci-studio-batch ci-hygiene ci-community ci-yaml ci-markdown ci-links ci-workflows ci-security ci-gitleaks ci-cargo-audit ci-osv ci-semgrep ci-trivy ci-companion ci-companion-migrate ci-tools verify-release-build-settings verify-bundle ci-shipping shipping-fixture shipping-appcast-fixture site-dev cli icon wiki wiki-push bench-cli performance-fixture approve-package-plugins

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

cli:
	./build.sh --no-open

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
	rg --files Packages/EdithHost Packages/ExtensionMarketplace Packages/ExtensionSupport Packages/EdithDocsWorker Extensions | rg '\.swift$$' | xargs swift format lint --strict --parallel

ci-swift-build:
	EDITH_RELEASE_ALLOW_DEV_SIGNING=1 ./build.sh --no-open --release
	$(MAKE) verify-bundle

ci-swift-test:
	$(MAKE) ci-marketplace-host ci-music-native

.PHONY: ci-host ci-host-core host ci-marketplace-runtime ci-marketplace-host extension-dev ci-extension-support ci-extension-docs ci-extension-commands ci-extension-workers
ci-host:
	swift format lint --strict --parallel --recursive Packages/EdithHost/Sources Packages/EdithHost/Tests Packages/EdithHost/Package.swift
	swift test --package-path Packages/EdithHost --build-system native --jobs $(EXTENSION_SWIFT_JOBS) -Xswiftc -plugin-path -Xswiftc "$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"

ci-host-core:
	bun scripts/test-host-core.mjs

host:
	bun scripts/build-minimal-host.mjs

extension-dev:
	bun scripts/build-extension-package.mjs $(EXTENSION) --development

ci-extension-support:
	swift format lint --strict --parallel --recursive Packages/ExtensionSupport/Sources Packages/ExtensionSupport/Tests Packages/ExtensionSupport/Package.swift Extensions/keepAwake Extensions/focusDim Extensions/windowSweaters Extensions/colorPicker Extensions/keystrokeHighlight Extensions/systemStats Extensions/micMute Extensions/emoji Extensions/homebrew Extensions/calendar Extensions/jev Extensions/presenter Extensions/system Extensions/timeLapse Extensions/cleaner Extensions/appMaintenance Extensions/blitztree Extensions/plugins Extensions/notchShelf Extensions/clipboard Extensions/music Extensions/docs Extensions/latex Extensions/usage Extensions/companion Extensions/bifrost Extensions/lidAwake Extensions/downloads Extensions/seoAudit Extensions/Package.swift Packages/EdithDocsWorker/Sources Packages/EdithDocsWorker/Tests Packages/EdithDocsWorker/Package.swift
	swift test --package-path Packages/ExtensionSupport --build-system native --no-parallel --jobs $(EXTENSION_SWIFT_JOBS) -Xswiftc -plugin-path -Xswiftc "$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"
	swift test --package-path Extensions --build-system native --no-parallel --jobs $(EXTENSION_SWIFT_JOBS) -Xswiftc -plugin-path -Xswiftc "$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins" --skip HerdrCollectorFixtureTests $(if $(FILTER),--filter '$(FILTER)')
	fixture=$$(mktemp -d /tmp/edith-extension-tests.XXXXXX); trap 'rm -rf "$$fixture"' EXIT; EDITH_EXTENSION_FIXTURE_HOME="$$fixture" EDITH_SHARED_DEFAULTS_SUITE="edith.extensions.tests.$$(basename "$$fixture")" swift test --package-path Extensions --build-system native --no-parallel --jobs $(EXTENSION_SWIFT_JOBS) -Xswiftc -plugin-path -Xswiftc "$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins" --filter HerdrCollectorFixtureTests

define UTILITY_EXTENSION_NATIVE_TEST
	swift format lint --strict --recursive Extensions/$(1)
	fixture=$$(mktemp -d /tmp/edith-$(1)-tests.XXXXXX); trap 'rm -rf "$$fixture"' EXIT; env -u EDITH_EXTENSION_TEST_SDK -u EDITH_TEST_VOICE_ENCODER -u EDITH_TEST_VOICE_MODEL EDITH_TEST_NATIVE_CAPTURE=0 EDITH_EXTENSION_FIXTURE_HOME="$$fixture" EDITH_EXTENSION_DATA_ROOT="$$fixture/data" EDITH_SHARED_DEFAULTS_SUITE="edith.$(1).tests.$$(basename "$$fixture")" swift test --package-path Extensions/$(1) --build-system native --no-parallel --jobs $(EXTENSION_SWIFT_JOBS) -Xswiftc -plugin-path -Xswiftc "$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins" $(if $(FILTER),--filter '$(FILTER)') $(if $(SKIP),--skip '$(SKIP)')
endef

.PHONY: ci-extension-homebrew
ci-extension-homebrew:
	$(call UTILITY_EXTENSION_NATIVE_TEST,homebrew)

.PHONY: ci-extension-jev
ci-extension-jev:
	$(call UTILITY_EXTENSION_NATIVE_TEST,jev)

.PHONY: ci-extension-system
ci-extension-system:
	$(call UTILITY_EXTENSION_NATIVE_TEST,system)

.PHONY: ci-extension-time-lapse
ci-extension-time-lapse:
	$(call UTILITY_EXTENSION_NATIVE_TEST,timeLapse)

.PHONY: ci-extension-cleaner
ci-extension-cleaner:
	$(call UTILITY_EXTENSION_NATIVE_TEST,cleaner)

.PHONY: ci-extension-app-maintenance
ci-extension-app-maintenance:
	$(call UTILITY_EXTENSION_NATIVE_TEST,appMaintenance)

.PHONY: ci-extension-blitztree
ci-extension-blitztree:
	$(call UTILITY_EXTENSION_NATIVE_TEST,blitztree)

.PHONY: ci-extension-lid-awake
ci-extension-lid-awake:
	$(call UTILITY_EXTENSION_NATIVE_TEST,lidAwake)
	swiftc -typecheck -swift-version 5 -module-name LidAwakePrivilegedRole -target arm64-apple-macos14.0 Extensions/lidAwake/Privileged/LidAwakePrivilegedController.swift Extensions/lidAwake/Privileged/LidAwakePrivilegedRuntime.swift Extensions/lidAwake/Services/LidAwakeCommand.swift Extensions/lidAwake/Services/LidAwakeCommandProcess.swift

.PHONY: ci-extension-audio-mixer
ci-extension-audio-mixer:
	$(call UTILITY_EXTENSION_NATIVE_TEST,audioMixer)

.PHONY: ci-extension-camera
ci-extension-camera:
	swift test --package-path Extensions/virtualCamera/Privileged --build-system native --jobs $(EXTENSION_SWIFT_JOBS) --no-parallel
	$(call UTILITY_EXTENSION_NATIVE_TEST,virtualCamera)
	swiftc -typecheck -swift-version 5 -module-name CameraCarrierRole -target arm64-apple-macos14.0 -I Extensions/virtualCamera/.build/arm64-apple-macosx/debug/Modules Extensions/virtualCamera/CameraCarrierRuntime.swift Extensions/virtualCamera/CameraCarrierLease.swift Extensions/virtualCamera/CameraCarrierProtocol.swift Extensions/virtualCamera/CameraCarrierSession.swift Extensions/virtualCamera/CameraSystemExtensionController.swift Extensions/virtualCamera/Carrier/Factory.swift

.PHONY: ci-extension-camera-roles
ci-extension-camera-roles: ci-extension-camera

.PHONY: ci-extension-camera-carrier
ci-extension-camera-carrier: host
	bun test scripts/camera-carrier.test.js
	bun scripts/test-camera-carrier.mjs

.PHONY: ci-extension-camera-voice
ci-extension-camera-voice:
	bun scripts/test-extension-native-policy.mjs
	python3 scripts/build-camera-microphone.py --application com.pulkit.edith.tests.camera --version 1.0.0 --output local/camera-microphone
	python3 scripts/build-camera-microphone.py --test --driver local/camera-microphone/com.pulkit.edith.tests.camera.microphone.driver --output local/camera-microphone
	swift test --package-path Extensions/virtualCamera/NativeRuntime --build-system native --jobs $(EXTENSION_SWIFT_JOBS) --no-parallel

ci-extension-docs:
	swift test --package-path Packages/EdithDocsWorker --build-system native --jobs $(EXTENSION_SWIFT_JOBS)

.PHONY: ci-extension-docs-native ci-extension-plugins-native ci-extension-latex-native ci-extension-code-stats-native ci-extension-seo-audit-native ci-extension-companion-native ci-extension-bifrost-native
ci-extension-docs-native:
	swift format lint --strict --recursive Extensions/docs
	fixture=$$(mktemp -d /tmp/edith-docs-native-tests.XXXXXX); trap 'rm -rf "$$fixture"' EXIT; EDITH_EXTENSION_FIXTURE_HOME="$$fixture" EDITH_SHARED_DEFAULTS_SUITE="edith.docs.fixture.$$(basename "$$fixture")" swift test --package-path Extensions/docs --build-system native --no-parallel --jobs 1 -Xswiftc -plugin-path -Xswiftc "$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"

ci-extension-plugins-native:
	swift format lint --strict --recursive Extensions/plugins
	fixture=$$(mktemp -d /tmp/edith-plugins-native-tests.XXXXXX); trap 'rm -rf "$$fixture"' EXIT; EDITH_EXTENSION_FIXTURE_HOME="$$fixture" EDITH_SHARED_DEFAULTS_SUITE="edith.plugins.fixture.$$(basename "$$fixture")" swift test --package-path Extensions/plugins --build-system native --no-parallel --jobs 1 -Xswiftc -plugin-path -Xswiftc "$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"

ci-extension-latex-native:
	swift format lint --strict --recursive Extensions/latex
	fixture=$$(mktemp -d /tmp/edith-latex-native-tests.XXXXXX); trap 'rm -rf "$$fixture"' EXIT; EDITH_EXTENSION_FIXTURE_HOME="$$fixture" EDITH_SHARED_DEFAULTS_SUITE="edith.latex.fixture.$$(basename "$$fixture")" swift test --package-path Extensions/latex --build-system native --no-parallel --jobs 1 -Xswiftc -plugin-path -Xswiftc "$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"

ci-extension-code-stats-native:
	swift format lint --strict --recursive Extensions/codeStats
	fixture=$$(mktemp -d /tmp/edith-codeStats-native-tests.XXXXXX); trap 'rm -rf "$$fixture"' EXIT; EDITH_EXTENSION_FIXTURE_HOME="$$fixture" EDITH_SHARED_DEFAULTS_SUITE="edith.codeStats.fixture.$$(basename "$$fixture")" swift test --package-path Extensions/codeStats --build-system native --no-parallel --jobs 1 -Xswiftc -plugin-path -Xswiftc "$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"

ci-extension-seo-audit-native:
	swift format lint --strict --recursive Extensions/seoAudit
	fixture=$$(mktemp -d /tmp/edith-seoAudit-native-tests.XXXXXX); trap 'rm -rf "$$fixture"' EXIT; EDITH_EXTENSION_FIXTURE_HOME="$$fixture" EDITH_SHARED_DEFAULTS_SUITE="edith.seoAudit.fixture.$$(basename "$$fixture")" swift test --package-path Extensions/seoAudit --build-system native --no-parallel --jobs 1 -Xswiftc -plugin-path -Xswiftc "$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"

ci-extension-companion-native:
	swift format lint --strict --recursive Extensions/companion
	fixture=$$(mktemp -d /tmp/edith-companion-native-tests.XXXXXX); trap 'rm -rf "$$fixture"' EXIT; EDITH_EXTENSION_FIXTURE_HOME="$$fixture" EDITH_SHARED_DEFAULTS_SUITE="edith.companion.fixture.$$(basename "$$fixture")" swift test --package-path Extensions/companion --build-system native --no-parallel --jobs 1 -Xswiftc -plugin-path -Xswiftc "$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"

ci-extension-bifrost-native:
	swift format lint --strict --recursive Extensions/bifrost
	fixture=$$(mktemp -d /tmp/edith-bifrost-native-tests.XXXXXX); trap 'rm -rf "$$fixture"' EXIT; EDITH_EXTENSION_FIXTURE_HOME="$$fixture" EDITH_SHARED_DEFAULTS_SUITE="edith.bifrost.fixture.$$(basename "$$fixture")" swift test --package-path Extensions/bifrost --build-system native --no-parallel --jobs 1 -Xswiftc -plugin-path -Xswiftc "$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"


ci-extension-workers:
	swift build --package-path Packages/EdithHost --build-system native --jobs $(EXTENSION_SWIFT_JOBS) --product HostLifecycleHarness
	bun scripts/test-extension-workers.mjs $(EXTENSION)

.PHONY: ci-privileged-worker
ci-privileged-worker:
	python3 -B scripts/test-privileged-extension-worker.py

.PHONY: ci-extension-bifrost ci-extension-lid-awake
ci-extension-bifrost:
	swift format lint --strict --recursive Extensions/bifrost
	swift test --package-path Extensions --build-system native --no-parallel --jobs $(EXTENSION_SWIFT_JOBS) -Xswiftc -plugin-path -Xswiftc "$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins" --filter BifrostExtensionTests

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

.PHONY: ci-host-cli
ci-host-cli:
	bun scripts/test-host-cli.mjs

ci-marketplace-runtime:
	swift format lint --strict --parallel --recursive Packages/ExtensionMarketplace/Sources Packages/ExtensionMarketplace/Tests
	swift test --package-path Packages/ExtensionMarketplace --build-system native --jobs $(EXTENSION_SWIFT_JOBS)

ci-marketplace-host: ci-host host
	$(MAKE) ci-host-cli
	python3 -B scripts/test-extension-size-report.py
	python3 -B scripts/test-extension-host-size-report.py
	python3 -B scripts/test-host-build-metadata.py
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
	bun test scripts/shipping-host.test.js scripts/build-install.test.js scripts/local-install-signing.test.js scripts/release-workflows.test.js scripts/ci-routing.test.js scripts/camera-extension.test.js scripts/publish-release-state.test.js scripts/publish-host-release.test.js scripts/extension-release-plan.test.js scripts/extension-publish.test.js scripts/extensions-workflow.test.js

shipping-fixture:
	@test -n "$(HOST_FIXTURE)" || { echo "set HOST_FIXTURE to a signed empty host" >&2; exit 1; }
	python3 scripts/package-shipping-host.py "$(HOST_FIXTURE)" local/shipping-fixture/Edith.app --identity - --release
	python3 scripts/verify-shipping-host.py local/shipping-fixture/Edith.app --release
	python3 scripts/package-host-dmg.py local/shipping-fixture/Edith.app local/shipping-fixture/Edith.dmg

shipping-appcast-fixture:
	python3 scripts/test-host-appcast.py local/shipping-fixture/Edith.app Packages/EdithHost/.build/artifacts/sparkle/Sparkle/bin


ghostty:
	bash scripts/build-ghostty.sh

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
	python3 scripts/test-semgrep.py
	python3 scripts/check-semgrep.py -- semgrep

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

.PHONY: ci-extension-database
ci-extension-database:
	swift format lint --strict --recursive Extensions/database
	env -u EDITH_DATABASE_POSTGRESQL_HOST swift test --package-path Extensions/database/DatabaseEngine --no-parallel --jobs $(EXTENSION_SWIFT_JOBS)
	cd Extensions/database && env -u EDITH_DATABASE_POSTGRESQL_HOST EDITH_DATABASE_RELATION_FILTERS=0 node test.mjs $(if $(FILTER),'$(FILTER)')

ci-tools:
	brew install yamllint lychee gitleaks trivy osv-scanner actionlint zizmor semgrep go zig fish || true
	cargo install cargo-audit --locked || true

endif

.PHONY: ghostty-extension ci-extension-terminal
ghostty-extension:
	bash scripts/build-ghostty.sh --extension-only

ci-extension-terminal: ghostty-extension
	swift format lint --strict --parallel --recursive Extensions/terminal
	swift test --package-path Extensions/terminal/Native --build-system native --jobs $(EXTENSION_SWIFT_JOBS) -Xswiftc -plugin-path -Xswiftc "$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"
	swift test --package-path Extensions/terminal --build-system native --jobs $(EXTENSION_SWIFT_JOBS) -Xswiftc -plugin-path -Xswiftc "$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins" $(if $(FILTER),--filter '$(FILTER)')

.PHONY: ci-extension-attention
ci-extension-attention:
	bun scripts/prepare-extension-native-support.mjs attention
	swift format lint --strict --recursive Extensions/attention
	swift test --package-path Extensions/attention/NativeRuntime --build-system native --no-parallel --jobs $(EXTENSION_SWIFT_JOBS) -Xswiftc -plugin-path -Xswiftc "$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"
.PHONY: ci-machines
ci-machines:
	EDITH_EXTENSION_FIXTURE_HOME=/tmp/edith-machines-tests swift test --package-path Extensions --build-system native --jobs $(EXTENSION_SWIFT_JOBS) -Xswiftc -plugin-path -Xswiftc "$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins" --filter MachinesExtensionTests

.PHONY: ci-machines-ui
ci-machines-ui: ghostty-extension
	EDITH_EXTENSION_FIXTURE_HOME=/tmp/edith-machines-tests swift test --package-path Extensions/machines --build-system native --jobs $(EXTENSION_SWIFT_JOBS) -Xswiftc -plugin-path -Xswiftc "$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"

.PHONY: ci-extension-machines
ci-extension-machines: ci-machines ci-machines-ui
.PHONY: ci-extension-downloads
ci-extension-downloads:
	swift format lint --strict --recursive Extensions/downloads
	fixture=$$(mktemp -d /tmp/edith-downloads-native-tests.XXXXXX); trap 'rm -rf "$$fixture"' EXIT; EDITH_EXTENSION_FIXTURE_HOME="$$fixture" EDITH_SHARED_DEFAULTS_SUITE="edith.downloads.fixture.$$(basename "$$fixture")" swift test --package-path Extensions/downloads --build-system native --no-parallel --jobs 1 -Xswiftc -plugin-path -Xswiftc "$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"

.PHONY: ci-extension-native-tasks
ci-extension-native-tasks:
	swift build --package-path Packages/EdithHost --build-system native --jobs $(EXTENSION_SWIFT_JOBS) --product HostNativeTaskHarness
	bun scripts/test-extension-native-tasks.mjs
.PHONY: ci-extension-herdr-core
ci-extension-herdr-core:
	fixture=$$(mktemp -d /tmp/edith-herdr-tests.XXXXXX); trap 'rm -rf "$$fixture"' EXIT; EDITH_EXTENSION_FIXTURE_HOME="$$fixture" EDITH_SHARED_DEFAULTS_SUITE="edith.herdr.fixture.$$(basename "$$fixture")" swift test --package-path Extensions --build-system native --jobs $(EXTENSION_SWIFT_JOBS) -Xswiftc -plugin-path -Xswiftc "$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins" --filter HerdrExtensionTests


.PHONY: ci-extension-herdr-ui ci-extension-herdr
ci-extension-herdr-ui: ghostty-extension
	fixture=$$(mktemp -d /tmp/edith-herdr-tests.XXXXXX); trap 'rm -rf "$$fixture"' EXIT; EDITH_EXTENSION_FIXTURE_HOME="$$fixture" EDITH_SHARED_DEFAULTS_SUITE="edith.herdr.fixture.$$(basename "$$fixture")" swift test --package-path Extensions/herdr --build-system native --no-parallel --skip AgentTranscriptMemoryTests --jobs $(EXTENSION_SWIFT_JOBS) -Xswiftc -plugin-path -Xswiftc "$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"
	fixture=$$(mktemp -d /tmp/edith-herdr-tests.XXXXXX); trap 'rm -rf "$$fixture"' EXIT; EDITH_EXTENSION_FIXTURE_HOME="$$fixture" EDITH_SHARED_DEFAULTS_SUITE="edith.herdr.fixture.$$(basename "$$fixture")" swift test --package-path Extensions/herdr --build-system native --no-parallel --filter AgentTranscriptMemoryTests --jobs $(EXTENSION_SWIFT_JOBS) -Xswiftc -plugin-path -Xswiftc "$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"
ci-extension-herdr: ci-extension-herdr-core ci-extension-herdr-ui

.PHONY: ci-extension-quinjet-core
ci-extension-quinjet-core:
	@fixture=$$(mktemp -d /tmp/edith-quinjet-tests.XXXXXX); trap 'rm -rf "$$fixture"' EXIT; EDITH_EXTENSION_FIXTURE_HOME="$$fixture" EDITH_SHARED_DEFAULTS_SUITE="edith.quinjet.tests.$$(uuidgen)" swift test --package-path Extensions --build-system native --jobs $(EXTENSION_SWIFT_JOBS) -Xswiftc -plugin-path -Xswiftc "$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins" --filter QuinjetExtensionTests

.PHONY: ci-extension-quinjet-ui ci-extension-quinjet
ci-extension-quinjet-ui: ghostty-extension
	@fixture=$$(mktemp -d /tmp/edith-quinjet-ui-tests.XXXXXX); trap 'rm -rf "$$fixture"' EXIT; EDITH_EXTENSION_FIXTURE_HOME="$$fixture" EDITH_SHARED_DEFAULTS_SUITE="edith.quinjet.ui.tests.$$(uuidgen)" swift test --package-path Extensions/quinjet --build-system native --no-parallel --jobs $(EXTENSION_SWIFT_JOBS) -Xswiftc -plugin-path -Xswiftc "$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"
ci-extension-quinjet: ci-extension-quinjet-core ci-extension-quinjet-ui

.PHONY: ci-extension-music
ci-extension-music:
	swift format lint --strict --parallel --recursive Extensions/music
	fixture=$$(mktemp -d /tmp/edith-music-tests.XXXXXX); trap 'rm -rf "$$fixture"' EXIT; EDITH_EXTENSION_FIXTURE_HOME="$$fixture" EDITH_EXTENSION_DATA_ROOT="$$fixture/data" EDITH_SHARED_DEFAULTS_SUITE="edith.music.tests.$$(basename "$$fixture")" swift test --package-path Extensions/music --build-system native --no-parallel --jobs $(EXTENSION_SWIFT_JOBS) -Xswiftc -plugin-path -Xswiftc "$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"

.PHONY: ci-extension-presenter
ci-extension-presenter:
	swift format lint --strict --parallel --recursive Extensions/presenter
	fixture=$$(mktemp -d /tmp/edith-presenter-tests.XXXXXX); trap 'rm -rf "$$fixture"' EXIT; EDITH_EXTENSION_FIXTURE_HOME="$$fixture" EDITH_EXTENSION_DATA_ROOT="$$fixture/data" EDITH_SHARED_DEFAULTS_SUITE="edith.presenter.tests.$$(basename "$$fixture")" swift test --package-path Extensions/presenter --build-system native --no-parallel --jobs $(EXTENSION_SWIFT_JOBS) -Xswiftc -plugin-path -Xswiftc "$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"
