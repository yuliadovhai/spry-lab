# Non-secret values only. Secrets and personal data (budget_email) are
# variables of the HCP Terraform workspace, set by infra-bootstrap/.

project_name     = "spry"
parser_role_name = "spry-ai-Role-Lf88Esqj2O52"
parser_image_uri = "416670858269.dkr.ecr.us-east-1.amazonaws.com/spry-agenda-parser:f671ca01c1f1-173327"
parser_model     = "us.amazon.nova-micro-v1:0"
allowed_origins  = ["http://localhost:3000", "https://app.yulia-spry.xyz"]
