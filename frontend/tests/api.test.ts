import { afterEach, describe, expect, it, vi } from "vitest";

import { ApiError, api } from "@/lib/api";

import { makeMeeting } from "./utils";

function mockFetch(body: unknown, init: { status?: number } = {}) {
  const status = init.status ?? 200;
  return vi.spyOn(globalThis, "fetch").mockResolvedValue({
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
  } as Response);
}

afterEach(() => vi.restoreAllMocks());

describe("api", () => {
  it("parses a list response", async () => {
    mockFetch({ meetings: [makeMeeting()], total: 1 });
    const list = await api.listMeetings();
    expect(list.total).toBe(1);
    expect(list.meetings[0].title).toBe("Pricing sync");
  });

  it("passes pagination through as query parameters", async () => {
    const spy = mockFetch({ meetings: [], total: 0 });
    await api.listMeetings({ limit: 5, offset: 10 });
    expect(spy.mock.calls[0][0]).toContain(
      "/api/v1/meetings?limit=5&offset=10",
    );
  });

  it("posts a new meeting as JSON", async () => {
    const spy = mockFetch(makeMeeting(), { status: 201 });
    await api.createMeeting({
      title: "Pricing sync",
      starts_at: "2026-11-02T08:00:00.000Z",
      ends_at: "2026-11-02T08:45:00.000Z",
      attendee_count: 4,
    });
    const init = spy.mock.calls[0][1];
    expect(init?.method).toBe("POST");
    expect(JSON.parse(String(init?.body)).attendee_count).toBe(4);
  });

  it("turns a FastAPI validation error into one message", async () => {
    const msg = "Value error, ends_at must be later than starts_at";
    mockFetch({ detail: [{ msg }] }, { status: 422 });
    await expect(api.listMeetings()).rejects.toMatchObject({
      status: 422,
      message: msg,
    });
  });

  it("raises ApiError when the network is unreachable", async () => {
    vi.spyOn(globalThis, "fetch").mockImplementation(async () => {
      throw new TypeError("failed");
    });
    await expect(api.listMeetings()).rejects.toBeInstanceOf(ApiError);
  });
});
