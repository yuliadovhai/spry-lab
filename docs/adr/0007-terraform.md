# ADR 0007 — The project's infrastructure in Terraform, run by HCP Terraform

- **Status:** accepted
- **Date:** 2026-10-30
- **Lab:** 7 (The cloud as code)

## Context

Labs 4–6 were meant to add three CloudFormation templates: `auth.yml` (Cognito),
`reports.yml` (the weekly report) and `ai.yml` (the agenda parser). This project
has only `ai.yml`, because Labs 4 and 5 have not been built yet. It also had one
resource that no template described: the parser's ECR repository, created by a
deploy script with `aws ecr create-repository` — exactly the "made by hand and
forgotten" case from Part 0.

The course template's own stacks (`infra/backend.yaml`, `frontend.yaml`,
`github-oidc.yaml`) stay in CloudFormation, as the lab allows.

Constraints:

- the parser's resources already exist and are in use (the site at
  `app.yulia-spry.xyz` calls the function URL), so they must be **adopted, not
  re-created**: a new function URL would be a new address the site does not know;
- the project already reaches outside AWS (the domain at Namecheap, GitHub) and
  will need a second environment;
- nobody should need AWS keys to change infrastructure.

## Decision

1. **Terraform**, in `infra/*.tf`: `versions.tf`, `variables.tf`, `ai.tf`,
   `outputs.tf`, `terraform.tfvars` (non-secret values only).
2. **HCP Terraform** keeps the state and runs Terraform: organization
   `ooad-yuliadovhai`, workspace `spry-dev`, Remote execution, working
   directory `infra`, connected to the GitHub repository. A pull request gets a
   speculative plan; a commit to `main` is planned and applied automatically.
3. **No stored AWS keys.** Runs get temporary credentials through OIDC: AWS
   trusts tokens from `app.terraform.io` for **this organization and this
   workspace only** (`organization:ooad-yuliadovhai:project:*:workspace:spry-dev:run_phase:*`).
   The trust, the role and the workspace with its variables are created once by
   `infra-bootstrap/`, from a laptop, with local state.
4. **Adoption, not re-creation.** Every resource in `ai.yml` got
   `DeletionPolicy: Retain`, the stack was deleted, and `import` blocks
   (generated from the stack's real IDs by `scripts/tf-adopt.sh`) handed the
   resources to Terraform. The plan was iterated until it showed only imports and
   the two re-created permissions, then applied; the next plan said
   *No changes*.
5. **Two roads.** Terraform owns the function's configuration (role, memory,
   timeout, environment, URL, CORS, budget). `make deploy-ai` owns its code: it
   pushes an image and calls `update-function-code`. `image_uri` is in
   `lifecycle.ignore_changes`, so the two never fight. The model is
   configuration: changing `parser_model` is a pull request.

### What was imported, and what was re-created

| Resource | How | Why it is safe |
|---|---|---|
| ECR repository `spry-agenda-parser` | imported | — (it was not in any template) |
| IAM role (`spry-ai-Role-…`), its inline policy `invoke-bedrock`, its managed policy attachment | imported | The CloudFormation-generated name is kept in `terraform.tfvars`; a new name would be a new role |
| Log group `/aws/lambda/spry-agenda-parser` | imported | Keeps the log lines Lab 6 submitted |
| Function `spry-agenda-parser`, its function URL | imported | Re-creating the URL would change the address the site calls |
| Budget `spry-monthly` | imported | — |
| The two function URL permissions | **re-created** | Statement IDs are part of their identity and CloudFormation chose them. Terraform added two new statements first; `scripts/tf-cleanup-permissions.sh` then removed the old ones. The URL stayed public throughout |

8 imported, 2 re-created, 0 destroyed.

## Alternatives considered

| Alternative | Why it lost |
|---|---|
| **Stay on CloudFormation** | AWS keeps the state for us, and it rolls back on failure. But it stops at one AWS account: the Namecheap DNS records, the GitHub repository and a future Google OAuth client cannot be in the same plan, and a second environment means copying stacks by hand |
| **AWS CDK** | Code instead of YAML, but it still deploys CloudFormation stacks, with the same one-cloud limit, and adds a TypeScript/Python build step to infrastructure |
| **OpenTofu** | The same language and providers under an open-source licence (Terraform is BSL since 2023). A valid choice; we use Terraform because the course and HCP Terraform's state, locking and VCS runs come with it. Switching later is mostly `tofu` instead of `terraform` and another backend |
| **Delete the stack, apply the Terraform** | Simplest, but it would destroy and re-create the function URL (new address) and the log group (old logs gone). With Cognito in Lab 4 it would delete every user |
| **State in an S3 bucket** | Works, with locking, but the bucket itself must be created first and protected; HCP Terraform also gives runs, a UI, plan checks on pull requests and OIDC to AWS |

## Consequences

**Who can change the infrastructure now, and how.** Anyone with push access to
the repository, through one road: edit `infra/`, open a pull request, read the
plan in the HCP Terraform check, merge; HCP Terraform applies. Nobody needs AWS
keys for it. The Makefile has no `apply`. `terraform apply` from a laptop is for
emergencies only (and HCP Terraform rejects it while the workspace is connected
to VCS). The bootstrap in `infra-bootstrap/` is the one exception, applied once.

**Where secrets and personal data end up.** No secret is in Git.
`budget_email` is a variable of the workspace, set by the bootstrap. **The
state holds every attribute in plain text**, including the budget email and the
function's environment, so the state is as sensitive as the account: it lives in
HCP Terraform (encrypted, access-controlled), never in Git or on a laptop.
`sensitive = true` would only hide a value in plan output, not in the state.
The bootstrap's local state holds the role ARN and the email; it is git-ignored.

**What happens if HCP Terraform is down.** Nothing that is running stops: the
site, the API and the parser do not depend on it. Only infrastructure changes
wait. In an emergency, the workspace can be switched to Local execution and
someone with AWS credentials can run `terraform apply` against the same remote
state once the service is back, or the state can be pulled
(`terraform state pull`) and kept for a manual recovery.

**Drift.** Every plan compares the files with the real resources. A change made
in the console is shown as a `~` line and reverted by the next apply. A 23:00
fix in the console must therefore be followed by the same change in `infra/`
the next morning, or it will be undone.

**Costs.** HCP Terraform's free tier covers this workspace. The resources cost
what they cost before.

**Not done here.** `auth.tf` and `reports.tf` will be written directly in
Terraform when Labs 4 and 5 are built. The course template's stacks
(`backend`, `frontend`, `github-oidc`) can be read from Terraform with the
`aws_cloudformation_stack` data source when something needs their outputs.
