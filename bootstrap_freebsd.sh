#!/bin/sh
pkg update
pkg install -y go
go run freebsd_install.go
