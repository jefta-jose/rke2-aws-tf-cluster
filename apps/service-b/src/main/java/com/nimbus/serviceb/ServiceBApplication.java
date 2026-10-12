package com.nimbus.serviceb;

import java.util.Map;
import java.util.concurrent.ThreadLocalRandom;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * service-b — the stateless Spring Boot peer (PLAN Phase 9.1 / 9.2).
 *
 * It does nothing but answer HTTP, which is the point: every request is counted and timed by
 * Micrometer's built-in `http.server.requests` metric (a counter + a latency histogram), exported
 * on /actuator/prometheus. The /work endpoint sleeps a random few ms so the latency histogram has
 * something interesting to show in Grafana. HOSTNAME = the pod name, so the frontend fan-out can
 * display which pod/worker served the call.
 */
@SpringBootApplication
@RestController
public class ServiceBApplication {

  public static void main(String[] args) {
    SpringApplication.run(ServiceBApplication.class, args);
  }

  @GetMapping("/")
  public Map<String, String> root() {
    return Map.of(
        "service", "service-b",
        "pod", System.getenv().getOrDefault("HOSTNAME", "unknown"));
  }

  /** Random small latency so the request-duration histogram is non-trivial. */
  @GetMapping("/work")
  public Map<String, Object> work() throws InterruptedException {
    long ms = ThreadLocalRandom.current().nextLong(5, 60);
    Thread.sleep(ms);
    return Map.of(
        "service", "service-b",
        "pod", System.getenv().getOrDefault("HOSTNAME", "unknown"),
        "sleptMs", ms);
  }
}
