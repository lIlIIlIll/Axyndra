#!/bin/bash
set -eu
/sdk/bin/cjc /workspace/src/clamp.cj /grader/targeted_v2.cj -o /tmp/clamp-targeted-v2
/tmp/clamp-targeted-v2
