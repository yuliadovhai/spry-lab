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
