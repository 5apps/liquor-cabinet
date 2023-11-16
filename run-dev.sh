#!/bin/bash

RACK_ENV=development \
REDIS_HOST=localhost \
REDIS_PORT=6379 \
REDIS_DB=1 \
S3_ENDPOINT='http://localhost:9000' \
S3_ACCESS_KEY='dev-key' \
S3_SECRET_KEY='123456789' \
S3_BUCKET=remotestorage \
bundle exec rackup -p 4567
