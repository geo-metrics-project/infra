.PHONY: infra-namespace metallb ingress all

SCRIPT_DIR=$(shell cd scripts/setup && pwd)
SETUP_SCRIPT=$(SCRIPT_DIR)/setup-infra.sh

infra-namespace:
	bash $(SETUP_SCRIPT) create_namespace

metallb:
	bash $(SETUP_SCRIPT) setup_metallb

ingress:
	bash $(SETUP_SCRIPT) deploy_ingress

all: infra-namespace helm-repos ingress