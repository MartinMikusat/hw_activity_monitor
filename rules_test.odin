// Rule engine tests with a synthetic clock: no sampling, no I/O.

package activity_monitor

import "core:testing"
import "core:time"

tick_at :: proc(seconds: f64) -> time.Tick {
	return time.tick_add(time.Tick{}, time.Duration(i64(seconds * 1e9)))
}

test_policy :: proc() -> Policy {
	return {
		cpu_percent = 60,
		sustained   = 300 * time.Second,
		cooldown    = 1800 * time.Second,
	}
}

@(test)
test_group_cpu_aggregates_by_name :: proc(t: ^testing.T) {
	samples := []Process_Cpu{
		{pid = 1, name = "hw_clay", cpu_fraction = 0.8},
		{pid = 2, name = "hw_clay", cpu_fraction = 0.8},
		{pid = 3, name = "hw_clay", cpu_fraction = 0.8},
		{pid = 4, name = "Brave Browser Helper", cpu_fraction = 0.1},
	}
	groups := group_cpu(samples)
	defer free_all(context.temp_allocator)
	testing.expect_value(t, len(groups), 2)
	testing.expect_value(t, groups[0].name, "hw_clay")
	testing.expect_value(t, groups[0].count, 3)
	testing.expect(t, abs(groups[0].cpu_percent - 240) < 0.001, "same-name processes must sum")
	testing.expect_value(t, groups[1].count, 1)
}

@(test)
test_alert_requires_sustained_window :: proc(t: ^testing.T) {
	tracker: Tracker
	defer tracker_destroy(&tracker)
	defer free_all(context.temp_allocator)
	policy := test_policy()
	hot := []Group_Cpu{{name = "hw_clay", count = 3, cpu_percent = 240}}

	testing.expect_value(t, len(tracker_evaluate(&tracker, hot, tick_at(0), policy)), 0)
	testing.expect_value(t, len(tracker_evaluate(&tracker, hot, tick_at(299), policy)), 0)
	alerts := tracker_evaluate(&tracker, hot, tick_at(300), policy)
	testing.expect_value(t, len(alerts), 1)
	testing.expect_value(t, alerts[0].name, "hw_clay")
	testing.expect_value(t, alerts[0].count, 3)
	testing.expect(t, abs(time.duration_seconds(alerts[0].sustained) - 300) < 0.001)
}

@(test)
test_alert_respects_cooldown :: proc(t: ^testing.T) {
	tracker: Tracker
	defer tracker_destroy(&tracker)
	defer free_all(context.temp_allocator)
	policy := test_policy()
	hot := []Group_Cpu{{name = "hw_clay", count = 1, cpu_percent = 90}}

	testing.expect_value(t, len(tracker_evaluate(&tracker, hot, tick_at(0), policy)), 0) // episode starts
	testing.expect_value(t, len(tracker_evaluate(&tracker, hot, tick_at(300), policy)), 1) // sustained
	testing.expect_value(t, len(tracker_evaluate(&tracker, hot, tick_at(600), policy)), 0) // cooldown
	testing.expect_value(t, len(tracker_evaluate(&tracker, hot, tick_at(2099), policy)), 0)
	testing.expect_value(t, len(tracker_evaluate(&tracker, hot, tick_at(2100), policy)), 1)
}

@(test)
test_episode_resets_after_drop :: proc(t: ^testing.T) {
	tracker: Tracker
	defer tracker_destroy(&tracker)
	defer free_all(context.temp_allocator)
	policy := test_policy()
	hot := []Group_Cpu{{name = "hw_clay", count = 1, cpu_percent = 90}}
	cool := []Group_Cpu{{name = "hw_clay", count = 1, cpu_percent = 10}}

	testing.expect_value(t, len(tracker_evaluate(&tracker, hot, tick_at(0), policy)), 0)
	testing.expect_value(t, len(tracker_evaluate(&tracker, cool, tick_at(100), policy)), 0)
	testing.expect_value(t, len(tracker_evaluate(&tracker, hot, tick_at(200), policy)), 0)

	testing.expect_value(t, len(tracker_evaluate(&tracker, hot, tick_at(400), policy)), 0)
	alerts := tracker_evaluate(&tracker, hot, tick_at(500), policy)
	testing.expect_value(t, len(alerts), 1)
	testing.expect(t, abs(time.duration_seconds(alerts[0].sustained) - 300) < 0.001, "clock restarts at the drop")
}

@(test)
test_safelist_and_budget :: proc(t: ^testing.T) {
	tracker: Tracker
	defer tracker_destroy(&tracker)
	defer free_all(context.temp_allocator)
	policy := test_policy()
	policy.safelist = {"odin", ""}

	below := []Group_Cpu{{name = "hw_clay", count = 1, cpu_percent = 59}}
	testing.expect_value(t, len(tracker_evaluate(&tracker, below, tick_at(9999), policy)), 0)

	compiler := []Group_Cpu{{name = "swiftc-frontend", count = 1, cpu_percent = 900}}
	testing.expect_value(t, len(tracker_evaluate(&tracker, compiler, tick_at(9999), policy)), 0)

	testing.expect(t, policy_safelisted("some-odin-wrapper", policy.safelist), "substring match")
	testing.expect(t, !policy_safelisted("hw_clay", policy.safelist), "unrelated names stay watched")
}
