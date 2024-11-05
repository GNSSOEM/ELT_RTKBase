#!/bin/bash

sudo apt -q -y update && sudo apt -q -y upgrade && sudo apt -q -y autoremove --purge && sudo apt -q -u clean
