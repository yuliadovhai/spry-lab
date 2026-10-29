import uuid

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Meeting
from app.schemas import AgendaSave, MeetingCreate


async def list_meetings(
    session: AsyncSession, *, limit: int, offset: int
) -> tuple[list[Meeting], int]:
    total = await session.scalar(select(func.count()).select_from(Meeting)) or 0
    result = await session.execute(
        select(Meeting).order_by(Meeting.starts_at, Meeting.id).limit(limit).offset(offset)
    )
    return list(result.scalars()), total


async def create_meeting(session: AsyncSession, payload: MeetingCreate) -> Meeting:
    meeting = Meeting(**payload.model_dump())
    session.add(meeting)
    await session.flush()
    await session.refresh(meeting)
    return meeting


async def get_meeting(session: AsyncSession, meeting_id: uuid.UUID) -> Meeting | None:
    return await session.get(Meeting, meeting_id)


async def save_agenda(session: AsyncSession, meeting: Meeting, payload: AgendaSave) -> Meeting:
    data = payload.model_dump(mode="json")
    meeting.ai_suggestion = data.pop("ai_suggestion")
    meeting.agenda = data
    await session.flush()
    await session.refresh(meeting)
    return meeting
