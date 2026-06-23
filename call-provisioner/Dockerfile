# --- build the static Go binary ---
FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /call-provisioner .

# --- minimal runtime ---
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /call-provisioner /call-provisioner
EXPOSE 8090
USER nonroot:nonroot
ENTRYPOINT ["/call-provisioner"]
