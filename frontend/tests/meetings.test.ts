import { describe, expect, it } from "vitest";

import {
  durationMinutes,
  formatMinutes,
  percentChange,
  startOfWeek,
  weekOverWeek,
} from "@/lib/meetings";

import { makeMeeting } from "./utils";

/** A meeting of `minutes` starting at 10:00 local time on the given date. */
function meetingOn(date: string, minutes = 60, attendees = 3) {
  const start = new Date(`${date}T10:00`);
  const end = new Date(start.getTime() + minutes * 60_000);
  return makeMeeting({
    starts_at: start.toISOString(),
    ends_at: end.toISOString(),
    attendee_count: attendees,
  });
}

describe("meeting maths", () => {
  it("measures a meeting in minutes", () => {
    expect(durationMinutes(meetingOn("2026-11-02", 45))).toBe(45);
  });

  it("starts the week on Monday", () => {
    // Wednesday 4 November 2026 belongs to the week of Monday 2 November.
    const monday = startOfWeek(new Date("2026-11-04T15:00"));
    expect(monday.getDay()).toBe(1);
    expect(monday.getDate()).toBe(2);
    // Sunday 8 November still belongs to that week.
    expect(startOfWeek(new Date("2026-11-08T20:00")).getDate()).toBe(2);
  });

  it("compares this week with the last one", () => {
    const meetings = [
      meetingOn("2026-10-27", 60), // last week
      meetingOn("2026-11-02", 30), // this week
      meetingOn("2026-11-04", 90), // this week
      meetingOn("2026-11-10", 60), // next week, ignored
    ];
    const { current, previous } = weekOverWeek(
      meetings,
      new Date("2026-11-05T12:00"),
    );
    expect(current).toMatchObject({ meetings: 2, minutes: 120 });
    expect(previous).toMatchObject({ meetings: 1, minutes: 60 });
    expect(percentChange(current.minutes, previous.minutes)).toBe(100);
  });

  it("has no change to report without last week's data", () => {
    expect(percentChange(5, 0)).toBeNull();
  });

  it("formats minutes as hours and minutes", () => {
    expect(formatMinutes(45)).toBe("45m");
    expect(formatMinutes(120)).toBe("2h");
    expect(formatMinutes(135)).toBe("2h 15m");
  });
});
