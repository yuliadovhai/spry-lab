import { describe, expect, it } from "vitest";

import "@/lib/api"; // load api.ts first, as the app does
import { meetingFields, toMeeting } from "@/lib/firestore";

describe("firestore mapping", () => {
  it("turns a Firestore document into a Meeting", () => {
    const meeting = toMeeting({
      name: "projects/p/databases/(default)/documents/meetings/abc123",
      fields: {
        title: { stringValue: "Weekly sync" },
        starts_at: { timestampValue: "2026-11-16T10:00:00Z" },
        ends_at: { timestampValue: "2026-11-16T10:30:00Z" },
        attendee_count: { integerValue: "6" },
        created_at: { timestampValue: "2026-11-15T09:00:00Z" },
        agenda_json: {
          stringValue: JSON.stringify({
            items: [{ topic: "Numbers", owner: "Anna", minutes: 10 }],
            action_items: [],
          }),
        },
      },
    });
    expect(meeting.id).toBe("abc123");
    expect(meeting.attendee_count).toBe(6);
    expect(meeting.agenda?.items[0].topic).toBe("Numbers");
  });

  it("writes typed fields for a new meeting", () => {
    const fields = meetingFields({
      title: "Design crit",
      starts_at: "2026-11-18T11:00:00+02:00",
      ends_at: "2026-11-18T11:45:00+02:00",
      attendee_count: 5,
    });
    expect(fields.attendee_count).toEqual({ integerValue: "5" });
    expect(fields.starts_at).toEqual({
      timestampValue: "2026-11-18T09:00:00.000Z",
    });
  });
});
