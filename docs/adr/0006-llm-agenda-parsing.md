# ADR 0006 — Parsing pasted agendas with an LLM on Amazon Bedrock

- **Status:** accepted
- **Date:** 2026-10-29
- **Lab:** 6 (Paste an agenda)

## Context

Real agendas arrive as an email, a chat message or a few lines of notes, not
as a form. We want a user to paste that text into a meeting and get a
pre-filled agenda form (items with owner and minutes, action items with owner
and due date), check it, and save it.

Constraints:

- **No NAT gateway.** The backend Lambda sits in the VPC only to reach RDS; it
  has no route to the internet, and a NAT gateway (~$32/month) or a Bedrock
  interface endpoint (~$7.30/month) breaks "$0 when idle".
- **Cost.** Every call is paid per token, so the endpoint must reject what it
  should not pay for (empty or oversized text) before calling the model.
- **Text from outside.** The pasted text is untrusted and may contain
  instructions ("ignore your instructions…"). It is data, never a command.
- **The model is sometimes wrong**, confidently and with HTTP 200.

## Decision

1. **A separate parser Lambda outside the VPC** (`infra/ai.yml`,
   `app/ai/agenda_lambda.py`) behind its own HTTPS function URL. It needs
   Bedrock, not the database, so outside the VPC it reaches Bedrock over the
   internet with no NAT and no endpoint, and costs $0 while nobody uses it.
2. **The model only suggests; it never writes.** The parser returns JSON. The
   browser shows a pre-filled form; every model-filled field carries a
   *suggested* badge until the person edits it. Saving goes through the normal
   API (`PUT /api/v1/meetings/{id}/agenda`) with its usual validation.
3. **Model:** `anthropic.claude-opus-5-5` through the Anthropic Messages API on
   Bedrock, `effort: low`. The model id is configuration (`PARSER_MODEL`); any
   non-Anthropic id (e.g. `us.amazon.nova-micro-v1:0`) goes through the Converse
   API instead, so a cheaper model can be measured on the same inputs.
4. **A schema, not free text.** The model must answer through one tool,
   `record_agenda`, whose input schema is the Pydantic `ParsedAgenda`. The
   answer is validated; on failure the model sees the validation error once,
   then the request fails with a clear 422. An empty `items` list is "no agenda
   found", not an empty save.
5. **Prompt hygiene.** Today's date and the user's time zone go into the
   prompt (relative dates are resolved in the user's week, not UTC); the
   pasted text is wrapped in `<pasted_text>`; the system prompt says it is data
   and to leave unknown fields empty rather than guess. Version: `agenda-v1`.
6. **Keep the suggestion.** The save request carries what the model suggested
   plus the model and prompt version; the API stores it in `ai_suggestion`
   (JSONB) next to the saved `agenda`. The diff between them is the quality
   signal, with no extra effort from the user.
7. **Guard rails:** text over 10,000 characters → 413 before any model call;
   CORS on the function URL limited to the site's origins and `POST`; one JSON
   log line per parse (model, prompt version, tokens, latency, cost); an AWS
   Budgets alarm at $5/month.

## Deviations from the lab text

- **No Cognito check on the parser yet.** Sign-in arrives with Lab 4, which
  this project has not built yet. Until then the URL is public: the length
  limit, CORS and the budget alarm limit the damage, but anyone who finds the
  URL can spend tokens. Adding `verify_cognito_token()` to the handler is the
  first follow-up once the user pool exists.
- **Its own small image** (Dockerfile stage `ai`) rather than the backend image
  with another handler: the parser needs the Anthropic SDK and pydantic, not
  FastAPI and asyncpg, and `app/ai` imports nothing else from `app/`.
- **RDS, not Aurora** (see infra): on the AWS Free account plan Aurora is only
  offered in "express configuration", outside any VPC.

## Alternatives considered

| Alternative | Why it lost |
|---|---|
| Call Bedrock from the main API through a VPC interface endpoint | ~$7.30/month per endpoint per AZ even when idle; puts a slow, paid, fallible call on the request path that also writes to the database |
| Call the Claude API directly instead of Bedrock | Needs an API key stored as a secret and a second bill; Bedrock uses the Lambda's IAM role, CloudWatch and the AWS bill we already have |
| A regular-expression parser | Free and deterministic, but breaks on every new phrasing, language mix ("Пн 10:00 … Taras") or layout; it cannot resolve "by Friday" or tell an owner from a topic |
| Let the model call a `save_agenda` tool | A wrong or injected answer would be written without a human check |

## Consequences

- **Cost per parse** is logged on every call (`make logs-ai`). A one-paragraph
  agenda is about 1,500 tokens in and 300–500 out: ~$0.01–0.02 with Opus 5.5,
  ~$0.0004 with Haiku 5.5.
- **Logged per parse:** user (anonymous until sign-in), model, prompt version,
  input and output tokens, characters, latency, cost in USD. Not logged: the
  text itself (it may contain personal data).
- **When Bedrock is down or throttling** the parser answers 503/502, the screen
  says "busy, try again" and the user types the agenda by hand in the same
  form. Everything else in Spry keeps working: the parser is not on the path of
  any other request.
