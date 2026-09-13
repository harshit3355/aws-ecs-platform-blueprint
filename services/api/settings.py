"""Application configuration.

Credentials are never baked into the image or the Terraform state. On ECS the
RDS password arrives as a Secrets Manager JSON key selector (see the task
definition in infrastructure/terraform/modules/compute), which lands here as
DB_PASSWORD.
"""

from urllib.parse import quote_plus

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    app_env: str = "local"
    log_level: str = "INFO"
    service_name: str = "meridian-api"
    # Set to the git SHA by the CD pipeline so the post-deploy smoke test can
    # assert that the running tasks are actually the commit we just shipped.
    app_version: str = "dev"

    db_host: str = "localhost"
    db_port: int = 5432
    db_name: str = "appdb"
    db_user: str = "appuser"
    db_password: str = Field(default="appsecret", repr=False)

    # Connection pool sizing. Kept small on purpose: RDS db.t4g.micro allows
    # ~85 connections, and every Fargate task holds pool_size + max_overflow.
    # RDS enforces rds.force_ssl = 1, so the connection must negotiate TLS.
    # "require" asks for it explicitly rather than relying on libpq's default of
    # "prefer", which silently falls back to plaintext if the server allows it.
    # Local compose has no certificates, so it overrides this to "disable".
    db_sslmode: str = "require"

    db_connect_timeout: int = 5
    db_pool_size: int = 5
    db_max_overflow: int = 5

    @property
    def database_url(self) -> str:
        # quote_plus matters: RDS-generated passwords legitimately contain
        # characters ("/", "@", ":", "%") that would otherwise corrupt the DSN.
        return (
            f"postgresql+psycopg://{quote_plus(self.db_user)}:"
            f"{quote_plus(self.db_password)}@{self.db_host}:{self.db_port}/"
            f"{self.db_name}?sslmode={self.db_sslmode}"
        )


settings = Settings()
