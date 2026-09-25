from prometheus_client import multiprocess


def child_exit(server, worker):
    # Without this, a worker process that gunicorn restarts (crash, or
    # normal recycling) leaves its old metric files behind — they'd get
    # counted forever, inflating totals with data from a process that no
    # longer exists.
    multiprocess.mark_process_dead(worker.pid)