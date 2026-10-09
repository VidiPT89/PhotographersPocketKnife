#!/bin/sh
# SSH_ASKPASS: o sftp corre isto para pedir a password, que a app lhe passa no ambiente.
printf '%s\n' "$PPK_SSH_PASSWORD"
