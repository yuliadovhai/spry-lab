import { z } from "zod";

/** Browser code must reach the API through the published port; server components
 *  resolve the Compose service name instead. */
export function apiBaseUrl(): string {
  if (typeof window === "undefined") {
    return process.env.INTERNAL_API_URL ?? "http://backend:8000";
  }
  return process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000";
}

export class ApiError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
    this.name = "ApiError";
  }
}

/** FastAPI's 422 carries a list of problems; turn it into one readable line. */
function errorDetail(body: unknown): string | null {
  const detail = (body as { detail?: unknown } | null)?.detail;
  if (typeof detail === "string") return detail;
  if (Array.isArray(detail)) {
    const messages = detail
      .map((entry) => (entry as { msg?: unknown })?.msg)
      .filter((msg): msg is string => typeof msg === "string");
    if (messages.length > 0) return messages.join("; ");
  }
  return null;
}

async function request<T>(
  path: string,
  schema: z.ZodType<T>,
  init?: RequestInit,
): Promise<T> {
  let response: Response;
  try {
    response = await fetch(`${apiBaseUrl()}${path}`, {
      ...init,
      cache: "no-store",
      headers: {
        "Content-Type": "application/json",
        ...(init?.headers ?? {}),
      },
    });
  } catch {
    throw new ApiError(0, "Could not reach the API");
  }

  if (!response.ok) {
    const detail = await response
      .json()
      .then(errorDetail)
      .catch(() => null);
    throw new ApiError(
      response.status,
      detail ?? `Request failed (${response.status})`,
    );
  }

  return schema.parse(await response.json());
}

/* --- schemas mirroring the API contract in PROJECT.md --- */

export const agendaItemSchema = z.object({
  topic: z.string(),
  owner: z.string().nullable(),
  minutes: z.number().int().nullable(),
});

export const actionItemSchema = z.object({
  task: z.string(),
  owner: z.string().nullable(),
  due: z.string().nullable(),
});

export const agendaSchema = z.object({
  items: z.array(agendaItemSchema),
  action_items: z.array(actionItemSchema),
});

export const meetingSchema = z.object({
  id: z.string(),
  title: z.string(),
  starts_at: z.string(),
  ends_at: z.string(),
  attendee_count: z.number().int(),
  created_at: z.string(),
  agenda: agendaSchema.nullable().optional(),
});

export const meetingListSchema = z.object({
  meetings: z.array(meetingSchema),
  total: z.number().int(),
});

export const healthSchema = z.object({
  status: z.string(),
  database: z.string(),
});

export type Meeting = z.infer<typeof meetingSchema>;
export type Agenda = z.infer<typeof agendaSchema>;

/** What PUT /api/v1/meetings/{id}/agenda accepts. */
export type AgendaSave = Agenda & {
  ai_suggestion?: {
    agenda: unknown;
    model: string;
    prompt_version: string;
  } | null;
};
export type MeetingList = z.infer<typeof meetingListSchema>;

/** What POST /api/v1/meetings accepts. Times are ISO 8601 with an offset. */
export type MeetingCreate = {
  title: string;
  starts_at: string;
  ends_at: string;
  attendee_count: number;
};

/* --- endpoints --- */

export const api = {
  readiness: () => request("/api/v1/health/ready", healthSchema),

  listMeetings: (params: { limit?: number; offset?: number } = {}) => {
    const query = new URLSearchParams();
    if (params.limit !== undefined) query.set("limit", String(params.limit));
    if (params.offset !== undefined) query.set("offset", String(params.offset));
    const suffix = query.size > 0 ? `?${query}` : "";
    return request(`/api/v1/meetings${suffix}`, meetingListSchema);
  },

  createMeeting: (payload: MeetingCreate) =>
    request("/api/v1/meetings", meetingSchema, {
      method: "POST",
      body: JSON.stringify(payload),
    }),

  saveAgenda: (meetingId: string, payload: AgendaSave) =>
    request(`/api/v1/meetings/${meetingId}/agenda`, meetingSchema, {
      method: "PUT",
      body: JSON.stringify(payload),
    }),
};
