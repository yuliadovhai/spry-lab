"use client";

import { useQuery } from "@tanstack/react-query";
import { CalendarDays, Clock, Plus, Users } from "lucide-react";
import { useState } from "react";

import { MeetingFormDialog } from "@/components/meeting-form-dialog";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { api, type Meeting } from "@/lib/api";
import {
  durationMinutes,
  formatMinutes,
  percentChange,
  weekOverWeek,
} from "@/lib/meetings";
import { cn } from "@/lib/utils";

const dayFormat = new Intl.DateTimeFormat(undefined, {
  weekday: "short",
  day: "numeric",
  month: "short",
});
const timeFormat = new Intl.DateTimeFormat(undefined, {
  hour: "2-digit",
  minute: "2-digit",
});

export function MeetingsView() {
  const [dialogOpen, setDialogOpen] = useState(false);
  const query = useQuery({
    queryKey: ["meetings"],
    queryFn: () => api.listMeetings({ limit: 100 }),
  });

  return (
    <main className="mx-auto grid w-full max-w-5xl gap-8 px-6 py-10 sm:px-8">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div className="grid gap-1">
          <h1 className="font-heading text-3xl font-bold tracking-tight">
            Insights this week
          </h1>
          <p className="text-sm text-muted-foreground">
            Where your week goes, compared with the last one.
          </p>
        </div>
        <Button onClick={() => setDialogOpen(true)}>
          <Plus data-icon="inline-start" className="size-4" />
          Add meeting
        </Button>
      </div>

      {query.isPending && <LoadingState />}

      {query.isError && (
        <Alert variant="destructive">
          <AlertTitle>Could not load meetings</AlertTitle>
          <AlertDescription className="flex items-center gap-3">
            {query.error.message}
            <Button size="sm" variant="outline" onClick={() => query.refetch()}>
              Retry
            </Button>
          </AlertDescription>
        </Alert>
      )}

      {query.isSuccess && (
        <>
          <InsightCards meetings={query.data.meetings} />
          <MeetingList
            meetings={query.data.meetings}
            onAdd={() => setDialogOpen(true)}
          />
        </>
      )}

      <MeetingFormDialog open={dialogOpen} onOpenChange={setDialogOpen} />
    </main>
  );
}

/** Every metric here is better when it goes down: fewer, shorter, smaller. */
function InsightCards({ meetings }: { meetings: Meeting[] }) {
  const { current, previous } = weekOverWeek(meetings);

  return (
    <section aria-label="This week" className="grid gap-4 sm:grid-cols-3">
      <InsightCard
        icon={<Clock className="size-4" />}
        label="Time in meetings"
        value={formatMinutes(current.minutes)}
        change={percentChange(current.minutes, previous.minutes)}
        higherIsBetter={false}
      />
      <InsightCard
        icon={<CalendarDays className="size-4" />}
        label="Meetings"
        value={String(current.meetings)}
        change={percentChange(current.meetings, previous.meetings)}
        higherIsBetter={false}
      />
      <InsightCard
        icon={<Users className="size-4" />}
        label="Average attendees"
        value={current.avgAttendees.toFixed(1)}
        change={percentChange(current.avgAttendees, previous.avgAttendees)}
        higherIsBetter={false}
      />
    </section>
  );
}

type InsightCardProps = {
  icon: React.ReactNode;
  label: string;
  value: string;
  change: number | null;
  higherIsBetter: boolean;
};

function InsightCard({
  icon,
  label,
  value,
  change,
  higherIsBetter,
}: InsightCardProps) {
  const delta = change ?? 0;
  const good = higherIsBetter ? delta > 0 : delta < 0;
  const bad = higherIsBetter ? delta < 0 : delta > 0;

  return (
    <div className="grid gap-3 rounded-xl border bg-card p-5 shadow-notion-xs">
      <div className="flex items-center gap-2 text-sm text-muted-foreground">
        {icon}
        {label}
      </div>
      <div className="text-3xl font-semibold tracking-tight">{value}</div>
      <div
        className={cn(
          "text-xs font-medium",
          good && "text-tint-green-foreground",
          bad && "text-tint-peach-foreground",
          !good && !bad && "text-muted-foreground",
        )}
      >
        {change === null
          ? "No data for last week"
          : `${change > 0 ? "+" : ""}${change}% vs last week`}
      </div>
    </div>
  );
}

function MeetingList({
  meetings,
  onAdd,
}: {
  meetings: Meeting[];
  onAdd: () => void;
}) {
  if (meetings.length === 0) {
    return (
      <div className="grid place-items-center gap-3 rounded-xl border border-dashed p-12 text-center">
        <p className="font-medium">No meetings yet</p>
        <p className="text-sm text-muted-foreground">
          Add the first one to see your week take shape.
        </p>
        <Button variant="outline" onClick={onAdd}>
          <Plus data-icon="inline-start" className="size-4" />
          Add meeting
        </Button>
      </div>
    );
  }

  return (
    <section aria-labelledby="meetings-heading" className="grid gap-3">
      <h2 id="meetings-heading" className="text-lg font-semibold">
        Meetings
      </h2>
      <ul className="divide-y rounded-xl border bg-card">
        {meetings.map((meeting) => {
          const start = new Date(meeting.starts_at);
          const startTime = timeFormat.format(start);
          const endTime = timeFormat.format(new Date(meeting.ends_at));
          return (
            <li
              key={meeting.id}
              className="flex flex-wrap items-center gap-x-6 gap-y-1 px-5 py-3"
            >
              <div className="w-28 text-sm text-muted-foreground">
                {dayFormat.format(start)}
              </div>
              <div className="w-28 text-sm tabular-nums">
                {startTime} – {endTime}
              </div>
              <div className="min-w-0 flex-1 truncate font-medium">
                {meeting.title}
              </div>
              <Badge variant="secondary">
                {formatMinutes(durationMinutes(meeting))}
              </Badge>
              <div className="flex items-center gap-1 text-sm text-muted-foreground">
                <Users aria-hidden className="size-3.5" />
                {meeting.attendee_count}
              </div>
            </li>
          );
        })}
      </ul>
    </section>
  );
}

function LoadingState() {
  return (
    <div className="grid gap-4">
      <div className="grid gap-4 sm:grid-cols-3">
        <Skeleton className="h-28 rounded-xl" />
        <Skeleton className="h-28 rounded-xl" />
        <Skeleton className="h-28 rounded-xl" />
      </div>
      <Skeleton className="h-48 rounded-xl" />
    </div>
  );
}
