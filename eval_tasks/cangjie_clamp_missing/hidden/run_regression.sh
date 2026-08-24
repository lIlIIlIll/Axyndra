#!/bin/bash
set -eu
/sdk/bin/cjc /workspace/src/clamp.cj /grader/regression.cj -o /tmp/clamp-regression
/tmp/clamp-regression
