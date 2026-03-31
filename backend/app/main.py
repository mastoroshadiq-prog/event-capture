from fastapi import FastAPI

from app.api.routes_events import router as events_router
from app.api.routes_odoo import router as odoo_router


app = FastAPI(
    title="Vehicle Event Gateway",
    version="1.0.0",
    description=(
        "Gateway API untuk ingest scan penerimaan kendaraan dan membentuk payload "
        "CloudEvents v1.0 sebelum dipublish ke Azure Event Hub."
    ),
)

app.include_router(events_router)
app.include_router(odoo_router)


@app.get("/health", tags=["health"])
async def health_check() -> dict[str, str]:
    return {"status": "ok"}

