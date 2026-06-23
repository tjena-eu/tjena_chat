# --- build the static SPA ---
FROM node:20-alpine AS build
WORKDIR /app
COPY package.json ./
# No lockfile committed; resolve fresh. Use install (not ci).
RUN npm install
COPY tsconfig.json vite.config.ts index.html ./
COPY src ./src
RUN npm run build

# --- serve it + proxy /api to the provisioner ---
FROM nginx:1.27-alpine
# Static assets
COPY --from=build /app/dist /usr/share/nginx/html
# Templated config: ${PROVISIONER_URL} is substituted at container start by the
# official nginx image's envsubst entrypoint (only env-defined vars are replaced,
# so nginx's own $host/$uri are left intact).
COPY nginx/default.conf.template /etc/nginx/templates/default.conf.template
ENV PROVISIONER_URL=http://call-provisioner:8090
EXPOSE 80
