[![Build Status](https://secure.travis-ci.org/5apps/liquor-cabinet.png?branch=master)](http://travis-ci.org/5apps/liquor-cabinet)

# Liquor Cabinet

Liquor Cabinet is where Frank stores all his stuff. It's a
remoteStorage-compatible storage provider API, based on Sinatra and currently
using Riak as backend. You can use it on its own, or e.g. mount it from a Rails
application.

It's merely implementing the storage API, not including the Webfinger and OAuth
parts of remoteStorage. You have to set the authorization keys/values in the
database yourself.

If you have any questions about this thing, drop by #remotestorage on Freenode, and
we'll happily answer them.

## Contributing

We love pull requests. If you want to submit a patch:

* Fork the project.
* Make your feature addition or bug fix.
* Write specs for it. This is important so nobody breaks it in a future version unintentionally.
* Push to your fork and send a pull request.
