package com.nimbus.servicea;

import java.util.Map;
import java.util.concurrent.ThreadLocalRandom;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * service-a — the stateful Spring Boot service (PLAN Phase 9.1 / 9.2) and the exemplar for the
 * 9.5–9.8 scheduling/affinity lessons.
 *
 * Like service-b it exports the Micrometer http.server.requests counter + latency histogram on
 * /actuator/prometheus. On top of that it writes to Postgres: /visit records a row and returns the
 * running count. The DB coupling is LAZY on purpose — the table is created on first use and Hikari
 * is told not to fail startup if Postgres is briefly unreachable (see application.yaml), so the pod
 * schedules and stays Ready independently of the database. That keeps the scheduling demos clean.
 */
@SpringBootApplication
@RestController
public class ServiceAApplication {

  private final JdbcTemplate jdbc;

  public ServiceAApplication(JdbcTemplate jdbc) {
    this.jdbc = jdbc;
  }

  public static void main(String[] args) {
    SpringApplication.run(ServiceAApplication.class, args);
  }

  @GetMapping("/")
  public Map<String, Object> root() {
    return Map.of(
        "service", "service-a",
        "pod", System.getenv().getOrDefault("HOSTNAME", "unknown"),
        "dbUp", dbUp());
  }

  /** Record a visit in Postgres and return the running total. Creates the table on first call. */
  @GetMapping("/visit")
  public Map<String, Object> visit() {
    jdbc.execute(
        "CREATE TABLE IF NOT EXISTS visits (id serial PRIMARY KEY, at timestamptz DEFAULT now())");
    jdbc.update("INSERT INTO visits DEFAULT VALUES");
    Integer total = jdbc.queryForObject("SELECT count(*) FROM visits", Integer.class);
    return Map.of(
        "service", "service-a",
        "pod", System.getenv().getOrDefault("HOSTNAME", "unknown"),
        "visits", total == null ? 0 : total);
  }

  /** Random small latency so the request-duration histogram is non-trivial. */
  @GetMapping("/work")
  public Map<String, Object> work() throws InterruptedException {
    long ms = ThreadLocalRandom.current().nextLong(5, 60);
    Thread.sleep(ms);
    return Map.of(
        "service", "service-a",
        "pod", System.getenv().getOrDefault("HOSTNAME", "unknown"),
        "sleptMs", ms);
  }

  private boolean dbUp() {
    try {
      jdbc.queryForObject("SELECT 1", Integer.class);
      return true;
    } catch (Exception e) {
      return false;
    }
  }
}
