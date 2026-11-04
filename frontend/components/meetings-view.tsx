"use client";

import { useQuery } from "@tanstack/react-query";
import { ListChecks, Plus } from "lucide-react";
import { useState } from "react";

import { AgendaDialog } from "@/components/agenda-dialog";
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

const weekdayFormat = new Intl.DateTimeFormat(undefined, { weekday: "short" });
const monthFormat = new Intl.DateTimeFormat(undefined, { month: "short" });
const timeFormat = new Intl.DateTimeFormat(undefined, {
  hour: "2-digit",
  minute: "2-digit",
});

export function MeetingsView() {
  const [dialogOpen, setDialogOpen] = useState(false);
  const [agendaFor, setAgendaFor] = useState<Meeting | null>(null);
  const query = useQuery({
    queryKey: ["meetings"],
    queryFn: () => api.listMeetings({ limit: 100 }),
  });

  return (
    <main className="mx-auto grid w-full max-w-5xl gap-8 px-6 py-10 sm:px-8">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div className="grid gap-2">
          <span className="w-fit rounded-full bg-tint-peach px-3 py-1 text-xs font-semibold text-tint-peach-foreground">
            Your week at a glance
          </span>
          <h1 className="font-heading text-4xl font-semibold">
            Insights this week
          </h1>
          <p className="text-sm text-muted-foreground">
            Where your week goes, compared with the last one.
          </p>
        </div>
        <Button
          className="rounded-full px-5 shadow-md shadow-primary/25"
          onClick={() => setDialogOpen(true)}
        >
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
            onAgenda={setAgendaFor}
          />
        </>
      )}

      <MeetingFormDialog open={dialogOpen} onOpenChange={setDialogOpen} />
      <AgendaDialog
        key={agendaFor?.id ?? "closed"}
        meeting={agendaFor}
        onOpenChange={(open) => {
          if (!open) setAgendaFor(null);
        }}
      />
    </main>
  );
}

/** Every metric here is better when it goes down: fewer, shorter, smaller. */
function InsightCards({ meetings }: { meetings: Meeting[] }) {
  const { current, previous } = weekOverWeek(meetings);

  return (
    <section aria-label="This week" className="grid gap-4 sm:grid-cols-3">
      <InsightCard
        tone="peach"
        label="Time in meetings"
        value={formatMinutes(current.minutes)}
        change={percentChange(current.minutes, previous.minutes)}
        higherIsBetter={false}
      />
      <InsightCard
        tone="yellow"
        label="Meetings"
        value={String(current.meetings)}
        change={percentChange(current.meetings, previous.meetings)}
        higherIsBetter={false}
      />
      <InsightCard
        tone="green"
        label="Average attendees"
        value={current.avgAttendees.toFixed(1)}
        change={percentChange(current.avgAttendees, previous.avgAttendees)}
        higherIsBetter={false}
      />
    </section>
  );
}

/* A small coloured dot tells the cards apart without icons. */
const toneClasses = {
  peach: "bg-primary",
  yellow: "bg-chart-2",
  green: "bg-chart-3",
} as const;

type InsightCardProps = {
  tone: keyof typeof toneClasses;
  label: string;
  value: string;
  change: number | null;
  higherIsBetter: boolean;
};

function InsightCard({
  tone,
  label,
  value,
  change,
  higherIsBetter,
}: InsightCardProps) {
  const delta = change ?? 0;
  const good = higherIsBetter ? delta > 0 : delta < 0;
  const bad = higherIsBetter ? delta < 0 : delta > 0;

  return (
    <div className="grid gap-3 rounded-3xl border bg-card/90 p-6 shadow-notion-sm transition-transform hover:-translate-y-0.5">
      <div className="flex items-center gap-2.5 text-sm font-medium text-muted-foreground">
        <span
          aria-hidden
          className={cn("size-2.5 rounded-full", toneClasses[tone])}
        />
        {label}
      </div>
      <div className="font-heading text-4xl font-semibold">{value}</div>
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
  onAgenda,
}: {
  meetings: Meeting[];
  onAdd: () => void;
  onAgenda: (meeting: Meeting) => void;
}) {
  if (meetings.length === 0) {
    return (
      <div className="grid place-items-center gap-3 rounded-2xl border-2 border-dashed bg-card/60 p-12 text-center">
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
      <h2 id="meetings-heading" className="font-heading text-2xl font-semibold">
        Meetings
      </h2>
      <ul className="divide-y overflow-hidden rounded-3xl border bg-card/90 shadow-notion-sm">
        {meetings.map((meeting) => {
          const start = new Date(meeting.starts_at);
          const startTime = timeFormat.format(start);
          const endTime = timeFormat.format(new Date(meeting.ends_at));
          return (
            <li
              key={meeting.id}
              className="flex flex-wrap items-center gap-x-6 gap-y-1 px-6 py-4 transition-colors hover:bg-muted/60"
            >
              <div className="grid w-12 place-items-center rounded-2xl bg-tint-peach py-1.5 text-tint-peach-foreground">
                <span className="text-[10px] font-bold tracking-wide uppercase">
                  {monthFormat.format(start)}
                </span>
                <span className="font-heading text-xl leading-none font-semibold">
                  {start.getDate()}
                </span>
              </div>
              <div className="w-12 text-sm text-muted-foreground">
                {weekdayFormat.format(start)}
              </div>
              <div className="w-28 text-sm tabular-nums">
                {startTime} – {endTime}
              </div>
              <div className="min-w-0 flex-1 truncate font-medium">
                {meeting.title}
              </div>
              <Badge variant="secondary" className="rounded-full">
                {formatMinutes(durationMinutes(meeting))}
              </Badge>
              <div className="flex items-center gap-1 text-sm text-muted-foreground">
                {meeting.attendee_count}{" "}
                {meeting.attendee_count === 1 ? "person" : "people"}
              </div>
              <Button
                size="sm"
                variant={meeting.agenda ? "ghost" : "outline"}
                onClick={() => onAgenda(meeting)}
              >
                <ListChecks data-icon="inline-start" className="size-3.5" />
                {meeting.agenda
                  ? `Agenda · ${meeting.agenda.items.length}`
                  : "Add agenda"}
              </Button>
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
        <Skeleton className="h-32 rounded-2xl" />
        <Skeleton className="h-32 rounded-2xl" />
        <Skeleton className="h-32 rounded-2xl" />
      </div>
      <Skeleton className="h-48 rounded-2xl" />
    </div>
  );
}
