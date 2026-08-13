# SPDX-FileCopyrightText: 2019-Present Christian Kußowski
# SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
#
# SPDX-License-Identifier: AGPL-3.0-or-later

FROM ghcr.io/cirruslabs/flutter as builder
RUN sudo apt update && sudo apt install curl wget jq build-essential python3 -y

WORKDIR /tmp
RUN wget https://github.com/mikefarah/yq/releases/download/v4.40.5/yq_linux_amd64.tar.gz
RUN tar -xzvf ./yq_linux_amd64.tar.gz
RUN mv yq_linux_amd64 /usr/bin/yq

COPY . /app
WORKDIR /app
RUN curl https://sh.rustup.rs -sSf | bash -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"
RUN rustup component add rust-src --toolchain nightly-x86_64-unknown-linux-gnu
RUN ./scripts/prepare-web.sh
COPY config.* /app/
RUN flutter pub get
# Apply the VoIP SDK patch (adds CallSession.addReconstructedRemoteStream, which
# lib/utils/voip_plugin.dart calls). A fresh `flutter pub get` fetches the
# unpatched matrix-dart-sdk from git, so without this the web build fails to
# compile. The room.dart bridge patches aren't needed on web (no on-device bridge).
RUN python3 patches/voip_remote_stream_fix.py \
    "$(find /root/.pub-cache/git -path '*matrix-dart-sdk*/lib/src/voip/call_session.dart' | head -1)"
RUN flutter build web --dart-define=FLUTTER_WEB_CANVASKIT_URL=canvaskit/ --release --source-maps

FROM docker.io/nginx:alpine
RUN rm -rf /usr/share/nginx/html
COPY --from=builder /app/build/web /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
