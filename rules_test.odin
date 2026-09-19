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
test_group_samples_aggregate_by_name :: proc(t: ^testing.T) {
	samples := []Process_Sample{
		{pid = 1, name = "hw_clay", cpu_fraction = 0.8, memory_bytes = 1 << 30},
		{pid = 2, name = "hw_clay", cpu_fraction = 0.8, memory_bytes = 1 << 30},
		{pid = 3, name = "hw_clay", cpu_fraction = 0.8, memory_bytes = 2 << 30},
		{pid = 4, name = "Brave Browser Helper", cpu_fraction = 0.1, memory_bytes = 1 << 28},
	}
	groups := group_samples(samples)
	defer free_all(context.temp_allocator)
	testing.expect_value(t, len(groups), 2)
	testing.expect_value(t, groups[0].name, "hw_clay")
	testing.expect_value(t, groups[0].count, 3)
	testing.expect(t, abs(groups[0].cpu_percent - 240) < 0.001, "same-name processes must sum")
	testing.expect_value(t, groups[0].memory_bytes, u64(4 << 30))
	testing.expect_value(t, groups[1].count, 1)
	testing.expect_value(t, groups[1].memory_bytes, u64(1 << 28))
}

@(test)
test_alert_requires_sustained_window :: proc(t: ^testing.T) {
	tracker: Tracker
	defer tracker_destroy(&tracker)
	defer free_all(context.temp_allocator)
	policy := test_policy()
	hot := []Group_Sample{{name = "hw_clay", count = 3, cpu_percent = 240}}

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
	hot := []Group_Sample{{name = "hw_clay", count = 1, cpu_percent = 90}}

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
	hot := []Group_Sample{{name = "hw_clay", count = 1, cpu_percent = 90}}
	cool := []Group_Sample{{name = "hw_clay", count = 1, cpu_percent = 10}}

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

	below := []Group_Sample{{name = "hw_clay", count = 1, cpu_percent = 59}}
	testing.expect_value(t, len(tracker_evaluate(&tracker, below, tick_at(9999), policy)), 0)

	compiler := []Group_Sample{{name = "swiftc-frontend", count = 1, cpu_percent = 900}}
	testing.expect_value(t, len(tracker_evaluate(&tracker, compiler, tick_at(9999), policy)), 0)

	testing.expect(t, policy_safelisted("some-odin-wrapper", policy.safelist), "substring match")
	testing.expect(t, !policy_safelisted("hw_clay", policy.safelist), "unrelated names stay watched")
}

@(test)
test_memory_alert_requires_sustained_window :: proc(t: ^testing.T) {
	tracker: Tracker
	defer tracker_destroy(&tracker)
	defer free_all(context.temp_allocator)
	policy := test_policy()
	policy.memory_bytes = 2 << 30
	hot := []Group_Sample{{name = "leak", count = 2, cpu_percent = 0.1, memory_bytes = 3 << 30}}

	testing.expect_value(t, len(tracker_evaluate(&tracker, hot, tick_at(0), policy)), 0)
	testing.expect_value(t, len(tracker_evaluate(&tracker, hot, tick_at(299), policy)), 0)
	alerts := tracker_evaluate(&tracker, hot, tick_at(300), policy)
	testing.expect_value(t, len(alerts), 1)
	testing.expect_value(t, alerts[0].kind, Alert_Kind.Memory)
	testing.expect_value(t, alerts[0].count, 2)
	testing.expect_value(t, alerts[0].memory_bytes, u64(3 << 30))
	testing.expect(t, abs(time.duration_seconds(alerts[0].sustained) - 300) < 0.001)
}

@(test)
test_memory_alerts_disabled_at_zero_budget :: proc(t: ^testing.T) {
	tracker: Tracker
	defer tracker_destroy(&tracker)
	defer free_all(context.temp_allocator)
	policy := test_policy() // memory_bytes stays 0: memory alerts are off
	leak := []Group_Sample{{name = "leak", count = 1, memory_bytes = 64 << 30}}

	testing.expect_value(t, len(tracker_evaluate(&tracker, leak, tick_at(9999), policy)), 0)
	testing.expect_value(t, len(tracker.episodes_memory), 0)
}

