COMPOSE := docker compose

.PHONY: help up down build logs ps migrate revision test test-backend test-frontend lint fmt clean shell-backend shell-db deploy-backend destroy-backend logs-backend migrate-backend cert domain domain-api deploy-frontend destroy-frontend github-role deploy-ai logs-ai llm-hello parse ai-image infra-init infra-plan infra-outputs lab8-bucket lab8-venv lab8-day lab8-stream-up lab8-stream-down

help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

up: ## Start the whole stack (detached)
	$(COMPOSE) up -d --build

down: ## Stop the stack
	$(COMPOSE) down

clean: ## Stop the stack and wipe the database volume
	$(COMPOSE) down -v

build: ## Rebuild images
	$(COMPOSE) build

logs: ## Tail all logs
	$(COMPOSE) logs -f

ps: ## Show service status
	$(COMPOSE) ps

migrate: ## Apply migrations
	$(COMPOSE) exec backend alembic upgrade head

revision: ## Autogenerate a migration: make revision m="add x"
	$(COMPOSE) exec backend alembic revision --autogenerate -m "$(m)"

test: test-backend test-frontend ## Run all tests

test-backend: ## Run backend tests
	$(COMPOSE) exec backend pytest

test-frontend: ## Run frontend tests
	$(COMPOSE) exec frontend pnpm test

lint: ## Lint both sides
	$(COMPOSE) exec backend ruff check .
	$(COMPOSE) exec frontend pnpm lint

fmt: ## Format both sides
	$(COMPOSE) exec backend ruff format .
	$(COMPOSE) exec frontend pnpm format

shell-backend: ## Shell into the backend container
	$(COMPOSE) exec backend bash

shell-db: ## psql into the database
	$(COMPOSE) exec db psql -U $${POSTGRES_USER:-spry} -d $${POSTGRES_DB:-spry}

deploy-backend: ## Build + push the image, roll the Lambda (function URL + Aurora), migrate, write BACKEND_URL to .env
	./scripts/deploy-backend.sh

destroy-backend: ## Delete the backend stack, Aurora cluster included
	./scripts/destroy-backend.sh

logs-backend: ## Tail the deployed backend's CloudWatch logs
	aws logs tail /aws/lambda/$${PROJECT_NAME:-spry}-backend --follow --since 10m

migrate-backend: ## Re-run migrations on the deployed backend (deploy-backend already does)
	aws lambda invoke --function-name $${PROJECT_NAME:-spry}-backend \
		--cli-binary-format raw-in-base64-out --payload '{"action":"migrate"}' /dev/stdout

cert: ## Request + DNS-validate a us-east-1 certificate for the frontend: make cert DOMAIN=app.example.com
	./scripts/domain-frontend.sh cert

domain: ## Assign a custom domain to the frontend: make domain DOMAIN=app.example.com
	./scripts/domain-frontend.sh domain

domain-api: ## Assign a custom domain to the API: make domain-api DOMAIN=api.example.com
	DOMAIN_TARGET=api ./scripts/domain-frontend.sh domain

deploy-frontend: ## Build the static export against BACKEND_URL and ship it to S3 + CloudFront
	./scripts/deploy-frontend.sh

destroy-frontend: ## Delete the frontend stack (bucket + distribution)
	./scripts/destroy-frontend.sh

github-role: ## Create the IAM role GitHub Actions assumes to deploy (OIDC, no keys)
	./scripts/github-role.sh

# --- Lab 6: the agenda parser ------------------------------------------------
# llm-hello / parse run the parser image on this laptop with your AWS
# credentials, so nothing needs installing beyond Docker.
AI_RUN = docker run --rm -v $$HOME/.aws:/root/.aws:ro -e AWS_REGION=$${AWS_REGION:-us-east-1} \
	-e AWS_PROFILE -e PARSER_MODEL=$${PARSER_MODEL:-anthropic.claude-opus-5-5} \
	--entrypoint python3 spry-ai -m app.ai.cli

ai-image: ## Build the parser image locally
	docker build --target ai -t spry-ai backend

llm-hello: ai-image ## One question to the model on Bedrock: prints the answer, stop_reason, usage
	$(AI_RUN) hello

parse: ai-image ## Parse text from this laptop: make parse TEXT="Mon 10:00, pricing sync..."
	$(AI_RUN) parse "$(TEXT)"

deploy-ai: ## Ship new parser code: build + push the image, update the function (infra is Terraform's)
	./scripts/deploy-ai.sh

logs-ai: ## Show the parser's log lines (model, tokens, latency, cost) from the last day
	aws logs tail /aws/lambda/$${PROJECT_NAME:-spry}-agenda-parser --since 1d --format short

# --- Lab 7: infrastructure as code (infra/, HCP Terraform workspace spry-dev) -------
# There is deliberately no apply here. Infrastructure changes reach AWS one way:
# a commit to main, planned and applied by HCP Terraform.
TF = terraform -chdir=infra

infra-init: ## Connect infra/ to the HCP Terraform workspace (after `terraform login`)
	$(TF) init

infra-plan: ## Speculative plan in HCP Terraform against your local files; changes nothing
	$(TF) plan

infra-outputs: ## Write the parser URL from the Terraform state into .env (for make deploy-frontend)
	@url=$$($(TF) output -raw parser_url) && \
	  python3 -c 'import re,sys; p=".env"; k,v="PARSER_URL",sys.argv[1]; ls=open(p).read().splitlines(); i=next((n for n,l in enumerate(ls) if l.startswith(k+"=")),None); (ls.__setitem__(i,k+"="+v) if i is not None else ls.append(k+"="+v)); open(p,"w").write("\n".join(ls)+"\n")' "$$url" && \
	  echo "PARSER_URL=$$url"

# ---------------------------------------------------------------- Lab 8
LAB8_BUCKET ?= spry-lab8-416670858269
LAB8_DAY    ?= 2026-10-15

lab8-bucket: ## Lab 8: create our bucket and copy the payments dataset into it (same region, free)
	aws s3api head-bucket --bucket $(LAB8_BUCKET) 2>/dev/null || aws s3 mb s3://$(LAB8_BUCKET) --region us-east-1
	aws s3 sync s3://ucu-ooad-lab8-payments/payments/ s3://$(LAB8_BUCKET)/payments/ --copy-props none --only-show-errors
	aws s3 ls s3://$(LAB8_BUCKET)/payments/ --recursive --summarize | tail -2

lab8-venv: ## Lab 8: python venv for the producers and the consumer
	python3 -m venv lab8/.venv
	lab8/.venv/bin/pip install -q -r lab8/stream/requirements.txt -r lab8/cloud/requirements.txt

lab8-day: ## Lab 8: download one day of events for the producers: make lab8-day LAB8_DAY=2026-10-15
	mkdir -p lab8/stream/data
	aws s3 cp s3://$(LAB8_BUCKET)/payments/dt=$(LAB8_DAY)/events.jsonl lab8/stream/data/events.jsonl --only-show-errors
	wc -l lab8/stream/data/events.jsonl

lab8-stream-up: ## Lab 8: Redpanda + Console (localhost:8080) + topic payments with 3 partitions
	docker compose -f lab8/stream/docker-compose.yml up -d --wait
	docker compose -f lab8/stream/docker-compose.yml exec redpanda rpk topic create payments -p 3 || true
	docker compose -f lab8/stream/docker-compose.yml exec redpanda rpk topic describe payments

lab8-stream-down: ## Lab 8: stop Redpanda and delete its data
	docker compose -f lab8/stream/docker-compose.yml down -v
