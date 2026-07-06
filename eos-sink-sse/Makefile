.PHONY: build install build-linux install-orb

BINARY_NAME=eos-sink-sse
GOBIN=./bin
INSTALL_PATH=~/.local/bin
ORB_MACHINE ?= debian

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
