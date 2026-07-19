FLAGS := $(if $(PR),--pr $(PR)) $(if $(BRANCH),--branch $(BRANCH))

.PHONY: build install reset reinstall release loc ci ci-comments ci-secrets ci-lint ci-scripts ci-promo ci-swift ci-swift-check ci-web db-migrate db-generate db-push db-studio license web-dev env-check env-generate env-rotate env-sync

ci:
	bun install --frozen-lockfile
	$(MAKE) ci-comments ci-secrets ci-lint ci-scripts ci-web ci-promo ci-swift-check

ci-web:
	cd apps/web && bun test tests
	cd apps/web && bunx tsc --noEmit

env-check:
	cd apps/web && bun -e 'const { missingEnvVars } = await import("./lib/required-env.ts"); const dotenv = Object.fromEntries((await Bun.file(".env").text()).split("\n").filter(l => l.includes("=")).map(l => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)])); const missing = missingEnvVars(dotenv); if (missing.length) { console.error("missing in apps/web/.env: " + missing.join(", ")); process.exit(1); } console.log("apps/web/.env has every required variable");'

env-generate:
	bash scripts/generate-env.sh --missing

env-rotate:
	bash scripts/generate-env.sh --rotate $(if $(filter 1,$(CONFIRM)),--confirm,--dry)

env-sync: env-check
	bash scripts/sync-env.sh $(if $(filter 1,$(CONFIRM)),--confirm,--dry)

license:
	@test -n "$(MACHINES)" || { echo "license blocked: set MACHINES, for example make license MACHINES=3 LABEL=\"Pulkit\" NAME=\"Pulkit Garg\" EMAIL=\"pulkit@example.com\" PHONE=\"+911234567890\"" >&2; exit 1; }
	bash scripts/mint-license.sh $(MACHINES) "$(LABEL)" "$(NAME)" "$(EMAIL)" "$(PHONE)"

web-dev:
	cd apps/web && bun run dev

db-generate:
	cd apps/web && bun run db:generate

db-push:
	cd apps/web && bun run db:push

db-studio:
	cd apps/web && bun run db:studio

db-migrate:
	@set -eu; \
	test -n "$(FILE)" || { echo "db-migrate blocked: set FILE, for example make db-migrate FILE=apps/web/drizzle/0001_licensing_v2.sql" >&2; exit 1; }; \
	test -f "$(FILE)" || { echo "db-migrate blocked: $(FILE) does not exist" >&2; exit 1; }; \
	DB_URL=$$(grep '^DATABASE_URL=' apps/web/.env | cut -d= -f2- | tr -d '"' | sed 's/&channel_binding=[^&]*//;s/channel_binding=[^&]*&//'); \
	test -n "$$DB_URL" || { echo "db-migrate blocked: DATABASE_URL missing from apps/web/.env" >&2; exit 1; }; \
	psql "$$DB_URL" -v ON_ERROR_STOP=1 -f "$(FILE)"

ci-comments:
	bun scripts/strip-comments.mjs --selftest
	bun scripts/strip-comments.mjs --check

ci-secrets:
	bun run check-secrets

ci-lint:
	bun run lint

ci-scripts:
	bun test ./scripts

ci-promo:
	cd apps/promo-video && npm ci && npx tsc --noEmit

ci-swift-check:
	cd apps/macos && swift format lint --strict --parallel --recursive Sources Tests Package.swift
	cd apps/macos && swift build
	cd apps/macos && ./test.sh

ci-swift: ci-swift-check
	cd apps/macos && ./build.sh --no-open
	test -f apps/macos/dist/Edith.app/Contents/MacOS/Edith
	test -f apps/macos/dist/Edith.app/Contents/Library/LoginItems/Edith.app/Contents/MacOS/Edith
	test -f apps/macos/dist/Edith.app/Contents/Library/LoginItems/Edith.app/Contents/Resources/AppIcon.icns
	test -z "$$(find apps/macos/dist/Edith.app -print | grep Helper)"
	/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' apps/macos/dist/Edith.app/Contents/Library/LoginItems/Edith.app/Contents/Info.plist | grep -qx Edith
	codesign --verify apps/macos/dist/Edith.app/Contents/Library/LoginItems/Edith.app
	codesign --verify apps/macos/dist/Edith.app

