import { WebTracerProvider } from '@opentelemetry/sdk-trace-web';
import { BatchSpanProcessor } from '@opentelemetry/sdk-trace-base';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-http';
import { registerInstrumentations } from '@opentelemetry/instrumentation';
import { FetchInstrumentation } from '@opentelemetry/instrumentation-fetch';
import { Resource } from '@opentelemetry/resources';
import { W3CTraceContextPropagator } from '@opentelemetry/core';

// Absolute URL required by the exporter — nginx proxies /v1/traces → alloy:4318/v1/traces
const exporter = new OTLPTraceExporter({ url: `${window.location.origin}/v1/traces` });

const provider = new WebTracerProvider({
  resource: new Resource({ 'service.name': 'travel-booking-frontend' }),
});

provider.addSpanProcessor(new BatchSpanProcessor(exporter));

provider.register({
  propagator: new W3CTraceContextPropagator(),
});

registerInstrumentations({
  instrumentations: [
    new FetchInstrumentation({
      // Don't create spans for the OTel export requests themselves
      ignoreUrls: [/\/v1\//],
    }),
  ],
});