@(test)
test_memory_and_cpu_episodes_are_independent :: proc(t: ^testing.T) {
	tracker: Tracker
	defer tracker_destroy(&tracker)
	defer free_all(context.temp_allocator)
	policy := test_policy()
	policy.memory_bytes = 1 << 30
	cpu_hot := []Group_Sample{{name = "hog", count = 1, cpu_percent = 90}}
	memory_hot := []Group_Sample{{name = "hog", count = 1, cpu_percent = 1, memory_bytes = 2 << 30}}

	// The memory episode starts while the group is CPU-quiet, then is dropped
	// when the group falls below the memory budget at tick 100.
	testing.expect_value(t, len(tracker_evaluate(&tracker, memory_hot, tick_at(0), policy)), 0)
	testing.expect_value(t, len(tracker.episodes_memory), 1)
	testing.expect_value(t, len(tracker_evaluate(&tracker, cpu_hot, tick_at(100), policy)), 0)
	testing.expect_value(t, len(tracker.episodes_memory), 0)
	testing.expect_value(t, len(tracker.episodes_cpu), 1)

	// CPU sustains on its own clock to its first alert.
	alerts := tracker_evaluate(&tracker, cpu_hot, tick_at(400), policy)
	testing.expect_value(t, len(alerts), 1)
	testing.expect_value(t, alerts[0].kind, Alert_Kind.CPU)

	// Rising on memory again starts a fresh memory episode, so the memory
	// alert waits its own full window.
	testing.expect_value(t, len(tracker_evaluate(&tracker, memory_hot, tick_at(500), policy)), 0)
	testing.expect_value(t, len(tracker_evaluate(&tracker, memory_hot, tick_at(799), policy)), 0)
	alerts = tracker_evaluate(&tracker, memory_hot, tick_at(800), policy)
	testing.expect_value(t, len(alerts), 1)
	testing.expect_value(t, alerts[0].kind, Alert_Kind.Memory)
}

@(test)
test_memory_safelist_and_cooldown :: proc(t: ^testing.T) {
	tracker: Tracker
	defer tracker_destroy(&tracker)
	defer free_all(context.temp_allocator)
	policy := test_policy()
	policy.memory_bytes = 1 << 30
	policy.safelist = {"odin"}

	exempt := []Group_Sample{{name = "odin-compiler", count = 1, memory_bytes = 8 << 30}}
	testing.expect_value(t, len(tracker_evaluate(&tracker, exempt, tick_at(9999), policy)), 0)

	leak := []Group_Sample{{name = "leak", count = 1, memory_bytes = 8 << 30}}
	testing.expect_value(t, len(tracker_evaluate(&tracker, leak, tick_at(0), policy)), 0)
	testing.expect_value(t, len(tracker_evaluate(&tracker, leak, tick_at(300), policy)), 1)
	testing.expect_value(t, len(tracker_evaluate(&tracker, leak, tick_at(600), policy)), 0)   // cooldown
	testing.expect_value(t, len(tracker_evaluate(&tracker, leak, tick_at(2100), policy)), 1) // cooldown over
}

@(test)
test_alert_text_names_the_condition :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	pids := make([dynamic]i32, 0, 2, context.temp_allocator)
	append(&pids, 11, 12)

	cpu_alert := Alert{
		kind         = .CPU,
		name         = "hw_clay",
		count        = 2,
		cpu_percent  = 240,
		memory_bytes = 3 << 30,
		sustained    = 300 * time.Second,
		pids         = pids,
	}
	testing.expect_value(t, alert_title(cpu_alert), "Runaway process")
	testing.expect_value(
		t,
		alert_description(cpu_alert),
		"hw_clay — 2 processes at 240% CPU and 3.00 GB memory for 5 min (pids 11, 12)",
	)

	memory_alert := cpu_alert
	memory_alert.kind = .Memory
	testing.expect_value(t, alert_title(memory_alert), "Runaway memory")
	testing.expect_value(
		t,
		alert_description(memory_alert),
		"hw_clay — 2 processes at 3.00 GB memory for 5 min (pids 11, 12)",
	)
	testing.expect_value(t, alert_kind_text(.CPU), "cpu")
	testing.expect_value(t, alert_kind_text(.Memory), "memory")
}
