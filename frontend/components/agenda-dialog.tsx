"use client";

import { useMutation, useQueryClient } from "@tanstack/react-query";
import { Loader2, Plus, Sparkles, Trash2 } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { api, type AgendaSave, type Meeting } from "@/lib/api";
import {
  ParseError,
  parseAgenda,
  parserUrl,
  type ParseResponse,
} from "@/lib/parser";
import { cn } from "@/lib/utils";

const MAX_TEXT = 10_000;

/* The form keeps every value as a string, the way inputs hand them back. */
type ItemRow = { topic: string; owner: string; minutes: string };
type ActionRow = { task: string; owner: string; due: string };

/** Rendered with key={meeting.id}, so each opening starts from fresh state. */
type Props = {
  meeting: Meeting | null;
  onOpenChange: (open: boolean) => void;
};

function toItemRows(meeting: Meeting | null): ItemRow[] {
  const items = meeting?.agenda?.items ?? [];
  if (items.length === 0) return [{ topic: "", owner: "", minutes: "" }];
  return items.map((item) => ({
    topic: item.topic,
    owner: item.owner ?? "",
    minutes: item.minutes ? String(item.minutes) : "",
  }));
}

function toActionRows(meeting: Meeting | null): ActionRow[] {
  return (meeting?.agenda?.action_items ?? []).map((a) => ({
    task: a.task,
    owner: a.owner ?? "",
    due: a.due ?? "",
  }));
}

