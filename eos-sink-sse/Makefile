.PHONY: help list build install build-linux install-orb release crap crap-report lint fmt

BINARY_NAME=eos-sink-sse
GOBIN=./bin
INSTALL_PATH=~/.local/bin
ORB_MACHINE ?= debian

# golangci-lint's cache is keyed on file content, so identical sources in two
# checkouts collide in the one shared per-user cache and a clean tree can be
# served the other tree's stored findings, complete with the absolute paths
# recorded when they were first analysed. Keeping the cache inside the module
# makes collision impossible and needs no reaping: it is removed with the tree
# that owns it. Must be absolute; $(CURDIR) is.
export GOLANGCI_LINT_CACHE := $(CURDIR)/.cache/golangci-lint

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-28s\033[0m %s\n", $$1, $$2}' | sort

list: help ## List all available commands

build: ## Build binary
	@mkdir -p $(GOBIN)
	CGO_ENABLED=0 go build -o $(GOBIN)/$(BINARY_NAME) .
	@echo "Built: $(GOBIN)/$(BINARY_NAME)"

install: build ## Install to ~/.local/bin
	@mkdir -p $(INSTALL_PATH)
	cp $(GOBIN)/$(BINARY_NAME) $(INSTALL_PATH)/
	@echo "Installed: $(INSTALL_PATH)/$(BINARY_NAME)"

build-linux: ## Cross-compile for Linux (amd64)
	@mkdir -p $(GOBIN)
	GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o $(GOBIN)/$(BINARY_NAME)-linux .
	@echo "Built: $(GOBIN)/$(BINARY_NAME)-linux"

install-orb: build-linux ## Install into OrbStack $(ORB_MACHINE) at /usr/local/bin
	orb run -m $(ORB_MACHINE) bash -lc "sudo cp $(PWD)/bin/$(BINARY_NAME)-linux /usr/local/bin/$(BINARY_NAME)"
	@echo "Installed $(BINARY_NAME) in OrbStack $(ORB_MACHINE)"

lint: ## Run golangci-lint over this plugin
	golangci-lint run --timeout=5m

fmt: ## Apply golangci-lint's formatters over this plugin
	golangci-lint fmt

crap: ## Run go-crap change-risk analysis (hard gate on changed functions only, requires: go install github.com/padiazg/go-crap@latest)
	@command -v go-crap >/dev/null 2>&1 || { echo "go-crap not found. Run: go install github.com/padiazg/go-crap@latest"; exit 1; }
	bash ../scripts/go-crap-gate.sh

crap-report: ## Full whole-module go-crap debt report (informational, no gate)
	@command -v go-crap >/dev/null 2>&1 || { echo "go-crap not found. Run: go install github.com/padiazg/go-crap@latest"; exit 1; }
	go-crap scan . --exclude '.*_test\.go'

# Releasing several plugins at once must go through ../scripts/release.sh:
# GitHub Actions creates no tag events when more than three tags land in
# one push, and this repo ships four plugins, so the whole set tagged in a
# single push publishes nothing and reports no error. One tag per push is
# always safe, which is what this target does.
release: ## Tag and push this plugin's release (usage: make release TAG=v0.1.0)
	@test -n "$(TAG)" || (echo "usage: make release TAG=v0.1.0" && exit 1)
	git tag $(BINARY_NAME)/$(TAG)
	git push origin $(BINARY_NAME)/$(TAG)
	@echo "Released $(BINARY_NAME)/$(TAG); CI will build and publish"
