# frontend image (PLAN Phase 9.1). Multi-stage: Node builds the React static bundle, nginx serves it.
#
#   build:  docker build -t localhost:5000/nimbus/frontend:0.1.0 apps/frontend
#   push:   docker push  localhost:5000/nimbus/frontend:0.1.0
#   nodes pull it as 192.168.122.1:5000/nimbus/frontend:0.1.0 (see vms/registries.yaml)

# ---- build stage: compile the React app to static files ----
FROM node:22-alpine AS build
WORKDIR /app
COPY package.json ./
RUN npm install
COPY . .
RUN npm run build

# ---- serve stage: unprivileged nginx (uid 101, port 8080) ----
FROM nginxinc/nginx-unprivileged:1.27-alpine
COPY nginx.conf /etc/nginx/nginx.conf
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 8080
