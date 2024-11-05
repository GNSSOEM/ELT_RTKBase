#!/bin/bash

sudo apt remove -y tailscale
sudo rm -f /var/lib/tailscale/tailscaled.state
