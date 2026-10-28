"use client";

import { zodResolver } from "@hookform/resolvers/zod";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useEffect } from "react";
import { useForm } from "react-hook-form";
import { toast } from "sonner";
import { z } from "zod";

import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Field, FieldError, FieldLabel } from "@/components/ui/field";
import { Input } from "@/components/ui/input";
import { api } from "@/lib/api";
import { localToIso } from "@/lib/meetings";

const formSchema = z
  .object({
    title: z
      .string()
      .trim()
      .min(1, "Title is required")
      .max(200, "Title is too long"),
    date: z.string().min(1, "Pick a date"),
    start: z.string().min(1, "Pick a start time"),
    end: z.string().min(1, "Pick an end time"),
    // Kept as the input's string; converted when the request is built.
    attendees: z
      .string()
      .regex(/^\d+$/, "Whole people only")
      .refine((value) => Number(value) >= 1, "At least one attendee")
      .refine((value) => Number(value) <= 1000, "At most 1000 attendees"),
  })
  .refine((values) => values.end > values.start, {
    path: ["end"],
    message: "The meeting must end after it starts",
  });

type FormValues = z.infer<typeof formSchema>;

function today(): string {
  const now = new Date();
  const offset = now.getTimezoneOffset() * 60_000;
  return new Date(now.getTime() - offset).toISOString().slice(0, 10);
}

const emptyForm = (): FormValues => ({
  title: "",
  date: today(),
  start: "10:00",
  end: "10:30",
  attendees: "2",
});

type Props = {
  open: boolean;
  onOpenChange: (open: boolean) => void;
};

export function MeetingFormDialog({ open, onOpenChange }: Props) {
  const queryClient = useQueryClient();

  const form = useForm<FormValues>({
    resolver: zodResolver(formSchema),
    defaultValues: emptyForm(),
  });

  useEffect(() => {
    if (open) form.reset(emptyForm());
  }, [open, form]);

  const mutation = useMutation({
    mutationFn: (values: FormValues) =>
      api.createMeeting({
        title: values.title,
        starts_at: localToIso(values.date, values.start),
        ends_at: localToIso(values.date, values.end),
        attendee_count: Number(values.attendees),
      }),
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ["meetings"] });
      toast.success("Meeting added");
      onOpenChange(false);
    },
    onError: (error: Error) => toast.error(error.message),
  });

  const { errors } = form.formState;

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>Add meeting</DialogTitle>
          <DialogDescription>
            Times are in your local time zone.
          </DialogDescription>
        </DialogHeader>

        <form
          className="grid gap-4"
          onSubmit={form.handleSubmit((values) => mutation.mutate(values))}
        >
          <Field data-invalid={Boolean(errors.title)}>
            <FieldLabel htmlFor="title">Title</FieldLabel>
            <Input
              id="title"
              autoComplete="off"
              placeholder="Pricing sync"
              {...form.register("title")}
            />
            {errors.title && <FieldError errors={[errors.title]} />}
          </Field>

          <Field data-invalid={Boolean(errors.date)}>
            <FieldLabel htmlFor="date">Date</FieldLabel>
            <Input id="date" type="date" {...form.register("date")} />
            {errors.date && <FieldError errors={[errors.date]} />}
          </Field>

          <div className="grid grid-cols-2 gap-4">
            <Field data-invalid={Boolean(errors.start)}>
              <FieldLabel htmlFor="start">Starts</FieldLabel>
              <Input id="start" type="time" {...form.register("start")} />
              {errors.start && <FieldError errors={[errors.start]} />}
            </Field>
            <Field data-invalid={Boolean(errors.end)}>
              <FieldLabel htmlFor="end">Ends</FieldLabel>
              <Input id="end" type="time" {...form.register("end")} />
              {errors.end && <FieldError errors={[errors.end]} />}
            </Field>
          </div>

          <Field data-invalid={Boolean(errors.attendees)}>
            <FieldLabel htmlFor="attendees">Attendees</FieldLabel>
            <Input
              id="attendees"
              type="number"
              min={1}
              inputMode="numeric"
              {...form.register("attendees")}
            />
            {errors.attendees && <FieldError errors={[errors.attendees]} />}
          </Field>

          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              onClick={() => onOpenChange(false)}
              disabled={mutation.isPending}
            >
              Cancel
            </Button>
            <Button type="submit" disabled={mutation.isPending}>
              {mutation.isPending ? "Saving..." : "Add meeting"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
