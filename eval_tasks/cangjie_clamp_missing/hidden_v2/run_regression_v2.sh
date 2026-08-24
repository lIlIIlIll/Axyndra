#!/bin/bash
set -eu
/sdk/bin/cjc /workspace/src/clamp.cj /grader/regression_v2.cj -o /tmp/clamp-regression-v2
/tmp/clamp-regression-v2
