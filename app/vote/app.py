from flask import Flask, render_template, request, make_response, g, Response
from redis import Redis
import os
import socket
import random
import json
import logging
import time
from prometheus_client import Counter, Histogram, CollectorRegistry, multiprocess, generate_latest, CONTENT_TYPE_LATEST

option_a = os.getenv('OPTION_A', "Cats")
option_b = os.getenv('OPTION_B', "Dogs")
hostname = socket.gethostname()

app = Flask(__name__)

gunicorn_error_logger = logging.getLogger('gunicorn.error')
app.logger.handlers.extend(gunicorn_error_logger.handlers)
app.logger.setLevel(logging.INFO)

# --- Metrics setup ---
# These Counter/Histogram objects are defined once at import time, but with
# gunicorn running --workers 4, each worker PROCESS gets its own separate
# copy in memory. PROMETHEUS_MULTIPROC_DIR (set in the Dockerfile/deployment)
# tells the client library to write each process's data to shared files on
# disk instead, so the /metrics endpoint can merge all 4 workers' numbers
# together — without this, a scrape only ever sees one worker's slice.
REQUEST_COUNT = Counter(
    'vote_requests_total', 'Total requests', ['method', 'endpoint', 'status']
)
REQUEST_DURATION = Histogram(
    'vote_request_duration_seconds', 'Request duration', ['method', 'endpoint']
)


@app.before_request
def start_timer():
    g.start_time = time.time()


@app.after_request
def record_metrics(response):
    duration = time.time() - g.start_time
    REQUEST_DURATION.labels(request.method, request.path).observe(duration)
    REQUEST_COUNT.labels(request.method, request.path, response.status_code).inc()
    return response


@app.route('/metrics')
def metrics():
    # Building a fresh registry per-request and merging all worker
    # processes' files via MultiProcessCollector — this is the multiprocess-
    # mode-specific way to expose combined metrics, different from the
    # single-process default the library normally uses.
    registry = CollectorRegistry()
    multiprocess.MultiProcessCollector(registry)
    return Response(generate_latest(registry), mimetype=CONTENT_TYPE_LATEST)
# --- End metrics setup ---


def get_redis():
    if not hasattr(g, 'redis'):
        g.redis = Redis(host="redis", db=0, socket_timeout=5)
    return g.redis

@app.route("/", methods=['POST','GET'])
def hello():
    voter_id = request.cookies.get('voter_id')
    if not voter_id:
        voter_id = hex(random.getrandbits(64))[2:-1]

    vote = None

    if request.method == 'POST':
        redis = get_redis()
        vote = request.form['vote']
        app.logger.info('Received vote for %s', vote)
        data = json.dumps({'voter_id': voter_id, 'vote': vote})
        redis.rpush('votes', data)

    resp = make_response(render_template(
        'index.html',
        option_a=option_a,
        option_b=option_b,
        hostname=hostname,
        vote=vote,
    ))
    resp.set_cookie('voter_id', voter_id)
    return resp


if __name__ == "__main__":
    app.run(host='0.0.0.0', port=80, debug=True, threaded=True)
