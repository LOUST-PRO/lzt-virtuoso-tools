# lzt-virtuoso-tools — Makefile
#
# Targets:
#   make build          Build Go bin + check bash scripts
#   make test           Run Go tests
#   make install        Copy bin/ scripts to ~/.local/bin
#   make probe          Run write-capability probe
#   make ingest VOCAB   Ingest vocabulary once: make ingest VOCAB=schema
#   make doc-ingest TECH  Ingest tech docs: make doc-ingest TECH=nextjs
#   make clean          Remove build artifacts
#
# Env:
#   LZT_VIRTUOSO_GRAPH  default: urn:lzt:vocab:docs:corpus:$(shell date +%F)
#   LZT_VIRTUOSO_CONTAINER, SSH_TARGET — see env.sh in lzt-virtuoso share dir

GO_DIR := src
BIN_DIR := bin
INSTALL_DIR := $(HOME)/.local/bin

GRAPH ?= urn:lzt:vocab:docs:corpus:$(shell date +%F)

.PHONY: build test install probe ingest doc-ingest clean help

help:
	@echo "Targets:"
	@echo "  build         Build Go bin + check bash scripts"
	@echo "  test          Run Go tests (17 tests)"
	@echo "  install       Copy scripts to $(INSTALL_DIR)"
	@echo "  probe         Diagnose Virtuoso write capability"
	@echo "  ingest VOCAB  Ingest a .ttl file (default graph: $(GRAPH))"
	@echo "  doc-ingest    Ingest tech docs (TECH=nextjs|react|...)"
	@echo "  clean         Remove build artifacts"

build:
	@echo "[build] compiling Go bin..."
	go -C $(GO_DIR) build -o ../$(BIN_DIR)/lzt-virtuoso-convert-jsonl-go .
	@echo "[build] checking bash syntax..."
	@for f in $(BIN_DIR)/lzt-virtuoso-*.sh; do \
		bash -n "$$f" && echo "  ok: $$f"; \
	done
	@echo "[build] done."

test:
	@echo "[test] running Go test suite..."
	go -C $(GO_DIR) test -v ./internal/convert/

install: build
	@echo "[install] copying scripts to $(INSTALL_DIR)..."
	install -m 0755 $(BIN_DIR)/lzt-virtuoso-* $(INSTALL_DIR)/
	@echo "[install] done."

probe:
	@echo "[probe] diagnosing Virtuoso write capability..."
	$(BIN_DIR)/lzt-virtuoso-write-probe.sh

ingest:
	@if [[ -z "$(VOCAB)" ]]; then \
		echo "Usage: make ingest VOCAB=filename.ttl"; \
		exit 1; \
	fi
	@echo "[ingest] $(VOCAB) → $(GRAPH)..."
	$(BIN_DIR)/lzt-virtuoso-ingest.sh $(VOCAB) $(GRAPH)

doc-ingest:
	@if [[ -z "$(TECH)" ]]; then \
		echo "Usage: make doc-ingest TECH=nextjs|react|react-three-fiber|drei|mermaid|tailwind"; \
		exit 1; \
	fi
	@echo "[doc-ingest] tech=$(TECH) → $(GRAPH)..."
	$(BIN_DIR)/lzt-virtuoso-doc-ingest.sh $(TECH)

clean:
	@rm -f $(BIN_DIR)/lzt-virtuoso-convert-jsonl-go
	@echo "[clean] removed Go bin (bash scripts untouched)"
