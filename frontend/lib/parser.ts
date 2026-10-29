import { z } from "zod";

/** The agenda parser Lambda (Lab 6). It only suggests; saving goes through the API. */
export function parserUrl(): string {
  return process.env.NEXT_PUBLIC_PARSER_URL ?? "";
}

export const parsedAgendaSchema = z.object({
  title: z.string().nullable(),
  starts_at: z.string().nullable(),
  duration_minutes: z.number().int().nullable(),
  items: z.array(
    z.object({
      topic: z.string(),
      owner: z.string().nullable(),
      minutes: z.number().int().nullable(),
    }),
  ),
  action_items: z.array(
    z.object({
      task: z.string(),
      owner: z.string().nullable(),
      due: z.string().nullable(),
    }),
  ),
  language: z.string(),
});

export const parseResponseSchema = z.object({
  agenda: parsedAgendaSchema,
  model: z.string(),
  prompt_version: z.string(),
});

export type ParsedAgenda = z.infer<typeof parsedAgendaSchema>;
export type ParseResponse = z.infer<typeof parseResponseSchema>;

export class ParseError extends Error {
  constructor(
    readonly kind: "too_long" | "no_agenda" | "busy" | "network" | "other",
    message: string,
  ) {
    super(message);
    this.name = "ParseError";
  }
}

/** Today's date in the user's time zone, not UTC: "Monday" means their Monday. */
function localToday(): string {
  const now = new Date();
  const offset = now.getTimezoneOffset() * 60_000;
  return new Date(now.getTime() - offset).toISOString().slice(0, 10);
}

export async function parseAgenda(
  text: string,
  signal?: AbortSignal,
): Promise<ParseResponse> {
  const url = parserUrl();
  if (!url) throw new ParseError("other", "The parser is not configured");

  let response: Response;
  try {
    response = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        text,
        today: localToday(),
        tz: Intl.DateTimeFormat().resolvedOptions().timeZone,
      }),
      signal,
    });
  } catch (error) {
    if (error instanceof DOMException && error.name === "AbortError")
      throw error;
    throw new ParseError(
      "network",
      "Could not reach the parser - check your connection",
    );
  }

  if (response.ok) return parseResponseSchema.parse(await response.json());

  const detail = await response
    .json()
    .then((body) => (typeof body?.error === "string" ? body.error : null))
    .catch(() => null);
  if (response.status === 413)
    throw new ParseError(
      "too_long",
      "The text is too long (10,000 characters at most)",
    );
  if (response.status === 422)
    throw new ParseError("no_agenda", "No agenda found in this text");
  if (response.status === 429 || response.status === 503)
    throw new ParseError(
      "busy",
      "The AI service is busy - try again in a minute",
    );
  throw new ParseError(
    "other",
    detail ?? `Parsing failed (${response.status})`,
  );
}
