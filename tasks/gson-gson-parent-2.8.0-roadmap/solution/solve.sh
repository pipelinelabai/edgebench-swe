#!/bin/bash
cd /app
git apply /solution/changes.patch
# Warm the compiled classes so the subsequent test.sh phase invocations do less work.
mvn -pl gson compile -q 2>/dev/null || true
