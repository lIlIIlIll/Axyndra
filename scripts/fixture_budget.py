"""Execution caps for the complete sequential Memory package fixture.

Cleanup/reaping is separately bounded by the dedicated process watcher. The
metadata allowance never extends a child command's original execution cap.
"""
MEMORY_STAGE_SECONDS = {'build': 900, 'unit': 900, 'protocol': 240}
FIXTURE_METADATA_SECONDS = 60
MEMORY_FIXTURE_SECONDS = sum(MEMORY_STAGE_SECONDS.values()) + FIXTURE_METADATA_SECONDS
