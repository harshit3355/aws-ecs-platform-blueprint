# Meridian Platform -- developer entry point.
#
# Every check that runs in CI has a target here with the same name, so a change
# can be validated locally before it is pushed. If a command exists in a
# workflow but not in this file, that is a bug in this file.

SHELL := /bin/bash
.DEFAULT_GOAL := help

PYTHON       ?= python
VENV         := .venv
VENV_BIN     := $(VENV)/bin
SERVICE_DIR  := services/api
TF_DIR       := infrastructure/terraform
COMPOSE      := docker compose -f platform/observability/docker-compose.yml
ENV          ?= staging

# Windows virtualenvs put executables in Scripts/ rather than bin/.
ifeq ($(OS),Windows_NT)
	VENV_BIN := $(VENV)/Scripts
endif

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------- environment

.PHONY: install
install: ## Create the virtualenv and install dev dependencies
	$(PYTHON) -m venv $(VENV)
	$(VENV_BIN)/python -m pip install --upgrade pip
	$(VENV_BIN)/python -m pip install -r $(SERVICE_DIR)/requirements-dev.txt

# ---------------------------------------------------------------- application

.PHONY: lint
lint: ## Lint and check formatting
	$(VENV_BIN)/ruff check .
	$(VENV_BIN)/ruff format --check .

.PHONY: format
format: ## Apply formatting and safe lint fixes
	$(VENV_BIN)/ruff check --fix .
	$(VENV_BIN)/ruff format .

.PHONY: test
test: ## Run unit tests
	$(VENV_BIN)/pytest -v -m "not integration"

.PHONY: test-integration
test-integration: ## Run integration tests against a live PostgreSQL
	$(VENV_BIN)/pytest -v -m integration

.PHONY: test-all
test-all: ## Run the whole suite with coverage
	$(VENV_BIN)/pytest -v --cov=$(SERVICE_DIR) --cov-report=term-missing

.PHONY: audit
audit: ## Check runtime dependencies for known vulnerabilities
	$(VENV_BIN)/pip-audit -r $(SERVICE_DIR)/requirements.txt --progress-spinner off

# ---------------------------------------------------------------- local stack

.PHONY: up
up: ## Start the full local stack (api, postgres, prometheus, grafana)
	$(COMPOSE) up -d --build
	@echo "api        http://localhost:8000/docs"
	@echo "prometheus http://localhost:9090"
	@echo "grafana    http://localhost:3000"

.PHONY: down
down: ## Stop the local stack
	$(COMPOSE) down

.PHONY: clean-volumes
clean-volumes: ## Stop the local stack and delete its data volumes
	$(COMPOSE) down -v

.PHONY: db-up
db-up: ## Start only PostgreSQL, for running integration tests locally
	$(COMPOSE) up -d postgres

.PHONY: db-down
db-down: ## Stop PostgreSQL
	$(COMPOSE) stop postgres

.PHONY: logs
logs: ## Follow local stack logs
	$(COMPOSE) logs -f

.PHONY: load
load: ## Drive traffic at the local API so the dashboards have data
	@for i in $$(seq 1 200); do curl -s localhost:8000/items > /dev/null; done
	@curl -s "localhost:8000/simulate/slow?seconds=2" > /dev/null
	@curl -s localhost:8000/simulate/error > /dev/null || true
	@echo "done - check the Service (RED) dashboard"

# ------------------------------------------------------------- infrastructure

.PHONY: tf-fmt
tf-fmt: ## Format Terraform
	terraform fmt -recursive infrastructure/

.PHONY: tf-fmt-check
tf-fmt-check: ## Check Terraform formatting without changing files
	terraform fmt -check -recursive -diff infrastructure/

.PHONY: tf-validate
tf-validate: ## Validate every environment without AWS credentials
	@for env in staging prod; do \
		echo "--- $$env ---"; \
		terraform -chdir=$(TF_DIR)/environments/$$env init -backend=false -input=false > /dev/null; \
		terraform -chdir=$(TF_DIR)/environments/$$env validate; \
	done

.PHONY: tf-lint
tf-lint: ## Run tflint across the Terraform tree
	tflint --chdir=$(TF_DIR) --recursive --format compact

.PHONY: tf-scan
tf-scan: ## Run Checkov static security analysis
	checkov --directory $(TF_DIR) --framework terraform --quiet

.PHONY: tf-plan
tf-plan: ## Plan an environment. Requires AWS credentials. ENV=staging|prod
	terraform -chdir=$(TF_DIR)/environments/$(ENV) plan

.PHONY: tf-apply
tf-apply: ## Apply an environment. Requires AWS credentials. ENV=staging|prod
	terraform -chdir=$(TF_DIR)/environments/$(ENV) apply

.PHONY: tf-output
tf-output: ## Show an environment's outputs. ENV=staging|prod
	terraform -chdir=$(TF_DIR)/environments/$(ENV) output

# ------------------------------------------------------------- observability

.PHONY: promtool-check
promtool-check: ## Validate the Prometheus config and alert rules
	promtool check config platform/observability/prometheus/prometheus.yml
	promtool check rules platform/observability/prometheus/rules/alerts.yml

.PHONY: dashboards-check
dashboards-check: ## Validate every dashboard PromQL expression with promtool
	@$(VENV_BIN)/python scripts/check_dashboards.py

# ---------------------------------------------------------------- aggregate

.PHONY: actionlint
actionlint: ## Lint the GitHub Actions workflows
	actionlint

.PHONY: verify
verify: lint test audit tf-fmt-check tf-validate promtool-check dashboards-check ## Run every check CI runs that needs no credentials
	@echo ""
	@echo "All local checks passed."

.PHONY: clean
clean: ## Remove caches and build artefacts
	rm -rf .pytest_cache .ruff_cache .coverage coverage.xml htmlcov
	find . -type d -name __pycache__ -not -path "./$(VENV)/*" -exec rm -rf {} + 2>/dev/null || true
