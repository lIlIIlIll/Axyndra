#!/bin/bash
set -eu
/sdk/bin/cjc /workspace/src/midpoint.cj /grader/regression.cj -o /tmp/midpoint-regression
/tmp/midpoint-regression
