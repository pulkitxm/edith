.PHONY: test format-check

FILTER ?= UsageEmbeddedUITests|UsageCLIExecutionTests|UsageCLIStreamTests|UsageCLIProviderTests|CLIUsageTests|CLIUsageShareTests

test:
	@fixture=$$(mktemp -d /tmp/usage-extension-fixture.XXXXXX); trap 'rm -rf "$$fixture"' EXIT; EDITH_EXTENSION_FIXTURE_HOME="$$fixture" EDITH_EXTENSION_DATA_ROOT="$$fixture/data-root" EDITH_SHARED_DEFAULTS_SUITE="edith.usage.tests.$$(basename "$$fixture")" swift test --package-path . --build-system native --no-parallel --jobs 1 --filter "$(FILTER)"

format-check:
	swift format lint --strict --recursive CLI Models/UsageUIPreferences.swift Services/UsageUICommands.swift Services/UsageWorkerController.swift ViewModels/UsageUIClient.swift Views/UsageHomeActivityCard.swift Views/UsageHomeScene.swift Views/UsageHomeUsageCard.swift Tests/UsageEmbeddedUITests.swift Tests/UsageCLIExecutionTests.swift Tests/UsageCLIStreamTests.swift Tests/UsageCLIProviderTests.swift Tests/UsageWorkerControllerTests.swift Runtime.swift Package.swift
