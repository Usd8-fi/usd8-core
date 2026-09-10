#!/usr/bin/env python3
"""Run a command against a pinned, ready, loopback-only disposable DynamoDB emulator."""
import json
import os
import pathlib
import selectors
import subprocess
import sys
import tempfile


def main():
    if len(sys.argv) < 3 or sys.argv[1] != "--":
        raise SystemExit("usage: with-dynamodb-tests.py -- <test command and arguments>")
    with tempfile.TemporaryDirectory(prefix="usd8-dynamodb-tests-") as directory:
        # No package files or dependency tree are written into the repository.
        subprocess.run(["npm", "install", "--prefix", directory, "--ignore-scripts", "--no-audit",
                        "--no-fund", "--package-lock=false", "dynalite@4.0.0"], check=True, timeout=180)
        module = str(pathlib.Path(directory) / "node_modules/dynalite")
        source = ('const server=require(' + json.dumps(module) + ')({createTableMs:0});'
                  'server.listen(0,"127.0.0.1",()=>console.log(server.address().port));')
        server = subprocess.Popen(["node", "-e", source], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            assert server.stdout is not None
            with selectors.DefaultSelector() as selector:
                selector.register(server.stdout, selectors.EVENT_READ)
                if not selector.select(timeout=20):
                    raise SystemExit("DYNAMODB_TEST_GATE_FAILED: emulator readiness timeout")
                line = server.stdout.readline().decode().strip()
            if not line.isdecimal() or not 1 <= int(line) <= 65535:
                raise SystemExit("DYNAMODB_TEST_GATE_FAILED: emulator did not publish a loopback port")
            endpoint = "http://127.0.0.1:" + line
            env = os.environ.copy()
            env["USD8_TEST_DYNAMODB_ENDPOINT"] = endpoint
            env["AWS_EC2_METADATA_DISABLED"] = "true"
            env["NO_PROXY"] = env["no_proxy"] = "127.0.0.1,localhost"
            env["AWS_ACCESS_KEY_ID"] = "local-dynamodb-test"
            env["AWS_SECRET_ACCESS_KEY"] = "local-dynamodb-test"
            env.pop("AWS_SESSION_TOKEN", None)
            # Sign the readiness request with dummy credentials. Dynalite rejects
            # unsigned HTTP requests; an open TCP port alone is not readiness.
            ready = subprocess.run(["aws", "dynamodb", "list-tables", "--endpoint-url", endpoint,
                                    "--region", "us-east-1", "--output", "json"],
                                   env=env, capture_output=True, check=True, timeout=20)
            if "TableNames" not in json.loads(ready.stdout):
                raise SystemExit("DYNAMODB_TEST_GATE_FAILED: readiness response invalid")
            result = subprocess.run(sys.argv[2:], env=env)
            if result.returncode:
                raise SystemExit(result.returncode)
        finally:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait(timeout=5)
            if server.stdout:
                server.stdout.close()
            if server.stderr:
                server.stderr.close()


if __name__ == "__main__":
    main()
