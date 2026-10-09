SHELL := /bin/bash -eo pipefail
.PHONY: setup format lint build test e2e run

DERIVED_DATA ?= .build/DerivedData
SESSION ?=
XCODEBUILD := xcodebuild -project Herdlight.xcodeproj -scheme Herdlight -derivedDataPath $(DERIVED_DATA)
BEAUTIFY := $(if $(shell command -v xcbeautify),| xcbeautify)

setup:
	brew bundle
	git config core.hooksPath .githooks

format:
	swiftformat .
	swiftlint lint --fix --quiet

lint:
	swiftformat --lint .
	swiftlint lint --strict --quiet

build:
	$(XCODEBUILD) -destination 'platform=macOS' build $(BEAUTIFY)
	$(XCODEBUILD) -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build $(BEAUTIFY)

test:
	swift test --package-path Packages/HerdrKit --scratch-path $(DERIVED_DATA)/HerdrKit

# Runs the UI tests against a throwaway herdr session, removed even when tests fail.
e2e:
	session=hl-e2e-$$(openssl rand -hex 3); \
	trap 'scripts/herdr-session.sh down '$$session EXIT; \
	scripts/herdr-session.sh up $$session; \
	rm -rf $(DERIVED_DATA)/e2e.xcresult; \
	TEST_RUNNER_HL_SESSION=$$session $(XCODEBUILD) -destination 'platform=macOS' \
		-resultBundlePath $(DERIVED_DATA)/e2e.xcresult test $(BEAUTIFY)

run:
	$(XCODEBUILD) -destination 'platform=macOS' build $(BEAUTIFY)
	open $(DERIVED_DATA)/Build/Products/Debug/Herdlight.app $(if $(SESSION),--args -session $(SESSION))
