# The two images of the bench, built from the repository root:
#
#   docker build -f bench/Dockerfile --target client -t <client image> .
#   docker build -f bench/Dockerfile --target bench --build-arg CLIENT_IMAGE=<client image> -t <bench image> .
#
# The bench image is docker-in-docker with the bench, helm, kubectl and
# kubectl cnpg; it starts the client image inside. Go cross-compiles and the
# tools are downloaded for the target; only the last stage's apk add runs
# under emulation in a build for another architecture.

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
WORKDIR /tools
RUN set -eu; \
  case $TARGETARCH in \
    amd64) helm=86584a54def73570558f66f5111cc53dfed56689637ae32c1201205d494f54fb \
      kubectl=316d712726d857c20744c57cb36aa47cfc79bc0af7e82cebf3780244b654c073 \
      cnpg=784bc46f176b24a150d5de84d0691f10ff613b59456af86b1a4868e1bacb9953 cnpgarch=x86_64 ;; \
    arm64) helm=31c5794dd55c66a51e6b7d2e2ac7a114ae8b1de41ff1d9ba51748ac973b06a08 \
      kubectl=9fe8aadd5aab9421978c7ac95de6fad304a3c4c0ce9dbf4127579779e0699080 \
      cnpg=6ffad753bbbf5d353576967233063f2ba0adb843a4e7ef5ff4cb7384b2716d5e cnpgarch=arm64 ;; \
    *) echo "no tools for $TARGETARCH" >&2; exit 1 ;; \
  esac; \
  wget -q -O helm.tar.gz "https://get.helm.sh/helm-v4.3.0-linux-$TARGETARCH.tar.gz"; \
  wget -q -O kubectl "https://dl.k8s.io/release/v1.33.13/bin/linux/$TARGETARCH/kubectl"; \
  wget -q -O cnpg.tar.gz "https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v1.30.1/kubectl-cnpg_1.30.1_linux_$cnpgarch.tar.gz"; \
  printf '%s  %s\n' "$helm" helm.tar.gz "$kubectl" kubectl "$cnpg" cnpg.tar.gz | sha256sum -c -; \
  mkdir out; \
  tar -xzf helm.tar.gz -C out --strip-components=1 "linux-$TARGETARCH/helm"; \
  tar -xzf cnpg.tar.gz -C out kubectl-cnpg; \
  install -m 755 kubectl out/kubectl

FROM alpine:3.22@sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f AS client
COPY --from=build /out/client /usr/local/bin/client
ENTRYPOINT ["client"]

FROM docker:29-dind@sha256:08a98015fce594af7c382883bea080ea206de74402a95da9dc52b6428c8cd121 AS bench
# mkfs.ext4, for the bench's own disk.
RUN apk add --no-cache e2fsprogs
COPY --from=tools /tools/out/ /usr/local/bin/
COPY --from=build /out/bench /usr/local/bin/bench
ARG CLIENT_IMAGE
# The whole run lives in this container, so testcontainers needs no reaper.
ENV BENCH_CLIENT_IMAGE=$CLIENT_IMAGE TESTCONTAINERS_RYUK_DISABLED=true
ENTRYPOINT ["bench"]
