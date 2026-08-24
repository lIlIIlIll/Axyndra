#!/bin/bash
set -eu
/sdk/bin/cjc /workspace/src/midpoint.cj /grader/targeted.cj -o /tmp/midpoint-targeted
/tmp/midpoint-targeted
