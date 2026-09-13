"""Database engine and session factory."""

from collections.abc import Iterator

from sqlalchemy import create_engine, text
from sqlalchemy.orm import Session, sessionmaker

from settings import settings

engine = create_engine(
    settings.database_url,
    # pool_pre_ping is not optional here: an RDS Multi-AZ failover silently
    # kills every pooled connection, and without it the first request after a
    # failover returns 500 instead of transparently reconnecting.
    pool_pre_ping=True,
    pool_size=settings.db_pool_size,
    max_overflow=settings.db_max_overflow,
    pool_recycle=1800,
    # libpq waits forever by default. Without an explicit timeout a security
    # group that DROPs instead of REJECTs turns "misconfigured" into "hangs
    # until the ALB times out", which is far harder to diagnose than a 503.
    connect_args={"connect_timeout": settings.db_connect_timeout},
)

SessionLocal = sessionmaker(bind=engine, expire_on_commit=False)


def get_session() -> Iterator[Session]:
    """FastAPI dependency: one session per request, always closed."""
    with SessionLocal() as session:
        yield session


def ping() -> None:
    """Raise if the database is unreachable. Used by the readiness probe."""
    with engine.connect() as conn:
        conn.execute(text("SELECT 1"))
