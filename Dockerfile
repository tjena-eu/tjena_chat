# SPDX-FileCopyrightText: 2019-Present Christian Kußowski
# SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
#
# SPDX-License-Identifier: AGPL-3.0-or-later

FROM ubuntu:26.04 AS builder
RUN apt-get update && apt-get install -y curl wget git unzip xz-utils jq build-essential pkg-config libssl-dev ca-certificates python3

ARG TARGETARCH
WORKDIR /tmp
RUN wget https://github.com/mikefarah/yq/releases/download/v4.40.5/yq_linux_${TARGETARCH}.tar.gz
RUN tar -xzvf ./yq_linux_${TARGETARCH}.tar.gz
RUN mv yq_linux_${TARGETARCH} /usr/bin/yq

# Install the Flutter version defined in .fvmrc
WORKDIR /app
COPY .fvmrc /app/
RUN git clone --depth 1 --branch "$(yq '.flutter' .fvmrc)" \
      https://github.com/flutter/flutter.git /opt/flutter
ENV PATH="/opt/flutter/bin:${PATH}"
RUN flutter precache --web

RUN curl https://sh.rustup.rs -sSf | bash -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"
RUN rustup component add rust-src --toolchain nightly

COPY . /app
RUN ./scripts/prepare-web.sh
COPY config.* /app/
RUN flutter pub get
# Apply the VoIP SDK patch for the legacy 1:1 calls (adds
# CallSession.addReconstructedRemoteStream, which lib/utils/voip_plugin.dart
# calls). `flutter pub get` fetches the unpatched SDK, so without this the web
# build fails to compile.
RUN python3 patches/voip_remote_stream_fix.py \
    "$(find /root/.pub-cache -path '*/matrix-*/lib/src/voip/call_session.dart' | head -1)"
RUN flutter build web --dart-define=FLUTTER_WEB_CANVASKIT_URL=canvaskit/ --release --source-maps

FROM docker.io/nginx:alpine
RUN rm -rf /usr/share/nginx/html
COPY --from=builder /app/build/web /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
