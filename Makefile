PROVIDER ?= $(shell grep -s '^PROVIDER=' .env | cut -d= -f2)
PROVIDER := $(or $(PROVIDER),hetzner)
COMPOSE  := docker compose

.PHONY: build tf-init tf-plan tf-apply tf-destroy ansible shell down

build:
	$(COMPOSE) build

tf-init:
	$(COMPOSE) run --rm -w /workspace/terraform/$(PROVIDER) tools terraform init

tf-plan:
	$(COMPOSE) run --rm -w /workspace/terraform/$(PROVIDER) tools terraform init
	$(COMPOSE) run --rm -w /workspace/terraform/$(PROVIDER) tools terraform plan $(ARGS)

tf-apply:
	$(COMPOSE) run --rm -w /workspace/terraform/$(PROVIDER) tools terraform init
	$(COMPOSE) run --rm -w /workspace/terraform/$(PROVIDER) tools terraform apply $(ARGS)

tf-destroy:
	$(COMPOSE) run --rm -w /workspace/terraform/$(PROVIDER) tools terraform init
	$(COMPOSE) run --rm -w /workspace/terraform/$(PROVIDER) tools terraform destroy $(ARGS)

ansible:
	$(COMPOSE) run --rm tools bash -c \
	  "bash scripts/gen-inventory.sh --tf-dir terraform/$(PROVIDER) && \
	   cd ansible && \
	   ansible-galaxy collection install -r requirements.yml && \
	   ansible-playbook playbooks/setup.yml"

shell:
	$(COMPOSE) run --rm tools bash

down:
	$(COMPOSE) down
