# syntax=docker/dockerfile:1.29@sha256:572cebbc2b15e6f84c077742952674889cb63cd5e9b80abdffcbe587b6f19183

# Build stage - resolve and install dependencies with uv.
# Chainguard's -dev image ships uv and gcc, so no extra apt installs are needed.
# Base images come from chainringlabs/base-images: signature-verified copies of
# cgr.dev/chainguard/python, held back 3 days (`aged`). Both tags move together
# from the same daily record, so the builder's venv matches the runtime Python.
FROM ghcr.io/chainringlabs/base/python-dev:aged@sha256:768ee36ee9f4b8c882634c07d0b889425bc8e100886a3f742b83b1c647cc2d4b AS builder

# Default user is nonroot; switch to root so we can write to /app during build.
USER root

WORKDIR /app

# uv settings: install into /app/.venv, copy (not symlink) for portability between stages
ENV UV_PROJECT_ENVIRONMENT=/app/.venv \
    UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1 \
    UV_PYTHON_DOWNLOADS=never

# Install only production deps first (no project), cached by lockfile contents
COPY pyproject.toml uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev --no-install-project

# Pre-create runtime directories with nonroot ownership so the distroless
# final stage (which has no shell) can receive them via COPY.
RUN mkdir -p /scaffold/config /scaffold/data && \
    chown -R 65532:65532 /scaffold


# Final stage - distroless runtime.
# Chainguard's runtime image is distroless and already runs as uid 65532 (nonroot).
FROM ghcr.io/chainringlabs/base/python:aged@sha256:f522a16f34c8aa60f831e6476e396ef3951830a1b9059d19bc531a544d0f1579

# Clear the upstream ENTRYPOINT (/usr/bin/python) so PATH-resolved "python" picks
# up the venv interpreter and activates the venv's site-packages.
ENTRYPOINT []

WORKDIR /app

# Copy the resolved virtualenv from the builder, owned by the runtime nonroot user.
COPY --from=builder --chown=65532:65532 /app/.venv /app/.venv
ENV PATH="/app/.venv/bin:$PATH"

# Copy application code
COPY --chown=65532:65532 src/ ./src/
COPY --chown=65532:65532 run.py .

# Create config (mount target) and data (RSS state) directories owned by nonroot.
COPY --from=builder --chown=65532:65532 /scaffold/config /app/config
COPY --from=builder --chown=65532:65532 /scaffold/data /app/data

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD ["python", "-c", "import sys; sys.exit(0)"]

CMD ["python", "run.py"]
