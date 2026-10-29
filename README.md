# Spry

Meeting analytics for teams: where the week goes, and how it compares with the
last one. This repository is a monorepo — FastAPI backend, Next.js + shadcn/ui
frontend, PostgreSQL — that starts with one command.

**[PROJECT.md](PROJECT.md) is the specification**: the layout, the API
contract, the Compose services and the pinned versions. This README is how to
run and deploy it.

## Getting started

Install Docker Desktop, then:

```bash
git clone https://github.com/<you>/<repo>.git spry && cd spry
cp .env.example .env
docker compose up --build
```

The first run builds the images and takes a few minutes.

| URL | What |
|-----|------|
| http://localhost:3000 | Frontend: the meetings page |
| http://localhost:8000/docs | API docs (Swagger) |
| http://localhost:8000/health | Liveness probe |
| `postgresql://spry:spry@localhost:5432/spry` | Database |

Open the frontend, add a meeting, reload the page. If it is still there, the
whole chain works: component → API → ORM → Postgres and back.

If a port is taken, change `POSTGRES_PORT`, `BACKEND_PORT` or `FRONTEND_PORT`
in `.env`.

## Everyday commands

```bash
make up              # start everything, detached
make logs            # tail all logs
make test            # backend and frontend tests
make lint            # ruff + eslint
make fmt             # ruff format + prettier --write
make revision m="add x"   # autogenerate a migration
make clean           # stop and wipe the database volume
make help            # everything else
```

Without Docker, for editor tooling: `docker compose up db`, then
`cd backend && uv sync && uv run uvicorn app.main:app --reload` and
`cd frontend && pnpm install && pnpm dev`, with `DATABASE_URL` pointed at
`localhost`.

## Deploying the backend to AWS

Everything lives in **us-east-1**, and every resource carries a `PROJECT_NAME` tag.

```bash
make deploy-backend      # build -> ECR -> CloudFormation -> Lambda -> migrate -> BACKEND_URL in .env
make migrate-backend     # re-run migrations alone
make logs-backend        # tail CloudWatch
make destroy-backend     # delete everything, database included
```

`infra/backend.yaml` is the whole architecture in one CloudFormation stack:

```
internet -> Lambda function URL (HTTPS) -> Lambda (FastAPI via Mangum, in the VPC) -> RDS PostgreSQL :5432
```

`scripts/deploy-backend.sh` drives it, in order:

1. ensures the ECR repository, builds the Dockerfile's `lambda` stage for `linux/arm64` and pushes
   it (with `--provenance=false`: Lambda rejects the manifest list buildx makes otherwise);
2. deploys the stack with the new image URI;
3. invokes the function directly with `{"action": "migrate"}`, which runs `alembic upgrade head`.
   A function URL request can never produce that event, so only someone allowed to call
   `lambda:InvokeFunction` can trigger it;
4. **writes the API URL into `.env` as `BACKEND_URL`** — the function URL, always HTTPS.
   `make deploy-frontend` builds against it, so the backend always goes first.

**Before the first run** put your credentials in `.env` (`AWS_PROFILE` works instead of static
keys). Everything else is optional: left blank, the script uses the default VPC and its subnets,
skipping AZs Lambda cannot use (`use1-az3`). The first deploy takes about ten minutes, almost all
of it the database. A first deploy that failed is cleaned up automatically on the next run.

**RDS, not Aurora.** The database is one `db.t4g.micro` RDS PostgreSQL 17 instance with 20 GiB of
gp2 storage, private to the VPC. On the AWS **Free account plan** Aurora is offered only through
"express configuration", which lives outside any VPC and accepts IAM tokens only; `db.t4g.micro`
RDS is in the free tier and keeps the original shape — function and database in the same VPC,
the database unreachable from the internet. On Lambda the app runs with `DB_POOLING=false`
(SQLAlchemy `NullPool`): each request opens and closes its own connection, so warm execution
environments cannot exhaust the small instance's connection limit.

**No NAT gateway.** The function sits in the VPC only to reach the database and needs nothing from the
internet, so the default subnets do. The flip side is that it cannot reach Secrets Manager, so
the connection string comes in as the `DATABASE_URL` environment variable. The password is
generated on the first deploy, kept in the `spry/backend/database-url` secret, and read back
from there on later deploys rather than rotated.

