# The e2e image, built from the repository root for the machine's own
# architecture: docker-in-docker with the e2e runner, the client binary and
# its two-line Dockerfile, helm, kubectl and kubectl cnpg. It also has the
# scripts of scripts/ with the tools they need, and a static bash and jq that
# it copies onto a node for host-check.sh. TestScenario of scenario_test.go
# builds and runs it.

FROM golang:1.27-alpine@sha256:fa3d596898d9f126af7c01d14ee7597bab3f39cccf392ef36b69fe77cd681f18 AS build
WORKDIR /src
# The client builds against the pgfallback package of this checkout.
COPY go.mod go.sum ./
COPY pgfallback/ pgfallback/
COPY e2e/go.mod e2e/go.sum e2e/
RUN cd e2e && go mod download
COPY e2e/ e2e/
RUN cd e2e && CGO_ENABLED=0 go build -trimpath -o /out/e2e . \
  && CGO_ENABLED=0 go build -trimpath -o /out/client ./client

FROM alpine:3.22@sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f AS tools
# ar, to unpack the Debian package of the static bash.
RUN apk add --no-cache binutils
WORKDIR /tools
RUN set -eu; \
  case $(uname -m) in \
    x86_64) arch=amd64 cnpgarch=x86_64 \
      helm=86584a54def73570558f66f5111cc53dfed56689637ae32c1201205d494f54fb \
      kubectl=316d712726d857c20744c57cb36aa47cfc79bc0af7e82cebf3780244b654c073 \
      cnpg=784bc46f176b24a150d5de84d0691f10ff613b59456af86b1a4868e1bacb9953 \
      bash=a8dfc61a50e70cdf2b790dcd9e1c45e2e42f396988e7fed1c45b1444df932953 \
      jq=5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93d7c58b81d19c8ff5 ;; \
    aarch64) arch=arm64 cnpgarch=arm64 \
      helm=31c5794dd55c66a51e6b7d2e2ac7a114ae8b1de41ff1d9ba51748ac973b06a08 \
      kubectl=9fe8aadd5aab9421978c7ac95de6fad304a3c4c0ce9dbf4127579779e0699080 \
      cnpg=6ffad753bbbf5d353576967233063f2ba0adb843a4e7ef5ff4cb7384b2716d5e \
      bash=7353d15a7160940496204ca38b6c00495995c389b4c3946d9b1f83b1b0b7a06e \
      jq=4dd2d8a0661df0b22f1bb9a1f9830f06b6f3b8f7d91211a1ef5d7c4f06a8b4a5 ;; \
    *) echo "no tools for $(uname -m)" >&2; exit 1 ;; \
  esac; \
  wget -q -O helm.tar.gz "https://get.helm.sh/helm-v4.3.0-linux-$arch.tar.gz"; \
  wget -q -O kubectl "https://dl.k8s.io/release/v1.33.13/bin/linux/$arch/kubectl"; \
  wget -q -O cnpg.tar.gz "https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v1.30.1/kubectl-cnpg_1.30.1_linux_$cnpgarch.tar.gz"; \
  wget -q -O bash.deb "https://deb.debian.org/debian/pool/main/b/bash/bash-static_5.2.37-2+b10_$arch.deb"; \
  wget -q -O jq "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-$arch"; \
  printf '%s  %s\n' "$helm" helm.tar.gz "$kubectl" kubectl "$cnpg" cnpg.tar.gz "$bash" bash.deb "$jq" jq | sha256sum -c -; \
  mkdir out node; \
  tar -xzf helm.tar.gz -C out --strip-components=1 "linux-$arch/helm"; \
  tar -xzf cnpg.tar.gz -C out kubectl-cnpg; \
  install -m 755 kubectl out/kubectl; \
  ar x bash.deb data.tar.xz; \
  tar -xJf data.tar.xz ./usr/bin/bash-static; \
  install -m 755 usr/bin/bash-static node/bash; \
  install -m 755 jq node/jq

FROM docker:29-dind@sha256:08a98015fce594af7c382883bea080ea206de74402a95da9dc52b6428c8cd121
# What the scripts of scripts/ need.
RUN apk add --no-cache bash coreutils jq openssl postgresql-client procps-ng python3 setpriv
COPY --from=tools /tools/out/ /usr/local/bin/
COPY --from=tools /tools/node/ /opt/cnpg-evidence/node/
COPY scripts/ /opt/cnpg-evidence/scripts/
COPY e2e/client/Dockerfile /opt/cnpg-evidence/client/
COPY --from=build /out/client /opt/cnpg-evidence/client/
COPY --from=build /out/e2e /usr/local/bin/e2e
ENTRYPOINT ["e2e"]
