# The two images of the bench, built from the repository root:
#
#   docker build -f bench/Dockerfile --target client -t <client image> .
#   docker build -f bench/Dockerfile --target bench --build-arg CLIENT_IMAGE=<client image> -t <bench image> .
#
# The bench image is docker-in-docker with the bench, helm, kubectl and
# kubectl cnpg; it starts the client image inside. It also has the scripts of
# scripts/ with the tools they need, and a static bash and jq that it copies
# onto a node for host-check.sh. Go cross-compiles and the tools are
# downloaded for the target; only the last stage's apk add runs under
# emulation in a build for another architecture.

FROM --platform=$BUILDPLATFORM golang:1.27-alpine@sha256:fa3d596898d9f126af7c01d14ee7597bab3f39cccf392ef36b69fe77cd681f18 AS build
ARG TARGETARCH
WORKDIR /src
# The client builds against the pgfallback package of this checkout.
COPY go.mod go.sum ./
COPY pgfallback/ pgfallback/
COPY bench/go.mod bench/go.sum bench/
RUN cd bench && go mod download
COPY bench/ bench/
RUN cd bench && CGO_ENABLED=0 GOARCH=$TARGETARCH go build -trimpath -o /out/bench . \
  && CGO_ENABLED=0 GOARCH=$TARGETARCH go build -trimpath -o /out/client ./client

FROM --platform=$BUILDPLATFORM alpine:3.22@sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f AS tools
ARG TARGETARCH
# ar, to unpack the Debian package of the static bash.
RUN apk add --no-cache binutils
WORKDIR /tools
RUN set -eu; \
  case $TARGETARCH in \
    amd64) helm=86584a54def73570558f66f5111cc53dfed56689637ae32c1201205d494f54fb \
      kubectl=316d712726d857c20744c57cb36aa47cfc79bc0af7e82cebf3780244b654c073 \
      cnpg=784bc46f176b24a150d5de84d0691f10ff613b59456af86b1a4868e1bacb9953 cnpgarch=x86_64 \
      bash=a8dfc61a50e70cdf2b790dcd9e1c45e2e42f396988e7fed1c45b1444df932953 \
      jq=5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93d7c58b81d19c8ff5 ;; \
    arm64) helm=31c5794dd55c66a51e6b7d2e2ac7a114ae8b1de41ff1d9ba51748ac973b06a08 \
      kubectl=9fe8aadd5aab9421978c7ac95de6fad304a3c4c0ce9dbf4127579779e0699080 \
      cnpg=6ffad753bbbf5d353576967233063f2ba0adb843a4e7ef5ff4cb7384b2716d5e cnpgarch=arm64 \
      bash=7353d15a7160940496204ca38b6c00495995c389b4c3946d9b1f83b1b0b7a06e \
      jq=4dd2d8a0661df0b22f1bb9a1f9830f06b6f3b8f7d91211a1ef5d7c4f06a8b4a5 ;; \
    *) echo "no tools for $TARGETARCH" >&2; exit 1 ;; \
  esac; \
  wget -q -O helm.tar.gz "https://get.helm.sh/helm-v4.3.0-linux-$TARGETARCH.tar.gz"; \
  wget -q -O kubectl "https://dl.k8s.io/release/v1.33.13/bin/linux/$TARGETARCH/kubectl"; \
  wget -q -O cnpg.tar.gz "https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v1.30.1/kubectl-cnpg_1.30.1_linux_$cnpgarch.tar.gz"; \
  wget -q -O bash.deb "https://deb.debian.org/debian/pool/main/b/bash/bash-static_5.2.37-2+b10_$TARGETARCH.deb"; \
  wget -q -O jq "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-$TARGETARCH"; \
  printf '%s  %s\n' "$helm" helm.tar.gz "$kubectl" kubectl "$cnpg" cnpg.tar.gz "$bash" bash.deb "$jq" jq | sha256sum -c -; \
  mkdir out node; \
  tar -xzf helm.tar.gz -C out --strip-components=1 "linux-$TARGETARCH/helm"; \
  tar -xzf cnpg.tar.gz -C out kubectl-cnpg; \
  install -m 755 kubectl out/kubectl; \
  ar x bash.deb data.tar.xz; \
  tar -xJf data.tar.xz ./usr/bin/bash-static; \
  install -m 755 usr/bin/bash-static node/bash; \
  install -m 755 jq node/jq

FROM alpine:3.22@sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f AS client
COPY --from=build /out/client /usr/local/bin/client
ENTRYPOINT ["client"]

FROM docker:29-dind@sha256:08a98015fce594af7c382883bea080ea206de74402a95da9dc52b6428c8cd121 AS bench
# mkfs.ext4, for the bench's own disk, and what the scripts of scripts/
# need.
RUN apk add --no-cache e2fsprogs bash coreutils jq openssl postgresql-client procps-ng python3 setpriv
COPY --from=tools /tools/out/ /usr/local/bin/
COPY --from=tools /tools/node/ /opt/cnpg-evidence/node/
COPY scripts/ /opt/cnpg-evidence/scripts/
COPY --from=build /out/bench /usr/local/bin/bench
ARG CLIENT_IMAGE
ENV BENCH_CLIENT_IMAGE=$CLIENT_IMAGE
ENTRYPOINT ["bench"]
