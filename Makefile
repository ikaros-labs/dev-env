PROVIDER ?= hetzner
COMPOSE  := docker compose

.PHONY: build tf-init tf-plan tf-apply tf-destroy ansible shell down

build:
	$(COMPOSE) build

tf-init:
	$(COMPOSE) run --rm tools bash -c \
	  "cd terraform/$(PROVIDER) && terraform init"

tf-plan:
	$(COMPOSE) run --rm tools bash -c \
	  "cd terraform/$(PROVIDER) && terraform init && terraform plan"

tf-apply:
	$(COMPOSE) run --rm tools bash -c \
	  "cd terraform/$(PROVIDER) && terraform init && terraform apply"

tf-destroy:
	$(COMPOSE) run --rm tools bash -c \
	  "cd terraform/$(PROVIDER) && terraform init && terraform destroy"

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
