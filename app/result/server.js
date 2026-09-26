var express = require('express'),
    async = require('async'),
    { Pool } = require('pg'),
    cookieParser = require('cookie-parser'),
    client = require('prom-client'),
    { trace } = require('@opentelemetry/api'),
    app = express(),
    server = require('http').Server(app),
    io = require('socket.io')(server);

var port = process.env.PORT || 4000;
// Named tracer for the manual spans below — the pg query itself gets its
// own span automatically via auto-instrumentation (from tracing.js), this
// is just for wrapping the overall poll cycle and the broadcast step.
var tracer = trace.getTracer('result');

// --- Metrics setup ---
// Single Node process here (confirmed via the Dockerfile), so the default
// global registry is fine — none of vote's multiprocess complexity applies.
client.collectDefaultMetrics();   // free Node.js runtime metrics: event loop lag, memory, GC — a nice bonus specific to Node

var httpRequestCount = new client.Counter({
  name: 'result_http_requests_total',
  help: 'Total HTTP requests',
  labelNames: ['method', 'path', 'status'],
});
var httpRequestDuration = new client.Histogram({
  name: 'result_http_request_duration_seconds',
  help: 'HTTP request duration',
  labelNames: ['method', 'path'],
});
// Custom to result specifically — "is anyone actually watching this data"
var connectedSockets = new client.Gauge({
  name: 'result_connected_sockets',
  help: 'Currently connected Socket.IO clients',
});

app.use(function (req, res, next) {
  var start = process.hrtime();
  res.on('finish', function () {
    var diff = process.hrtime(start);
    var seconds = diff[0] + diff[1] / 1e9;
    httpRequestDuration.labels(req.method, req.path).observe(seconds);
    httpRequestCount.labels(req.method, req.path, res.statusCode).inc();
  });
  next();
});

app.get('/metrics', async function (req, res) {
  res.set('Content-Type', client.register.contentType);
  res.end(await client.register.metrics());
});
// --- End metrics setup ---

io.on('connection', function (socket) {
  connectedSockets.inc();

  socket.emit('message', { text : 'Welcome!' });

  socket.on('subscribe', function (data) {
    socket.join(data.channel);
  });

  socket.on('disconnect', function () {
    connectedSockets.dec();
  });
});

var pool = new Pool({
  connectionString: 'postgres://postgres:postgres@db/postgres'
});

async.retry(
  {times: 1000, interval: 1000},
  function(callback) {
    pool.connect(function(err, client, done) {
      if (err) {
        console.error("Waiting for db");
      }
      callback(err, client);
    });
  },
  function(err, client) {
    if (err) {
      return console.error("Giving up");
    }
    console.log("Connected to db");
    getVotes(client);
  }
);

function getVotes(client) {
  // Deliberately a NEW root span every cycle, not extracting any vote's
  // trace context — this poll aggregates ALL votes, it isn't "caused by"
  // any one of them, so it gets its own honest, separate trace rather than
  // being falsely attached to whichever vote happened to trigger a scrape.
  tracer.startActiveSpan('poll_and_broadcast', function (span) {
    client.query('SELECT vote, COUNT(id) AS count FROM votes GROUP BY vote', [], function(err, result) {
      if (err) {
        console.error("Error performing query: " + err);
        span.recordException(err);
      } else {
        var votes = collectVotesFromResult(result);

        tracer.startActiveSpan('broadcast', function (broadcastSpan) {
          broadcastSpan.setAttribute('votes.a', votes.a);
          broadcastSpan.setAttribute('votes.b', votes.b);
          io.sockets.emit("scores", JSON.stringify(votes));
          broadcastSpan.end();
        });
      }

      span.end();
      setTimeout(function() {getVotes(client) }, 1000);
    });
  });
}

function collectVotesFromResult(result) {
  var votes = {a: 0, b: 0};

  result.rows.forEach(function (row) {
    votes[row.vote] = parseInt(row.count);
  });

  return votes;
}

app.use(cookieParser());
app.use(express.urlencoded());
app.use(express.static(__dirname + '/views'));

app.get('/', function (req, res) {
  res.sendFile(path.resolve(__dirname + '/views/index.html'));
});

server.listen(port, function () {
  var port = server.address().port;
  console.log('App running on port ' + port);
});
