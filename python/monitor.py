# opens tcp connections to a node
import socket

import sys

# wraps that connection in TLS. the certificate arrives during 
import ssl

from datetime import datetime, timezone

from cryptography import x509


# Maximum time to wait for an endpoint.
CONNECT_TIMEOUT_SECONDS = 5

# Alert thresholds, in days remaining.
WARNING_DAYS = 90
CRITICAL_DAYS = 30
EMERGENCY_DAYS = 7

# Ports an NLB health-checks on control-plane nodes: the Kubernetes API
# and the RKE2 supervisor (agent registration).
TARGET_PORTS = [6443, 9345]

# CloudWatch namespace the metrics will be published to.
METRIC_NAMESPACE = "RKE2/Certs"

# Value for the Cluster dimension on every metric.
CLUSTER = "nimbus"


# Nimbus RKE2 lab topology.
# In AWS this list will come from EC2/ASG tags instead.
NODES = [
    {
        "name": "nimbus-server-1",
        "ip": "192.168.122.11",
        "role": "control-plane",
        "ports": [6443, 2379, 10250],
    },
    {
        "name": "nimbus-agent-1",
        "ip": "192.168.122.21",
        "role": "worker",
        "ports": [10250],
    },
    {
        "name": "nimbus-agent-2",
        "ip": "192.168.122.22",
        "role": "worker",
        "ports": [10250],
    },
]


def fetch_certificate(host: str, port: int) -> bytes:
    """
    Open a TLS connection and return the server's certificate (DER bytes).

    Verification is deliberately disabled: we want to read the cert even
    if it is expired or untrusted. This reports what the endpoint
    presents, not whether it is trusted.
    """

    with socket.create_connection(
        (host, port),
        timeout=CONNECT_TIMEOUT_SECONDS,
    ) as tcp_socket:

        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE

        with context.wrap_socket(
            tcp_socket,
            server_hostname=None,
        ) as tls_socket:

            return tls_socket.getpeercert(binary_form=True)


def get_expiry(der_certificate: bytes) -> datetime:
    """
    Decode a DER certificate and return its notAfter date (UTC).
    """

    certificate = x509.load_der_x509_certificate(der_certificate)

    return certificate.not_valid_after_utc


def classify_certificate(days_remaining: float) -> str:
    """
    Turn days remaining into a severity label.
    """

    if days_remaining <= 0:
        return "EXPIRED"

    if days_remaining < EMERGENCY_DAYS:
        return "EMERGENCY"

    if days_remaining < CRITICAL_DAYS:
        return "CRITICAL"

    if days_remaining < WARNING_DAYS:
        return "WARNING"

    return "HEALTHY"


def inspect_certificate(host: str, port: int, node_name: str) -> dict:
    """
    Check one node/port: fetch its certificate, read the expiry and
    classify it. Never raises; failures are recorded in the result.
    """

    checked_at = datetime.now(timezone.utc)

    result = {
        "node": node_name,
        "host": host,
        "port": port,
        "handshake_ok": False,
        "status": None,
        "severity": None,
        "certificate_expiry": None,
        "days_remaining": None,
        "error": None,
    }

    try:
        der_certificate = fetch_certificate(host, port)

        # The handshake completed, so the endpoint is reachable.
        result["handshake_ok"] = True

        if not der_certificate:
            result["status"] = "NO_CERTIFICATE"
            result["error"] = "Handshake succeeded but no certificate was returned"
            return result

        expiry = get_expiry(der_certificate)
        days_remaining = (expiry - checked_at).total_seconds() / 86400

        result["status"] = "CERTIFICATE_RETRIEVED"
        result["certificate_expiry"] = expiry.isoformat()
        result["days_remaining"] = round(days_remaining, 2)
        result["severity"] = classify_certificate(days_remaining)

    except socket.timeout:
        result["status"] = "CONNECTION_TIMEOUT"
        result["error"] = "Connection timed out"

    except ConnectionRefusedError:
        result["status"] = "CONNECTION_REFUSED"
        result["error"] = "Connection refused"

    except ssl.SSLError as exc:
        result["status"] = "TLS_ERROR"
        result["error"] = str(exc)

    except ValueError as exc:
        result["status"] = "CERTIFICATE_PARSE_ERROR"
        result["error"] = str(exc)

    except OSError as exc:
        result["status"] = "CONNECTION_ERROR"
        result["error"] = str(exc)

    return result


