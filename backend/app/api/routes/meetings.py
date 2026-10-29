import uuid
from typing import Annotated

from fastapi import APIRouter, HTTPException, Query, status

from app.db import SessionDep
from app.schemas import AgendaSave, MeetingCreate, MeetingList, MeetingRead
from app.services import meetings as meetings_service

router = APIRouter(prefix="/meetings", tags=["meetings"])


@router.get("", response_model=MeetingList, summary="List meetings, earliest first")
async def list_meetings(
    session: SessionDep,
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
    offset: Annotated[int, Query(ge=0)] = 0,
) -> MeetingList:
    meetings, total = await meetings_service.list_meetings(session, limit=limit, offset=offset)
    return MeetingList(meetings=[MeetingRead.model_validate(m) for m in meetings], total=total)


@router.post(
    "",
    response_model=MeetingRead,
    status_code=status.HTTP_201_CREATED,
    summary="Create a meeting",
)
async def create_meeting(payload: MeetingCreate, session: SessionDep) -> MeetingRead:
    meeting = await meetings_service.create_meeting(session, payload)
    return MeetingRead.model_validate(meeting)


@router.put(
    "/{meeting_id}/agenda",
    response_model=MeetingRead,
    summary="Save the meeting's agenda (typed by hand or confirmed from a suggestion)",
)
async def save_agenda(
    meeting_id: uuid.UUID, payload: AgendaSave, session: SessionDep
) -> MeetingRead:
    meeting = await meetings_service.get_meeting(session, meeting_id)
    if meeting is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Meeting not found")
    meeting = await meetings_service.save_agenda(session, meeting, payload)
    return MeetingRead.model_validate(meeting)
