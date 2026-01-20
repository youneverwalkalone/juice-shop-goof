# Updated Dockerfile with security improvements and best practices
# Base image: Using Bookworm (Debian 12) with pinned version for reproducibility
FROM node:20.18.1-bookworm-slim AS installer

# Copy application files
COPY . /juice-shop
WORKDIR /juice-shop

# Install git (required for npm dependencies) and clean up in same layer
RUN apt-get update && \
    apt-get install -y --no-install-recommends git && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Install global dependencies with pinned versions
RUN npm i -g typescript@5.7.2 ts-node@10.9.2

# Install production dependencies
# Note: --unsafe-perm is required for Juice Shop due to:
# - postinstall scripts that need elevated permissions
# - native module compilation (sqlite3, libxmljs2)
# - file system operations during dependency installation
RUN npm install --omit=dev --unsafe-perm

# Deduplicate dependencies to reduce size
RUN npm dedupe

# Clean up frontend build artifacts and unnecessary files
RUN rm -rf frontend/node_modules
RUN rm -rf frontend/.angular
RUN rm -rf frontend/src/assets

# Create logs directory with proper ownership
RUN mkdir -p logs && chown -R 65532:0 logs

# Set group permissions for OpenShift/Kubernetes compatibility
RUN chgrp -R 0 ftp/ frontend/dist/ logs/ data/ i18n/
RUN chmod -R g=u ftp/ frontend/dist/ logs/ data/ i18n/

# Conditional cleanup - only remove files if they exist
RUN if [ -f data/chatbot/botDefaultTrainingData.json ]; then rm data/chatbot/botDefaultTrainingData.json; fi
RUN if [ -f ftp/legal.md ]; then rm ftp/legal.md; fi
RUN find i18n -name "*.json" -type f -delete 2>/dev/null || true

# Generate SBOM (Software Bill of Materials) with pinned version
ARG CYCLONEDX_NPM_VERSION=5.3.1
RUN npm install -g @cyclonedx/cyclonedx-npm@$CYCLONEDX_NPM_VERSION
RUN npm run sbom

# Workaround stage for libxmljs compatibility issues
# This addresses platform/architecture-specific build requirements
FROM node:20.18.1-bookworm AS libxmljs-builder
WORKDIR /juice-shop

# Install build dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential \
    python3 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Copy node_modules from installer stage
COPY --from=installer /juice-shop/node_modules ./node_modules

# Rebuild libxmljs2 for the target architecture
RUN rm -rf node_modules/libxmljs2/build && \
    cd node_modules/libxmljs2 && \
    npm run build

# Final production stage using distroless image for minimal attack surface
FROM gcr.io/distroless/nodejs20-debian12:nonroot

# Build arguments for image metadata
ARG BUILD_DATE
ARG VCS_REF

# OCI image labels
LABEL org.opencontainers.image.title="OWASP Juice Shop"
LABEL org.opencontainers.image.description="Probably the most modern and sophisticated insecure web application"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.version="1.0.0"
LABEL org.opencontainers.image.created="${BUILD_DATE}"
LABEL org.opencontainers.image.revision="${VCS_REF}"
LABEL org.opencontainers.image.source="https://github.com/somerset-inc/juice-shop-goof"
LABEL org.opencontainers.image.url="https://github.com/somerset-inc/juice-shop-goof"
LABEL org.opencontainers.image.documentation="https://github.com/somerset-inc/juice-shop-goof/blob/main/README.md"
LABEL io.snyk.containers.image.dockerfile="/Dockerfile"
LABEL maintainer="Your Team <team@example.com>"

# Set working directory
WORKDIR /juice-shop

# Copy application files from installer stage
COPY --from=installer --chown=65532:0 /juice-shop .

# Copy rebuilt libxmljs2 from builder stage
COPY --chown=65532:0 --from=libxmljs-builder /juice-shop/node_modules/libxmljs2 ./node_modules/libxmljs2

# Use non-root user (already default in distroless:nonroot, but explicit for clarity)
USER 65532

# Expose application port
EXPOSE 3000

# Health check to monitor application status
# Note: Distroless images don't include shell, so we use node directly
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD ["/nodejs/bin/node", "-e", "require('http').get('http://localhost:3000/rest/admin/application-version', (r) => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))"]

# Start the application
CMD ["/juice-shop/build/app.js"]