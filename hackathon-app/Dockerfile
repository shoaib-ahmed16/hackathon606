# syntax=docker/dockerfile:1

# ---- build stage: compile the Vite app ----
FROM node:24-alpine AS build
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY . .

# VITE_* values are baked into the JS bundle at BUILD time. Pass them with --build-arg.
ARG VITE_API_URL
ARG VITE_OPS_API_URL
ARG VITE_WS_URL
ARG VITE_SHOW_DEMO_USERS=false
ENV VITE_SHOW_DEMO_USERS=$VITE_SHOW_DEMO_USERS \
    VITE_API_URL=$VITE_API_URL \
    VITE_OPS_API_URL=$VITE_OPS_API_URL \
    VITE_WS_URL=$VITE_WS_URL

RUN npm run build

# ---- runtime stage: tiny nginx serving /dist ----
FROM nginx:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY security-headers.conf /etc/nginx/security-headers.conf
COPY --from=build /app/dist /usr/share/nginx/html

EXPOSE 80
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://127.0.0.1/ >/dev/null || exit 1
CMD ["nginx", "-g", "daemon off;"]
