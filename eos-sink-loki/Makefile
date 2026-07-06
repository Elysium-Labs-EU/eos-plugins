.PHONY: help list build install build-linux install-orb release

BINARY_NAME=eos-sink-loki
GOBIN=./bin
INSTALL_PATH=~/.local/bin
ORB_MACHINE ?= debian

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

release: ## Tag and push release (usage: make release TAG=v0.1.0)
	@test -n "$(TAG)" || (echo "usage: make release TAG=v0.1.0" && exit 1)
	git tag $(BINARY_NAME)/$(TAG)
	git push origin $(BINARY_NAME)/$(TAG)
	@echo "Released $(BINARY_NAME)/$(TAG) — CI will build and publish"
