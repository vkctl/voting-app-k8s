// This file must be loaded BEFORE server.js requires anything else —
// auto-instrumentation works by patching libraries (like `pg`) the first
// time they're required, so if pg gets required before this SDK starts,
// the patch never applies. Loaded via NODE_OPTIONS="--require ./tracing.js"
// in the Dockerfile, which preloads this ahead of server.js's own requires.
const { NodeSDK } = require('@opentelemetry/sdk-node');
const { getNodeAutoInstrumentations } = require('@opentelemetry/auto-instrumentations-node');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-grpc');
const { resourceFromAttributes } = require('@opentelemetry/resources');
// Using the plain 'service.name' string key directly rather than a
// semantic-conventions constant — @opentelemetry/resources v2.x removed
// the Resource class (now resourceFromAttributes), and semantic-conventions
// renamed several of its own constants in the same migration wave. The raw
// key is stable regardless of what that package currently calls it.

const sdk = new NodeSDK({
  resource: resourceFromAttributes({
    'service.name': 'result',
  }),
  traceExporter: new OTLPTraceExporter({
    url: 'http://alloy-traces.observability.svc.cluster.local:4317',
  }),
  instrumentations: [getNodeAutoInstrumentations()],
});

sdk.start();
