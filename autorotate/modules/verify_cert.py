#!/usr/bin/env python3
import argparse
import os
import socket
import ssl
import sys
from typing import Iterable


class DnsResolveError(RuntimeError):
    pass

EXIT_OK = 0
EXIT_DNS_FAIL = 2
EXIT_TCP_FAIL = 3
EXIT_TLS_FAIL = 4


def eprint(message: str) -> None:
    print(message, file=sys.stderr)


def resolve_host(host: str, port: int) -> Iterable[tuple]:
    try:
        return socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    except socket.gaierror as exc:
        raise DnsResolveError(f"DNS resolve failed for {host}:{port}: {exc}")


def verify_host(host: str, port: int, timeout: float) -> int:
    try:
        infos = resolve_host(host, port)
    except DnsResolveError as exc:
        eprint(str(exc))
        return EXIT_DNS_FAIL

    context = ssl.create_default_context()
    context.check_hostname = True
    context.verify_mode = ssl.CERT_REQUIRED

    tcp_failed = True
    tls_failed = False

    for family, socktype, proto, _canonname, sockaddr in infos:
        sock = socket.socket(family, socktype, proto)
        sock.settimeout(timeout)
        try:
            sock.connect(sockaddr)
            tcp_failed = False
        except OSError as exc:
            eprint(f"TCP connect failed to {sockaddr}: {exc}")
            sock.close()
            continue

        try:
            with context.wrap_socket(sock, server_hostname=host) as tls_sock:
                tls_sock.settimeout(timeout)
                tls_sock.do_handshake()
            return EXIT_OK
        except (ssl.SSLError, OSError) as exc:
            tls_failed = True
            eprint(f"TLS/hostname verify failed for {host}:{port}: {exc}")
            try:
                sock.close()
            except OSError:
                pass
            continue

    if tcp_failed:
        return EXIT_TCP_FAIL
    if tls_failed:
        return EXIT_TLS_FAIL
    return EXIT_TCP_FAIL


def parse_args() -> argparse.Namespace:
    default_timeout = int(os.getenv("VERIFY_TIMEOUT", "5"))
    parser = argparse.ArgumentParser(description="Verify TLS certificate for hostname.")
    parser.add_argument("--host", required=True, help="Hostname to verify")
    parser.add_argument("--port", type=int, default=443, help="Port to connect")
    parser.add_argument(
        "--timeout",
        type=float,
        default=default_timeout,
        help="Timeout seconds (default from VERIFY_TIMEOUT)",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    exit_code = verify_host(args.host, args.port, args.timeout)
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
