# Makefile for writing-schedule.el
# Run "make help" for a list of targets.

SHELL := /bin/bash
.DEFAULT_GOAL := help

# --- Tool configuration (override on the command line if needed) ---
EMACS        ?= emacs
COVERAGE_MIN ?= 90

# If your Emacs user directory is not ~/.emacs.d, set EMACS_DIR so the
# package-based targets (install-test-deps, coverage, lint) reuse your
# installed packages and their elpa store, for example:
#   make coverage EMACS_DIR=~/e30fewpackages
# This needs Emacs 29 or later, which provides --init-directory.
EMACS_DIR    ?=
INIT_DIR     := $(if $(strip $(EMACS_DIR)),--init-directory $(EMACS_DIR),)

SRC_DIR      ?= .
TEST_DIR     ?= test

# Source files, excluding tests and package descriptors.
SRC_FILES    := $(filter-out %-test.el test-%.el %-pkg.el,$(wildcard $(SRC_DIR)/*.el))
# All test files.  Look in TEST_DIR first, then fall back to the current
# directory so a flat layout (tests beside the Makefile) also works.
TEST_FILES   := $(wildcard $(TEST_DIR)/test-*.el $(TEST_DIR)/*-test.el)
ifeq ($(strip $(TEST_FILES)),)
  TEST_DIR   := .
  TEST_FILES := $(wildcard test-*.el *-test.el)
endif

# Make packages installed with package.el (undercover, package-lint) visible.
INIT_PKG     := --eval "(progn (require (quote package)) (package-initialize))"

ifneq ($(TERM),)
  GREEN  := \033[0;32m
  RED    := \033[0;31m
  YELLOW := \033[0;33m
  RESET  := \033[0m
else
  GREEN  :=
  RED    :=
  YELLOW :=
  RESET  :=
endif

.PHONY: help test test-unit test-integration compile lint checkdoc \
        coverage coverage-html coverage-check clean install-test-deps

help: ## Show this help message
	@echo "writing-schedule.el make targets:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
	awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' 
	@echo ""

install-test-deps: ## Install undercover and package-lint via package.el
	@echo -e "$(YELLOW)Installing test dependencies...$(RESET)"
	$(EMACS) $(INIT_DIR) --batch \
	--eval "(require 'package)" \
	--eval "(setq package-archives (append package-archives (quote ((\"melpa\" . \"https://melpa.org/packages/\")))))" \
	--eval "(package-initialize)" \
	--eval "(package-refresh-contents)" \
	--eval "(dolist (p (quote (undercover package-lint))) (unless (package-installed-p p) (package-install p)))"
	@echo -e "$(GREEN)Dependencies installed.$(RESET)"

test: ## Run all tests (unit + integration)
	@echo -e "$(YELLOW)Running all tests...$(RESET)"
	$(EMACS) $(INIT_DIR) --batch \
	-L $(SRC_DIR) -L $(TEST_DIR) \
	$(foreach f,$(TEST_FILES),-l $(f)) \
	-f ert-run-tests-batch-and-exit
	@echo -e "$(GREEN)All tests passed.$(RESET)"

test-unit: ## Run unit tests only
	@echo -e "$(YELLOW)Running unit tests...$(RESET)"
	$(EMACS) $(INIT_DIR) --batch \
	-L $(SRC_DIR) -L $(TEST_DIR) \
	$(foreach f,$(filter-out %-integration.el,$(TEST_FILES)),-l $(f)) \
	-f ert-run-tests-batch-and-exit
	@echo -e "$(GREEN)Unit tests passed.$(RESET)"

test-integration: ## Run integration tests only
	@echo -e "$(YELLOW)Running integration tests...$(RESET)"
	$(EMACS) $(INIT_DIR) --batch \
	-L $(SRC_DIR) -L $(TEST_DIR) \
	$(foreach f,$(filter %-integration.el,$(TEST_FILES)),-l $(f)) \
	--eval "(ert-run-tests-batch-and-exit '(tag integration))"
	@echo -e "$(GREEN)Integration tests passed.$(RESET)"

compile: ## Byte-compile the source with warnings as errors
	@echo -e "$(YELLOW)Byte-compiling...$(RESET)"
	$(EMACS) $(INIT_DIR) --batch \
	-L $(SRC_DIR) \
	--eval "(setq byte-compile-error-on-warn t)" \
	-f batch-byte-compile $(SRC_FILES)
	@echo -e "$(GREEN)Compiled with no warnings.$(RESET)"

lint: ## Run package-lint on the source (needs install-test-deps)
	@echo -e "$(YELLOW)Running package-lint...$(RESET)"
	$(EMACS) $(INIT_DIR) --batch $(INIT_PKG) \
	-L $(SRC_DIR) \
	--eval "(require 'package-lint)" \
	$(foreach f,$(SRC_FILES),--eval '(with-current-buffer (find-file-noselect "$(f)") (package-lint-current-buffer))')
	@echo -e "$(GREEN)Lint complete.$(RESET)"

checkdoc: ## Check documentation strings
	@echo -e "$(YELLOW)Running checkdoc...$(RESET)"
	$(EMACS) $(INIT_DIR) --batch $(foreach f,$(SRC_FILES),--eval '(checkdoc-file "$(f)")')
	@echo -e "$(GREEN)Checkdoc complete.$(RESET)"

coverage: ## Run tests with undercover.el (text report; needs install-test-deps)
	@echo -e "$(YELLOW)Running tests with coverage...$(RESET)"
	$(EMACS) $(INIT_DIR) --batch $(INIT_PKG) \
	-L $(SRC_DIR) -L $(TEST_DIR) \
	--eval "(require 'undercover)" \
	--eval '(undercover "$(SRC_DIR)/*.el" (:report-format (quote text)) (:send-report nil))' \
	$(foreach f,$(TEST_FILES),-l $(f)) \
	-f ert-run-tests-batch-and-exit
	@echo -e "$(GREEN)Coverage report printed above.$(RESET)"

coverage-html: ## Generate an LCOV HTML coverage report in htmlcov/
	@echo -e "$(YELLOW)Generating HTML coverage report...$(RESET)"
	$(EMACS) $(INIT_DIR) --batch $(INIT_PKG) \
	-L $(SRC_DIR) -L $(TEST_DIR) \
	--eval "(require 'undercover)" \
	--eval '(undercover "$(SRC_DIR)/*.el" (:report-format (quote lcov)) (:report-file "coverage.lcov") (:send-report nil))' \
	$(foreach f,$(TEST_FILES),-l $(f)) \
	-f ert-run-tests-batch-and-exit
	genhtml coverage.lcov --output-directory htmlcov
	@echo -e "$(GREEN)Open htmlcov/index.html in your browser.$(RESET)"

coverage-check: ## Fail if line coverage is below $(COVERAGE_MIN)%
	@echo -e "$(YELLOW)Checking coverage threshold ($(COVERAGE_MIN)%)...$(RESET)"
	@$(MAKE) coverage-html
	@TOTAL=$$(lcov --summary coverage.lcov 2>&1 | grep 'lines' | awk '{print $$2}' | tr -d '%'); \
	echo "Total line coverage: $${TOTAL}%"; \
	if [ $$(echo "$${TOTAL} < $(COVERAGE_MIN)" | bc -l) -eq 1 ]; then \
	echo -e "$(RED)Coverage $${TOTAL}% is below the $(COVERAGE_MIN)% threshold.$(RESET)"; \
	exit 1; \
	else \
	echo -e "$(GREEN)Coverage meets the threshold.$(RESET)"; \
	fi

clean: ## Remove byte-compiled files and coverage artifacts
	@echo -e "$(YELLOW)Cleaning...$(RESET)"
	rm -rf htmlcov/ coverage.lcov *.elc $(TEST_DIR)/*.elc
	@echo -e "$(GREEN)Clean.$(RESET)"
