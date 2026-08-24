#!/bin/bash
set -eu
/sdk/bin/cjc /workspace/src/midpoint.cj /grader/regression_v2.cj -o /tmp/midpoint-regression-v2
/tmp/midpoint-regression-v2
