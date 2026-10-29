import uuid
from datetime import date
from typing import Any, Self

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field, model_validator


class MeetingCreate(BaseModel):
    title: str = Field(min_length=1, max_length=200)
    # AwareDatetime rejects "2026-10-28T10:00:00" without an offset: a meeting
    # time without a time zone is ambiguous, so the client must say which one.
    starts_at: AwareDatetime
    ends_at: AwareDatetime
    attendee_count: int = Field(ge=1, le=1000)

    @model_validator(mode="after")
    def _ends_after_start(self) -> Self:
        if self.ends_at <= self.starts_at:
            raise ValueError("ends_at must be later than starts_at")
        return self


class AgendaItem(BaseModel):
    topic: str = Field(min_length=1, max_length=300)
    owner: str | None = Field(default=None, max_length=200)
    minutes: int | None = Field(default=None, ge=1, le=480)


class ActionItem(BaseModel):
    task: str = Field(min_length=1, max_length=500)
    owner: str | None = Field(default=None, max_length=200)
    due: date | None = None


class Agenda(BaseModel):
    items: list[AgendaItem] = Field(min_length=1, max_length=50)
    action_items: list[ActionItem] = Field(default_factory=list, max_length=50)


class AiSuggestion(BaseModel):
    """What the parser returned, kept next to what the person saved."""

    agenda: dict[str, Any]
    model: str = Field(max_length=200)
    prompt_version: str = Field(max_length=50)


class AgendaSave(Agenda):
    ai_suggestion: AiSuggestion | None = None


class MeetingRead(MeetingCreate):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    created_at: AwareDatetime
    agenda: Agenda | None = None


class MeetingList(BaseModel):
    meetings: list[MeetingRead]
    total: int
