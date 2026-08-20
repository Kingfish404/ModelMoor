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

.PHONY: help build app app-dev cli debug test run run-dev run-release install clean

help: ## Show available build commands
	@grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) \
		| awk -F':.*## ' '{printf "  %-10s %s\n", $$1, $$2}'

build: app ## Build the release app bundle and CLI (alias for app)

app: ## Build the release app bundle and CLI
	./Scripts/build-app.sh production

app-dev: ## Build the isolated ModelMoor Dev app bundle
	./Scripts/build-app.sh development

cli: ## Build the release CLI
	swift build $(BUILD_OPTIONS) -c release

debug: ## Build the debug binaries
	swift build $(BUILD_OPTIONS)

test: ## Run the test suite
	swift test $(BUILD_OPTIONS)

run: run-dev ## Build and open the isolated development app

run-dev: app-dev ## Build and open ModelMoor Dev
	open "$(DEV_APP_DIR)"

run-release: app ## Build and open the production-profile app
	open "$(APP_DIR)"

install: app ## Build and install to /Applications
	rm -rf /Applications/ModelMoor.app
	cp -R $(APP_DIR) /Applications/ModelMoor.app

clean: ## Remove build artifacts
	rm -rf $(BUILD_DIR)
