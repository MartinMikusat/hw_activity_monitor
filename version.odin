// A packaged release is built with these (scripts/release_macos.py compiles them
// in through build.sh); every other build reports "dev" and never updates.

package activity_monitor

UPDATE_VERSION :: #config(HW_UPDATE_VERSION, "")
UPDATE_FEED_URL :: #config(HW_UPDATE_FEED_URL, "")
UPDATE_TEAM_ID :: #config(HW_UPDATE_TEAM_ID, "")

when UPDATE_VERSION != "" {
	VERSION :: UPDATE_VERSION
} else {
	VERSION :: "dev"
}
