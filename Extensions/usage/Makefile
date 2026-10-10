.PHONY: test format-check

FILTER ?= UsageEmbeddedUITests

test:
	@fixture=$$(mktemp -d /tmp/usage-extension-fixture.XXXXXX); trap 'rm -rf "$$fixture"' EXIT; EDITH_EXTENSION_FIXTURE_HOME="$$fixture" EDITH_EXTENSION_DATA_ROOT="$$fixture/data-root" EDITH_SHARED_DEFAULTS_SUITE="edith.usage.tests.$$(basename "$$fixture")" swift test --package-path . --build-system native --jobs 1 --filter "$(FILTER)"

format-check:
	swift format lint --strict --recursive Models/UsageUIPreferences.swift Services/UsageUICommands.swift ViewModels/UsageUIClient.swift Views/UsageHomeActivityCard.swift Tests/UsageEmbeddedUITests.swift Runtime.swift Package.swift