export function AgendaDialog({ meeting, onOpenChange }: Props) {
  const queryClient = useQueryClient();
  const open = meeting !== null;

  const [text, setText] = useState("");
  const [parsing, setParsing] = useState(false);
  const [parseError, setParseError] = useState<string | null>(null);
  const [suggestion, setSuggestion] = useState<ParseResponse | null>(null);
  // Field keys the model filled and the person has not touched yet.
  const [suggested, setSuggested] = useState<Set<string>>(new Set());
  const [items, setItems] = useState<ItemRow[]>(() => toItemRows(meeting));
  const [actions, setActions] = useState<ActionRow[]>(() =>
    toActionRows(meeting),
  );
  const [formError, setFormError] = useState<string | null>(null);
  const abortRef = useRef<AbortController | null>(null);

  useEffect(() => () => abortRef.current?.abort(), []);

  async function onParse() {
    setParseError(null);
    const controller = new AbortController();
    abortRef.current = controller;
    setParsing(true);
    try {
      const result = await parseAgenda(text, controller.signal);
      const keys = new Set<string>();
      const newItems = result.agenda.items.map((item, i) => {
        if (item.topic) keys.add(`items.${i}.topic`);
        if (item.owner) keys.add(`items.${i}.owner`);
        if (item.minutes) keys.add(`items.${i}.minutes`);
        return {
          topic: item.topic,
          owner: item.owner ?? "",
          minutes: item.minutes ? String(item.minutes) : "",
        };
      });
      const newActions = result.agenda.action_items.map((a, i) => {
        if (a.task) keys.add(`actions.${i}.task`);
        if (a.owner) keys.add(`actions.${i}.owner`);
        if (a.due) keys.add(`actions.${i}.due`);
        return { task: a.task, owner: a.owner ?? "", due: a.due ?? "" };
      });
      setItems(
        newItems.length ? newItems : [{ topic: "", owner: "", minutes: "" }],
      );
      setActions(newActions);
      setSuggested(keys);
      setSuggestion(result);
    } catch (error) {
      if (error instanceof DOMException && error.name === "AbortError") return;
      setParseError(
        error instanceof ParseError
          ? error.message
          : "Something went wrong while parsing",
      );
    } finally {
      setParsing(false);
      abortRef.current = null;
    }
  }

  function onCancelParse() {
    abortRef.current?.abort();
    setParsing(false);
  }

  function touch(key: string) {
    if (!suggested.has(key)) return;
    const next = new Set(suggested);
    next.delete(key);
    setSuggested(next);
  }

  function updateItem(i: number, field: keyof ItemRow, value: string) {
    touch(`items.${i}.${field}`);
    setItems(
      items.map((row, j) => (j === i ? { ...row, [field]: value } : row)),
    );
  }

  function updateAction(i: number, field: keyof ActionRow, value: string) {
    touch(`actions.${i}.${field}`);
    setActions(
      actions.map((row, j) => (j === i ? { ...row, [field]: value } : row)),
    );
  }

  const mutation = useMutation({
    mutationFn: (payload: AgendaSave) => api.saveAgenda(meeting!.id, payload),
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ["meetings"] });
      toast.success("Agenda saved");
      onOpenChange(false);
    },
    onError: (error: Error) => toast.error(error.message),
  });

  function onSave() {
    setFormError(null);
    const cleanItems = items.filter((row) => row.topic.trim());
    if (cleanItems.length === 0) {
      setFormError("Add at least one agenda item");
      return;
    }
    for (const row of cleanItems) {
      if (row.minutes && !/^\d+$/.test(row.minutes)) {
        setFormError("Minutes must be a whole number");
        return;
      }
      const minutes = Number(row.minutes);
      if (row.minutes && (minutes < 1 || minutes > 480)) {
        setFormError("Minutes must be between 1 and 480");
        return;
      }
    }
    mutation.mutate({
      items: cleanItems.map((row) => ({
        topic: row.topic.trim(),
        owner: row.owner.trim() || null,
        minutes: row.minutes ? Number(row.minutes) : null,
      })),
      action_items: actions
        .filter((row) => row.task.trim())
        .map((row) => ({
          task: row.task.trim(),
          owner: row.owner.trim() || null,
          due: row.due || null,
        })),
      // Keep what the model said next to what the person saved.
      ai_suggestion: suggestion
        ? {
            agenda: suggestion.agenda,
            model: suggestion.model,
            prompt_version: suggestion.prompt_version,
          }
        : null,
    });
  }

  const hasParser = Boolean(parserUrl());

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[90vh] overflow-y-auto sm:max-w-2xl">
        <DialogHeader>
          <DialogTitle>Agenda · {meeting?.title}</DialogTitle>
          <DialogDescription>
            Paste an email, a chat message or notes and let the model suggest
            the agenda. You check it and save - or just type it below.
          </DialogDescription>
        </DialogHeader>

        <section className="grid gap-2 rounded-lg border bg-muted/40 p-3">
          <label htmlFor="paste" className="text-sm font-medium">
            Paste an agenda
          </label>
          <Textarea
            id="paste"
            rows={5}
            value={text}
            maxLength={MAX_TEXT}
            disabled={parsing}
            placeholder="Пн 10:00, синк по прайсингу, 45 хв. 1) нові тарифи Pro — Олена, 15 хв 2) ..."
            onChange={(e) => setText(e.target.value)}
          />
          <div className="flex flex-wrap items-center gap-2">
            {parsing ? (
              <>
                <Button type="button" disabled>
                  <Loader2
                    data-icon="inline-start"
                    className="size-4 animate-spin"
                  />
                  Reading the text...
                </Button>
                <Button type="button" variant="outline" onClick={onCancelParse}>
                  Cancel
                </Button>
                <span className="text-xs text-muted-foreground">
                  Usually 2-8 seconds
                </span>
              </>
            ) : (
              <Button
                type="button"
                onClick={onParse}
                disabled={!text.trim() || !hasParser}
              >
                <Sparkles data-icon="inline-start" className="size-4" />
                Parse
              </Button>
            )}
            <span className="ml-auto text-xs text-muted-foreground">
              {text.length.toLocaleString()} / {MAX_TEXT.toLocaleString()}
            </span>
          </div>
          {!hasParser && (
            <p className="text-xs text-muted-foreground">
              The parser is not configured here; type the agenda by hand.
            </p>
          )}
          {parseError && (
            <p role="alert" className="text-sm text-destructive">
              {parseError}. You can still type the agenda by hand.
            </p>
          )}
          {suggestion && (
            <p className="text-xs text-muted-foreground">
              Suggested by {suggestion.model} ({suggestion.prompt_version}).
              Check every field marked <SuggestedBadge /> before saving.
            </p>
          )}
        </section>

        <section className="grid gap-3">
          <h3 className="text-sm font-semibold">Items</h3>
          {items.map((row, i) => (
            <div
              key={i}
              className="grid gap-2 sm:grid-cols-[1fr_10rem_6rem_auto]"
            >
              <SuggestedInput
                aria-label={`Item ${i + 1} topic`}
                placeholder="Topic"
                value={row.topic}
                suggested={suggested.has(`items.${i}.topic`)}
                onChange={(v) => updateItem(i, "topic", v)}
              />
              <SuggestedInput
                aria-label={`Item ${i + 1} owner`}
                placeholder="Owner"
                value={row.owner}
                suggested={suggested.has(`items.${i}.owner`)}
                onChange={(v) => updateItem(i, "owner", v)}
              />
              <SuggestedInput
                aria-label={`Item ${i + 1} minutes`}
                placeholder="Min"
                inputMode="numeric"
                value={row.minutes}
                suggested={suggested.has(`items.${i}.minutes`)}
                onChange={(v) => updateItem(i, "minutes", v)}
              />
              <Button
                type="button"
                size="icon"
                variant="ghost"
                aria-label={`Remove item ${i + 1}`}
                disabled={items.length === 1}
                onClick={() => setItems(items.filter((_, j) => j !== i))}
              >
                <Trash2 className="size-4" />
              </Button>
            </div>
          ))}
          <Button
            type="button"
            variant="outline"
            size="sm"
            className="justify-self-start"
            onClick={() =>
              setItems([...items, { topic: "", owner: "", minutes: "" }])
            }
          >
            <Plus data-icon="inline-start" className="size-3.5" />
            Add item
          </Button>

          <h3 className="mt-2 text-sm font-semibold">Action items</h3>
          {actions.length === 0 && (
            <p className="text-xs text-muted-foreground">None yet.</p>
          )}
          {actions.map((row, i) => (
            <div
              key={i}
              className="grid gap-2 sm:grid-cols-[1fr_10rem_10rem_auto]"
            >
              <SuggestedInput
                aria-label={`Action ${i + 1} task`}
                placeholder="Task"
                value={row.task}
                suggested={suggested.has(`actions.${i}.task`)}
                onChange={(v) => updateAction(i, "task", v)}
              />
              <SuggestedInput
                aria-label={`Action ${i + 1} owner`}
                placeholder="Owner"
                value={row.owner}
                suggested={suggested.has(`actions.${i}.owner`)}
                onChange={(v) => updateAction(i, "owner", v)}
              />
              <SuggestedInput
                aria-label={`Action ${i + 1} due`}
                type="date"
                value={row.due}
                suggested={suggested.has(`actions.${i}.due`)}
                onChange={(v) => updateAction(i, "due", v)}
              />
              <Button
                type="button"
                size="icon"
                variant="ghost"
                aria-label={`Remove action ${i + 1}`}
                onClick={() => setActions(actions.filter((_, j) => j !== i))}
              >
                <Trash2 className="size-4" />
              </Button>
            </div>
          ))}
          <Button
            type="button"
            variant="outline"
            size="sm"
            className="justify-self-start"
            onClick={() =>
              setActions([...actions, { task: "", owner: "", due: "" }])
            }
          >
            <Plus data-icon="inline-start" className="size-3.5" />
            Add action item
          </Button>
        </section>

        {formError && (
          <p role="alert" className="text-sm text-destructive">
            {formError}
          </p>
        )}

        <DialogFooter>
          <Button
            type="button"
            variant="outline"
            onClick={() => onOpenChange(false)}
            disabled={mutation.isPending}
          >
            Close
          </Button>
          <Button
            type="button"
            onClick={onSave}
            disabled={mutation.isPending || parsing}
          >
            {mutation.isPending ? "Saving..." : "Save agenda"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function SuggestedBadge() {
  return (
    <Badge
      variant="secondary"
      className="bg-tint-blue px-1.5 py-0 text-[10px] text-tint-blue-foreground"
    >
      suggested
    </Badge>
  );
}

type SuggestedInputProps = Omit<
  React.ComponentProps<typeof Input>,
  "onChange"
> & {
  suggested: boolean;
  onChange: (value: string) => void;
};

function SuggestedInput({
  suggested,
  onChange,
  className,
  ...props
}: SuggestedInputProps) {
  return (
    <div className="relative">
      <Input
        {...props}
        className={cn(suggested && "border-primary/50 pr-20", className)}
        onChange={(e) => onChange(e.target.value)}
      />
      {suggested && (
        <span className="pointer-events-none absolute top-1/2 right-2 -translate-y-1/2">
          <SuggestedBadge />
        </span>
      )}
    </div>
  );
}
