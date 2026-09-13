"""Meridian catalog API.

A small HTTP service over a PostgreSQL-backed item catalogue. The domain is
intentionally narrow; what this service is built to demonstrate is operability --
separate liveness and readiness signals, RED metrics on every request, a build
identifier the deployment pipeline can assert on, and structured logs that
downstream tooling can query as fields rather than as text.
"""

import logging
import time
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, HTTPException, Response
from fastapi.responses import JSONResponse
from prometheus_fastapi_instrumentator import Instrumentator, metrics
from sqlalchemy import select
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

import db
from logconf import configure_logging
from models import Base, Item
from schemas import ItemIn, ItemOut
from settings import settings

log = logging.getLogger(__name__)

SCHEMA_INIT_ATTEMPTS = 5
SCHEMA_INIT_BACKOFF_SECONDS = 2


def _init_schema() -> None:
    """Create tables, retrying while the database finishes coming up.

    Note: create_all is adequate while the schema is owned solely by this
    service. Schema changes that need to be reviewed, ordered or reverted belong
    in Alembic, run as a one-off ECS task ahead of the service update. Tracked in
    docs/adr/0006-schema-management.md.
    """
    for attempt in range(1, SCHEMA_INIT_ATTEMPTS + 1):
        try:
            Base.metadata.create_all(bind=db.engine)
            return
        except SQLAlchemyError:
            if attempt == SCHEMA_INIT_ATTEMPTS:
                raise
            log.warning(
                "database not ready, retrying schema init",
                extra={"attempt": attempt, "max_attempts": SCHEMA_INIT_ATTEMPTS},
            )
            time.sleep(SCHEMA_INIT_BACKOFF_SECONDS)


@asynccontextmanager
async def lifespan(_: FastAPI):
    configure_logging(settings.service_name, settings.app_env, settings.log_level)
    _init_schema()
    log.info(
        "service started",
        extra={"version": settings.app_version, "env": settings.app_env},
    )
    yield
    db.engine.dispose()
    log.info("service stopped")


app = FastAPI(
    title="Meridian Catalog API",
    version=settings.app_version,
    lifespan=lifespan,
)

# Exposes http_requests_total and http_request_duration_seconds -- the rate,
# errors and duration that both Grafana dashboards are built on.
_instrumentator = Instrumentator(
    # Keep the exact status code. Grouping to "2xx"/"5xx" makes it impossible to
    # tell a 502 from a 503 on the dashboard, which is the first thing you want
    # to know during an incident.
    should_group_status_codes=False,
    # Without this, every unmatched path becomes its own label value and the
    # metric cardinality explodes the first time someone scans the service.
    should_ignore_untemplated=True,
    should_instrument_requests_inprogress=True,
    inprogress_labels=True,
    excluded_handlers=["/metrics", "/health"],
)
_instrumentator.add(
    metrics.default(
        # The library default for the per-handler histogram is (0.1, 0.5, 1),
        # which cannot express any p99 above one second -- histogram_quantile
        # would just return +Inf. These buckets span 10ms to 10s.
        latency_lowr_buckets=(
            0.01,
            0.025,
            0.05,
            0.1,
            0.25,
            0.5,
            0.75,
            1,
            2.5,
            5,
            10,
        ),
    )
)
_instrumentator.instrument(app).expose(app, include_in_schema=False)


@app.exception_handler(SQLAlchemyError)
async def database_error_handler(_, exc: SQLAlchemyError) -> JSONResponse:
    """Turn a database outage into an honest 503 instead of a bare 500.

    A 500 tells the caller "this request is broken, do not retry"; a 503 tells
    the caller and the load balancer "the dependency is down, retry later".
    The distinction matters to clients and to the error-rate alert.
    """
    log.error("database error", extra={"error": str(exc)}, exc_info=exc)
    return JSONResponse(status_code=503, content={"detail": "database unavailable"})


@app.get("/health", tags=["ops"])
def health() -> dict:
    """Liveness. Intentionally does NOT touch the database.

    This is what the ALB target group checks. If it checked the DB, a brief RDS
    failover would fail every target at once and take the whole service out of
    the load balancer for no reason.
    """
    return {"status": "ok", "version": settings.app_version, "env": settings.app_env}


@app.get("/readyz", tags=["ops"])
def readyz(response: Response) -> dict:
    """Readiness. Reports DB reachability; used by humans and by alerting."""
    try:
        db.ping()
    except SQLAlchemyError as exc:
        log.error("readiness check failed", extra={"error": str(exc)})
        response.status_code = 503
        return {"status": "degraded", "database": "unreachable"}
    return {"status": "ok", "database": "reachable"}


@app.post("/items", response_model=ItemOut, status_code=201, tags=["items"])
def create_item(payload: ItemIn, session: Session = Depends(db.get_session)) -> Item:
    item = Item(name=payload.name, description=payload.description)
    session.add(item)
    session.commit()
    session.refresh(item)
    log.info("item created", extra={"item_id": item.id})
    return item


@app.get("/items", response_model=list[ItemOut], tags=["items"])
def list_items(
    limit: int = 50, session: Session = Depends(db.get_session)
) -> list[Item]:
    limit = max(1, min(limit, 200))
    return list(session.scalars(select(Item).order_by(Item.id.desc()).limit(limit)))


@app.get("/items/{item_id}", response_model=ItemOut, tags=["items"])
def get_item(item_id: int, session: Session = Depends(db.get_session)) -> Item:
    item = session.get(Item, item_id)
    if item is None:
        raise HTTPException(status_code=404, detail="item not found")
    return item


@app.get("/simulate/error", tags=["ops"], include_in_schema=False)
def simulate_error() -> None:
    """Emit a 500 on demand so the HighErrorRate alert and the RED dashboard
    can be demonstrated without waiting for a real incident."""
    log.error("simulated failure", extra={"simulated": True})
    raise HTTPException(status_code=500, detail="simulated failure")


@app.get("/simulate/slow", tags=["ops"], include_in_schema=False)
def simulate_slow(seconds: float = 1.0) -> dict:
    """Burn latency on demand to exercise the p99 latency panels and alert."""
    seconds = max(0.0, min(seconds, 5.0))
    time.sleep(seconds)
    return {"slept": seconds}