**A custom domain on the backend too.** A function URL cannot carry a domain, so
`make domain-api DOMAIN=api.example.com` switches on a CloudFront distribution in front of it
(`ApiDistribution` in `infra/backend.yaml`): an ACM certificate from us-east-1, nothing cached,
every header including `Authorization` passed through, and `Host` rewritten to the function URL's
own name. It then writes `BACKEND_URL=https://api.example.com` to `.env`; rebuild the site with
`make deploy-frontend` so it calls the API there. Later `make deploy-backend` runs keep the domain.

**What it costs.**

| | Idle | Per use |
|---|---|---|
| Lambda (512 MB, arm64) | $0 | free tier: 1M requests + 400k GB-s a month |
| RDS `db.t4g.micro` + 20 GiB | free tier on the Free plan; about $14/month on pay-as-you-go | — |
| Secrets Manager (one secret) | $0.40 | — |
| ECR, CloudWatch Logs | ~$0 at this size | — |

## Deploying the frontend to CloudFront

```bash
make deploy-frontend                  # build the static export against BACKEND_URL -> S3 -> CloudFront
make domain DOMAIN=app.example.com    # assign a custom domain to the site, separately
make domain-api DOMAIN=api.example.com  # and to the API
make cert   DOMAIN=app.example.com    # just the certificate half
make destroy-frontend                 # delete the bucket and the distribution
```

Every route in this app prerenders (`next build` reports them all as `○ Static`), so the frontend
ships as a static export rather than a running server:

```
browser -> CloudFront (HTTPS, edge cache) -> private S3 bucket
                   |
           viewer-request function: /page -> /page.html
```

`infra/frontend.yaml` holds it. The bucket blocks all public access and has no website endpoint;
CloudFront reaches it through an origin access control, and the bucket policy only trusts requests
carrying this distribution's ARN. A static export writes `page.html`, not `page/index.html`, so a
small CloudFront Function rewrites `/page` and `/page/` onto `page.html`. Missing keys
come back from S3 as 403 rather than 404, so both map to the exported `404.html`.

**The API URL is compiled in, not read at runtime.** `NEXT_PUBLIC_*` is substituted at build time,
so the script builds against `BACKEND_URL` from `.env` — written there by `make deploy-backend` —
and stops if it is empty. The `NEXT_PUBLIC_API_URL` further up that file stays pointed at localhost
for Compose and is not used here.

**Then let the site through CORS.** The script prints the exact line: put the site's URL in
`API_CORS_ORIGINS` and run `make deploy-backend` once more.

### Custom domain

The custom domain is the frontend's alone, and it is assigned separately: `make deploy-frontend`
never touches the domain settings, and `make domain` touches nothing else — it does not rebuild or
re-upload the site.

```bash
make domain DOMAIN=app.example.com
```

Run it once, after the first `make deploy-frontend`. It finds or requests an ACM certificate
**in us-east-1** (the only region CloudFront takes certificates from), gets it DNS-validated,
records the domain in `.env`, and updates the frontend stack with the domain. The distribution then
answers on the domain as well as on its `*.cloudfront.net` name. Certificates are free and renew
themselves as long as the validation record stays put.

- **DNS in Route 53.** The script finds the hosted zone by longest suffix match, writes the
  validation record itself, and hands `HostedZoneId` to CloudFormation, which then owns A and AAAA
  alias records pointing at the distribution. Nothing to do by hand.
- **DNS anywhere else.** The script prints the validation `CNAME` and waits for it, then prints the
  second record — your domain to the distribution's hostname. A zone apex cannot be a `CNAME`, so
  for `example.com` rather than `app.example.com` you need Route 53 or your provider's
  `ALIAS`/`ANAME` record.

`make cert` is the first half on its own. Both are safe to re-run. The certificate is not part of
the stack, so `make destroy-frontend` leaves it behind. Afterwards, add `https://app.example.com`
to `API_CORS_ORIGINS` and `make deploy-backend`.

**Caching.** Hashed assets under `_next/static/` upload with `max-age=31536000,immutable` and
without `--delete`, so a client mid-navigation can still fetch the previous build's chunks; they
cost fractions of a cent and can be pruned by hand whenever. Everything else uploads with
`max-age=0,must-revalidate` and the distribution is invalidated on every deploy, so a deploy is
visible immediately.

