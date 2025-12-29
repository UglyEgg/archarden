SHELL := /bin/bash

lint:
	shellcheck harden lib/*.sh

fmt:
	shfmt -w harden lib/*.sh

test:
	bats test/

install:
	sudo ./harden $(EXTRA_FLAGS)

dry-run:
	sudo ./harden --dry-run --non-interactive --skip-firewall-enable $(EXTRA_FLAGS)

.PHONY: lint fmt test install dry-run
