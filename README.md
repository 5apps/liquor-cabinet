# Liquor Cabinet

Liquor Cabinet is where Frank stores all his stuff. It's a
remoteStorage-compatible storage provider API, based on Sinatra and currently
using Riak as backend. You can use it on its own, or e.g. mount it from a Rails
application.

It's merely implementing the storage API, not including the Webfinger and Oauth
parts of remoteStorage. You have to set the authorization keys/values in the
database yourself.

If you have any questions about this thing, drop by #unhosted on Freenode, and
we'll happily answer them.