build:
	apps/macos/build.sh $(FLAGS)

install:
	apps/macos/build.sh --install $(FLAGS)

reset:
	apps/macos/reset.sh

reinstall: reset
	apps/macos/build.sh --install $(FLAGS)

release:
	@set -eu; \
	test -n "$(V)" || { echo "release blocked: set V, for example make release V=1.8.0" >&2; exit 1; }; \
	command -v gh >/dev/null 2>&1 || { echo "release blocked: gh CLI is not installed" >&2; exit 1; }; \
	gh auth status >/dev/null 2>&1 || { echo "release blocked: gh CLI is not authenticated" >&2; exit 1; }; \
	KEY=$$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' apps/macos/Resources/Info.plist 2>/dev/null || true); \
	test -n "$$KEY" || { echo "release blocked: set SUPublicEDKey in apps/macos/Resources/Info.plist" >&2; exit 1; }; \
	if command -v generate_appcast >/dev/null 2>&1; then \
	  GENERATE_APPCAST=$$(command -v generate_appcast); \
	elif test -x apps/macos/.build/artifacts/sparkle/Sparkle/bin/generate_appcast; then \
	  GENERATE_APPCAST=apps/macos/.build/artifacts/sparkle/Sparkle/bin/generate_appcast; \
	else \
	  echo "release blocked: generate_appcast is not on PATH or at apps/macos/.build/artifacts/sparkle/Sparkle/bin/generate_appcast" >&2; \
	  exit 1; \
	fi; \
	BUILD=$$(( $$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' apps/macos/Resources/Info.plist) + 1 )); \
	for p in apps/macos/Resources/Info.plist apps/macos/Resources/HelperInfo.plist apps/macos/Resources/InstallerInfo.plist; do \
	  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(V)" $$p; \
	  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $$BUILD" $$p; \
	done; \
	git commit -m "Bump version to $(V)" apps/macos/Resources/Info.plist apps/macos/Resources/HelperInfo.plist apps/macos/Resources/InstallerInfo.plist; \
	git tag "v$(V)"; \
	(cd apps/macos && ./build.sh --no-open --release); \
	rm -rf apps/macos/dmg-root; \
	rm -f "apps/macos/Edith-v$(V).dmg"; \
	mkdir apps/macos/dmg-root; \
	cp -R apps/macos/dist/Edith.app apps/macos/dmg-root/; \
	ln -s /Applications apps/macos/dmg-root/Applications; \
	hdiutil create -volname Edith -srcfolder apps/macos/dmg-root -format UDZO "apps/macos/Edith-v$(V).dmg"; \
	rm -rf apps/macos/dmg-root; \
	rm -rf apps/macos/dist/appcast; \
	mkdir apps/macos/dist/appcast; \
	cp "apps/macos/Edith-v$(V).dmg" apps/macos/dist/appcast/; \
	"$$GENERATE_APPCAST" apps/macos/dist/appcast; \
	test -f apps/macos/dist/appcast/appcast.xml || mv apps/macos/dist/appcast/appcast apps/macos/dist/appcast/appcast.xml; \
	test -f apps/macos/dist/appcast/appcast.xml || { echo "release blocked: generate_appcast did not create apps/macos/dist/appcast/appcast.xml" >&2; exit 1; }; \
	(cd apps/macos && ./build-installer.sh --release); \
	git push origin HEAD "v$(V)"; \
	gh release create "v$(V)" --title "Edith v$(V)" --generate-notes \
	  "apps/macos/Edith-v$(V).dmg" \
	  apps/macos/dist/EdithInstaller.dmg \
	  apps/macos/dist/appcast/appcast.xml \
	|| gh release upload "v$(V)" --clobber \
	  "apps/macos/Edith-v$(V).dmg" \
	  apps/macos/dist/EdithInstaller.dmg \
	  apps/macos/dist/appcast/appcast.xml

loc:
	cloc --vcs=git
