[![Build Status](https://drone.kosmos.org/api/badges/5apps/liquor-cabinet/status.svg)](https://drone.kosmos.org/5apps/liquor-cabinet)

# Liquor Cabinet

Liquor Cabinet is where Frank stores all his stuff. It's a
[remoteStorage](https://remotestorage.io) HTTP API, based on Sinatra. The
metadata and OAuth tokens are stored in Redis, and
documents/files can be stored in anything that supports
the S3 object storage API.

Liquor Cabinet only implements the storage API part of the remoteStorage
protocol, but does not include the Webfinger and OAuth parts. It is meant to be
added to existing systems and user accounts, so you will have to add your own
OAuth dialog for remoteStorage authorizations and persist the tokens in Redis.

There is an [open-source accounts management
app](https://gitea.kosmos.org/kosmos/akkounts/) by the Kosmos project, which
comes with a built-in remoteStorage dashboard and is compatible with Liquor
Cabinet.

If you have any questions about this program, please [post to the RS
forums](https://community.remotestorage.io/c/server-development), and we'll
gladly answer them.

## System requirements

* [Ruby](https://www.ruby-lang.org/en/) and [Bundler](https://bundler.io/)
* [Redis](https://redis.io/)
* S3-compatible object storage (e.g. [Garage](https://garagehq.deuxfleurs.fr/)
  or [MinIO](https://min.io/) for self-hosting)

## Setup

1. Check the `config.yml.erb.example` file. Either copy it to `config.yml.erb`
   and use the enviroment variables it contains, or create/deploy your own
   config YAML file with custom values.
2. Install dependencies: `bundle install`

## Development

Running the test suite:

    bundle exec rake test

Running the app:

    bundle exec rainbows

## Deployment

_TODO document options_

## Contributing

We love pull requests. If you want to submit a patch:

* Fork the project.
* Make your feature addition or bug fix.
* Write specs for it. This is important so nobody breaks it in a future version.
* Push to your fork and send a pull request.