**What it costs: nothing.** CloudFront's always-free tier is 1 TB out and 10M requests a month,
permanently, and the whole site is 2 MB. The distribution uses nothing outside it: CloudFront
Functions get 2M invocations free a month, invalidations are free up to 1,000 paths a month and
this uses one per deploy, and there is no WAF, logging, Lambda@Edge, Origin Shield or dedicated
IP. The price class is fixed at `PriceClass_100` (North America and Europe), the cheapest, should
traffic ever outgrow the free tier. The S3 bucket holding the site costs a few cents a year. For a
hard $0 cap rather than a free tier, CloudFront's flat-rate *Free* plan can be selected on the
distribution in the console; there is no API for it yet.

## Deploying from GitHub Actions

```bash
make github-role      # once: create the role Actions assumes
```

Then write the word **deploy** in a commit message on `main`:

```bash
git commit -m "feat: sort meetings by start, deploy"
git push
```

`.github/workflows/deploy-backend.yml` picks that up and runs `make deploy-backend` on a runner.
Ordinary commits to `main` do nothing, so the expensive path stays opt-in. The workflow also has a
`workflow_dispatch` trigger, so it can be run by hand from the Actions tab without any magic word.
Matching is case-insensitive — GitHub compares strings that way — so `Deploy` and `redeployed`
count too.

**No access key is involved.** `make github-role` creates a stack holding an IAM role and, if the
account does not already have one, the GitHub OIDC provider. The workflow asks GitHub for a
short-lived token describing the run, and AWS trades it for temporary credentials. The trust policy
accepts that token only for this repository and only for the subject below:

```
repo:<owner>/<repo>:ref:refs/heads/main
```

That restriction matters. Widening it to `repo:<owner>/<repo>:*` — via `GITHUB_SUBJECT_CLAIM` in
`.env` — would let any branch, and any pull request from anyone who can open one, assume a role
that can deploy. The default keeps it to `main`.

The role's policy is deliberately not `AdministratorAccess`. It is scoped to the services the
deploy actually drives, and to this project's resource names wherever the API supports it —
a few, such as `ec2:CreateSecurityGroup`, accept no resource-level permissions at all. If a CI deploy ever stops with `AccessDenied`, the missing
action belongs in `infra/github-oidc.yaml`.

**Two repository variables** carry the rest: `AWS_DEPLOY_ROLE_ARN` and `AWS_REGION`. If the `gh`
CLI is installed and logged in, `make github-role` sets both for you; otherwise it prints them to
paste into *Settings → Secrets and variables → Actions*. Neither is secret — the ARN is useless
without a token minted by this repository's workflows.

**CI has no `.env`, and that is fine.** Any parameter the deploy script resolves to an empty value
is left out of the CloudFormation call, and CloudFormation then keeps whatever the stack already
has. So a deploy from CI will not widen `API_CORS_ORIGINS` back to `*` — the settings you made
locally survive. CI also writes `BACKEND_URL` into a throwaway `.env` on the runner; locally, run
`make deploy-backend` yourself before `make deploy-frontend`.

**The image builds under emulation.** The function runs on arm64 and the runner is x86, so
the workflow sets up QEMU and buildx pushes the cross-architecture image straight to ECR rather
than loading it into the local daemon. Switching the job to a `ubuntu-24.04-arm` runner makes the
build native and those two steps unnecessary.

The frontend is not wired to CI — `make deploy-frontend` stays a local command for now.

## Lab 6: Paste an agenda

```bash
make llm-hello                      # one question to the model, from this laptop (Docker)
make parse TEXT="Пн 10:00, синк..." # the parser on a piece of text, from this laptop
BUDGET_EMAIL=you@example.com make deploy-ai   # parser Lambda + function URL + $5 budget
make deploy-backend                 # migration 0002: agenda + ai_suggestion
make deploy-frontend                # compiles PARSER_URL into the site
make logs-ai                        # model, prompt version, tokens, latency, cost per parse
```

`PARSER_MODEL=anthropic.claude-haiku-5-5 make deploy-ai` switches the model; any non-Anthropic id
(e.g. `us.amazon.nova-micro-v1:0`) goes through the Converse API. Design and trade-offs:
[ADR 0006](docs/adr/0006-llm-agenda-parsing.md); report template: [docs/lab6-report.md](docs/lab6-report.md).
