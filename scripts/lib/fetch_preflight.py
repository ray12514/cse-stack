#!/usr/bin/env python3
"""Fetch preflight: HEAD-check every source tarball URL in the active Spack environment.

Run as:
    spack python scripts/lib/fetch_preflight.py [--strict] [--timeout N]

Exit codes:
    0  all URLs reachable (or --strict not set)
    1  one or more URLs unreachable and --strict set
    2  no active Spack environment
"""
import argparse
import collections
import socket
import sys
import urllib.error
import urllib.request

import spack.environment as ev


def _iter_http_urls(pkg):
    """Yield HTTP/HTTPS source URLs for a package's fetch stages."""
    for stage in pkg.stages:
        fetcher = stage.fetcher
        # FetchStrategyComposite wraps multiple fetchers (mirrors + primary)
        fetchers = getattr(fetcher, 'fetchers', [fetcher])
        for f in fetchers:
            candidates = getattr(f, 'candidate_urls', None)
            if candidates:
                for url in candidates:
                    if url.startswith(('http://', 'https://')):
                        yield url
            else:
                url = getattr(f, 'url', '')
                if url.startswith(('http://', 'https://')):
                    yield url


def _check_url(url, timeout):
    req = urllib.request.Request(url, method='HEAD')
    req.add_header('User-Agent', 'cse-stack-preflight/1.0')
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return True, f"HTTP {resp.status}"
    except urllib.error.HTTPError as e:
        # 405 Method Not Allowed / 403 Forbidden still means the server is reachable
        if e.code in (403, 405):
            return True, f"HTTP {e.code} (reachable)"
        return False, f"HTTP {e.code}"
    except urllib.error.URLError as e:
        return False, str(e.reason)
    except (socket.timeout, TimeoutError):
        return False, f"timeout after {timeout}s"
    except OSError as e:
        return False, str(e)


def main():
    parser = argparse.ArgumentParser(description="CSE fetch preflight URL check")
    parser.add_argument('--strict', action='store_true',
                        help='Exit 1 if any URL is unreachable')
    parser.add_argument('--timeout', type=int, default=5,
                        help='Per-URL connect+read timeout in seconds (default: 5)')
    args = parser.parse_args()

    env = ev.active_environment()
    if env is None:
        print("ERROR: no active Spack environment", file=sys.stderr)
        sys.exit(2)

    # url → list of "name@version" labels that fetch from it
    url_to_specs = collections.defaultdict(list)
    for spec in env.all_specs():
        if spec.external:
            continue
        label = f"{spec.name}@{spec.version}"
        try:
            seen = set()
            for url in _iter_http_urls(spec.package):
                if url not in seen:
                    seen.add(url)
                    url_to_specs[url].append(label)
        except Exception as e:
            print(f"  WARN  {label}: could not inspect fetch strategy: {e}",
                  file=sys.stderr)

    if not url_to_specs:
        print("Stage 4 preflight: no HTTP source URLs found "
              "(all packages external or git-only).")
        return

    print(f"Stage 4 preflight: checking {len(url_to_specs)} source URL(s)...")

    col_w = 32
    failures = []
    for url in sorted(url_to_specs):
        label = url_to_specs[url][0]
        ok, detail = _check_url(url, args.timeout)
        status = "PASS" if ok else "FAIL"
        print(f"  {status}  {label:<{col_w}}  {detail}")
        if not ok:
            failures.append((url, url_to_specs[url], detail))

    if failures:
        print(f"\nStage 4 preflight: {len(failures)} URL(s) unreachable:")
        for url, specs, detail in failures:
            print(f"  {', '.join(specs)}")
            print(f"    {url}")
            print(f"    reason: {detail}")
        print()
        print("  Options:")
        print("    --mirror-path <path>   point to a local Spack source mirror")
        print("    CSE_GATEWAY_HOST=<host>  auto-fetch via gateway (coming soon)")
        if args.strict:
            sys.exit(1)
    else:
        print(f"Stage 4 preflight: all {len(url_to_specs)} URL(s) reachable.")


if __name__ == '__main__':
    main()
