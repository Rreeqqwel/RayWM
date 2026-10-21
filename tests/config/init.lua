-- Smoke-test config: logs compositor events to $RAYWM_TEST_OUT and runs
-- the shipped tiling plugin (copied from config/plugins by smoke.sh).
raywm.load("eventlog")
raywm.load("tiling")
