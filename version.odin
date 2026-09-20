// The single source of truth for the app version. `install.sh`, `release.sh`,
// and the updater all read this constant (the scripts parse this file), and the
// bundle's Info.plist is stamped from it, so the version reported by
// `--version`, the version in the installed bundle, and the release tag cannot
// drift apart.

package activity_monitor

VERSION :: "1.1.1"
