import uuid
from datetime import datetime

from httpx import AsyncClient

MEETING = {
    "title": "Pricing sync",
    "starts_at": "2026-11-02T10:00:00+02:00",
    "ends_at": "2026-11-02T10:45:00+02:00",
    "attendee_count": 4,
}


def on_day(day: int, title: str = "Sync") -> dict:
    """A one-hour meeting at 09:00 UTC on the given day of November 2026."""
    return {
        **MEETING,
        "title": title,
        "starts_at": f"2026-11-{day:02d}T09:00:00Z",
        "ends_at": f"2026-11-{day:02d}T10:00:00Z",
    }


async def test_list_is_empty_initially(client: AsyncClient) -> None:
    response = await client.get("/api/v1/meetings")
    assert response.status_code == 200
    assert response.json() == {"meetings": [], "total": 0}


async def test_create_returns_201_and_the_meeting(client: AsyncClient) -> None:
    response = await client.post("/api/v1/meetings", json=MEETING)
    assert response.status_code == 201
    body = response.json()
    assert uuid.UUID(body["id"])
    assert body["title"] == "Pricing sync"
    assert body["attendee_count"] == 4
    assert body["created_at"]


async def test_times_keep_the_same_instant(client: AsyncClient) -> None:
    body = (await client.post("/api/v1/meetings", json=MEETING)).json()
    # Postgres stores an instant; the offset it comes back with may differ,
    # but 10:00+02:00 and 08:00Z are the same moment.
    assert datetime.fromisoformat(body["starts_at"]) == datetime.fromisoformat(
        "2026-11-02T08:00:00+00:00"
    )


async def test_created_meeting_appears_in_the_list(client: AsyncClient) -> None:
    await client.post("/api/v1/meetings", json=MEETING)
    body = (await client.get("/api/v1/meetings")).json()
    assert body["total"] == 1
    assert body["meetings"][0]["title"] == "Pricing sync"


async def test_list_is_ordered_by_start_time(client: AsyncClient) -> None:
    await client.post("/api/v1/meetings", json=on_day(3, "Later"))
    await client.post("/api/v1/meetings", json=on_day(1, "Earlier"))
    body = (await client.get("/api/v1/meetings")).json()
    assert [m["title"] for m in body["meetings"]] == ["Earlier", "Later"]


async def test_rejects_end_before_start(client: AsyncClient) -> None:
    bad = {**MEETING, "ends_at": "2026-11-02T09:00:00+02:00"}
    assert (await client.post("/api/v1/meetings", json=bad)).status_code == 422


async def test_rejects_time_without_offset(client: AsyncClient) -> None:
    bad = {**MEETING, "starts_at": "2026-11-02T10:00:00"}
    assert (await client.post("/api/v1/meetings", json=bad)).status_code == 422


async def test_rejects_empty_title(client: AsyncClient) -> None:
    bad = {**MEETING, "title": ""}
    assert (await client.post("/api/v1/meetings", json=bad)).status_code == 422


async def test_rejects_zero_attendees(client: AsyncClient) -> None:
    bad = {**MEETING, "attendee_count": 0}
    assert (await client.post("/api/v1/meetings", json=bad)).status_code == 422


async def test_pagination(client: AsyncClient) -> None:
    for day in range(1, 4):
        await client.post("/api/v1/meetings", json=on_day(day))
    body = (await client.get("/api/v1/meetings", params={"limit": 2})).json()
    assert body["total"] == 3
    assert len(body["meetings"]) == 2


async def test_pagination_rejects_bad_limit(client: AsyncClient) -> None:
    assert (await client.get("/api/v1/meetings", params={"limit": 0})).status_code == 422
    assert (await client.get("/api/v1/meetings", params={"limit": 101})).status_code == 422


AGENDA = {
    "items": [
        {"topic": "New Pro pricing", "owner": "Олена", "minutes": 15},
        {"topic": "Customer feedback", "owner": "Taras", "minutes": None},
    ],
    "action_items": [{"task": "Competitor comparison", "owner": "Taras", "due": "2026-11-06"}],
}


async def test_new_meeting_has_no_agenda(client: AsyncClient) -> None:
    body = (await client.post("/api/v1/meetings", json=MEETING)).json()
    assert body["agenda"] is None


async def test_save_agenda_with_ai_suggestion(client: AsyncClient) -> None:
    meeting = (await client.post("/api/v1/meetings", json=MEETING)).json()
    payload = {
        **AGENDA,
        "ai_suggestion": {
            "agenda": {"items": [{"topic": "New Pro tariffs"}]},
            "model": "anthropic.claude-opus-5-5",
            "prompt_version": "agenda-v1",
        },
    }
    response = await client.put(f"/api/v1/meetings/{meeting['id']}/agenda", json=payload)
    assert response.status_code == 200
    assert response.json()["agenda"]["items"][0]["owner"] == "Олена"
    listed = (await client.get("/api/v1/meetings")).json()["meetings"][0]
    assert listed["agenda"]["action_items"][0]["due"] == "2026-11-06"


async def test_save_agenda_by_hand(client: AsyncClient) -> None:
    meeting = (await client.post("/api/v1/meetings", json=MEETING)).json()
    response = await client.put(f"/api/v1/meetings/{meeting['id']}/agenda", json=AGENDA)
    assert response.status_code == 200


async def test_agenda_needs_at_least_one_item(client: AsyncClient) -> None:
    meeting = (await client.post("/api/v1/meetings", json=MEETING)).json()
    url = f"/api/v1/meetings/{meeting['id']}/agenda"
    assert (await client.put(url, json={"items": []})).status_code == 422


async def test_agenda_for_missing_meeting_is_404(client: AsyncClient) -> None:
    url = f"/api/v1/meetings/{uuid.uuid4()}/agenda"
    assert (await client.put(url, json=AGENDA)).status_code == 404
