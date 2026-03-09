<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>__LABEL__</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>__REPO_DIR__/.claude/quality-worker/run.sh</string>
    </array>

    <key>WorkingDirectory</key>
    <string>__REPO_DIR__</string>

    <!-- Run daily at the configured time -->
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>__HOUR__</integer>
        <key>Minute</key>
        <integer>__MINUTE__</integer>
    </dict>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>HOME</key>
        <string>__HOME__</string>
        <key>LANG</key>
        <string>en_US.UTF-8</string>
    </dict>

    <key>StandardOutPath</key>
    <string>__REPO_DIR__/.claude/quality-worker/logs/launchd-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>__REPO_DIR__/.claude/quality-worker/logs/launchd-stderr.log</string>

    <key>KeepAlive</key>
    <false/>

    <key>TimeOut</key>
    <integer>__TIMEOUT__</integer>
</dict>
</plist>
