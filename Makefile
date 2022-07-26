app := stats-article
stage ?= dev
region ?= us-west-2
account := $(shell aws sts get-caller-identity |jq -r .Account)
bucket ?= bucket-$(stage)-$(region)

test:
	@echo "stage $(stage)"

.PHONY: build
build:
	sam build --region $(region) --use-container --template-file template.yaml
	sam package --region $(region) --template-file .aws-sam/build/template.yaml --s3-bucket $(bucket) --output-template-file packaged-template.yaml

.PHONY: clean
clean:
	rm -rf ./bin ./vendor Gopkg.lock

.PHONY: deploy
deploy: build
	sam deploy --region us-east-1 --template-file template-virginia.yml --stack-name $(app) --no-fail-on-empty-changeset
	sleep 20
	sam deploy --region $(region) --template-file packaged-template.yaml --stack-name $(app) --capabilities CAPABILITY_IAM --no-fail-on-empty-changeset --parameter-overrides WebACLArn=$(shell aws cloudformation describe-stacks --region us-east-1 --stack-name $(app) --query 'Stacks[0].Outputs[?OutputKey==`WebACLArn`].OutputValue' --output text)

.PHONY: remove
remove: 
	aws cloudformation delete-stack --stack-name $(app) --region $(region)
	sleep 20
	aws cloudformation delete-stack --stack-name $(app) --region us-east-1

.PHONY: terra-deploy
terra-deploy:
	terraform -chdir=terraform apply


.PHONY: terra-remove
terra-remove:
	terraform -chdir=terraform destroy