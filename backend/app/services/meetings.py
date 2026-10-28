from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Meeting
from app.schemas import MeetingCreate


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
