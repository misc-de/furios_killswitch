#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
set -euo pipefail

systemctl --user disable --now killswitch-indicator.service 2>/dev/null || true
rm -f "$HOME/.local/bin/killswitch-indicator"
rm -f "$HOME/.config/systemd/user/killswitch-indicator.service"
rm -rf "$HOME/.local/share/doc/killswitch-indicator"
systemctl --user daemon-reload
echo "Removed."
