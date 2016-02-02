development: &defaults
  maintenance: false
  # riak: &riak_defaults
  #   host: localhost
  #   http_port: 8098
  #   riak_cs:
  #     credentials_file: "cs_credentials.json"
  #     endpoint: "http://cs.example.com:8080"
  #   buckets:
  #     data: rs_data
  #     directories: rs_directories
  #     binaries: rs_binaries
  #     cs_binaries: rs.binaries
  #     authorizations: rs_authorizations
  #     opslog: rs_opslog
  # # uncomment this section and comment the riak one
  # swift: &swift_defaults
  #   host: "https://swift.example.com"
  # # Redis is needed for the swift backend
  # redis:
  #   host: localhost
  #   port: 6379

test:
  <<: *defaults
  # riak:
  #   <<: *riak_defaults
  #   buckets:
  #     data: rs_data_test
  #     directories: rs_directories_test
  #     binaries: rs_binaries_test
  #     cs_binaries: rs.binaries.test
  #     authorizations: rs_authorizations_test
  #     opslog: rs_opslog_test
  swift:
    host: "https://swift.example.com"
  redis:
    host: localhost
    port: 6379

staging:
  <<: *defaults

production:
  <<: *defaults
