import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, type RenderOptions } from "@testing-library/react";
import type { ReactElement, ReactNode } from "react";

import type { Meeting } from "@/lib/api";

/** Render with a fresh QueryClient so tests never share cache state. */
export function renderWithQuery(ui: ReactElement, options?: RenderOptions) {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
  });

  function Wrapper({ children }: { children: ReactNode }) {
    return (
      <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
    );
  }

  return render(ui, { wrapper: Wrapper, ...options });
}

export function makeMeeting(overrides: Partial<Meeting> = {}): Meeting {
  return {
    id: "11111111-1111-1111-1111-111111111111",
    title: "Pricing sync",
    starts_at: "2026-11-02T08:00:00Z",
    ends_at: "2026-11-02T08:45:00Z",
    attendee_count: 4,
    created_at: "2026-10-28T12:00:00Z",
    ...overrides,
  };
}