def monitor_cluster() -> list[dict]:
    """
    Inspect every configured node/port combination.
    """

    results = []

    for node in NODES:
        for port in node["ports"]:
            result = inspect_certificate(
                host=node["ip"],
                port=port,
                node_name=node["name"],
            )
            result["role"] = node["role"]

            results.append(result)

    return results


def probe_targets() -> dict[str, bool]:
    """
    Emulate NLB target health for the control-plane nodes.

    A node is a healthy target when the TLS handshake succeeds on
    every port in TARGET_PORTS. Returns {node name: healthy}.
    """

    health = {}

    for node in NODES:
        if node["role"] != "control-plane":
            continue

        node_ok = True

        for port in TARGET_PORTS:
            result = inspect_certificate(
                host=node["ip"],
                port=port,
                node_name=node["name"],
            )

            if not result["handshake_ok"]:
                node_ok = False
                break

        health[node["name"]] = node_ok

    return health


def build_metrics(results: list[dict], target_health: dict[str, bool]) -> list[dict]:
    """
    Build the CloudWatch metrics described in DD-1463.

    DaysToExpiry    dimensions: Cluster, Node, Port
    ApiReachable    dimensions: Cluster
    HealthyTargets  dimensions: Cluster
    """

    metrics = []

    # DaysToExpiry: one metric per node/port where we read a date.
    for result in results:
        if result["days_remaining"] is None:
            continue

        metrics.append(
            {
                "MetricName": "DaysToExpiry",
                "Dimensions": {
                    "Cluster": CLUSTER,
                    "Node": result["node"],
                    "Port": str(result["port"]),
                },
                "Value": result["days_remaining"],
            }
        )

    # ApiReachable: 1 only if every control-plane node answered on 6443.
    api_reachable = 1
    control_plane_checks = 0

    for result in results:
        if result["role"] != "control-plane" or result["port"] != 6443:
            continue

        control_plane_checks += 1

        if not result["handshake_ok"]:
            api_reachable = 0

    if control_plane_checks == 0:
        api_reachable = 0

    metrics.append(
        {
            "MetricName": "ApiReachable",
            "Dimensions": {"Cluster": CLUSTER},
            "Value": api_reachable,
        }
    )

    # HealthyTargets: how many control-plane nodes are healthy targets.
    healthy_targets = 0

    for node_name, healthy in target_health.items():
        if healthy:
            healthy_targets += 1

    metrics.append(
        {
            "MetricName": "HealthyTargets",
            "Dimensions": {"Cluster": CLUSTER},
            "Value": healthy_targets,
        }
    )

    return metrics


def print_report(
    results: list[dict],
    target_health: dict[str, bool],
    metrics: list[dict],
) -> None:
    """
    Print the certificate table, target health and metrics.
    """

    print(f"== Certificates (cluster={CLUSTER}) ==")
    print(
        f"{'NODE':<18} {'PORT':<6} {'STATUS':<24} "
        f"{'SEVERITY':<10} {'DAYS':<9} EXPIRES (UTC)"
    )

    for result in results:
        if result["days_remaining"] is None:
            days = "-"
        else:
            days = f"{result['days_remaining']:.2f}"

        severity = result["severity"] or "-"
        expiry = result["certificate_expiry"] or result["error"] or "-"

        print(
            f"{result['node']:<18} {result['port']:<6} {result['status']:<24} "
            f"{severity:<10} {days:<9} {expiry}"
        )

    print()
    print(f"== Target health (ports {TARGET_PORTS}) ==")

    for node_name, healthy in target_health.items():
        label = "healthy" if healthy else "UNHEALTHY"
        print(f"{node_name:<18} {label}")

    print()
    print(f"== Metrics (namespace {METRIC_NAMESPACE}) ==")

    for metric in metrics:
        dims = ",".join(f"{k}={v}" for k, v in metric["Dimensions"].items())
        print(f"{metric['MetricName']:<15} {{{dims}}} = {metric['Value']}")


def main() -> int:
    """
    Local entry point: run every check, print the report and return
    an exit code (1 if the API is unreachable, else 0).
    """

    results = monitor_cluster()
    target_health = probe_targets()
    metrics = build_metrics(results, target_health)

    print_report(results, target_health, metrics)

    for metric in metrics:
        if metric["MetricName"] == "ApiReachable":
            return 0 if metric["Value"] == 1 else 1

    return 1


if __name__ == "__main__":
    sys.exit(main())
