package activity_monitor

import "core:testing"

@(test)
test_process_detail_text :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	testing.expect_value(t, process_detail_text("python3.12", {"python3.12", "/srv/app/worker.py", "--fast"}, "app"), "app/worker.py (app)")
	testing.expect_value(t, process_detail_text("python3.12", {"python3.12", "-m", "http.server"}, ""), "-m http.server")
	testing.expect_value(t, process_detail_text("node", {"node", "--inspect", "/p/web/server.js"}, "web"), "web/server.js (web)")
	testing.expect_value(t, process_detail_text("2.1.289", {"claude"}, "proj"), "claude (proj)")
	testing.expect_value(t, process_detail_text("Brave Browser Helper", {"/A/Brave Browser Helper", "--type=utility", "--utility-sub-type=network.mojom.NetworkService"}, ""), "NetworkService")
	testing.expect_value(t, process_detail_text("Brave Browser Helper (Renderer)", {"/A/Brave Browser Helper (Renderer)", "--type=renderer"}, ""), "")
	testing.expect_value(t, process_detail_text("ghostty", {"/Applications/Ghostty.app/Contents/MacOS/ghostty"}, ""), "")
}
