from prometheus_client import multiprocess


def child_exit(server, worker):
    # Without this, a worker process that gunicorn restarts (crash, or
    # normal recycling) leaves its old metric files behind — they'd get
    # counted forever, inflating totals with data from a process that no
    # longer exists.
    multiprocess.mark_process_dead(worker.pid)


def post_fork(server, worker):
    # OpenTelemetry's span exporter uses a background thread to batch and
    # flush spans. Background threads don't survive fork() — setting up
    # tracing BEFORE gunicorn forks would leave only the master process
    # with a working flush thread, not the actual workers handling
    # requests. This hook runs inside each of the 4 worker processes,
    # AFTER it exists independently, so each gets its own working exporter.
    from opentelemetry import trace
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor
    from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
    from opentelemetry.instrumentation.flask import FlaskInstrumentor
    from opentelemetry.instrumentation.redis import RedisInstrumentor

    provider = TracerProvider()
    provider.add_span_processor(
        BatchSpanProcessor(
            OTLPSpanExporter(endpoint="alloy-traces.observability.svc.cluster.local:4317", insecure=True)
        )
    )
    trace.set_tracer_provider(provider)

    RedisInstrumentor().instrument()

    # Importing app here (not at module top-level) — gunicorn.conf.py needs
    # the actual Flask app object to instrument, but only after this
    # worker's own tracer is already set up above.
    from app import app as flask_app
    FlaskInstrumentor().instrument_app(flask_app)
