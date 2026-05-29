from __future__ import annotations

import os
import random
import ssl
import time
import logging
from dataclasses import dataclass
from typing import Optional, Sequence

from gevent import monkey

monkey.patch_all()

import pg8000
from locust import User, between, events, task


LOGGER = logging.getLogger("locust.materialize")
if not LOGGER.handlers:
    _handler = logging.StreamHandler()
    _handler.setFormatter(
        logging.Formatter("%(asctime)s | %(levelname)s | %(name)s | %(message)s")
    )
    LOGGER.addHandler(_handler)
LOGGER.setLevel(logging.INFO)
LOGGER.propagate = False


def _env_str(name: str, default: str) -> str:
    value = os.getenv(name, "")
    return value.strip() or default


def _env_int(name: str, default: int) -> int:
    raw_value = os.getenv(name, "")
    if not raw_value.strip():
        return default
    return int(raw_value)


def _env_float(name: str, default: float) -> float:
    raw_value = os.getenv(name, "")
    if not raw_value.strip():
        return default
    return float(raw_value)


def _env_bool(name: str, default: bool) -> bool:
    raw_value = os.getenv(name, "").strip().lower()
    if not raw_value:
        return default
    return raw_value in {"1", "true", "yes", "on", "y"}


def _format_params(parameters: Sequence[object]) -> str:
    if not parameters:
        return "[]"

    rendered = repr(tuple(parameters))
    if len(rendered) > 500:
        return rendered[:497] + "..."
    return rendered


def _sql_ident(name: str) -> str:
    # Quote identifier for SQL and escape embedded double-quotes.
    return '"' + name.replace('"', '""') + '"'


def _build_ssl_context(mode: str) -> Optional[ssl.SSLContext]:
    if mode.strip().lower() == "disable":
        return None

    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    return context


@dataclass(frozen=True)
class MaterializeSettings:
    host: str
    port: int
    database: str
    schema: str
    user: str
    password: str
    sslmode: str
    cluster: str
    customer_pool_size: int
    recent_orders_limit: int
    min_wait_seconds: float
    max_wait_seconds: float


SETTINGS = MaterializeSettings(
    host=_env_str("MATERIALIZE_HOST", "materialized"),
    port=_env_int("MATERIALIZE_PORT", 6875),
    database=_env_str("MATERIALIZE_DATABASE", "materialize"),
    schema=_env_str("MATERIALIZE_SCHEMA", "tpcc_aks"),
    user=_env_str("MATERIALIZE_USER", "materialize"),
    password=_env_str("MATERIALIZE_PASSWORD", ""),
    sslmode=_env_str("MATERIALIZE_SSLMODE", "disable"),
    cluster=_env_str("MATERIALIZE_CLUSTER", "quickstart"),
    customer_pool_size=_env_int("LOCUST_CUSTOMER_POOL_SIZE", 1000),
    recent_orders_limit=_env_int("LOCUST_RECENT_ORDERS_LIMIT", 5),
    min_wait_seconds=_env_float("LOCUST_MIN_WAIT_SECONDS", 0.2),
    max_wait_seconds=_env_float("LOCUST_MAX_WAIT_SECONDS", 2.0),
)


LOG_QUERIES = _env_bool("LOCUST_LOG_QUERIES", True)


def _record_sql_result(
    name: str,
    start_time: float,
    row_count: int,
    exception: Optional[BaseException] = None,
) -> None:
    duration_ms = (time.perf_counter() - start_time) * 1000.0
    events.request.fire(
        request_type="SQL",
        name=name,
        response_time=duration_ms,
        response_length=row_count,
        exception=exception,
    )


def _connect() -> pg8000.dbapi.Connection:
    ssl_context = _build_ssl_context(SETTINGS.sslmode)
    connection_kwargs = {
        "host": SETTINGS.host,
        "port": SETTINGS.port,
        "database": SETTINGS.database,
        "user": SETTINGS.user,
        "password": SETTINGS.password,
    }
    if ssl_context is not None:
        connection_kwargs["ssl_context"] = ssl_context
    return pg8000.connect(**connection_kwargs)


def _connect_with_retry(max_attempts: int = 30, delay_seconds: float = 2.0) -> pg8000.dbapi.Connection:
    last_error: Optional[BaseException] = None
    for attempt in range(1, max_attempts + 1):
        try:
            if attempt > 1:
                LOGGER.info("Connecting to Materialize (attempt %s/%s)", attempt, max_attempts)
            return _connect()
        except Exception as exc:  # pragma: no cover - startup retry path
            last_error = exc
            LOGGER.warning(
                "Connect attempt %s/%s failed: %s",
                attempt,
                max_attempts,
                exc,
            )
            if attempt < max_attempts:
                time.sleep(delay_seconds)

    raise RuntimeError("Materialize did not become ready in time") from last_error


