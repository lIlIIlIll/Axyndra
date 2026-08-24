#!/bin/bash
set -eu
/sdk/bin/cjc /workspace/src/midpoint.cj /grader/targeted_v2.cj -o /tmp/midpoint-targeted-v2
/tmp/midpoint-targeted-v2
