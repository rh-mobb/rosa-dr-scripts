#!/usr/bin/env sh

# Source this file from bash or zsh. It defines validation helpers only; it does
# not contact AWS or either cluster until one of the functions is called.

stop_here() {
  echo "$1"
  return 1 2>/dev/null || false
}