class MaterializeSqlUser(User):
    abstract = True

    wait_time = between(SETTINGS.min_wait_seconds, SETTINGS.max_wait_seconds)

    def on_start(self) -> None:
        LOGGER.info(
            "Locust user starting | host=%s port=%s db=%s schema=%s cluster=%s sslmode=%s",
            SETTINGS.host,
            SETTINGS.port,
            SETTINGS.database,
            SETTINGS.schema,
            SETTINGS.cluster,
            SETTINGS.sslmode,
        )
        self.connection = _connect_with_retry()
        self.connection.autocommit = True
        self._execute_query(
            "set_cluster",
            f"SET cluster = {_sql_ident(SETTINGS.cluster)}",
            record_event=False,
        )
        self._execute_query(
            "set_search_path",
            f"SET search_path = {_sql_ident(SETTINGS.schema)}, public",
            record_event=False,
        )
        self.customer_pool = self._load_customer_pool()
        LOGGER.info("Customer pool loaded with %s rows", len(self.customer_pool))

    def on_stop(self) -> None:
        connection = getattr(self, "connection", None)
        if connection is not None:
            connection.close()
        LOGGER.info("Locust user stopped")

    def _execute_query(
        self,
        name: str,
        sql_text: str,
        parameters: Sequence[object] = (),
        record_event: bool = True,
    ) -> list[tuple]:
        start_time = time.perf_counter()
        if LOG_QUERIES:
            LOGGER.info("Query start | name=%s | params=%s", name, _format_params(parameters))
        cursor = self.connection.cursor()
        try:
            cursor.execute(sql_text, parameters)
            if cursor.description is None:
                rows = []
            else:
                rows = cursor.fetchall()
            elapsed_ms = (time.perf_counter() - start_time) * 1000.0
            if record_event:
                _record_sql_result(name, start_time, len(rows))
            if LOG_QUERIES:
                LOGGER.info(
                    "Query done  | name=%s | rows=%s | duration_ms=%.2f",
                    name,
                    len(rows),
                    elapsed_ms,
                )
            return rows
        except Exception as exc:  # pragma: no cover - reported through Locust
            elapsed_ms = (time.perf_counter() - start_time) * 1000.0
            if record_event:
                _record_sql_result(name, start_time, 0, exc)
            LOGGER.exception(
                "Query fail  | name=%s | params=%s | duration_ms=%.2f",
                name,
                _format_params(parameters),
                elapsed_ms,
            )
            raise
        finally:
            cursor.close()

    def _load_customer_pool(self) -> list[tuple[int, int, int, str, str]]:
        rows = self._execute_query(
            "customer_pool_bootstrap",
            """
            SELECT c_w_id, c_d_id, c_id, c_first, c_last
            FROM customer
            ORDER BY c_w_id, c_d_id, c_id
            LIMIT %s
            """,
            (SETTINGS.customer_pool_size,),
            record_event=False,
        )
        if not rows:
            raise RuntimeError("No customers were returned from customer")
        return rows  # type: ignore[return-value]


class CustomerOrderJourney(MaterializeSqlUser):
    @task(2)
    def customer_directory(self) -> None:
        self._execute_query(
            "customer_directory",
            """
            SELECT c_w_id, c_d_id, c_id, c_first, c_last
            FROM customer
            ORDER BY c_w_id, c_d_id, c_id
            LIMIT %s
            """,
            (SETTINGS.customer_pool_size,),
        )

    @task(6)
    def recent_orders_and_order_details(self) -> None:
        customer = random.choice(self.customer_pool)
        recent_orders = self._execute_query(
            "recent_orders",
            """
            SELECT
                o_id,
                o_w_id,
                o_d_id,
                o_c_id,
                o_ol_cnt,
                o_entry_d,
                w_id,
                w_name,
                c_first,
                c_last,
                c_state,
                c_street_1,
                c_street_2,
                c_phone,
                o_total
                        FROM order_summary
            WHERE o_w_id = %s
              AND o_d_id = %s
              AND o_c_id = %s
            ORDER BY o_entry_d DESC, o_id DESC
            LIMIT %s
            """,
            (customer[0], customer[1], customer[2], SETTINGS.recent_orders_limit),
        )

        for order in recent_orders:
            self._execute_query(
                "order_detail",
                """
                SELECT
                    ol_o_id,
                    ol_d_id,
                    ol_w_id,
                    ol_number,
                    ol_i_id,
                    i_name,
                    i_price,
                    ol_delivery_d,
                    ol_amount,
                    ol_supply_w_id,
                    w_name,
                    w_state,
                    ol_quantity
                                FROM order_detail
                WHERE ol_w_id = %s
                  AND ol_d_id = %s
                  AND ol_o_id = %s
                ORDER BY ol_number
                """,
                (order[1], order[2], order[0]),
            )

    @task(1)
    def dashboard_summary(self) -> None:
        self._execute_query(
            "dashboard_summary",
            """
            SELECT o_d_id, sum(o_total) AS total_o_amount
            FROM order_summary
            GROUP BY o_d_id
            ORDER BY o_d_id
            """,
        )
