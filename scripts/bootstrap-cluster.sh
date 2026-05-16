#!/usr/bin/env bash
set -euo pipefail

inventory="${ANSIBLE_INVENTORY:-ansible/inventory/hosts.ini}"

ansible-playbook -i "${inventory}" ansible/site.yml "$@"

