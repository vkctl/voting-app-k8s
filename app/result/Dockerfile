FROM node:18-slim

# add curl for healthcheck
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl tini && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /usr/local/app

# have nodemon available for local dev use (file watching)
RUN npm install -g nodemon

COPY package*.json ./

RUN npm ci && \
 npm cache clean --force && \
 mv /usr/local/app/node_modules /node_modules

COPY . .

ENV PORT=80
EXPOSE 80

# Preloads tracing.js BEFORE server.js's own requires run — required for
# auto-instrumentation to correctly patch libraries like `pg` the first
# time they're required, rather than after they're already loaded.
ENV NODE_OPTIONS="--require ./tracing.js"

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["node", "server.js"]
