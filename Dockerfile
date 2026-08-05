# syntax=docker/dockerfile:1.7
#
# Derived image from nousresearch/hermes-agent that adds:
#   - gh (GitHub CLI), pwsh (PowerShell), age (file encryption)
#   - an egress allowlist enforced via iptables, controlled by the
#     MY_HOST_NAMES_FILE_PATH env var (see README.md)
#
# Needs --cap-add=NET_ADMIN --cap-add=NET_RAW at `docker run` for the
# allowlist to be enforced; without them the container refuses to start
# (see docker/cont-init.d/03-egress-firewall).

ARG HERMES_BASE_IMAGE=nousresearch/hermes-agent:latest
FROM ${HERMES_BASE_IMAGE}

# Base image default (0) continues booting even if a cont-init.d script
# exits non-zero — that would silently defeat the fail-closed egress check.
ENV S6_BEHAVIOUR_IF_STAGE2_FAILS=2

ARG TARGETARCH
ARG GH_VERSION=2.97.0
ARG PWSH_VERSION=7.6.4
ARG AGE_VERSION=1.3.1

USER root

RUN apt-get -o Acquire::Retries=3 update && \
    apt-get -o Acquire::Retries=3 install -y --no-install-recommends iptables && \
    rm -rf /var/lib/apt/lists/*

# GitHub CLI — single .deb from the release page.
RUN set -eu; \
    case "${TARGETARCH:-amd64}" in \
        amd64) gh_arch=amd64 ;; \
        arm64) gh_arch=arm64 ;; \
        *) echo "Unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL --retry 3 -o /tmp/gh.deb \
        "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${gh_arch}.deb" && \
    apt-get -o Acquire::Retries=3 update && \
    apt-get -o Acquire::Retries=3 install -y --no-install-recommends /tmp/gh.deb && \
    rm -f /tmp/gh.deb && \
    rm -rf /var/lib/apt/lists/*

# PowerShell — portable tarball (no Debian 13 .deb published upstream).
RUN set -eu; \
    case "${TARGETARCH:-amd64}" in \
        amd64) pwsh_arch=x64 ;; \
        arm64) pwsh_arch=arm64 ;; \
        *) echo "Unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL --retry 3 -o /tmp/pwsh.tar.gz \
        "https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VERSION}/powershell-${PWSH_VERSION}-linux-${pwsh_arch}.tar.gz" && \
    mkdir -p /opt/microsoft/powershell && \
    tar -xzf /tmp/pwsh.tar.gz -C /opt/microsoft/powershell && \
    chmod +x /opt/microsoft/powershell/pwsh && \
    ln -sf /opt/microsoft/powershell/pwsh /usr/local/bin/pwsh && \
    rm -f /tmp/pwsh.tar.gz

# Avoids pulling in libicu just for pwsh; no locale-aware text processing needed here.
ENV DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1

# age (filippo.io/age) — Go binaries from the release page.
RUN set -eu; \
    case "${TARGETARCH:-amd64}" in \
        amd64) age_arch=amd64 ;; \
        arm64) age_arch=arm64 ;; \
        *) echo "Unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL --retry 3 -o /tmp/age.tar.gz \
        "https://github.com/FiloSottile/age/releases/download/v${AGE_VERSION}/age-v${AGE_VERSION}-linux-${age_arch}.tar.gz" && \
    tar -xzf /tmp/age.tar.gz -C /tmp && \
    install -m 0755 /tmp/age/age /usr/local/bin/age && \
    install -m 0755 /tmp/age/age-keygen /usr/local/bin/age-keygen && \
    rm -rf /tmp/age /tmp/age.tar.gz

# Runs as root via s6 cont-init.d, before any Hermes service starts.
COPY --chmod=0755 docker/cont-init.d/03-egress-firewall /etc/cont-init.d/03-egress-firewall

RUN command -v gh && command -v pwsh && command -v age && command -v age-keygen && command -v iptables
