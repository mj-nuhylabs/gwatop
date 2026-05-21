from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, Field


class DeviceRegisterRequest(BaseModel):
    apns_token: str = Field(min_length=8, max_length=512)
    platform: Literal["ios", "android"] = "ios"


class DeviceResponse(BaseModel):
    id: UUID
    apns_token: str
    platform: str
    last_seen_at: datetime
    created_at: datetime

    model_config = {"from_attributes": True}
