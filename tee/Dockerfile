# Reproducible image for the Nitro enclave. The resulting PCR0 measurement is
# what the attestation document commits to — pin everything so independent
# rebuilds produce the identical measurement, and the published config.ts is
# covered by it (changing any θ/W/margin changes PCR0, publicly).
#
# Build the enclave image:
#   docker build -t usd8-coverpool-tee .
#   nitro-cli build-enclave --docker-uri usd8-coverpool-tee --output-file tee.eif
#   # publish the PCR0 from build-enclave output alongside this source.
#
# At runtime the enclave reaches an Ethereum archive node through the parent
# instance's vsock→TCP proxy; set RPC_URL to the proxy endpoint. TLS
# terminates inside the enclave.

FROM node:22.9.0-bookworm-slim@sha256:0000000000000000000000000000000000000000000000000000000000000000 AS build
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci --no-audit --no-fund
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

FROM node:22.9.0-bookworm-slim@sha256:0000000000000000000000000000000000000000000000000000000000000000
WORKDIR /app
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY package.json ./
# Default to the signing service; override CMD for verify/keygen.
ENTRYPOINT ["node", "dist/main.js"]
CMD ["settle"]
