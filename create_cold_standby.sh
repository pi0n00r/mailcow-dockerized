#!/bin/bash

export REMOTE_SSH_KEY=/home/myremoteuser/.ssh/id_rsa
export REMOTE_SSH_PORT=22
export REMOTE_SSH_HOST=my.remote.host
export REMOTE_SSH_USER=myremoteuser

/opt/mailcow-dockerized/helper-scripts/_cold-standby.sh
