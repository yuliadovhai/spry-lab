import type { Meeting } from "@/lib/api";

const MINUTE = 60_000;
const DAY = 24 * 60 * MINUTE;

export function durationMinutes(meeting: Meeting): number {
  const start = new Date(meeting.starts_at).getTime();
  const end = new Date(meeting.ends_at).getTime();
  return Math.max(0, Math.round((end - start) / MINUTE));
}

/** Monday 00:00 local time of the week that contains `date` (ISO weeks). */
export function startOfWeek(date: Date): Date {
  const monday = new Date(date);
  monday.setHours(0, 0, 0, 0);
  const daysSinceMonday = (monday.getDay() + 6) % 7;
  monday.setDate(monday.getDate() - daysSinceMonday);
  return monday;
}

export type WeekStats = {
  meetings: number;
  minutes: number;
  avgAttendees: number;
};

function statsFor(meetings: Meeting[], from: Date, to: Date): WeekStats {
  const inWeek = meetings.filter((meeting) => {
    const start = new Date(meeting.starts_at).getTime();
    return start >= from.getTime() && start < to.getTime();
  });
  const minutes = inWeek.reduce((sum, m) => sum + durationMinutes(m), 0);
  const attendees = inWeek.reduce((sum, m) => sum + m.attendee_count, 0);
  return {
    meetings: inWeek.length,
    minutes,
    avgAttendees: inWeek.length > 0 ? attendees / inWeek.length : 0,
  };
}

/** This week's numbers and last week's, for the week-over-week cards. */
export function weekOverWeek(
  meetings: Meeting[],
  now: Date = new Date(),
): { current: WeekStats; previous: WeekStats } {
  const thisMonday = startOfWeek(now);
  const nextMonday = new Date(thisMonday.getTime() + 7 * DAY);
  const lastMonday = new Date(thisMonday.getTime() - 7 * DAY);
  return {
    current: statsFor(meetings, thisMonday, nextMonday),
    previous: statsFor(meetings, lastMonday, thisMonday),
  };
}

/** "2h 15m", "45m", "3h". */
export function formatMinutes(total: number): string {
  const hours = Math.floor(total / 60);
  const minutes = Math.round(total % 60);
  if (hours === 0) return `${minutes}m`;
  if (minutes === 0) return `${hours}h`;
  return `${hours}h ${minutes}m`;
}

/** Change against last week as a signed percentage, or null when there is no base. */
export function percentChange(
  current: number,
  previous: number,
): number | null {
  if (previous === 0) return null;
  return Math.round(((current - previous) / previous) * 100);
}

/** The local date and time from a form, turned into ISO 8601 in UTC. */
export function localToIso(date: string, time: string): string {
  return new Date(`${date}T${time}`).toISOString();
}
