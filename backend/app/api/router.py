from fastapi import APIRouter

from app.api.routes import health, meetings

# No authentication yet: sign-in arrives with Cognito in a later lab, and will
# be declared here once, as a router dependency, so no route can miss it.
api_router = APIRouter(prefix="/api/v1")
api_router.include_router(health.router)
api_router.include_router(meetings.router)
