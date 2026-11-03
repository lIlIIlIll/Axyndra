package agent_testkit

import model_fixture_runtime as fixture
import agent_ports as ports

// Preserve the internal fixture API while Product no longer imports this testkit.
public type FixtureModelPort = fixture.FixtureModelPort

public func fixtureModelPort(): ports.ModelPort { FixtureModelPort() }
public func primaryFixtureModelPort(): ports.ModelPort { FixtureModelPort(failFirst: true) }
