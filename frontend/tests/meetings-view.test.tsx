import { screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import { MeetingsView } from "@/components/meetings-view";
import { ApiError, api } from "@/lib/api";

import { makeMeeting, renderWithQuery } from "./utils";

describe("MeetingsView", () => {
  it("lists the meetings from the API", async () => {
    vi.spyOn(api, "listMeetings").mockResolvedValue({
      meetings: [makeMeeting({ title: "Weekly leads" })],
      total: 1,
    });
    renderWithQuery(<MeetingsView />);
    expect(await screen.findByText("Weekly leads")).toBeInTheDocument();
  });

  it("shows an empty state with no meetings", async () => {
    vi.spyOn(api, "listMeetings").mockResolvedValue({ meetings: [], total: 0 });
    renderWithQuery(<MeetingsView />);
    expect(await screen.findByText("No meetings yet")).toBeInTheDocument();
  });

  it("shows an error with a retry button when the API fails", async () => {
    vi.spyOn(api, "listMeetings").mockRejectedValue(
      new ApiError(0, "Could not reach the API"),
    );
    renderWithQuery(<MeetingsView />);
    expect(
      await screen.findByText("Could not load meetings"),
    ).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Retry" })).toBeInTheDocument();
  });
});
