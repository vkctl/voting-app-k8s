using System;
using System.Collections.Generic;
using System.Data.Common;
using System.Diagnostics;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using Newtonsoft.Json;
using Npgsql;
using OpenTelemetry;
using OpenTelemetry.Context.Propagation;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
using Prometheus;
using StackExchange.Redis;

namespace Worker
{
    public class Program
    {
        // --- Metrics setup ---
        // No existing HTTP server anywhere in this app (unlike vote/result) —
        // MetricServer runs its own tiny standalone HttpListener-based server
        // just for /metrics, no ASP.NET Core dependency needed, matching the
        // plain dotnet/runtime image this Dockerfile deliberately uses.
        private static readonly Counter VotesProcessed = Metrics.CreateCounter(
            "worker_votes_processed_total", "Total votes processed",
            new CounterConfiguration { LabelNames = new[] { "outcome" } }); // "insert" (new voter) or "update" (changed vote)

        private static readonly Histogram VoteProcessingDuration = Metrics.CreateHistogram(
            "worker_vote_processing_duration_seconds", "Time to process a single vote (pop through db write)");

        // THE metric that actually reveals the bottleneck: how many votes are
        // sitting in Redis waiting, sampled every loop iteration — not just
        // when one happens to get processed. Under load, this should climb
        // and stay high, visibly proving the ~10/sec ceiling from Thread.Sleep(100).
        private static readonly Gauge RedisQueueLength = Metrics.CreateGauge(
            "worker_redis_queue_length", "Current number of votes waiting in the Redis queue");

        private static readonly Counter RedisReconnects = Metrics.CreateCounter(
            "worker_redis_reconnects_total", "Times the Redis connection was recreated");

        private static readonly Counter DbReconnects = Metrics.CreateCounter(
            "worker_db_reconnects_total", "Times the Postgres connection was recreated");
        // --- End metrics setup ---

        // --- Tracing setup ---
        // StackExchange.Redis 2.2.4 and Npgsql 4.1.9 both predate their own
        // libraries' native OpenTelemetry integration (that arrived in later
        // major versions with real API changes we're not making here) — so
        // spans are created MANUALLY via ActivitySource, the actual
        // foundation the OTel .NET SDK listens to, rather than relying on
        // auto-instrumentation packages that wouldn't correctly cover these versions.
        private static readonly ActivitySource WorkerActivitySource = new ActivitySource("Worker");
        // --- End tracing setup ---

        public static int Main(string[] args)
        {
            var metricServer = new MetricServer(port: 9090);
            metricServer.Start();
            Console.WriteLine("Metrics server listening on :9090/metrics");

            using var tracerProvider = Sdk.CreateTracerProviderBuilder()
                .AddSource("Worker")
                .SetResourceBuilder(ResourceBuilder.CreateDefault().AddService("worker"))
                .AddOtlpExporter(otlp =>
                {
                    otlp.Endpoint = new Uri("http://alloy-traces.observability.svc.cluster.local:4317");
                })
                .Build();

            try
            {
                var pgsql = OpenDbConnection("Server=db;Username=postgres;Password=postgres;");
                var redisConn = OpenRedisConnection("redis");
                var redis = redisConn.GetDatabase();

                // Keep alive is not implemented in Npgsql yet. This workaround was recommended:
                // https://github.com/npgsql/npgsql/issues/1214#issuecomment-235828359
                var keepAliveCommand = pgsql.CreateCommand();
                keepAliveCommand.CommandText = "SELECT 1";

                // Now includes trace_context — the carrier dict vote injected
                // (matching the {"traceparent": "..."} shape) so this trace
                // can be continued here, not started fresh and disconnected.
                var definition = new { vote = "", voter_id = "", trace_context = new Dictionary<string, string>() };
                while (true)
                {
                    // Slow down to prevent CPU spike, only query each 100ms
                    Thread.Sleep(100);

                    // Reconnect redis if down
                    if (redisConn == null || !redisConn.IsConnected) {
                        Console.WriteLine("Reconnecting Redis");
                        redisConn = OpenRedisConnection("redis");
                        redis = redisConn.GetDatabase();
                        RedisReconnects.Inc();
                    }

                    RedisQueueLength.Set(redis.ListLength("votes"));

                    string json = redis.ListLeftPopAsync("votes").Result;
                    if (json != null)
                    {
                        var sw = Stopwatch.StartNew();
                        var vote = JsonConvert.DeserializeAnonymousType(json, definition);
                        Console.WriteLine($"Processing vote for '{vote.vote}' by '{vote.voter_id}'");

                        // Extract vote's injected trace context so the span
                        // below joins the SAME trace as the original HTTP
                        // request, rather than starting a disconnected new one.
                        var parentContext = Propagators.DefaultTextMapPropagator.Extract(
                            default,
                            vote.trace_context,
                            (carrier, key) => carrier != null && carrier.TryGetValue(key, out var value)
                                ? new[] { value }
                                : Enumerable.Empty<string>());

                        using var activity = WorkerActivitySource.StartActivity(
                            "process_vote", ActivityKind.Consumer, parentContext.ActivityContext);
                        activity?.SetTag("voter_id", vote.voter_id);
                        activity?.SetTag("vote", vote.vote);

                        // Reconnect DB if down
                        if (!pgsql.State.Equals(System.Data.ConnectionState.Open))
                        {
                            Console.WriteLine("Reconnecting DB");
                            pgsql = OpenDbConnection("Server=db;Username=postgres;Password=postgres;");
                            DbReconnects.Inc();
                        }
                        else
                        { // Normal +1 vote requested
                            string outcome;
                            using (WorkerActivitySource.StartActivity("db_write", ActivityKind.Client))
                            {
                                outcome = UpdateVote(pgsql, vote.voter_id, vote.vote);
                            }
                            sw.Stop();
                            VoteProcessingDuration.Observe(sw.Elapsed.TotalSeconds);
                            VotesProcessed.Labels(outcome).Inc();
                            activity?.SetTag("outcome", outcome);
                        }
                    }
                    else
                    {
                        keepAliveCommand.ExecuteNonQuery();
                    }
                }
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine(ex.ToString());
                return 1;
            }
        }

