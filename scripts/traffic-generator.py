import argparse
import concurrent.futures
import random
import requests
import time


# (concurrency, number_of_requests)
PHASES = [
    (5, 1000),
    (20, 5000),
    (50, 10000),
    (100, 20000),   # peak
    (50, 10000),
    (20, 5000),
    (5, 1000),
]


def send_vote(url):
    vote = random.choice(["a", "b"])

    try:
        r = requests.post(
            url,
            data={"vote": vote},
            timeout=10,
        )
        return r.ok

    except requests.RequestException:
        return False


def run_phase(url, workers, requests_count):
    print(
        f"Phase: {workers} workers, "
        f"{requests_count} requests"
    )

    start = time.perf_counter()

    success = 0
    errors = 0

    with concurrent.futures.ThreadPoolExecutor(
        max_workers=workers
    ) as executor:

        results = executor.map(
            send_vote,
            [url] * requests_count
        )

        for result in results:
            if result:
                success += 1
            else:
                errors += 1

    elapsed = time.perf_counter() - start

    rps = requests_count / elapsed if elapsed > 0 else 0

    print(
        f"  Success : {success}"
    )
    print(
        f"  Errors  : {errors}"
    )
    print(
        f"  Time    : {elapsed:.2f}s"
    )
    print(
        f"  Rate    : {rps:.2f} req/s"
    )
    print()


def main():
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--url",
        required=True
    )

    args = parser.parse_args()

    url = args.url.rstrip("/") + "/"

    print()
    print("Voting App Load Test")
    print("--------------------")
    print(f"Target: {url}")
    print()

    total_start = time.perf_counter()

    for workers, requests_count in PHASES:
        run_phase(
            url,
            workers,
            requests_count
        )

    total_elapsed = time.perf_counter() - total_start

    print("--------------------")
    print(
        f"Total time: {total_elapsed:.2f}s"
    )
    print("Load test complete.")


if __name__ == "__main__":
    main()
