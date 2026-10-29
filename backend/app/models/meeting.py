import uuid
from datetime import datetime

from sqlalchemy import CheckConstraint, DateTime, Integer, String, func
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.dialects.postgresql import UUID as PGUUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base


class Meeting(Base):
    """One meeting on someone's calendar. The first slice of the Spry domain."""

    __tablename__ = "meetings"
    __table_args__ = (
        CheckConstraint("ends_at > starts_at", name="ck_meetings_ends_after_start"),
        CheckConstraint("attendee_count >= 1", name="ck_meetings_attendee_count"),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        PGUUID(as_uuid=True),
        primary_key=True,
        server_default=func.gen_random_uuid(),
    )
    title: Mapped[str] = mapped_column(String(200), nullable=False)
    starts_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, index=True)
    ends_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    attendee_count: Mapped[int] = mapped_column(Integer, nullable=False)
    # The saved agenda: {"items": [...], "action_items": [...]}. Null until saved.
    agenda: Mapped[dict | None] = mapped_column(JSONB, nullable=True)
    # What the LLM suggested before the person edited it, plus the model and
    # prompt version that produced it. The difference is the quality signal.
    ai_suggestion: Mapped[dict | None] = mapped_column(JSONB, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
