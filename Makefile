SHELL := /bin/bash

# Local configuration; keep .env out of Git.
-include .env
export TF_VAR_allowed_email
.PHONY: build build-primary build-secondary init validate plan deploy serve test check destroy destroy-plan push
build: build-primary build-secondary
build-primary:
	mkdir -p .build
	cd lambda && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -tags lambda.norpc -trimpath -o ../.build/bootstrap .
build-secondary:
	mkdir -p .build/secondary
	cd lambda-secondary && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -tags lambda.norpc -trimpath -o ../.build/secondary/bootstrap .
init:
	terraform init
validate: build
	terraform fmt -check
	terraform validate
plan: build
	terraform plan -out=.build/poc.tfplan
deploy: plan
	terraform apply .build/poc.tfplan
serve:
	python3 scripts/poc.py serve
test:
	python3 scripts/poc.py test
check: validate
	terraform test -filter=secondary.tftest.hcl
	cd lambda && go test ./...
	cd lambda-secondary && go test ./...
	python3 -m unittest discover -s scripts -p 'test_*.py' -v
destroy:
	terraform destroy

# Preview only; this command does not delete resources.
destroy-plan:
	mkdir -p .build
	terraform plan -destroy -out=.build/destroy.tfplan

# Commit the reviewed files before running this target.
push:
	git push -u origin main