        private static NpgsqlConnection OpenDbConnection(string connectionString)
        {
            NpgsqlConnection connection;

            while (true)
            {
                try
                {
                    connection = new NpgsqlConnection(connectionString);
                    connection.Open();
                    break;
                }
                catch (SocketException)
                {
                    Console.Error.WriteLine("Waiting for db");
                    Thread.Sleep(1000);
                }
                catch (DbException)
                {
                    Console.Error.WriteLine("Waiting for db");
                    Thread.Sleep(1000);
                }
            }

            Console.Error.WriteLine("Connected to db");

            var command = connection.CreateCommand();
            command.CommandText = @"CREATE TABLE IF NOT EXISTS votes (
                                        id VARCHAR(255) NOT NULL UNIQUE,
                                        vote VARCHAR(255) NOT NULL
                                    )";
            command.ExecuteNonQuery();

            return connection;
        }

        private static ConnectionMultiplexer OpenRedisConnection(string hostname)
        {
            // Use IP address to workaround https://github.com/StackExchange/StackExchange.Redis/issues/410
            var ipAddress = GetIp(hostname);
            Console.WriteLine($"Found redis at {ipAddress}");

            while (true)
            {
                try
                {
                    Console.Error.WriteLine("Connecting to redis");
                    return ConnectionMultiplexer.Connect(ipAddress);
                }
                catch (RedisConnectionException)
                {
                    Console.Error.WriteLine("Waiting for redis");
                    Thread.Sleep(1000);
                }
            }
        }

        private static string GetIp(string hostname)
            => Dns.GetHostEntryAsync(hostname)
                .Result
                .AddressList
                .First(a => a.AddressFamily == AddressFamily.InterNetwork)
                .ToString();

        // Now returns which outcome happened ("insert" or "update"), so the
        // caller can label VotesProcessed correctly — same DB behavior as
        // before, just reporting back what it did.
        private static string UpdateVote(NpgsqlConnection connection, string voterId, string vote)
        {
            var command = connection.CreateCommand();
            try
            {
                command.CommandText = "INSERT INTO votes (id, vote) VALUES (@id, @vote)";
                command.Parameters.AddWithValue("@id", voterId);
                command.Parameters.AddWithValue("@vote", vote);
                command.ExecuteNonQuery();
                return "insert";
            }
            catch (DbException)
            {
                command.CommandText = "UPDATE votes SET vote = @vote WHERE id = @id";
                command.ExecuteNonQuery();
                return "update";
            }
            finally
            {
                command.Dispose();
            }
        }
    }
}
