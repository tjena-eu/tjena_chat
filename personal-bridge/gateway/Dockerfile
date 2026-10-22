FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /bridge-gateway .

FROM alpine:3.22
RUN apk add --no-cache ca-certificates && adduser -D -H -u 1337 gateway
COPY --from=build /bridge-gateway /usr/bin/bridge-gateway
USER gateway
# 29331 public (wap.tjena.eu), 29332 internal (Synapse only)
EXPOSE 29331 29332
ENTRYPOINT ["/usr/bin/bridge-gateway", "-config", "/data/config.yaml"]
CMD ["serve"]
