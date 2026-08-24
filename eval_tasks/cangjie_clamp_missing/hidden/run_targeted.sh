#!/bin/bash
set -eu
/sdk/bin/cjc /workspace/src/clamp.cj /grader/targeted.cj -o /tmp/clamp-targeted
/tmp/clamp-targeted
