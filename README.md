[![Build Status](https://github.com/5apps/liquor-cabinet/actions/workflows/ruby.yml/badge.svg)](https://github.com/5apps/liquor-cabinet/actions/workflows/ruby.yml)

# Liquor Cabinet

Liquor Cabinet is where Frank stores all his stuff. It's a
[remoteStorage](https://remotestorage.io) HTTP API, based on Sinatra. The
metadata and OAuth tokens are stored in Redis, and documents can be stored in
anything that supports the storage API of either Openstack Swift or Amazon S3.

Liquor Cabinet only implements the storage API part of the remoteStorage
protocol, but does not include the Webfinger and OAuth parts. It is meant to be
added to existing systems and user accounts, so you will have to add your own
OAuth dialog for remoteStorage authorizations and persist the tokens in Redis.

If you have any questions about this program, drop by #remotestorage on
Freenode, or [post to the RS
forums](https://community.remotestorage.io/c/server-development), and we'll
happily answer them.

## Contributing

We love pull requests. If you want to submit a patch:

* Fork the project.
* Make your feature addition or bug fix.
* Write specs for it. This is important so nobody breaks it in a future version unintentionally.
* Push to your fork and send a pull request.
