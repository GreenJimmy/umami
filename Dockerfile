ARG NODE_IMAGE_VERSION="22-alpine"

# Install dependencies only when needed
FROM node:${NODE_IMAGE_VERSION} AS deps
# Check https://github.com/nodejs/docker-node/tree/b4117f9333da4138b03a546ec926ef50a31506c3#nodealpine to understand why libc6-compat might be needed.
RUN apk add --no-cache libc6-compat
WORKDIR /app
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN corepack enable && corepack prepare pnpm@11.5.0 --activate
RUN pnpm install --frozen-lockfile

# Rebuild the source code only when needed
FROM node:${NODE_IMAGE_VERSION} AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
COPY docker/proxy.ts ./src

ARG BASE_PATH

ENV BASE_PATH=$BASE_PATH
ENV NEXT_TELEMETRY_DISABLED=1
ENV DATABASE_URL="postgresql://user:pass@localhost:5432/dummy"

RUN npm run build-docker

# Production image, copy all the files and run next
FROM node:${NODE_IMAGE_VERSION} AS runner
WORKDIR /app

ARG PRISMA_VERSION="7.8.0"
ARG NODE_OPTIONS

ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
ENV NODE_OPTIONS=$NODE_OPTIONS

RUN addgroup --system --gid 1001 nodejs
RUN adduser --system --uid 1001 nextjs
RUN set -x \
    && apk add --no-cache curl \
    && corepack enable && corepack prepare pnpm@11.5.0 --activate

# Script dependencies
RUN pnpm --allow-build='@prisma/engines' --allow-build='prisma' add npm-run-all dotenv chalk semver \
    prisma@${PRISMA_VERSION} \
    @prisma/client@${PRISMA_VERSION} \
    @prisma/adapter-pg@${PRISMA_VERSION}

COPY --from=builder --chown=nextjs:nodejs /app/public ./public
COPY --from=builder /app/prisma ./prisma
COPY --from=builder /app/prisma.config.ts ./prisma.config.ts
COPY --from=builder /app/scripts ./scripts
COPY --from=builder /app/generated ./generated

# Automatically leverage output traces to reduce image size
# https://nextjs.org/docs/advanced-features/output-file-tracing
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static

# The standalone bundle ships its own minimal package.json. Overlay the repo's
# package.json so the ESM startup scripts (scripts/*.js use `import`) resolve as
# modules via "type": "module". Nothing reads its dependency list at runtime.
COPY --from=builder /app/package.json ./package.json

USER nextjs

EXPOSE 3000

ENV HOSTNAME=0.0.0.0
ENV PORT=3000
# Put node_modules/.bin on PATH so check-db.js can resolve the `prisma` binary
# (execSync('prisma migrate deploy')) without going through a package manager.
ENV PATH="/app/node_modules/.bin:$PATH"

# Run the startup steps directly with node instead of `pnpm start-docker`.
# pnpm v11 runs an implicit "deps status check" (an install) before every
# `pnpm <script>`; at runtime the container is non-root and /app is root-owned,
# so that check crash-loops with EACCES. start-docker is just these three node
# steps, so invoke them directly and avoid pnpm at runtime entirely.
CMD ["sh", "-c", "node scripts/check-db.js && node scripts/update-tracker.js && node server.js"]