# service-b image (PLAN Phase 9.1). Multi-stage so the host only needs Docker — Maven + JDK live
# in the build stage; the final image is just a slim JRE + the fat jar.
#
#   build:  docker build -t localhost:5000/nimbus/service-b:0.1.0 apps/service-b
#   push:   docker push  localhost:5000/nimbus/service-b:0.1.0
#   nodes pull it as 192.168.122.1:5000/nimbus/service-b:0.1.0 (see vms/registries.yaml)

# ---- build stage: compile + package the fat jar ----
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app
# cache deps first: copy only the pom, resolve, THEN copy source
COPY pom.xml .
RUN mvn -q -B dependency:go-offline
COPY src ./src
RUN mvn -q -B clean package -DskipTests

# ---- run stage: slim JRE, non-root, tiny heap ----
FROM eclipse-temurin:21-jre-alpine
WORKDIR /app
RUN addgroup -S app && adduser -S app -G app
COPY --from=build /app/target/app.jar app.jar
USER app
EXPOSE 8080
# MaxRAMPercentage sizes the heap off the container memory LIMIT (so 256Mi limit -> ~192m heap);
# SerialGC drops the G1 bookkeeping overhead that is wasteful on a tiny, low-CPU container.
ENV JAVA_OPTS="-XX:MaxRAMPercentage=75 -XX:+UseSerialGC"
ENTRYPOINT ["sh","-c","exec java $JAVA_OPTS -jar app.jar"]
