# ModelMoor build commands.
#
# The app-bundle assembly (actool, codesign) lives in Scripts/build-app.sh;
# this Makefile wraps it and the Swift Package Manager commands.
#
# Usage: make <target>   (run `make help` for a list)

SHELL := /bin/zsh

PROJECT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
BUILD_DIR := $(PROJECT_DIR)/.build
APP_DIR := $(BUILD_DIR)/app/ModelMoor.app
DEV_APP_DIR := $(BUILD_DIR)/app-dev/ModelMoor Dev.app
CACHE_DIR := $(BUILD_DIR)/cache
MODULE_CACHE := $(BUILD_DIR)/module-cache

XCODE_DEV := /Applications/Xcode.app/Contents/Developer
ifneq ($(wildcard $(XCODE_DEV)),)
export DEVELOPER_DIR := $(XCODE_DEV)
endif

export CLANG_MODULE_CACHE_PATH := $(MODULE_CACHE)
export SWIFTPM_MODULECACHE_OVERRIDE := $(MODULE_CACHE)

BUILD_OPTIONS := --disable-sandbox --cache-path $(CACHE_DIR)

.DEFAULT_GOAL := help

.PHONY: help build app app-dev cli tui debug run run-dev run-release run-cli run-tui test test-root test-app test-tui test-cli-signal test-cli-tui-terminal test-tui-terminal test-all architecture-check localization-check install clean

help: ## Show available build commands
	@printf "Build:\n"
	@$(MAKE) --no-print-directory help-group TARGETS="build app app-dev cli tui debug"
	@printf "\nRun:\n"
	@$(MAKE) --no-print-directory help-group TARGETS="run run-dev run-release run-cli run-tui"
	@printf "\nTest and validation:\n"
	@$(MAKE) --no-print-directory help-group TARGETS="test test-root test-app test-tui test-cli-signal test-cli-tui-terminal test-tui-terminal test-all architecture-check localization-check"
	@printf "\nInstall and maintenance:\n"
	@$(MAKE) --no-print-directory help-group TARGETS="install clean"

.PHONY: help-group
help-group:
	@for target in $(TARGETS); do \
		awk -v target="$$target" -F':.*## ' '$$1 == target {printf "  %-20s %s\n", $$1, $$2}' $(MAKEFILE_LIST); \
	done

build: app ## Build the release app bundle and CLI (alias for app)

app: ## Build the release app bundle and CLI
	./Scripts/build-app.sh production

app-dev: ## Build the isolated ModelMoor Dev app bundle
	./Scripts/build-app.sh development

cli: ## Build the release CLI
	swift build $(BUILD_OPTIONS) -c release

tui: ## Build the standalone release TUI compatibility executable
	swift build --package-path Apps/TUI $(BUILD_OPTIONS) -c release

debug: ## Build the debug binaries
	swift build $(BUILD_OPTIONS)

test: architecture-check ## Run architecture checks and the root test suite
	swift test $(BUILD_OPTIONS)

architecture-check: ## Reject cross-layer platform/UI/terminal imports
	./Scripts/check-layering.sh

localization-check: ## Verify catalog parity and compiler-extracted GUI key coverage
	./Scripts/sync-localizations.sh --check
	./Scripts/check-localization-coverage.sh

run: run-dev ## Build and open the isolated development app

run-dev: app-dev ## Build and open ModelMoor Dev
	open "$(DEV_APP_DIR)"

run-release: app ## Build and open the production-profile app
	open "$(APP_DIR)"

run-cli: ## Run the debug CLI (pass arguments with ARGS='...')
	swift run $(BUILD_OPTIONS) modelmoor $(ARGS)

run-tui: ## Run the debug TUI (pass arguments with ARGS='...')
	swift run --package-path Apps/TUI $(BUILD_OPTIONS) modelmoor-tui $(ARGS)

test-root: test ## Run architecture checks and the root test suite (explicit alias)

test-app: ## Run the macOS app package tests
	swift test --package-path Apps/macOS $(BUILD_OPTIONS)

test-tui: ## Run the TUI package tests
	swift test --package-path Apps/TUI $(BUILD_OPTIONS)

test-cli-signal: cli ## Verify CLI signal handling and cleanup
	bin_path="$$(swift build $(BUILD_OPTIONS) -c release --show-bin-path)"; \
		python3 Scripts/test-cli-signal.py "$$bin_path/modelmoor"

test-cli-tui-terminal: cli ## Verify the default CLI TUI terminal behavior
	bin_path="$$(swift build $(BUILD_OPTIONS) -c release --show-bin-path)"; \
		python3 Scripts/test-tui-terminal.py "$$bin_path/modelmoor"

test-tui-terminal: tui ## Verify TUI terminal, resize, and signal handling
	bin_path="$$(swift build --package-path Apps/TUI $(BUILD_OPTIONS) -c release --show-bin-path)"; \
		python3 Scripts/test-tui-terminal.py "$$bin_path/modelmoor-tui"

test-all: test-root test-app test-tui test-cli-signal test-cli-tui-terminal test-tui-terminal ## Run all unit and terminal integration tests

install: app ## Build and install to /Applications
	rm -rf /Applications/ModelMoor.app
	cp -R $(APP_DIR) /Applications/ModelMoor.app

clean: ## Remove build artifacts
	rm -rf $(BUILD_DIR)
