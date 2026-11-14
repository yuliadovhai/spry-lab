/**
 * Lab 9: the same three calls as lib/api.ts, but against Cloud Firestore on
 * Google Cloud instead of the FastAPI API on AWS. It uses Firestore's REST API
 * with plain fetch, so no Firebase SDK is added to the bundle.
 *
 * Who may read and write is decided by firestore.rules (deployed with the
 * site): anyone may read and add meetings - the same as the AWS API today,
 * which has no sign-in yet - and only the agenda of an existing meeting may be
 * changed.
 *
 * The agenda is stored as one JSON string (agenda_json): Firestore's typed
 * map/array encoding for nested lists adds a lot of code for no gain here.
 */
import {
  type AgendaSave,
  ApiError,
  type MeetingCreate,
  type MeetingList,
  agendaSchema,
  meetingListSchema,
  meetingSchema,
} from "@/lib/api";

type FirestoreValue =
  | { stringValue: string }
  | { integerValue: string }
  | { timestampValue: string }
  | { nullValue: null };

type FirestoreDocument = {
  name: string;
  fields?: Record<string, FirestoreValue>;
  createTime?: string;
};

function baseUrl(): string {
  const project = process.env.NEXT_PUBLIC_FIREBASE_PROJECT_ID;
  if (!project)
    throw new ApiError(0, "NEXT_PUBLIC_FIREBASE_PROJECT_ID is not set");
  return `https://firestore.googleapis.com/v1/projects/${project}/databases/(default)/documents`;
}

async function call(url: string, init?: RequestInit): Promise<unknown> {
  let response: Response;
  try {
    response = await fetch(url, {
      ...init,
      cache: "no-store",
      headers: { "Content-Type": "application/json", ...(init?.headers ?? {}) },
    });
  } catch {
    throw new ApiError(0, "Could not reach Firestore");
  }
  const body: unknown = await response.json().catch(() => null);
  if (!response.ok) {
    const message = (body as { error?: { message?: string } } | null)?.error
      ?.message;
    throw new ApiError(
      response.status,
      message ?? `Firestore request failed (${response.status})`,
    );
  }
  return body;
}

function read(
  fields: Record<string, FirestoreValue>,
  key: string,
): string | null {
  const value = fields[key];
  if (!value || "nullValue" in value) return null;
  if ("stringValue" in value) return value.stringValue;
  if ("integerValue" in value) return value.integerValue;
  return value.timestampValue;
}

/** One Firestore document -> the Meeting shape the UI already understands. */
export function toMeeting(doc: FirestoreDocument) {
  const fields = doc.fields ?? {};
  const agendaJson = read(fields, "agenda_json");
  return meetingSchema.parse({
    id: doc.name.split("/").pop(),
    title: read(fields, "title") ?? "",
    starts_at: read(fields, "starts_at") ?? "",
    ends_at: read(fields, "ends_at") ?? "",
    attendee_count: Number(read(fields, "attendee_count") ?? 0),
    created_at: read(fields, "created_at") ?? doc.createTime ?? "",
    agenda: agendaJson ? agendaSchema.parse(JSON.parse(agendaJson)) : null,
  });
}

export function meetingFields(
  payload: MeetingCreate,
): Record<string, FirestoreValue> {
  return {
    title: { stringValue: payload.title },
    starts_at: { timestampValue: new Date(payload.starts_at).toISOString() },
    ends_at: { timestampValue: new Date(payload.ends_at).toISOString() },
    attendee_count: { integerValue: String(payload.attendee_count) },
    created_at: { timestampValue: new Date().toISOString() },
  };
}

export const firestoreApi = {
  readiness: async () => ({ status: "ok", database: "firestore" }),

  listMeetings: async (
    params: { limit?: number; offset?: number } = {},
  ): Promise<MeetingList> => {
    const body = (await call(`${baseUrl()}/meetings?pageSize=300`)) as {
      documents?: FirestoreDocument[];
    };
    // Newest first, like the API's ORDER BY starts_at DESC.
    const all = (body.documents ?? [])
      .map(toMeeting)
      .sort((a, b) => b.starts_at.localeCompare(a.starts_at));
    const offset = params.offset ?? 0;
    const page = all.slice(offset, offset + (params.limit ?? all.length));
    return meetingListSchema.parse({ meetings: page, total: all.length });
  },

  createMeeting: async (payload: MeetingCreate) => {
    const doc = (await call(`${baseUrl()}/meetings`, {
      method: "POST",
      body: JSON.stringify({ fields: meetingFields(payload) }),
    })) as FirestoreDocument;
    return toMeeting(doc);
  },

  saveAgenda: async (meetingId: string, payload: AgendaSave) => {
    const agenda = { items: payload.items, action_items: payload.action_items };
    const doc = (await call(
      `${baseUrl()}/meetings/${encodeURIComponent(meetingId)}?updateMask.fieldPaths=agenda_json`,
      {
        method: "PATCH",
        body: JSON.stringify({
          fields: { agenda_json: { stringValue: JSON.stringify(agenda) } },
        }),
      },
    )) as FirestoreDocument;
    return toMeeting(doc);
  },
};
